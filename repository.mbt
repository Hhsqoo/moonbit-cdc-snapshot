///|
/// Create an empty snapshot repository. Re-running init on a valid repository
/// is idempotent; an unrelated non-empty directory is never adopted.
pub async fn init_repository(root : String) -> Unit raise SnapshotError {
  if safe_async_exists(root) {
    guard safe_async_kind(root) is @afs.FileKind::Directory else {
      raise SnapshotError("repository path is not a directory")
    }
    if safe_async_exists(join_path(root, repository_marker)) {
      require_repository(root)
      return
    }
    let contents = safe_readdir(root)
    guard contents.length() == 0 else {
      raise SnapshotError("refusing to initialize a non-empty directory")
    }
  } else {
    @afs.mkdir(root, recursive=true) catch {
      _ => raise SnapshotError("cannot create repository directory")
    }
  }
  ensure_directory(join_path(root, "objects"))
  ensure_directory(join_path(root, "snapshots"))
  ensure_directory(join_path(root, "tmp"))
  let lock = acquire_repository_lock(root)
  defer release_repository_lock(lock)
  let marker_path = join_path(root, repository_marker)
  let marker_tmp = join_path(root, "tmp/repository.json.part")
  @fs.write_string_to_file(marker_tmp, "{\"format\":1}") catch {
    _ => raise SnapshotError("cannot write repository format marker")
  }
  @afs.rename(marker_tmp, marker_path, replace=false) catch {
    _ => raise SnapshotError("cannot publish repository format marker")
  }
}

///|
/// Check the repository marker and required directory layout before any command
/// reads or mutates repository data.
pub async fn require_repository(root : String) -> Unit raise SnapshotError {
  guard safe_async_exists(root) else {
    raise SnapshotError("repository does not exist; run init first")
  }
  guard safe_async_kind(root) is @afs.FileKind::Directory else {
    raise SnapshotError("repository path is not a directory")
  }
  let marker_path = join_path(root, repository_marker)
  guard safe_async_exists(marker_path) else {
    raise SnapshotError("repository marker is missing; run init first")
  }
  let marker = @fs.read_file_to_string(marker_path) catch {
    _ => raise SnapshotError("cannot read repository format marker")
  }
  guard marker == "{\"format\":1}" else {
    raise SnapshotError("repository marker is invalid or unsupported")
  }
  for name in ["objects", "snapshots", "tmp"] {
    let path = join_path(root, name)
    guard safe_async_exists(path) &&
      safe_async_kind(path) is @afs.FileKind::Directory else {
      raise SnapshotError("repository directory is missing or invalid: " + name)
    }
  }
}

///|
/// Read and validate a snapshot manifest from a repository.
pub async fn read_repository_manifest(
  root : String,
  id : String,
) -> SnapshotManifest raise SnapshotError {
  validate_snapshot_id(id)
  require_repository(root)
  let path = snapshot_manifest_path(root, id)
  let size = @afs.file_size(path) catch {
    _ => raise SnapshotError("snapshot manifest does not exist: " + id)
  }
  guard size >= 0L && size <= max_manifest_size.to_int64() else {
    raise SnapshotError("manifest exceeds the 64 MiB size limit")
  }
  let text = @fs.read_file_to_string(path) catch {
    _ => raise SnapshotError("cannot read snapshot manifest: " + id)
  }
  let manifest = SnapshotManifest::from_json(text)
  guard manifest.id == id else {
    raise SnapshotError("manifest id does not match its filename")
  }
  manifest
}

///|
/// List repository snapshot ids in deterministic lexical order.
pub async fn list_snapshot_ids(
  root : String,
) -> Array[String] raise SnapshotError {
  require_repository(root)
  let directory = join_path(root, "snapshots")
  let names = safe_readdir(directory)
  let ids : Array[String] = []
  for name in names {
    guard name.has_suffix(".json") && name.length() > 5 else {
      raise SnapshotError("unexpected entry in snapshots directory: " + name)
    }
    let id = name[:name.length() - 5].to_owned()
    validate_snapshot_id(id)
    guard safe_async_kind(join_path(directory, name)) is @afs.FileKind::Regular else {
      raise SnapshotError("snapshot manifest is not a regular file: " + name)
    }
    ids.push(id)
  }
  ids
}

///|
/// List manifest summaries without reading chunk payloads.
pub async fn list_repository_snapshots(
  root : String,
) -> Array[SnapshotSummary] raise SnapshotError {
  let ids = list_snapshot_ids(root)
  let summaries : Array[SnapshotSummary] = []
  for id in ids {
    let manifest = read_repository_manifest(root, id)
    summaries.push(snapshot_summary(manifest))
  }
  summaries
}

///|
fn snapshot_summary(manifest : SnapshotManifest) -> SnapshotSummary {
  let unique_chunks : @hashmap.HashMap[String, Int32] = HashMap([])
  let mut chunk_count = 0
  for file in manifest.files {
    chunk_count += file.chunks.length()
    for chunk in file.chunks {
      if !unique_chunks.contains(chunk.digest) {
        unique_chunks.set(chunk.digest, chunk.size)
      }
    }
  }
  {
    id: manifest.id,
    file_count: manifest.files.length(),
    directory_count: manifest.directories.length(),
    chunk_count,
    total_bytes: manifest.total_size,
    unique_chunk_count: unique_chunks.length(),
    unique_chunk_bytes: unique_chunk_bytes(unique_chunks),
  }
}

///|
fn snapshot_manifest_path(root : String, id : String) -> String {
  join_path(join_path(root, "snapshots"), id + ".json")
}

///|
let repository_marker : String = ".moonbit-cdc-snapshot"

///|
/// Serialize repository mutations. The advisory lock protects object writes
/// from concurrent garbage collection by another program using this tool.
async fn acquire_repository_lock(
  root : String,
) -> @afs.File raise SnapshotError {
  let file = @afs.open(
    join_path(root, ".lock"),
    mode=@afs.Mode::ReadWrite,
    create_mode=@afs.CreateMode::OpenOrCreate,
  ) catch {
    _ => raise SnapshotError("cannot open repository lock file")
  }
  file.lock(@afs.Lock::Exclusive) catch {
    _ => {
      file.close()
      raise SnapshotError("cannot acquire repository lock")
    }
  }
  file
}

///|
fn release_repository_lock(file : @afs.File) -> Unit {
  file.unlock()
  file.close()
}

///|
async fn safe_async_exists(path : String) -> Bool raise SnapshotError {
  @afs.exists(path) catch {
    _ => raise SnapshotError("cannot inspect path: " + path)
  }
}

///|
async fn safe_async_kind(path : String) -> @afs.FileKind raise SnapshotError {
  @afs.kind(path, follow_symlink=false) catch {
    _ => raise SnapshotError("cannot inspect file type: " + path)
  }
}

///|
async fn safe_readdir(path : String) -> Array[String] raise SnapshotError {
  let names = @afs.readdir(path, include_hidden=true, sort=false) catch {
    _ => raise SnapshotError("cannot read directory: " + path)
  }
  stable_sort_strings(names)
}
