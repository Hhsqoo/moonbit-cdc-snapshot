///|
/// One regular file in a tree snapshot.
pub(all) struct FileRecord {
  path : String
  size : Int64
  digest : String
  chunks : Array[ChunkRef]
} derive(Eq, Debug)

///|
pub extend FileRecord with Eq::{equal, not_equal}

///|
pub extend FileRecord with @debug.Debug::{to_repr}

///|
/// Versioned description of an immutable repository snapshot.
pub(all) struct SnapshotManifest {
  version : Int32
  id : String
  root_name : String
  root_is_file : Bool
  config : FastCdcConfig
  total_size : Int64
  directories : Array[String]
  files : Array[FileRecord]
} derive(Eq, Debug)

///|
pub extend SnapshotManifest with Eq::{equal, not_equal}

///|
pub extend SnapshotManifest with @debug.Debug::{to_repr}

///|
/// Summary returned after snapshot creation or inspection.
pub(all) struct SnapshotSummary {
  id : String
  file_count : Int32
  directory_count : Int32
  chunk_count : Int32
  total_bytes : Int64
  unique_chunk_count : Int32
  unique_chunk_bytes : Int64
} derive(Eq, Debug)

///|
pub extend SnapshotSummary with Eq::{equal, not_equal}

///|
pub extend SnapshotSummary with @debug.Debug::{to_repr}

///|
/// A canonical JSON representation used by repository manifests.
pub fn SnapshotManifest::to_json(self : SnapshotManifest) -> String {
  let directories : Array[Json] = self.directories.map(path => {
    @json.ToJson::to_json(path)
  })
  let files : Array[Json] = self.files.map(file => {
    let chunks : Array[Json] = file.chunks.map(chunk => {
      "digest": chunk.digest,
      "size": chunk.size,
    })
    {
      "path": file.path,
      "size": file.size,
      "digest": file.digest,
      "chunks": chunks,
    }
  })
  let json : Json = {
    "format": self.version,
    "id": self.id,
    "root_name": self.root_name,
    "root_is_file": self.root_is_file,
    "min": self.config.min,
    "average": self.config.average,
    "max": self.config.max,
    "total_size": self.total_size,
    "directories": directories,
    "files": files,
  }
  json.stringify()
}

///|
/// Parse untrusted JSON and validate all metadata before object-store access.
pub fn SnapshotManifest::from_json(
  text : String,
) -> SnapshotManifest raise SnapshotError {
  guard text.length() <= max_manifest_size else {
    raise SnapshotError("manifest exceeds the 64 MiB size limit")
  }
  let json = @json.parse(text) catch {
    _ => raise SnapshotError("manifest is not valid JSON")
  }
  guard json is Object(object) else {
    raise SnapshotError("manifest root must be an object")
  }
  let version = json_int(object, "format")
  guard version == 2 else {
    raise SnapshotError("unsupported snapshot format version")
  }
  let id = json_string(object, "id")
  validate_snapshot_id(id)
  let root_name = json_string(object, "root_name")
  validate_relative_path(root_name)
  let root_is_file = json_bool(object, "root_is_file")
  let config : FastCdcConfig = {
    min: json_int(object, "min"),
    average: json_int(object, "average"),
    max: json_int(object, "max"),
  }
  config.validate()
  let total_size = json_int64(object, "total_size")
  guard total_size >= 0L else {
    raise SnapshotError("snapshot total size cannot be negative")
  }
  let directories = json_string_array(object, "directories")
  let files = json_file_array(object)
  guard directories.length() + files.length() <= max_manifest_entries else {
    raise SnapshotError("manifest exceeds the 100,000 entry limit")
  }
  guard files.length() <= max_manifest_entries else {
    raise SnapshotError("manifest exceeds the 100,000 file limit")
  }
  let all_paths : @hashmap.HashMap[String, Bool] = HashMap([])
  let chunk_sizes : @hashmap.HashMap[String, Int32] = HashMap([])
  let mut directory_total = 0L
  let mut chunk_total = 0
  let mut previous_directory = ""
  for index, path in directories {
    validate_relative_path(path)
    guard index == 0 ||
      lexicographically_less_or_equal(previous_directory, path) else {
      raise SnapshotError("manifest directories must be unique and sorted")
    }
    guard !all_paths.contains(path) else {
      raise SnapshotError("manifest contains a duplicate path: " + path)
    }
    all_paths.set(path, true)
    previous_directory = path
  }
  let mut previous_file = ""
  for index, file in files {
    validate_relative_path(file.path)
    guard index == 0 ||
      lexicographically_less_or_equal(previous_file, file.path) else {
      raise SnapshotError("manifest files must be unique and sorted")
    }
    guard !all_paths.contains(file.path) else {
      raise SnapshotError("manifest contains a duplicate path: " + file.path)
    }
    all_paths.set(file.path, true)
    previous_file = file.path
    guard file.size >= 0L else {
      raise SnapshotError("file size cannot be negative")
    }
    guard file.size <= max_total_bytes - directory_total else {
      raise SnapshotError("snapshot size exceeds the supported integer range")
    }
    directory_total += file.size
    chunk_total += file.chunks.length()
    guard chunk_total <= max_chunk_count else {
      raise SnapshotError("manifest exceeds the 1,000,000 chunk limit")
    }
    validate_file_chunks(file, config)
    for chunk in file.chunks {
      match chunk_sizes.get(chunk.digest) {
        Some(size) if size != chunk.size =>
          raise SnapshotError("manifest assigns multiple sizes to one chunk")
        _ => chunk_sizes.set(chunk.digest, chunk.size)
      }
    }
  }
  validate_manifest_hierarchy(directories, files)
  guard directory_total == total_size else {
    raise SnapshotError("snapshot file sizes do not match total_size")
  }
  if root_is_file {
    guard files.length() == 1 &&
      directories.length() == 0 &&
      files[0].path == root_name else {
      raise SnapshotError(
        "single-file snapshots must contain exactly the root file",
      )
    }
  }
  {
    version,
    id,
    root_name,
    root_is_file,
    config,
    total_size,
    directories,
    files,
  }
}

///|
/// A regular file cannot also be the parent of another manifest entry. This
/// protects restoration from file/directory collisions in untrusted manifests.
fn validate_manifest_hierarchy(
  directories : Array[String],
  files : Array[FileRecord],
) -> Unit raise SnapshotError {
  let file_paths : @hashmap.HashMap[String, Bool] = HashMap([])
  for file in files {
    file_paths.set(file.path, true)
  }
  for directory in directories {
    reject_file_ancestors(directory, file_paths)
  }
  for file in files {
    reject_file_ancestors(file.path, file_paths)
  }
}

///|
fn reject_file_ancestors(
  path : String,
  file_paths : @hashmap.HashMap[String, Bool],
) -> Unit raise SnapshotError {
  let bytes = @utf8.encode(path)
  for index in 0..<bytes.length() {
    if bytes[index] == b'/' {
      let ancestor = path[:index].to_owned()
      guard !file_paths.contains(ancestor) else {
        raise SnapshotError(
          "manifest file is a parent of another path: " + ancestor,
        )
      }
    }
  }
}

///|
fn validate_file_chunks(
  file : FileRecord,
  config : FastCdcConfig,
) -> Unit raise SnapshotError {
  let mut chunk_size = 0L
  for index, chunk in file.chunks {
    validate_digest(chunk.digest)
    guard chunk.size > 0 &&
      chunk.size <= config.max &&
      (index == file.chunks.length() - 1 || chunk.size >= config.min) else {
      raise SnapshotError("manifest contains an invalid chunk size")
    }
    chunk_size += chunk.size.to_int64()
  }
  guard chunk_size == file.size else {
    raise SnapshotError("file chunk sizes do not match file size: " + file.path)
  }
  guard (file.size == 0L) == (file.chunks.length() == 0) else {
    raise SnapshotError("empty files must have no chunks")
  }
  validate_digest(file.digest)
}

///|
fn json_int64(
  object : Map[String, Json],
  key : String,
) -> Int64 raise SnapshotError {
  let value = match object.get(key) {
    Some(value) => value
    None => raise SnapshotError("manifest is missing field: " + key)
  }
  @json.from_json(value) catch {
    _ => raise SnapshotError("manifest field must be an int64: " + key)
  }
}

///|
fn json_bool(
  object : Map[String, Json],
  key : String,
) -> Bool raise SnapshotError {
  let value = match object.get(key) {
    Some(value) => value
    None => raise SnapshotError("manifest is missing field: " + key)
  }
  @json.from_json(value) catch {
    _ => raise SnapshotError("manifest field must be a boolean: " + key)
  }
}

///|
fn json_string_array(
  object : Map[String, Json],
  key : String,
) -> Array[String] raise SnapshotError {
  let value = match object.get(key) {
    Some(value) => value
    None => raise SnapshotError("manifest is missing field: " + key)
  }
  guard value is Array(items) else {
    raise SnapshotError("manifest field must be an array: " + key)
  }
  let result : Array[String] = []
  for item in items {
    result.push(
      @json.from_json(item) catch {
        _ => raise SnapshotError("manifest array contains a non-string value")
      },
    )
  }
  result
}

///|
fn json_file_array(
  object : Map[String, Json],
) -> Array[FileRecord] raise SnapshotError {
  let value = match object.get("files") {
    Some(value) => value
    None => raise SnapshotError("manifest is missing files")
  }
  guard value is Array(items) else {
    raise SnapshotError("manifest files must be an array")
  }
  guard items.length() <= max_manifest_entries else {
    raise SnapshotError("manifest exceeds the 100,000 file limit")
  }
  let files : Array[FileRecord] = []
  for item in items {
    guard item is Object(fields) else {
      raise SnapshotError("manifest file record must be an object")
    }
    let path = json_string(fields, "path")
    let size = json_int64(fields, "size")
    let digest = json_string(fields, "digest")
    let chunks = json_chunk_array(fields)
    files.push({ path, size, digest, chunks, })
  }
  files
}

///|
fn json_chunk_array(
  object : Map[String, Json],
) -> Array[ChunkRef] raise SnapshotError {
  let value = match object.get("chunks") {
    Some(value) => value
    None => raise SnapshotError("manifest file is missing chunks")
  }
  guard value is Array(items) else {
    raise SnapshotError("manifest chunks must be an array")
  }
  guard items.length() <= max_chunk_count else {
    raise SnapshotError("manifest exceeds the 1,000,000 chunk limit")
  }
  let chunks : Array[ChunkRef] = []
  for item in items {
    guard item is Object(fields) else {
      raise SnapshotError("manifest chunk must be an object")
    }
    chunks.push({
      digest: json_string(fields, "digest"),
      size: json_int(fields, "size"),
    })
  }
  chunks
}

///|
let max_total_bytes : Int64 = 9_000_000_000_000_000_000L
