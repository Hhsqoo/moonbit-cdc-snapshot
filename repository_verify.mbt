///|
/// Verify one repository snapshot without reconstructing whole files in memory.
pub async fn verify_repository_snapshot(
  root : String,
  id : String,
) -> SnapshotSummary raise SnapshotError {
  let manifest = read_repository_manifest(root, id)
  let mut chunk_count = 0
  let unique_chunks : @hashmap.HashMap[String, Int32] = HashMap([])
  for file in manifest.files {
    verify_file_chunks(root, file, unique_chunks)
    chunk_count += file.chunks.length()
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
/// Verify all manifests and objects in one repository.
pub async fn verify_entire_repository(
  root : String,
) -> Array[SnapshotSummary] raise SnapshotError {
  require_repository(root)
  let ids = list_snapshot_ids(root)
  let results : Array[SnapshotSummary] = []
  for id in ids {
    results.push(verify_repository_snapshot(root, id))
  }
  results
}

///|
fn verify_file_chunks(
  root : String,
  file : FileRecord,
  unique_chunks : @hashmap.HashMap[String, Int32],
) -> Unit raise SnapshotError {
  let hasher = @sha2.Hasher::new()
  let mut size = 0L
  for reference in file.chunks {
    let bytes = read_verified_chunk(root, reference)
    hasher.write(bytes[:])
    size += bytes.length().to_int64()
    if !unique_chunks.contains(reference.digest) {
      unique_chunks.set(reference.digest, reference.size)
    }
  }
  guard size == file.size else {
    raise SnapshotError(
      "verified file size does not match manifest: " + file.path,
    )
  }
  guard @base16.encode(hasher.finish()) == file.digest else {
    raise SnapshotError("whole-file digest mismatch: " + file.path)
  }
}
