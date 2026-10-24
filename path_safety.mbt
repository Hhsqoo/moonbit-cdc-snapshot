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
      segment_start = index + 1
    } else {
      guard bytes[index] != b'\\' &&
        bytes[index] != b':' &&
        bytes[index].to_int() != 0 else {
        raise SnapshotError("manifest path contains a forbidden character")
      }
    }
  }
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
