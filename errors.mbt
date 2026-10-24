///|
/// Errors returned by the snapshot library and command line.
pub(all) suberror SnapshotError {
  SnapshotError(String)
}

///|
/// Prevent an untrusted manifest from requesting unbounded chunk allocations.
let max_chunk_size : Int32 = 4 * 1024 * 1024

///|
/// Bound manifest parsing, directory traversal, and per-file references.
let max_chunk_count : Int32 = 1_000_000

///|
/// Leave room for large, but still bounded, snapshot manifests.
let max_manifest_size : Int32 = 64 * 1024 * 1024

///|
/// Bound the number of files/directories represented by one manifest.
let max_manifest_entries : Int32 = 100_000

///|
/// Bound paths before parsing, matching, or joining them to a destination.
let max_relative_path_length : Int32 = 4096

///|
/// Read file data in bounded windows; chunk assembly is bounded by max_chunk_size.
let io_buffer_size : Int32 = 256 * 1024
