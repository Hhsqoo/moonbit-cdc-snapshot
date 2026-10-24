///|
/// Restore a snapshot into a new destination. Existing destinations are never
/// replaced. Files are checked while writing a hidden staging path and the
/// completed file or directory is published with a same-volume rename.
pub async fn restore_repository_snapshot(
  root : String,
  id : String,
  destination : String,
) -> Unit raise SnapshotError {
  let manifest = read_repository_manifest(root, id)
  guard !safe_async_exists(destination) else {
    raise SnapshotError("restore destination already exists: " + destination)
  }
  let parent = @path.Path(destination).dirname().to_string()
  ensure_directory(parent)
  let staging = destination + ".moonbit-cdc-" + id + ".part"
  guard !safe_async_exists(staging) else {
    raise SnapshotError("restore staging path already exists: " + staging)
  }
  if manifest.root_is_file {
    guard manifest.files.length() == 1 else {
      raise SnapshotError("single-file manifest has an invalid file count")
    }
    restore_file_to_path(root, manifest.files[0], staging) catch {
      SnapshotError::SnapshotError(message) => {
        cleanup_restore_path(staging) catch {
          _ => ()
        }
        raise SnapshotError(message)
      }
    }
    @afs.rename(staging, destination, replace=false) catch {
      _ => {
        remove_async_file(staging)
        raise SnapshotError("cannot publish restored file")
      }
    }
    return
  }
  @afs.mkdir(staging) catch {
    _ => raise SnapshotError("cannot create restore staging directory")
  }
  try {
    for relative_directory in manifest.directories {
      validate_relative_path(relative_directory)
      ensure_directory(join_path(staging, relative_directory))
    }
    for file in manifest.files {
      validate_relative_path(file.path)
      let output_path = join_path(staging, file.path)
      ensure_parent_directory(output_path)
      restore_file_to_path(root, file, output_path)
    }
    @afs.rename(staging, destination, replace=false) catch {
      _ => raise SnapshotError("cannot publish restored directory")
    }
  } catch {
    SnapshotError::SnapshotError(message) => {
      cleanup_restore_path(staging) catch {
        _ => ()
      }
      raise SnapshotError(message)
    }
  }
}

///|
async fn restore_file_to_path(
  root : String,
  record : FileRecord,
  output_path : String,
) -> Unit raise SnapshotError {
  let output = @afs.open(
    output_path,
    mode=@afs.Mode::WriteOnly,
    sync=@afs.SyncMode::Data,
    create_mode=@afs.CreateMode::CreateNew,
  ) catch {
    _ => raise SnapshotError("cannot create restored file: " + record.path)
  }
  defer output.close()
  let hasher = @sha2.Hasher::new()
  let mut total_size = 0L
  for reference in record.chunks {
    let chunk = read_verified_chunk(root, reference)
    output.write(chunk[:]) catch {
      _ => raise SnapshotError("cannot write restored file: " + record.path)
    }
    hasher.write(chunk[:])
    total_size += chunk.length().to_int64()
  }
  guard total_size == record.size else {
    raise SnapshotError("restored file size mismatch: " + record.path)
  }
  guard @base16.encode(hasher.finish()) == record.digest else {
    raise SnapshotError("restored file digest mismatch: " + record.path)
  }
}

///|
/// Best-effort cleanup for paths created by a failed restore.
async fn cleanup_restore_path(path : String) -> Unit raise SnapshotError {
  let exists = @afs.exists(path) catch { _ => false }
  if !exists {
    return
  }
  let kind = @afs.kind(path, follow_symlink=false) catch {
    _ => @afs.FileKind::Unknown
  }
  match kind {
    @afs.FileKind::Directory =>
      @afs.rmdir(path, recursive=true) catch {
        _ => ()
      }
    _ => @afs.remove(path) catch { _ => () }
  }
}
