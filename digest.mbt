///|
/// SHA-256 as canonical lowercase hexadecimal, used for chunks and files.
pub fn sha256_hex(input : BytesView) -> String {
  @base16.encode(@sha2.hash(input))
}
