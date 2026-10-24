///|
/// Stable merge sort for manifest strings. We own the ordering rule instead of
/// relying on platform directory enumeration order.
fn stable_sort_strings(values : Array[String]) -> Array[String] {
  let mut source = values
  let length = source.length()
  let mut width = 1
  while width < length {
    let target : Array[String] = []
    let mut start = 0
    while start < length {
      let middle = if start + width < length { start + width } else { length }
      let end = if start + width * 2 < length {
        start + width * 2
      } else {
        length
      }
      let mut left = start
      let mut right = middle
      while left < middle || right < end {
        if right >= end ||
          (
            left < middle &&
            lexicographically_less_or_equal(source[left], source[right])
          ) {
          target.push(source[left])
          left += 1
        } else {
          target.push(source[right])
          right += 1
        }
      }
      start = end
    }
    source = target
    width *= 2
  }
  source
}

///|
/// Stable merge sort for files using normalized relative paths.
fn stable_sort_file_records(values : Array[FileRecord]) -> Array[FileRecord] {
  let mut source = values
  let length = source.length()
  let mut width = 1
  while width < length {
    let target : Array[FileRecord] = []
    let mut start = 0
    while start < length {
      let middle = if start + width < length { start + width } else { length }
      let end = if start + width * 2 < length {
        start + width * 2
      } else {
        length
      }
      let mut left = start
      let mut right = middle
      while left < middle || right < end {
        if right >= end ||
          (
            left < middle &&
            lexicographically_less_or_equal(
              source[left].path,
              source[right].path,
            )
          ) {
          target.push(source[left])
          left += 1
        } else {
          target.push(source[right])
          right += 1
        }
      }
      start = end
    }
    source = target
    width *= 2
  }
  source
}

///|
/// Compare UTF-8 bytes directly so paths are ordered consistently regardless
/// of locale or the standard string ordering implementation.
fn lexicographically_less_or_equal(left : String, right : String) -> Bool {
  let left_bytes = @utf8.encode(left)
  let right_bytes = @utf8.encode(right)
  let shared = if left_bytes.length() < right_bytes.length() {
    left_bytes.length()
  } else {
    right_bytes.length()
  }
  for index in 0..<shared {
    if left_bytes[index] < right_bytes[index] {
      return true
    }
    if left_bytes[index] > right_bytes[index] {
      return false
    }
  }
  left_bytes.length() <= right_bytes.length()
}
