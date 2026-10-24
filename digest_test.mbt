///|
/// SHA-256 test vector from FIPS 180-4.
test "SHA-256 uses canonical lowercase hex" {
  assert_eq(
    @moonbit-cdc-snapshot.sha256_hex(b"abc"[:]),
    "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad",
  )
  assert_eq(
    @moonbit-cdc-snapshot.sha256_hex(b""[:]),
    "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
  )
}
