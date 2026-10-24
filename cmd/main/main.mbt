///|
/// Async command-line entry point for local repository operations.
async fn main {
  let raw = @env.args()
  let args = if raw.length() > 0 { raw[1:].to_owned() } else { [] }
  run(args) catch {
    @snapshot.SnapshotError::SnapshotError(message) => {
      println("error: " + message)
      panic()
    }
  }
}

///|
async fn run(args : Array[String]) -> Unit raise @snapshot.SnapshotError {
  if args.length() == 0 ||
    args[0] == "help" ||
    args[0] == "--help" ||
    args[0] == "-h" {
    print_usage()
    return
  }
  match args[0] {
    "init" => {
      require_count(args, 2)
      @snapshot.init_repository(args[1])
      println("repository initialized: " + args[1])
    }
    "snapshot" => run_snapshot(args)
    "list" => {
      require_count(args, 2)
      let snapshots = @snapshot.list_repository_snapshots(args[1])
      if snapshots.length() == 0 {
        println("no snapshots")
      }
      for item in snapshots {
        print_summary(item)
      }
    }
    "show" => {
      require_count(args, 3)
      let manifest = @snapshot.read_repository_manifest(args[1], args[2])
      println("id: " + manifest.id)
      println("root: " + manifest.root_name)
      let kind = if manifest.root_is_file { "file" } else { "directory" }
      println("kind: " + kind)
      println("files: \{manifest.files.length()}")
      println("directories: \{manifest.directories.length()}")
      println("bytes: \{manifest.total_size}")
      println(
        "chunk settings: \{manifest.config.min}/\{manifest.config.average}/\{manifest.config.max}",
      )
      for file in manifest.files {
        println(
          "  \{file.path}  \{file.size} bytes  \{file.chunks.length()} chunks",
        )
      }
    }
    "verify" => {
      guard args.length() == 2 || args.length() == 3 else {
        raise @snapshot.SnapshotError(
          "usage: verify <repository> [snapshot-id]",
        )
      }
      if args.length() == 2 {
        let summaries = @snapshot.verify_entire_repository(args[1])
        println("verified \{summaries.length()} snapshots")
        for item in summaries {
          print_summary(item)
        }
      } else {
        let summary = @snapshot.verify_repository_snapshot(args[1], args[2])
        println("verified snapshot")
        print_summary(summary)
      }
    }
    "restore" => {
      require_count(args, 4)
      @snapshot.restore_repository_snapshot(args[1], args[2], args[3])
      println("restored to: " + args[3])
    }
    "compare" => {
      require_count(args, 4)
      let result = @snapshot.compare_repository_snapshots(
        args[1],
        args[2],
        args[3],
      )
      println(
        "added: \{result.added.length()} files, \{result.added_bytes} bytes",
      )
      for path in result.added {
        println("  + " + path)
      }
      println(
        "removed: \{result.removed.length()} files, \{result.removed_bytes} bytes",
      )
      for path in result.removed {
        println("  - " + path)
      }
      println(
        "changed: \{result.changed.length()} files, \{result.changed_bytes} bytes",
      )
      for path in result.changed {
        println("  * " + path)
      }
      println(
        "unchanged: \{result.unchanged.length()} files, \{result.unchanged_bytes} bytes",
      )
      println("reused chunk bytes: \{result.reused_chunk_bytes}")
      println("new chunk bytes: \{result.new_chunk_bytes}")
    }
    "stats" => {
      require_count(args, 2)
      let stats = @snapshot.inspect_repository(args[1])
      println("snapshots: \{stats.snapshot_count}")
      println("files: \{stats.file_count}")
      println("directories: \{stats.directory_count}")
      println("logical bytes: \{stats.logical_bytes}")
      println("referenced chunks: \{stats.referenced_chunk_count}")
      println("referenced chunk bytes: \{stats.referenced_chunk_bytes}")
      println("stored objects: \{stats.object_count}")
      println("stored bytes: \{stats.object_bytes}")
      println("orphan objects: \{stats.orphan_object_count}")
      println("orphan bytes: \{stats.orphan_object_bytes}")
      println("missing objects: \{stats.missing_object_count}")
      println("size mismatches: \{stats.size_mismatch_count}")
    }
    "gc" => {
      guard args.length() == 2 || (args.length() == 3 && args[2] == "--apply") else {
        raise @snapshot.SnapshotError("usage: gc <repository> [--apply]")
      }
      let apply = args.length() == 3
      let report = @snapshot.garbage_collect(args[1], apply)
      if apply {
        println(
          "removed \{report.removed_count} objects (\{report.removed_bytes} bytes) and \{report.removed_temporary_count} temporary files (\{report.removed_temporary_bytes} bytes)",
        )
      } else {
        println(
          "preview: \{report.candidate_count} orphan objects (\{report.candidate_bytes} bytes), \{report.temporary_count} temporary files (\{report.temporary_bytes} bytes)",
        )
        println("pass --apply to remove these objects and temporary files")
      }
      for digest in report.candidates {
        println("  " + digest)
      }
      for name in report.temporary_files {
        println("  tmp/" + name)
      }
    }
    "forget" => {
      guard args.length() == 3 || (args.length() == 4 && args[3] == "--apply") else {
        raise @snapshot.SnapshotError(
          "usage: forget <repository> <snapshot-id> [--apply]",
        )
      }
      let apply = args.length() == 4
      let result = @snapshot.forget_snapshot(args[1], args[2], apply)
      if apply {
        println(
          "forgot snapshot \{result.id}; \{result.file_count} files, \{result.logical_bytes} bytes",
        )
      } else {
        println(
          "preview: snapshot \{result.id} has \{result.file_count} files, \{result.logical_bytes} bytes",
        )
        println(
          "pass --apply to remove its manifest; unreferenced objects remain until gc",
        )
      }
    }
    _ => raise @snapshot.SnapshotError("unknown command: " + args[0])
  }
}

///|
async fn run_snapshot(
  args : Array[String],
) -> Unit raise @snapshot.SnapshotError {
  guard args.length() >= 4 else {
    raise @snapshot.SnapshotError(
      "usage: snapshot <repository> <source> <id> [options]",
    )
  }
  let excludes : Array[String] = []
  let mut config = @snapshot.default_config
  let mut skip_symlinks = false
  let mut index = 4
  while index < args.length() {
    match args[index] {
      "--exclude" => {
        guard index + 1 < args.length() else {
          raise @snapshot.SnapshotError("--exclude requires a glob pattern")
        }
        excludes.push(args[index + 1])
        index += 2
      }
      "--skip-symlinks" => {
        skip_symlinks = true
        index += 1
      }
      "--min" => {
        guard index + 1 < args.length() else {
          raise @snapshot.SnapshotError("--min requires a byte count")
        }
        config = {
          min: parse_chunk_size(args[index + 1]),
          average: config.average,
          max: config.max,
        }
        index += 2
      }
      "--average" => {
        guard index + 1 < args.length() else {
          raise @snapshot.SnapshotError("--average requires a byte count")
        }
        config = {
          min: config.min,
          average: parse_chunk_size(args[index + 1]),
          max: config.max,
        }
        index += 2
      }
      "--max" => {
        guard index + 1 < args.length() else {
          raise @snapshot.SnapshotError("--max requires a byte count")
        }
        config = {
          min: config.min,
          average: config.average,
          max: parse_chunk_size(args[index + 1]),
        }
        index += 2
      }
      _ =>
        raise @snapshot.SnapshotError("unknown snapshot option: " + args[index])
    }
  }
  let summary = @snapshot.create_snapshot(
    args[1],
    args[2],
    args[3],
    config~,
    excludes~,
    skip_symlinks~,
  )
  println("snapshot created")
  print_summary(summary)
}

///|
fn parse_chunk_size(value : String) -> Int32 raise @snapshot.SnapshotError {
  let parsed = @json.parse(value) catch {
    _ => raise @snapshot.SnapshotError("chunk sizes must be positive integers")
  }
  let size : Int32 = @json.from_json(parsed) catch {
    _ =>
      raise @snapshot.SnapshotError("chunk sizes must fit in a 32-bit integer")
  }
  guard size > 0 else {
    raise @snapshot.SnapshotError("chunk sizes must be positive integers")
  }
  size
}

///|
fn print_summary(item : @snapshot.SnapshotSummary) -> Unit {
  println(
    "\{item.id}: \{item.file_count} files, \{item.directory_count} directories, \{item.total_bytes} bytes, \{item.chunk_count} chunks",
  )
  println(
    "  unique chunks: \{item.unique_chunk_count}, unique chunk bytes: \{item.unique_chunk_bytes}",
  )
}

///|
fn require_count(
  args : Array[String],
  expected : Int32,
) -> Unit raise @snapshot.SnapshotError {
  guard args.length() == expected else {
    raise @snapshot.SnapshotError("wrong number of arguments for " + args[0])
  }
}

///|
fn print_usage() -> Unit {
  println("MoonBit CDC Snapshot — local content-defined snapshots")
  println("Usage: moon run --target native cmd/main -- <command> ...")
  println("")
  println("  init <repository>")
  println(
    "  snapshot <repository> <source-file-or-directory> <id> [--exclude GLOB] [--skip-symlinks] [--min N --average N --max N]",
  )
  println("  list <repository>")
  println("  show <repository> <id>")
  println("  verify <repository> [id]")
  println("  restore <repository> <id> <new-destination>")
  println("  compare <repository> <old-id> <new-id>")
  println("  stats <repository>")
  println("  gc <repository> [--apply]")
  println("  forget <repository> <id> [--apply]")
}
