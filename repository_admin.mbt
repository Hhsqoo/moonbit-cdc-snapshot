///|
/// Repository-wide logical and physical storage accounting.
pub(all) struct RepositoryStats {
  snapshot_count : Int32
  file_count : Int32
  directory_count : Int32
  logical_bytes : Int64
  referenced_chunk_count : Int32
  referenced_chunk_bytes : Int64
  object_count : Int32
  object_bytes : Int64
  missing_object_count : Int32
  size_mismatch_count : Int32
  orphan_object_count : Int32
  orphan_object_bytes : Int64
} derive(Eq, Debug)

///|
pub extend RepositoryStats with Eq::{equal, not_equal}

///|
pub extend RepositoryStats with @debug.Debug::{to_repr}

///|
/// Preview or apply deletion of objects not referenced by any valid snapshot.
pub(all) struct GarbageCollectionReport {
  applied : Bool
  candidate_count : Int32
  candidate_bytes : Int64
  removed_count : Int32
  removed_bytes : Int64
  temporary_count : Int32
  temporary_bytes : Int64
  removed_temporary_count : Int32
  removed_temporary_bytes : Int64
  candidates : Array[String]
  temporary_files : Array[String]
} derive(Eq, Debug)

///|
pub extend GarbageCollectionReport with Eq::{equal, not_equal}

///|
pub extend GarbageCollectionReport with @debug.Debug::{to_repr}

///|
/// Result of previewing or removing one snapshot manifest.
pub(all) struct ForgetResult {
  id : String
  applied : Bool
  logical_bytes : Int64
  file_count : Int32
} derive(Eq, Debug)

///|
pub extend ForgetResult with Eq::{equal, not_equal}

///|
pub extend ForgetResult with @debug.Debug::{to_repr}

///|
priv struct StoredObject {
  digest : String
  path : String
  size : Int64
}

///|
priv struct ObjectInventory {
  objects : Array[StoredObject]
  orphans : Array[StoredObject]
  missing_count : Int32
  size_mismatch_count : Int32
  total_bytes : Int64
  orphan_bytes : Int64
}

///|
priv struct TemporaryArtifact {
  name : String
  path : String
  size : Int64
}

///|
/// Inspect all manifests and object names without hashing object contents.
/// Use verify to authenticate the bytes themselves.
pub async fn inspect_repository(
  root : String,
) -> RepositoryStats raise SnapshotError {
  require_repository(root)
  let ids = list_snapshot_ids(root)
  let references : @hashmap.HashMap[String, Int32] = HashMap([])
  let mut file_count = 0
  let mut directory_count = 0
  let mut logical_bytes = 0L
  for id in ids {
    let manifest = read_repository_manifest(root, id)
    file_count += manifest.files.length()
    directory_count += manifest.directories.length()
    logical_bytes += manifest.total_size
    for file in manifest.files {
      for chunk in file.chunks {
        record_chunk_reference(references, chunk)
      }
    }
  }
  let inventory = inspect_objects(root, references)
  {
    snapshot_count: ids.length(),
    file_count,
    directory_count,
    logical_bytes,
    referenced_chunk_count: references.length(),
    referenced_chunk_bytes: unique_chunk_bytes(references),
    object_count: inventory.objects.length(),
    object_bytes: inventory.total_bytes,
    missing_object_count: inventory.missing_count,
    size_mismatch_count: inventory.size_mismatch_count,
    orphan_object_count: inventory.orphans.length(),
    orphan_object_bytes: inventory.orphan_bytes,
  }
}

///|
/// Preview is the default. Applying GC requires an explicit true argument from
/// the caller and holds the repository mutation lock throughout the scan/delete.
pub async fn garbage_collect(
  root : String,
  apply : Bool,
) -> GarbageCollectionReport raise SnapshotError {
  require_repository(root)
  let lock = acquire_repository_lock(root)
  defer release_repository_lock(lock)
  let ids = list_snapshot_ids(root)
  let references : @hashmap.HashMap[String, Int32] = HashMap([])
  for id in ids {
    let manifest = read_repository_manifest(root, id)
    for file in manifest.files {
      for chunk in file.chunks {
        record_chunk_reference(references, chunk)
      }
    }
  }
  let inventory = inspect_objects(root, references)
  let temporary_artifacts = inspect_temporary_artifacts(root)
  guard inventory.missing_count == 0 else {
    raise SnapshotError(
      "garbage collection stopped: referenced objects are missing",
    )
  }
  guard inventory.size_mismatch_count == 0 else {
    raise SnapshotError(
      "garbage collection stopped: referenced object sizes are invalid",
    )
  }
  let candidates = inventory.orphans.map(object => object.digest)
  let mut removed_count = 0
  let mut removed_bytes = 0L
  if apply {
    for object in inventory.orphans {
      @afs.remove(object.path) catch {
        _ =>
          raise SnapshotError("cannot remove orphan object: " + object.digest)
      }
      removed_count += 1
      removed_bytes += object.size
    }
  }
  let mut removed_temporary_count = 0
  let mut removed_temporary_bytes = 0L
  if apply {
    for artifact in temporary_artifacts {
      @afs.remove(artifact.path) catch {
        _ =>
          raise SnapshotError(
            "cannot remove temporary artifact: " + artifact.name,
          )
      }
      removed_temporary_count += 1
      removed_temporary_bytes += artifact.size
    }
  }
  {
    applied: apply,
    candidate_count: inventory.orphans.length(),
    candidate_bytes: inventory.orphan_bytes,
    removed_count,
    removed_bytes,
    temporary_count: temporary_artifacts.length(),
    temporary_bytes: temporary_artifact_bytes(temporary_artifacts),
    removed_temporary_count,
    removed_temporary_bytes,
    candidates,
    temporary_files: temporary_artifacts.map(artifact => artifact.name),
  }
}

///|
fn record_chunk_reference(
  references : @hashmap.HashMap[String, Int32],
  chunk : ChunkRef,
) -> Unit raise SnapshotError {
  match references.get(chunk.digest) {
    Some(size) if size != chunk.size =>
      raise SnapshotError("manifests disagree on chunk size: " + chunk.digest)
    _ => references.set(chunk.digest, chunk.size)
  }
}

///|
/// Scan interrupted temporary writes while holding the repository lock.
async fn inspect_temporary_artifacts(
  root : String,
) -> Array[TemporaryArtifact] raise SnapshotError {
  let directory = join_path(root, "tmp")
  let names = safe_readdir(directory)
  let artifacts : Array[TemporaryArtifact] = []
  for name in names {
    guard name.has_suffix(".part") && name.length() > 5 else {
      raise SnapshotError("unexpected entry in temporary directory: " + name)
    }
    let path = join_path(directory, name)
    guard safe_async_kind(path) is @afs.FileKind::Regular else {
      raise SnapshotError("temporary artifact is not a regular file: " + name)
    }
    let size = @afs.file_size(path) catch {
      _ => raise SnapshotError("cannot inspect temporary artifact: " + name)
    }
    guard size >= 0L else {
      raise SnapshotError("temporary artifact has an invalid size: " + name)
    }
    artifacts.push({ name, path, size, })
  }
  artifacts
}

///|
fn temporary_artifact_bytes(artifacts : Array[TemporaryArtifact]) -> Int64 {
  let mut total = 0L
  for artifact in artifacts {
    total += artifact.size
  }
  total
}

///|
/// Preview or remove one snapshot manifest. Orphaned objects are left for GC.
pub async fn forget_snapshot(
  root : String,
  id : String,
  apply : Bool,
) -> ForgetResult raise SnapshotError {
  validate_snapshot_id(id)
  require_repository(root)
  let lock = acquire_repository_lock(root)
  defer release_repository_lock(lock)
  let manifest = read_repository_manifest(root, id)
  if apply {
    @afs.remove(snapshot_manifest_path(root, id)) catch {
      _ => raise SnapshotError("cannot remove snapshot manifest: " + id)
    }
  }
  {
    id,
    applied: apply,
    logical_bytes: manifest.total_size,
    file_count: manifest.files.length(),
  }
}

///|
/// Enumerate and validate object paths before any GC operation can delete data.
async fn inspect_objects(
  root : String,
  references : @hashmap.HashMap[String, Int32],
) -> ObjectInventory raise SnapshotError {
  let object_root = join_path(root, "objects")
  let shards = safe_readdir(object_root)
  let objects : Array[StoredObject] = []
  let orphans : Array[StoredObject] = []
  let found : @hashmap.HashMap[String, Bool] = HashMap([])
  let mut total_bytes = 0L
  let mut orphan_bytes = 0L
  let mut size_mismatch_count = 0
  for shard in shards {
    guard is_lower_hex(shard, 2) else {
      raise SnapshotError("invalid directory in object store: " + shard)
    }
    let shard_path = join_path(object_root, shard)
    guard safe_async_kind(shard_path) is @afs.FileKind::Directory else {
      raise SnapshotError("object shard is not a directory: " + shard)
    }
    let names = safe_readdir(shard_path)
    for name in names {
      guard is_lower_hex(name, 62) else {
        raise SnapshotError("invalid object filename: " + shard + "/" + name)
      }
      let digest = shard + name
      let path = join_path(shard_path, name)
      guard safe_async_kind(path) is @afs.FileKind::Regular else {
        raise SnapshotError("object is not a regular file: " + digest)
      }
      let size = @afs.file_size(path) catch {
        _ => raise SnapshotError("cannot inspect object size: " + digest)
      }
      guard size >= 0L else {
        raise SnapshotError("object has a negative file size: " + digest)
      }
      let object : StoredObject = { digest, path, size, }
      objects.push(object)
      total_bytes += size
      found.set(digest, true)
      match references.get(digest) {
        Some(expected_size) if expected_size.to_int64() != size =>
          size_mismatch_count += 1
        None => {
          orphans.push(object)
          orphan_bytes += size
        }
        _ => ()
      }
    }
  }
  let mut missing_count = 0
  for digest in references.keys() {
    if !found.contains(digest) {
      missing_count += 1
    }
  }
  {
    objects,
    orphans,
    missing_count,
    size_mismatch_count,
    total_bytes,
    orphan_bytes,
  }
}

///|
fn is_lower_hex(value : String, expected_length : Int32) -> Bool {
  let bytes = @utf8.encode(value)
  if bytes.length() != expected_length {
    return false
  }
  for byte in bytes[:] {
    if !(byte is (b'0'..<=b'9' | b'a'..<=b'f')) {
      return false
    }
  }
  true
}
