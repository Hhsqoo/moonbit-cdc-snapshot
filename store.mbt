///|
fn join_path(left : String, right : String) -> String {
  @path.Path::join(@path.Path(left), @path.Path(right)).to_string()
}

///|
fn ensure_parent_directory(path : String) -> Unit raise SnapshotError {
  @path.Path(path).dirname().to_string() |> ensure_directory
}

///|
fn ensure_directory(path : String) -> Unit raise SnapshotError {
  if path == "" || path == "." {
    return
  }
  if @fs.path_exists(path) {
    let directory = @fs.is_dir(path) catch {
      _ => raise SnapshotError("cannot inspect directory: " + path)
    }
    guard directory else {
      raise SnapshotError("path exists but is not a directory: " + path)
    }
  } else {
    let parent = @path.Path(path).dirname().to_string()
    if parent != path {
      ensure_directory(parent)
    }
    @fs.create_dir(path) catch {
      _ => raise SnapshotError("cannot create directory: " + path)
    }
  }
}

///|
/// Map a SHA-256 digest to a two-level immutable object path.
fn repository_object_path(root : String, digest : String) -> String {
  join_path(
    join_path(root, "objects/" + digest[:2].to_owned()),
    digest[2:].to_owned(),
  )
}

///|
/// Write a content-addressed object atomically and validate reused bytes.
async fn store_chunk_atomic(
  root : String,
  snapshot_id : String,
  digest : String,
  bytes : Bytes,
) -> Unit raise SnapshotError {
  validate_digest(digest)
  guard sha256_hex(bytes[:]) == digest else {
    raise SnapshotError("chunk digest changed before storage")
  }
  let final_path = repository_object_path(root, digest)
  ensure_parent_directory(final_path)
  if @fs.path_exists(final_path) {
    verify_existing_chunk(final_path, digest, bytes.length())
    return
  }
  let temporary_path = join_path(
    root,
    "tmp/" + snapshot_id + "-" + digest + ".part",
  )
  let file = @afs.open(
    temporary_path,
    mode=@afs.Mode::WriteOnly,
    sync=@afs.SyncMode::Data,
    create_mode=@afs.CreateMode::CreateNew,
  ) catch {
    _ => raise SnapshotError("cannot create temporary chunk object")
  }
  try {
    file.write(bytes[:])
    file.close()
  } catch {
    _ => {
      file.close()
      remove_async_file(temporary_path)
      raise SnapshotError("cannot write temporary chunk object")
    }
  }
  @afs.rename(temporary_path, final_path, replace=false) catch {
    _ =>
      if @fs.path_exists(final_path) {
        remove_async_file(temporary_path)
        verify_existing_chunk(final_path, digest, bytes.length())
      } else {
        remove_async_file(temporary_path)
        raise SnapshotError("cannot publish chunk object: " + digest)
      }
  }
}

///|
fn verify_existing_chunk(
  path : String,
  digest : String,
  expected_size : Int32,
) -> Unit raise SnapshotError {
  let bytes = @fs.read_file_to_bytes(path) catch {
    _ => raise SnapshotError("cannot read existing chunk object: " + digest)
  }
  guard bytes.length() == expected_size && sha256_hex(bytes[:]) == digest else {
    raise SnapshotError("existing chunk object is corrupt: " + digest)
  }
}

///|
async fn remove_async_file(path : String) -> Unit raise SnapshotError {
  let exists = @afs.exists(path) catch { _ => false }
  if exists {
    @afs.remove(path) catch {
      _ => ()
    }
  }
}

///|
/// Load and authenticate one bounded object before it is restored or verified.
fn read_verified_chunk(
  root : String,
  reference : ChunkRef,
) -> Bytes raise SnapshotError {
  let path = repository_object_path(root, reference.digest)
  let bytes = @fs.read_file_to_bytes(path) catch {
    _ =>
      raise SnapshotError(
        "missing or unreadable chunk object: " + reference.digest,
      )
  }
  guard bytes.length() == reference.size else {
    raise SnapshotError("chunk length mismatch: " + reference.digest)
  }
  guard sha256_hex(bytes[:]) == reference.digest else {
    raise SnapshotError("chunk digest mismatch: " + reference.digest)
  }
  bytes
}
