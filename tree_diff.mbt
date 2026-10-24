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
/// Compare two already validated manifests without reading object payloads.
pub fn compare_snapshot_manifests(
  previous : SnapshotManifest,
  current : SnapshotManifest,
) -> SnapshotDiff raise SnapshotError {
  guard previous.config == current.config else {
    raise SnapshotError(
      "cannot compare snapshots with different chunk settings",
    )
  }
  let previous_by_path : @hashmap.HashMap[String, FileRecord] = HashMap([])
  let current_by_path : @hashmap.HashMap[String, FileRecord] = HashMap([])
  let old_chunks : @hashmap.HashMap[String, Int32] = HashMap([])
  for file in previous.files {
    previous_by_path.set(file.path, file)
    for chunk in file.chunks {
      old_chunks.set(chunk.digest, chunk.size)
    }
  }
  for file in current.files {
    current_by_path.set(file.path, file)
  }
  let added : Array[String] = []
  let removed : Array[String] = []
  let changed : Array[String] = []
  let unchanged : Array[String] = []
  let mut added_bytes = 0L
  let mut removed_bytes = 0L
  let mut changed_bytes = 0L
  let mut unchanged_bytes = 0L
  for file in current.files {
    match previous_by_path.get(file.path) {
      None => {
        added.push(file.path)
        added_bytes += file.size
      }
      Some(old_file) if old_file.digest == file.digest => {
        unchanged.push(file.path)
        unchanged_bytes += file.size
      }
      Some(_) => {
        changed.push(file.path)
        changed_bytes += file.size
      }
    }
  }
  for old_file in previous.files {
    if !current_by_path.contains(old_file.path) {
      removed.push(old_file.path)
      removed_bytes += old_file.size
    }
  }
  let mut reused_chunk_bytes = 0L
  let mut new_chunk_bytes = 0L
  for file in current.files {
    for chunk in file.chunks {
      match old_chunks.get(chunk.digest) {
        Some(old_size) if old_size == chunk.size =>
          reused_chunk_bytes += chunk.size.to_int64()
        _ => new_chunk_bytes += chunk.size.to_int64()
      }
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
    reused_chunk_bytes,
    new_chunk_bytes,
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
