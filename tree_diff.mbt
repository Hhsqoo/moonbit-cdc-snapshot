///|
/// Whether a path in the current snapshot is new, changed, or unchanged.
pub(all) enum SnapshotFileChange {
  Added
  Changed
  Unchanged
} derive(Eq, Debug)

///|
pub extend SnapshotFileChange with Eq::{equal, not_equal}

///|
pub extend SnapshotFileChange with @debug.Debug::{to_repr}

///|
/// Per-file accounting of current chunk references against a previous snapshot.
pub(all) struct FileChunkReuse {
  path : String
  change : SnapshotFileChange
  file_bytes : Int64
  reused_chunk_count : Int32
  reused_chunk_bytes : Int64
  new_chunk_count : Int32
  new_chunk_bytes : Int64
} derive(Eq, Debug)

///|
pub extend FileChunkReuse with Eq::{equal, not_equal}

///|
pub extend FileChunkReuse with @debug.Debug::{to_repr}

///|
/// CDC chunk reuse totals and per-file details for two snapshots.
/// Byte totals are logical chunk-reference bytes, not physical disk savings.
pub(all) struct ChunkReuseAnalysis {
  files : Array[FileChunkReuse]
  reused_chunk_count : Int32
  reused_chunk_bytes : Int64
  new_chunk_count : Int32
  new_chunk_bytes : Int64
} derive(Eq, Debug)

///|
pub extend ChunkReuseAnalysis with Eq::{equal, not_equal}

///|
pub extend ChunkReuseAnalysis with @debug.Debug::{to_repr}

///|
/// One current chunk and its deterministic matching location in the previous
/// snapshot, when the digest and size are reusable.
pub(all) struct ChunkReferenceExplanation {
  index : Int32
  current_offset : Int64
  size : Int32
  digest : String
  previous_path : String?
  previous_offset : Int64?
} derive(Eq, Debug)

///|
pub extend ChunkReferenceExplanation with Eq::{equal, not_equal}

///|
pub extend ChunkReferenceExplanation with @debug.Debug::{to_repr}

///|
/// A bounded chunk map for one file in the current snapshot.
pub(all) struct SnapshotFileExplanation {
  file : FileChunkReuse
  chunk_count : Int32
  chunks : Array[ChunkReferenceExplanation]
  omitted_count : Int32
} derive(Eq, Debug)

///|
pub extend SnapshotFileExplanation with Eq::{equal, not_equal}

///|
pub extend SnapshotFileExplanation with @debug.Debug::{to_repr}

///|
/// File-level changes between two directory snapshots.
pub(all) struct SnapshotDiff {
  added : Array[String]
  removed : Array[String]
  changed : Array[String]
  unchanged : Array[String]
  added_bytes : Int64
  removed_bytes : Int64
  changed_bytes : Int64
  unchanged_bytes : Int64
  reused_chunk_bytes : Int64
  new_chunk_bytes : Int64
} derive(Eq, Debug)

///|
pub extend SnapshotDiff with Eq::{equal, not_equal}

///|
pub extend SnapshotDiff with @debug.Debug::{to_repr}

///|
/// Explain current snapshot chunk reuse by path without reading source files or
/// object payloads. Repeated references are counted separately.
pub fn analyze_snapshot_manifests(
  previous : SnapshotManifest,
  current : SnapshotManifest,
) -> ChunkReuseAnalysis raise SnapshotError {
  guard previous.config == current.config else {
    raise SnapshotError(
      "cannot compare snapshots with different chunk settings",
    )
  }
  let previous_by_path : @hashmap.HashMap[String, FileRecord] = HashMap([])
  let old_chunks : @hashmap.HashMap[String, Int32] = HashMap([])
  for file in previous.files {
    previous_by_path.set(file.path, file)
    for chunk in file.chunks {
      old_chunks.set(chunk.digest, chunk.size)
    }
  }
  let details : Array[FileChunkReuse] = []
  let mut reused_chunk_count = 0
  let mut reused_chunk_bytes = 0L
  let mut new_chunk_count = 0
  let mut new_chunk_bytes = 0L
  for file in current.files {
    let change = match previous_by_path.get(file.path) {
      None => SnapshotFileChange::Added
      Some(old_file) if old_file.digest == file.digest =>
        SnapshotFileChange::Unchanged
      Some(_) => SnapshotFileChange::Changed
    }
    let mut file_reused_chunk_count = 0
    let mut file_reused_chunk_bytes = 0L
    let mut file_new_chunk_count = 0
    let mut file_new_chunk_bytes = 0L
    for chunk in file.chunks {
      match old_chunks.get(chunk.digest) {
        Some(old_size) if old_size == chunk.size => {
          file_reused_chunk_count += 1
          file_reused_chunk_bytes += chunk.size.to_int64()
        }
        _ => {
          file_new_chunk_count += 1
          file_new_chunk_bytes += chunk.size.to_int64()
        }
      }
    }
    reused_chunk_count += file_reused_chunk_count
    reused_chunk_bytes += file_reused_chunk_bytes
    new_chunk_count += file_new_chunk_count
    new_chunk_bytes += file_new_chunk_bytes
    details.push({
      path: file.path,
      change,
      file_bytes: file.size,
      reused_chunk_count: file_reused_chunk_count,
      reused_chunk_bytes: file_reused_chunk_bytes,
      new_chunk_count: file_new_chunk_count,
      new_chunk_bytes: file_new_chunk_bytes,
    })
  }
  {
    files: details,
    reused_chunk_count,
    reused_chunk_bytes,
    new_chunk_count,
    new_chunk_bytes,
  }
}

///|
/// Compare two already validated manifests without reading object payloads.
pub fn compare_snapshot_manifests(
  previous : SnapshotManifest,
  current : SnapshotManifest,
) -> SnapshotDiff raise SnapshotError {
  let analysis = analyze_snapshot_manifests(previous, current)
  let current_paths : @hashmap.HashMap[String, Bool] = HashMap([])
  for file in current.files {
    current_paths.set(file.path, true)
  }
  let added : Array[String] = []
  let removed : Array[String] = []
  let changed : Array[String] = []
  let unchanged : Array[String] = []
  let mut added_bytes = 0L
  let mut removed_bytes = 0L
  let mut changed_bytes = 0L
  let mut unchanged_bytes = 0L
  for file in analysis.files {
    match file.change {
      SnapshotFileChange::Added => {
        added.push(file.path)
        added_bytes += file.file_bytes
      }
      SnapshotFileChange::Changed => {
        changed.push(file.path)
        changed_bytes += file.file_bytes
      }
      SnapshotFileChange::Unchanged => {
        unchanged.push(file.path)
        unchanged_bytes += file.file_bytes
      }
    }
  }
  for old_file in previous.files {
    if !current_paths.contains(old_file.path) {
      removed.push(old_file.path)
      removed_bytes += old_file.size
    }
  }
  {
    added,
    removed,
    changed,
    unchanged,
    added_bytes,
    removed_bytes,
    changed_bytes,
    unchanged_bytes,
    reused_chunk_bytes: analysis.reused_chunk_bytes,
    new_chunk_bytes: analysis.new_chunk_bytes,
  }
}

///|
/// Load and compare two repository manifests.
pub async fn compare_repository_snapshots(
  root : String,
  previous_id : String,
  current_id : String,
) -> SnapshotDiff raise SnapshotError {
  let previous = read_repository_manifest(root, previous_id)
  let current = read_repository_manifest(root, current_id)
  compare_snapshot_manifests(previous, current)
}

///|
/// Load and analyze two repository manifests without reading object payloads.
pub async fn analyze_repository_snapshots(
  root : String,
  previous_id : String,
  current_id : String,
) -> ChunkReuseAnalysis raise SnapshotError {
  let previous = read_repository_manifest(root, previous_id)
  let current = read_repository_manifest(root, current_id)
  analyze_snapshot_manifests(previous, current)
}

///|
/// A representative prior occurrence of a content-addressed chunk.
priv struct PreviousChunkLocation {
  path : String
  offset : Int64
  size : Int32
}

///|
/// Explain chunk positions for one current file. Totals cover the complete
/// file; at most `limit` individual chunk rows are retained.
pub fn explain_snapshot_file_chunks(
  previous : SnapshotManifest,
  current : SnapshotManifest,
  path : String,
  limit : Int32,
) -> SnapshotFileExplanation raise SnapshotError {
  guard previous.config == current.config else {
    raise SnapshotError(
      "cannot compare snapshots with different chunk settings",
    )
  }
  guard limit >= 1 && limit <= 1000 else {
    raise SnapshotError("chunk detail limit must be between 1 and 1000")
  }
  let previous_by_path : @hashmap.HashMap[String, FileRecord] = HashMap([])
  let previous_chunks : @hashmap.HashMap[String, PreviousChunkLocation] = HashMap([],
  )
  for old_file in previous.files {
    previous_by_path.set(old_file.path, old_file)
    let mut old_offset = 0L
    for chunk in old_file.chunks {
      if !previous_chunks.contains(chunk.digest) {
        previous_chunks.set(chunk.digest, {
          path: old_file.path,
          offset: old_offset,
          size: chunk.size,
        })
      }
      old_offset += chunk.size.to_int64()
    }
  }
  let mut selected_file : FileRecord? = None
  for file in current.files {
    if file.path == path {
      selected_file = Some(file)
    }
  }
  let current_file = match selected_file {
    Some(file) => file
    None =>
      raise SnapshotError(
        "file is not present in the current snapshot: " + path,
      )
  }
  let change = match previous_by_path.get(path) {
    None => SnapshotFileChange::Added
    Some(old_file) if old_file.digest == current_file.digest =>
      SnapshotFileChange::Unchanged
    Some(_) => SnapshotFileChange::Changed
  }
  let mut reused_chunk_count = 0
  let mut reused_chunk_bytes = 0L
  let mut new_chunk_count = 0
  let mut new_chunk_bytes = 0L
  let chunks : Array[ChunkReferenceExplanation] = []
  let mut current_offset = 0L
  for index, chunk in current_file.chunks {
    let old_location = match previous_chunks.get(chunk.digest) {
      Some(location) if location.size == chunk.size => Some(location)
      _ => None
    }
    match old_location {
      Some(_) => {
        reused_chunk_count += 1
        reused_chunk_bytes += chunk.size.to_int64()
      }
      None => {
        new_chunk_count += 1
        new_chunk_bytes += chunk.size.to_int64()
      }
    }
    if index < limit {
      let previous_path = match old_location {
        Some(location) => Some(location.path)
        None => None
      }
      let previous_offset = match old_location {
        Some(location) => Some(location.offset)
        None => None
      }
      chunks.push({
        index,
        current_offset,
        size: chunk.size,
        digest: chunk.digest,
        previous_path,
        previous_offset,
      })
    }
    current_offset += chunk.size.to_int64()
  }
  {
    file: {
      path: current_file.path,
      change,
      file_bytes: current_file.size,
      reused_chunk_count,
      reused_chunk_bytes,
      new_chunk_count,
      new_chunk_bytes,
    },
    chunk_count: current_file.chunks.length(),
    omitted_count: current_file.chunks.length() - chunks.length(),
    chunks,
  }
}

///|
/// Load two manifests and explain chunk positions for a selected current file.
pub async fn explain_repository_file_chunks(
  root : String,
  previous_id : String,
  current_id : String,
  path : String,
  limit : Int32,
) -> SnapshotFileExplanation raise SnapshotError {
  let previous = read_repository_manifest(root, previous_id)
  let current = read_repository_manifest(root, current_id)
  explain_snapshot_file_chunks(previous, current, path, limit)
}
