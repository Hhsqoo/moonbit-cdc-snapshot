///|
pub fn validate_snapshot_id(id : String) -> Unit raise SnapshotError {
  let encoded = @utf8.encode(id)
  guard encoded.length() > 0 && encoded.length() <= 64 else {
    raise SnapshotError("snapshot id must contain 1 to 64 characters")
  }
  for byte in encoded[:] {
    guard byte is (b'a'..<=b'z' | b'0'..<=b'9' | b'_' | b'-') else {
      raise SnapshotError(
        "snapshot id may contain only lowercase letters, digits, '_' and '-'",
      )
    }
  }
  guard id != "." && id != ".." else {
    raise SnapshotError("snapshot id is reserved")
  }
}

///|
/// Reject absolute, ambiguous, and parent-traversing manifest paths.
pub fn validate_relative_path(path : String) -> Unit raise SnapshotError {
  let bytes = @utf8.encode(path)
  guard bytes.length() > 0 && bytes.length() <= max_relative_path_length else {
    raise SnapshotError("manifest path must contain 1 to 4096 bytes")
  }
  guard bytes[0] != b'/' && bytes[0] != b'\\' else {
    raise SnapshotError("manifest paths must be relative")
  }
  let mut segment_start = 0
  for index in 0..<=bytes.length() {
    if index == bytes.length() || bytes[index] == b'/' {
      let segment_length = index - segment_start
      guard segment_length > 0 else {
        raise SnapshotError("manifest path contains an empty component")
      }
      guard !(segment_length == 1 && bytes[segment_start] == b'.') &&
        !(segment_length == 2 &&
        bytes[segment_start] == b'.' &&
        bytes[segment_start + 1] == b'.') else {
        raise SnapshotError("manifest path contains a dot component")
      }
      guard bytes[index - 1] != b'.' && bytes[index - 1] != b' ' else {
        raise SnapshotError(
          "manifest path components cannot end in a period or space",
        )
      }
      guard !is_windows_reserved_device_name(bytes[segment_start:index]) else {
        raise SnapshotError("manifest path contains a reserved device name")
      }
      segment_start = index + 1
    } else {
      guard bytes[index].to_int() >= 32 &&
        bytes[index] != b'<' &&
        bytes[index] != b'>' &&
        bytes[index] != b'"' &&
        bytes[index] != b'|' &&
        bytes[index] != b'?' &&
        bytes[index] != b'*' &&
        bytes[index] != b'\\' &&
        bytes[index] != b':' &&
        bytes[index].to_int() != 127 else {
        raise SnapshotError("manifest path contains a forbidden character")
      }
    }
  }
}

///|
/// Windows normalizes trailing dots/spaces and treats DOS device names as
/// devices even when an extension is present. Reject these names in manifests
/// so restoring an untrusted snapshot cannot open a device path by mistake.
fn is_windows_reserved_device_name(segment : BytesView) -> Bool {
  let mut stem_length = segment.length()
  for index in 0..<segment.length() {
    if segment[index] == b'.' {
      stem_length = index
      break
    }
  }
  while stem_length > 0 &&
        (segment[stem_length - 1] == b' ' || segment[stem_length - 1] == b'.') {
    stem_length -= 1
  }
  let stem = segment[:stem_length]
  ascii_name_equal_ignore_case(stem, "con") ||
  ascii_name_equal_ignore_case(stem, "prn") ||
  ascii_name_equal_ignore_case(stem, "aux") ||
  ascii_name_equal_ignore_case(stem, "nul") ||
  ascii_name_equal_ignore_case(stem, "conin$") ||
  ascii_name_equal_ignore_case(stem, "conout$") ||
  ascii_name_equal_ignore_case(stem, "clock$") ||
  is_numbered_windows_device_name(stem, "com") ||
  is_numbered_windows_device_name(stem, "lpt")
}

///|
fn is_numbered_windows_device_name(stem : BytesView, prefix : String) -> Bool {
  if stem.length() == 4 && stem[3] >= b'1' && stem[3] <= b'9' {
    return ascii_name_equal_ignore_case(stem[:3], prefix)
  }
  if stem.length() == 5 &&
    stem[3] == b'\xC2' &&
    (stem[4] == b'\xB9' || stem[4] == b'\xB2' || stem[4] == b'\xB3') {
    return ascii_name_equal_ignore_case(stem[:3], prefix)
  }
  false
}

///|
fn ascii_name_equal_ignore_case(value : BytesView, expected : String) -> Bool {
  let expected_bytes = @utf8.encode(expected)
  if value.length() != expected_bytes.length() {
    return false
  }
  for index in 0..<value.length() {
    let code = value[index].to_int()
    let folded = if code >= 65 && code <= 90 { code + 32 } else { code }
    if folded != expected_bytes[index].to_int() {
      return false
    }
  }
  true
}

///|
/// Validate a slash-separated include/exclude glob.
pub fn validate_glob(pattern : String) -> Unit raise SnapshotError {
  let bytes = @utf8.encode(pattern)
  guard bytes.length() > 0 && bytes.length() <= 256 else {
    raise SnapshotError("glob patterns must contain 1 to 256 bytes")
  }
  guard bytes[0] != b'/' && bytes[0] != b'\\' else {
    raise SnapshotError("glob patterns must be relative")
  }
  let mut segment_start = 0
  for index in 0..<=bytes.length() {
    if index == bytes.length() || bytes[index] == b'/' {
      let segment_length = index - segment_start
      guard segment_length > 0 else {
        raise SnapshotError("glob pattern contains an empty component")
      }
      guard !(segment_length == 1 && bytes[segment_start] == b'.') &&
        !(segment_length == 2 &&
        bytes[segment_start] == b'.' &&
        bytes[segment_start + 1] == b'.') else {
        raise SnapshotError("glob pattern contains a dot component")
      }
      segment_start = index + 1
    } else {
      guard bytes[index] != b'\\' &&
        bytes[index] != b':' &&
        bytes[index].to_int() != 0 else {
        raise SnapshotError("glob pattern contains a forbidden character")
      }
    }
  }
}

///|
/// Match a relative path. Single star matches within a component; double star
/// may cross slash separators. Patterns must match the whole path.
pub fn glob_matches(
  pattern : String,
  path : String,
) -> Bool raise SnapshotError {
  validate_glob(pattern)
  validate_relative_path(path)
  let pat = @utf8.encode(pattern)
  let text = @utf8.encode(path)
  let memo : @hashmap.HashMap[String, Bool] = HashMap([])
  glob_match_at(pat[:], text[:], 0, 0, memo)
}

///|
fn glob_match_at(
  pattern : BytesView,
  path : BytesView,
  pattern_index : Int32,
  path_index : Int32,
  memo : @hashmap.HashMap[String, Bool],
) -> Bool {
  let key = "\{pattern_index}:\{path_index}"
  match memo.get(key) {
    Some(result) => return result
    None => ()
  }
  let matched = if pattern_index == pattern.length() {
    path_index == path.length()
  } else if pattern[pattern_index] == b'*' {
    let is_globstar = pattern_index + 1 < pattern.length() &&
      pattern[pattern_index + 1] == b'*'
    if is_globstar {
      let after_stars = pattern_index + 2
      if after_stars < pattern.length() && pattern[after_stars] == b'/' {
        glob_match_at(pattern, path, after_stars + 1, path_index, memo) ||
        (
          path_index < path.length() &&
          glob_match_at(pattern, path, pattern_index, path_index + 1, memo)
        )
      } else {
        glob_match_at(pattern, path, after_stars, path_index, memo) ||
        (
          path_index < path.length() &&
          glob_match_at(pattern, path, pattern_index, path_index + 1, memo)
        )
      }
    } else {
      glob_match_at(pattern, path, pattern_index + 1, path_index, memo) ||
      (
        path_index < path.length() &&
        path[path_index] != b'/' &&
        glob_match_at(pattern, path, pattern_index, path_index + 1, memo)
      )
    }
  } else {
    path_index < path.length() &&
    pattern[pattern_index] == path[path_index] &&
    glob_match_at(pattern, path, pattern_index + 1, path_index + 1, memo)
  }
  memo.set(key, matched)
  matched
}
