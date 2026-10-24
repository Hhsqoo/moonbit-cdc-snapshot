///|
/// Snapshot a regular file or a directory tree into a repository.
pub async fn create_snapshot(
  root : String,
  source : String,
  id : String,
  config~ : FastCdcConfig = default_config,
  excludes~ : Array[String] = [],
  skip_symlinks~ : Bool = false,
) -> SnapshotSummary raise SnapshotError {
  validate_snapshot_id(id)
  config.validate()
  for pattern in excludes {
    validate_glob(pattern)
  }
  require_repository(root)
  let lock = acquire_repository_lock(root)
  defer release_repository_lock(lock)
  let manifest_path = snapshot_manifest_path(root, id)
  guard !safe_async_exists(manifest_path) else {
    raise SnapshotError("snapshot id already exists: " + id)
  }
  guard !safe_async_exists(join_path(root, "tmp/" + id + ".manifest.part")) else {
    raise SnapshotError(
      "temporary manifest already exists for snapshot id: " + id,
    )
  }
  let source_kind = safe_async_kind(source)
  let root_name = @path.Path(source).basename().to_owned()
  validate_relative_path(root_name)
  let files : Array[FileRecord] = []
  let directories : Array[String] = []
  let unique_chunks : @hashmap.HashMap[String, Int32] = HashMap([])
  match source_kind {
    @afs.FileKind::Regular => {
      if matches_excludes(excludes, root_name) {
        raise SnapshotError("exclude patterns removed the source file")
      }
      files.push(
        snapshot_regular_file(
          root, source, root_name, id, config, unique_chunks,
        ),
      )
    }
    @afs.FileKind::Directory => {
      ensure_repository_outside_source(root, source)
      collect_tree(
        root, source, "", id, config, excludes, skip_symlinks, files, directories,
        unique_chunks,
      )
    }
    @afs.FileKind::SymLink =>
      raise SnapshotError("the snapshot root cannot be a symbolic link")
    _ => raise SnapshotError("source must be a regular file or directory")
  }
  let sorted_files = stable_sort_file_records(files)
  let sorted_directories = stable_sort_strings(directories)
  let mut total_size = 0L
  let mut chunk_count = 0
  for file in files {
    guard file.size <= max_total_bytes - total_size else {
      raise SnapshotError("snapshot exceeds the supported integer range")
    }
    total_size += file.size
    chunk_count += file.chunks.length()
    guard chunk_count <= max_chunk_count else {
      raise SnapshotError("snapshot exceeds the 1,000,000 chunk limit")
    }
  }
  guard files.length() + directories.length() <= max_manifest_entries else {
    raise SnapshotError("snapshot exceeds the 100,000 entry limit")
  }
  let manifest : SnapshotManifest = {
    version: 2,
    id,
    root_name,
    root_is_file: source_kind is @afs.FileKind::Regular,
    config,
    total_size,
    directories: sorted_directories,
    files: sorted_files,
  }
  let json = manifest.to_json()
  guard json.length() <= max_manifest_size else {
    raise SnapshotError("snapshot manifest exceeds the 64 MiB limit")
  }
  write_manifest_atomic(root, id, manifest_path, json)
  {
    id,
    file_count: files.length(),
    directory_count: directories.length(),
    chunk_count,
    total_bytes: total_size,
    unique_chunk_count: unique_chunks.length(),
    unique_chunk_bytes: unique_chunk_bytes(unique_chunks),
  }
}

///|
/// Walk a directory sequentially in sorted order. Symbolic links and special
/// files are never followed. Excluding a directory skips its whole subtree.
async fn collect_tree(
  root : String,
  source_root : String,
  relative_directory : String,
  snapshot_id : String,
  config : FastCdcConfig,
  excludes : Array[String],
  skip_symlinks : Bool,
  files : Array[FileRecord],
  directories : Array[String],
  unique_chunks : @hashmap.HashMap[String, Int32],
) -> Unit raise SnapshotError {
  let absolute_directory = if relative_directory == "" {
    source_root
  } else {
    join_path(source_root, relative_directory)
  }
  let names = safe_readdir(absolute_directory)
  for name in names {
    let relative_path = if relative_directory == "" {
      name
    } else {
      relative_directory + "/" + name
    }
    validate_relative_path(relative_path)
    if matches_excludes(excludes, relative_path) {
      continue
    }
    let absolute_path = join_path(absolute_directory, name)
    match safe_async_kind(absolute_path) {
      @afs.FileKind::Directory => {
        directories.push(relative_path)
        guard files.length() + directories.length() < max_manifest_entries else {
          raise SnapshotError("snapshot exceeds the 100,000 entry limit")
        }
        collect_tree(
          root, source_root, relative_path, snapshot_id, config, excludes, skip_symlinks,
          files, directories, unique_chunks,
        )
      }
      @afs.FileKind::Regular => {
        files.push(
          snapshot_regular_file(
            root, absolute_path, relative_path, snapshot_id, config, unique_chunks,
          ),
        )
        guard files.length() + directories.length() <= max_manifest_entries else {
          raise SnapshotError("snapshot exceeds the 100,000 entry limit")
        }
      }
      @afs.FileKind::SymLink if skip_symlinks => ()
      @afs.FileKind::SymLink =>
        raise SnapshotError("symbolic links are not followed: " + relative_path)
      _ =>
        raise SnapshotError(
          "unsupported special file in source tree: " + relative_path,
        )
    }
  }
}

///|
/// Stream one source file into bounded chunks while hashing the complete file.
async fn snapshot_regular_file(
  root : String,
  source_path : String,
  relative_path : String,
  snapshot_id : String,
  config : FastCdcConfig,
  unique_chunks : @hashmap.HashMap[String, Int32],
) -> FileRecord raise SnapshotError {
  let file = @afs.open(source_path, mode=@afs.Mode::ReadOnly) catch {
    _ => raise SnapshotError("cannot open source file: " + relative_path)
  }
  defer file.close()
  let initial_size = file.size() catch {
    _ =>
      raise SnapshotError("cannot inspect source file size: " + relative_path)
  }
  let initial_mtime = file.mtime() catch {
    _ =>
      raise SnapshotError(
        "cannot inspect source file timestamp: " + relative_path,
      )
  }
  let chunker = FastCdcStream::new(config)
  let file_hasher = @sha2.Hasher::new()
  let buffer = FixedArray::make(io_buffer_size, b'\x00')
  let chunks : Array[ChunkRef] = []
  let mut total_read = 0L
  let mut emitted_chunks = 0
  while true {
    let count = file.read(buffer) catch {
      _ => raise SnapshotError("cannot read source file: " + relative_path)
    }
    if count == 0 {
      break
    }
    let view = buffer.unsafe_reinterpret_as_bytes()[:count]
    file_hasher.write(view)
    guard total_read <= max_total_bytes - count.to_int64() else {
      raise SnapshotError("source file exceeds the supported integer range")
    }
    total_read += count.to_int64()
    let ready = chunker.push(view)
    for chunk in ready {
      record_chunk(root, snapshot_id, chunk, chunks, unique_chunks)
      emitted_chunks += 1
    }
  }
  for chunk in chunker.finish() {
    record_chunk(root, snapshot_id, chunk, chunks, unique_chunks)
    emitted_chunks += 1
  }
  guard emitted_chunks <= max_chunk_count else {
    raise SnapshotError("source file exceeds the 1,000,000 chunk limit")
  }
  let final_size = file.size() catch {
    _ =>
      raise SnapshotError("cannot recheck source file size: " + relative_path)
  }
  let final_mtime = file.mtime() catch {
    _ =>
      raise SnapshotError(
        "cannot recheck source file timestamp: " + relative_path,
      )
  }
  guard initial_size == final_size &&
    initial_mtime == final_mtime &&
    total_read == final_size else {
    raise SnapshotError(
      "source file changed while being snapshotted: " + relative_path,
    )
  }
  {
    path: relative_path,
    size: total_read,
    digest: @base16.encode(file_hasher.finish()),
    chunks,
  }
}

///|
async fn record_chunk(
  root : String,
  snapshot_id : String,
  bytes : Bytes,
  chunks : Array[ChunkRef],
  unique_chunks : @hashmap.HashMap[String, Int32],
) -> Unit raise SnapshotError {
  let digest = sha256_hex(bytes[:])
  store_chunk_atomic(root, snapshot_id, digest, bytes)
  chunks.push({ digest, size: bytes.length(), })
  if !unique_chunks.contains(digest) {
    unique_chunks.set(digest, bytes.length())
  }
}

///|
fn unique_chunk_bytes(chunks : @hashmap.HashMap[String, Int32]) -> Int64 {
  let mut total = 0L
  for size in chunks.values() {
    total += size.to_int64()
  }
  total
}

///|
async fn ensure_repository_outside_source(
  root : String,
  source : String,
) -> Unit raise SnapshotError {
  let source_real = @afs.realpath(source) catch {
    _ => raise SnapshotError("cannot resolve source directory")
  }
  let root_real = @afs.realpath(root) catch {
    _ => raise SnapshotError("cannot resolve repository directory")
  }
  let source_normalized = source_real
    .replace_all(old="\\", new="/")
    .trim_end(chars="/")
  let root_normalized = root_real
    .replace_all(old="\\", new="/")
    .trim_end(chars="/")
  guard root_normalized != source_normalized &&
    !root_normalized.has_prefix(source_normalized + "/") else {
    raise SnapshotError("repository must be outside the source directory")
  }
}

///|
fn matches_excludes(
  patterns : Array[String],
  path : String,
) -> Bool raise SnapshotError {
  for pattern in patterns {
    if glob_matches(pattern, path) {
      return true
    }
  }
  false
}

///|
async fn write_manifest_atomic(
  root : String,
  id : String,
  final_path : String,
  contents : String,
) -> Unit raise SnapshotError {
  let temporary_path = join_path(root, "tmp/" + id + ".manifest.part")
  let file = @afs.open(
    temporary_path,
    mode=@afs.Mode::WriteOnly,
    sync=@afs.SyncMode::Full,
    create_mode=@afs.CreateMode::CreateNew,
  ) catch {
    _ => raise SnapshotError("cannot create temporary manifest")
  }
  try {
    file.write(contents)
    file.close()
  } catch {
    _ => {
      file.close()
      remove_async_file(temporary_path)
      raise SnapshotError("cannot write snapshot manifest")
    }
  }
  @afs.rename(temporary_path, final_path, replace=false) catch {
    _ => {
      remove_async_file(temporary_path)
      raise SnapshotError("cannot publish snapshot manifest")
    }
  }
}
