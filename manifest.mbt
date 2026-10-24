///|
/// One immutable content-addressed chunk referenced by a file record.
pub(all) struct ChunkRef {
  digest : String
  size : Int32
} derive(Eq, Debug)

///|
pub extend ChunkRef with Eq::{not_equal, equal}

///|
pub extend ChunkRef with @debug.Debug::{to_repr}

///|
/// Read a required integer field from a JSON object.
fn json_int(
  object : Map[String, Json],
  key : String,
) -> Int32 raise SnapshotError {
  let value = match object.get(key) {
    Some(value) => value
    None => raise SnapshotError("manifest is missing field: " + key)
  }
  @json.from_json(value) catch {
    _ => raise SnapshotError("manifest field must be an integer: " + key)
  }
}

///|
/// Read a required string field from a JSON object.
fn json_string(
  object : Map[String, Json],
  key : String,
) -> String raise SnapshotError {
  let value = match object.get(key) {
    Some(value) => value
    None => raise SnapshotError("manifest is missing field: " + key)
  }
  @json.from_json(value) catch {
    _ => raise SnapshotError("manifest field must be a string: " + key)
  }
}

///|
/// Validate a lowercase SHA-256 digest before using it in a path.
fn validate_digest(digest : String) -> Unit raise SnapshotError {
  guard digest.length() == 64 else {
    raise SnapshotError("SHA-256 digest must have 64 hex characters")
  }
  let decoded = @base16.decode(digest) catch {
    _ => raise SnapshotError("digest contains invalid hexadecimal characters")
  }
  guard decoded.length() == 32 && @base16.encode(decoded) == digest else {
    raise SnapshotError("digest must use lowercase canonical hexadecimal")
  }
}
