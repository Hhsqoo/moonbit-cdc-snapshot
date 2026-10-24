///|
fn sample_tree_manifest() -> @moonbit-cdc-snapshot.SnapshotManifest {
  let payload = b"hello"
  let digest = @moonbit-cdc-snapshot.sha256_hex(payload[:])
  {
    version: 2,
    id: "baseline",
    root_name: "source",
    root_is_file: false,
    config: { min: 16, average: 64, max: 256, },
    total_size: 5L,
    directories: ["data", "empty"],
    files: [
      {
        path: "data/alpha.txt",
        size: 5L,
        digest,
        chunks: [{ digest, size: 5, }],
      },
    ],
  }
}

///|
test "tree manifest roundtrips 64-bit sizes and sorted paths" {
  let manifest = sample_tree_manifest()
  let json = manifest.to_json()
  assert_eq(@moonbit-cdc-snapshot.SnapshotManifest::from_json(json), manifest)
}

///|
test "tree manifest rejects traversal and duplicate entries" {
  let json = sample_tree_manifest().to_json()
  let traversal = json.replace_all(old="data/alpha.txt", new="../alpha.txt")
  try {
    ignore(@moonbit-cdc-snapshot.SnapshotManifest::from_json(traversal))
    panic()
  } catch {
    @moonbit-cdc-snapshot.SnapshotError::SnapshotError(_) => ()
  }

  let manifest = sample_tree_manifest()
  let duplicate_manifest : @moonbit-cdc-snapshot.SnapshotManifest = {
    version: manifest.version,
    id: manifest.id,
    root_name: manifest.root_name,
    root_is_file: manifest.root_is_file,
    config: manifest.config,
    total_size: manifest.total_size,
    directories: ["data", "data/alpha.txt", "empty"],
    files: manifest.files,
  }
  let duplicate = duplicate_manifest.to_json()
  try {
    ignore(@moonbit-cdc-snapshot.SnapshotManifest::from_json(duplicate))
    panic()
  } catch {
    @moonbit-cdc-snapshot.SnapshotError::SnapshotError(_) => ()
  }
}

///|
test "tree manifest rejects a file used as a parent directory" {
  let manifest = sample_tree_manifest()
  let empty_digest = @moonbit-cdc-snapshot.sha256_hex(b""[:])
  let collision : @moonbit-cdc-snapshot.SnapshotManifest = {
    version: manifest.version,
    id: manifest.id,
    root_name: manifest.root_name,
    root_is_file: manifest.root_is_file,
    config: manifest.config,
    total_size: manifest.total_size,
    directories: manifest.directories,
    files: manifest.files +
    [
      {
        path: "data/alpha.txt/child",
        size: 0L,
        digest: empty_digest,
        chunks: [],
      },
    ],
  }
  try {
    ignore(
      @moonbit-cdc-snapshot.SnapshotManifest::from_json(collision.to_json()),
    )
    panic()
  } catch {
    @moonbit-cdc-snapshot.SnapshotError::SnapshotError(_) => ()
  }
}

///|
test "tree manifest rejects inconsistent sizes for a repeated chunk digest" {
  let manifest = sample_tree_manifest()
  let digest = manifest.files[0].chunks[0].digest
  let conflicting : @moonbit-cdc-snapshot.SnapshotManifest = {
    version: manifest.version,
    id: manifest.id,
    root_name: manifest.root_name,
    root_is_file: false,
    config: manifest.config,
    total_size: 9L,
    directories: manifest.directories,
    files: [
      manifest.files[0],
      {
        path: "data/beta.txt",
        size: 4L,
        digest,
        chunks: [{ digest, size: 4, }],
      },
    ],
  }
  try {
    ignore(
      @moonbit-cdc-snapshot.SnapshotManifest::from_json(conflicting.to_json()),
    )
    panic()
  } catch {
    @moonbit-cdc-snapshot.SnapshotError::SnapshotError(_) => ()
  }
}
