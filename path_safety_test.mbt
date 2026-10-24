///|
test "snapshot ids accept only safe filename characters" {
  @moonbit-cdc-snapshot.validate_snapshot_id("october-24")
  @moonbit-cdc-snapshot.validate_snapshot_id("baseline_2")
  for invalid in ["", ".", "..", "../escape", "UPPER", "two words", "a/b"] {
    try {
      @moonbit-cdc-snapshot.validate_snapshot_id(invalid)
      panic()
    } catch {
      @moonbit-cdc-snapshot.SnapshotError::SnapshotError(_) => ()
    }
  }
}

///|
test "relative paths reject traversal, absolute paths and Windows prefixes" {
  @moonbit-cdc-snapshot.validate_relative_path("nested/data.bin")
  @moonbit-cdc-snapshot.validate_relative_path("资料/说明.txt")
  for
    invalid in [
      "", "/root/file", "../escape", "a/../escape", "a//b", "C:/outside", "a\\b",
      ".", "a/.",
    ] {
    try {
      @moonbit-cdc-snapshot.validate_relative_path(invalid)
      panic()
    } catch {
      @moonbit-cdc-snapshot.SnapshotError::SnapshotError(_) => ()
    }
  }
}

///|
test "glob supports component stars and recursive globstars" {
  assert_true(@moonbit-cdc-snapshot.glob_matches("*.txt", "readme.txt"))
  assert_true(@moonbit-cdc-snapshot.glob_matches("**/*.tmp", "a/b/cache.tmp"))
  assert_true(@moonbit-cdc-snapshot.glob_matches("**/*.tmp", "cache.tmp"))
  assert_true(@moonbit-cdc-snapshot.glob_matches("src/*", "src/main.mbt"))
  assert_false(@moonbit-cdc-snapshot.glob_matches("src/*", "src/lib/main.mbt"))
  assert_false(@moonbit-cdc-snapshot.glob_matches("*.txt", "sub/readme.txt"))
  assert_false(@moonbit-cdc-snapshot.glob_matches("**/*.tmp", "a/b/file.txt"))
}
