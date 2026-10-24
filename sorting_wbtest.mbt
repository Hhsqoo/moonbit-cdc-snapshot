///|
test "stable sort orders strings lexically" {
  assert_eq(
    stable_sort_strings(["new.bin", "duplicate.bin", "docs/readme.txt"]),
    ["docs/readme.txt", "duplicate.bin", "new.bin"],
  )
}

///|
test "stable sort orders file records by normalized path" {
  let values : Array[FileRecord] = [
    { path: "new.bin", size: 0L, digest: "", chunks: [], },
    { path: "duplicate.bin", size: 0L, digest: "", chunks: [], },
    { path: "docs/readme.txt", size: 0L, digest: "", chunks: [], },
  ]
  let sorted = stable_sort_file_records(values)
  assert_eq(sorted[0].path, "docs/readme.txt")
  assert_eq(sorted[1].path, "duplicate.bin")
  assert_eq(sorted[2].path, "new.bin")
}
