///|
async test "repository snapshots trees, reuses content, verifies and restores" {
  let root = "tmp_cdc_repository_integration"
  remove_tree(root)
  @fs.create_dir(root)
  let repository = root + "/repository"
  let source = root + "/source"
  @fs.create_dir(source)
  @fs.create_dir(source + "/docs")
  @fs.create_dir(source + "/docs/empty")
  let original = Bytes::makei(32768, i => ((i * 19 + i / 71) % 256).to_byte())
  @fs.write_bytes_to_file(source + "/a.bin", original)
  @fs.write_bytes_to_file(source + "/duplicate.bin", original)
  @fs.write_string_to_file(source + "/docs/readme.txt", "version one")
  @fs.write_string_to_file(source + "/cache.tmp", "excluded")

  @moonbit-cdc-snapshot.init_repository(repository)
  let config : @moonbit-cdc-snapshot.FastCdcConfig = {
    min: 128,
    average: 512,
    max: 2048,
  }
  let first = @moonbit-cdc-snapshot.create_snapshot(
    repository,
    source,
    "baseline",
    config~,
    excludes=["**/*.tmp"],
  )
  assert_eq(first.file_count, 3)
  assert_true(first.directory_count >= 2)
  assert_eq(@moonbit-cdc-snapshot.list_snapshot_ids(repository), ["baseline"])
  ignore(
    @moonbit-cdc-snapshot.verify_repository_snapshot(repository, "baseline"),
  )

  let changed_array : Array[Byte] = []
  for index in 0..<16384 {
    changed_array.push(original[index])
  }
  for byte in b"inserted bytes"[:] {
    changed_array.push(byte)
  }
  for index in 16384..<original.length() {
    changed_array.push(original[index])
  }
  let changed = Bytes::from_array(changed_array)
  @fs.write_bytes_to_file(source + "/a.bin", changed)
  @fs.write_string_to_file(source + "/docs/readme.txt", "version one")
  @fs.write_string_to_file(source + "/new.bin", "new file")
  let second = @moonbit-cdc-snapshot.create_snapshot(
    repository,
    source,
    "updated",
    config~,
    excludes=["**/*.tmp"],
  )
  assert_eq(second.file_count, 4)
  let difference = @moonbit-cdc-snapshot.compare_repository_snapshots(
    repository, "baseline", "updated",
  )
  assert_eq(difference.added, ["new.bin"])
  assert_eq(difference.changed, ["a.bin"])
  assert_eq(difference.unchanged, ["docs/readme.txt", "duplicate.bin"])
  assert_true(difference.reused_chunk_bytes > 0L)
  assert_eq(
    difference.reused_chunk_bytes + difference.new_chunk_bytes,
    second.total_bytes,
  )

  let analysis = @moonbit-cdc-snapshot.analyze_repository_snapshots(
    repository, "baseline", "updated",
  )
  assert_eq(analysis.reused_chunk_bytes, difference.reused_chunk_bytes)
  assert_eq(analysis.new_chunk_bytes, difference.new_chunk_bytes)
  assert_eq(
    analysis.reused_chunk_count + analysis.new_chunk_count,
    second.chunk_count,
  )
  let mut found_changed_file = false
  let mut found_added_file = false
  let mut per_file_reused_bytes = 0L
  let mut per_file_new_bytes = 0L
  for item in analysis.files {
    per_file_reused_bytes += item.reused_chunk_bytes
    per_file_new_bytes += item.new_chunk_bytes
    if item.path == "a.bin" {
      found_changed_file = true
      assert_eq(item.change, @moonbit-cdc-snapshot.SnapshotFileChange::Changed)
      assert_true(item.reused_chunk_count > 0)
      assert_true(item.new_chunk_count > 0)
    }
    if item.path == "new.bin" {
      found_added_file = true
      assert_eq(item.change, @moonbit-cdc-snapshot.SnapshotFileChange::Added)
      assert_eq(item.reused_chunk_count, 0)
      assert_true(item.new_chunk_count > 0)
    }
  }
  assert_true(found_changed_file)
  assert_true(found_added_file)
  assert_eq(per_file_reused_bytes, analysis.reused_chunk_bytes)
  assert_eq(per_file_new_bytes, analysis.new_chunk_bytes)

  let destination = root + "/restored"
  @moonbit-cdc-snapshot.restore_repository_snapshot(
    repository, "updated", destination,
  )
  assert_eq(@fs.read_file_to_bytes(destination + "/a.bin"), changed)
  assert_eq(
    @fs.read_file_to_string(destination + "/docs/readme.txt"),
    "version one",
  )
  assert_true(@fs.is_dir(destination + "/docs/empty"))
  try {
    @moonbit-cdc-snapshot.restore_repository_snapshot(
      repository, "updated", destination,
    )
    panic()
  } catch {
    @moonbit-cdc-snapshot.SnapshotError::SnapshotError(_) => ()
  }

  let stats = @moonbit-cdc-snapshot.inspect_repository(repository)
  assert_eq(stats.snapshot_count, 2)
  assert_eq(stats.file_count, 7)
  assert_true(stats.object_count > 0)
  remove_tree(root)
}

///|
async test "garbage collection previews by default and forgets explicitly" {
  let root = "tmp_cdc_repository_gc"
  remove_tree(root)
  @fs.create_dir(root)
  let repository = root + "/repository"
  let source = root + "/source.bin"
  @fs.write_string_to_file(source, "live chunk")
  @moonbit-cdc-snapshot.init_repository(repository)
  ignore(
    @moonbit-cdc-snapshot.create_snapshot(repository, source, "keep", config={
      min: 16,
      average: 64,
      max: 256,
    }),
  )

  let orphan_bytes = b"orphan object"
  let orphan_digest = @moonbit-cdc-snapshot.sha256_hex(orphan_bytes[:])
  let shard = repository + "/objects/" + orphan_digest[:2].to_owned()
  @fs.create_dir(shard)
  @fs.write_bytes_to_file(
    shard + "/" + orphan_digest[2:].to_owned(),
    orphan_bytes,
  )
  let interrupted_write = repository + "/tmp/crashed-write.part"
  @fs.write_bytes_to_file(interrupted_write, b"partial")
  let preview = @moonbit-cdc-snapshot.garbage_collect(repository, false)
  assert_eq(preview.candidate_count, 1)
  assert_eq(preview.candidate_bytes, orphan_bytes.length().to_int64())
  assert_eq(preview.temporary_count, 1)
  assert_eq(preview.temporary_bytes, 7L)
  assert_true(@fs.path_exists(shard + "/" + orphan_digest[2:].to_owned()))
  assert_true(@fs.path_exists(interrupted_write))
  let applied = @moonbit-cdc-snapshot.garbage_collect(repository, true)
  assert_eq(applied.removed_count, 1)
  assert_eq(applied.removed_temporary_count, 1)
  assert_false(@fs.path_exists(shard + "/" + orphan_digest[2:].to_owned()))
  assert_false(@fs.path_exists(interrupted_write))

  let forget_preview = @moonbit-cdc-snapshot.forget_snapshot(
    repository, "keep", false,
  )
  assert_false(forget_preview.applied)
  assert_eq(@moonbit-cdc-snapshot.list_snapshot_ids(repository), ["keep"])
  let forgotten = @moonbit-cdc-snapshot.forget_snapshot(
    repository, "keep", true,
  )
  assert_true(forgotten.applied)
  assert_eq(@moonbit-cdc-snapshot.list_snapshot_ids(repository), [])
  let cleanup = @moonbit-cdc-snapshot.garbage_collect(repository, true)
  assert_true(cleanup.removed_count > 0)
  remove_tree(root)
}

///|
async test "streaming repository accepts files larger than the old memory cap" {
  let root = "tmp_cdc_repository_large"
  remove_tree(root)
  @fs.create_dir(root)
  let repository = root + "/repository"
  let source = root + "/large.bin"
  @moonbit-cdc-snapshot.init_repository(repository)
  let block = Bytes::makei(256 * 1024, i => ((i * 23 + i / 89) % 256).to_byte())
  let writer = @afs.create(source)
  for _ in 0..<257 {
    writer.write(block)
  }
  writer.close()
  let config : @moonbit-cdc-snapshot.FastCdcConfig = {
    min: 64 * 1024,
    average: 1024 * 1024,
    max: 2 * 1024 * 1024,
  }
  let summary = @moonbit-cdc-snapshot.create_snapshot(
    repository,
    source,
    "large",
    config~,
  )
  assert_eq(summary.total_bytes, (257 * 256 * 1024).to_int64())
  assert_true(summary.total_bytes > (64 * 1024 * 1024).to_int64())
  ignore(@moonbit-cdc-snapshot.verify_repository_snapshot(repository, "large"))
  remove_tree(root)
}

///|
async test "repository verification detects corruption and failed restore cleans staging" {
  let root = "tmp_cdc_repository_corruption"
  remove_tree(root)
  @fs.create_dir(root)
  let repository = root + "/repository"
  let source = root + "/source.bin"
  let payload = Bytes::makei(4096, index => (index * 13).to_byte())
  @fs.write_bytes_to_file(source, payload)
  @moonbit-cdc-snapshot.init_repository(repository)
  ignore(@moonbit-cdc-snapshot.create_snapshot(repository, source, "stable"))
  let manifest = @moonbit-cdc-snapshot.read_repository_manifest(
    repository, "stable",
  )
  let first_chunk = manifest.files[0].chunks[0]
  let object_path = repository +
    "/objects/" +
    first_chunk.digest[:2].to_owned() +
    "/" +
    first_chunk.digest[2:].to_owned()
  @fs.write_bytes_to_file(object_path, b"corrupt")

  try {
    ignore(
      @moonbit-cdc-snapshot.verify_repository_snapshot(repository, "stable"),
    )
    panic()
  } catch {
    @moonbit-cdc-snapshot.SnapshotError::SnapshotError(_) => ()
  }
  let destination = root + "/restored.bin"
  try {
    @moonbit-cdc-snapshot.restore_repository_snapshot(
      repository, "stable", destination,
    )
    panic()
  } catch {
    @moonbit-cdc-snapshot.SnapshotError::SnapshotError(_) => ()
  }
  assert_false(@fs.path_exists(destination))
  assert_false(@fs.path_exists(destination + ".moonbit-cdc-stable.part"))
  remove_tree(root)
}

///|
async test "repository init is idempotent and refuses an unrelated directory" {
  let root = "tmp_cdc_repository_init"
  remove_tree(root)
  @fs.create_dir(root)
  let repository = root + "/repository"
  @moonbit-cdc-snapshot.init_repository(repository)
  @moonbit-cdc-snapshot.init_repository(repository)
  let unrelated = root + "/unrelated"
  @fs.create_dir(unrelated)
  @fs.write_string_to_file(unrelated + "/keep.txt", "keep")
  try {
    @moonbit-cdc-snapshot.init_repository(unrelated)
    panic()
  } catch {
    @moonbit-cdc-snapshot.SnapshotError::SnapshotError(_) => ()
  }
  assert_eq(@fs.read_file_to_string(unrelated + "/keep.txt"), "keep")
  remove_tree(root)
}
