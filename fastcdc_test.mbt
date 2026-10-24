///|
/// Small parameters keep boundary tests fast and deterministic.
let test_config : @moonbit-cdc-snapshot.FastCdcConfig = {
  min: 16,
  average: 64,
  max: 256,
}

///|
test "FastCDC handles empty and short inputs" {
  assert_eq(@moonbit-cdc-snapshot.fastcdc_ranges(b""[:], config=test_config), [])
  let short = b"hello"
  let ranges = @moonbit-cdc-snapshot.fastcdc_ranges(
    short[:],
    config=test_config,
  )
  assert_eq(ranges, [{ start: 0, length: 5, }])
}

///|
test "FastCDC boundaries are deterministic and within limits" {
  let input = Bytes::makei(8192, i => (i * 37 % 256).to_byte())
  let first = @moonbit-cdc-snapshot.fastcdc_ranges(input[:], config=test_config)
  let second = @moonbit-cdc-snapshot.fastcdc_ranges(
    input[:],
    config=test_config,
  )
  assert_eq(first, second)
  assert_true(first.length() > 1)
  for i, range in first {
    assert_true(range.length <= test_config.max)
    if i < first.length() - 1 {
      assert_true(range.length >= test_config.min)
    }
    assert_true(range.start >= 0)
    assert_true(range.start + range.length <= input.length())
  }
  let rebuilt : Array[Byte] = []
  for range in first {
    for index in range.start..<(range.start + range.length) {
      rebuilt.push(input[index])
    }
  }
  assert_eq(Bytes::from_array(rebuilt), input)
}

///|
test "FastCDC rejects invalid chunk configuration" {
  try {
    ignore(
      @moonbit-cdc-snapshot.fastcdc_ranges(b"data"[:], config={
        min: 10,
        average: 63,
        max: 100,
      }),
    )
    panic()
  } catch {
    @moonbit-cdc-snapshot.SnapshotError::SnapshotError(_) => ()
  }
}

///|
test "streaming FastCDC matches one-shot boundaries at every buffer split" {
  let input = Bytes::makei(4097, i => ((i * 37 + i / 113) % 256).to_byte())
  let config : @moonbit-cdc-snapshot.FastCdcConfig = {
    min: 16,
    average: 64,
    max: 256,
  }
  let expected = @moonbit-cdc-snapshot.fastcdc_ranges(input[:], config~)
  for split in 0..<=input.length() {
    let stream = @moonbit-cdc-snapshot.FastCdcStream::new(config)
    let chunks = stream.push(input[:split])
    chunks.append(stream.push(input[split:]))
    chunks.append(stream.finish())
    let mut offset = 0
    for index, range in expected {
      assert_eq(range.start, offset)
      assert_eq(chunks[index].length(), range.length)
      offset += chunks[index].length()
    }
    assert_eq(offset, input.length())
  }
}

///|
test "streaming FastCDC preserves short final files and empty input" {
  let empty = @moonbit-cdc-snapshot.FastCdcStream::new(test_config)
  assert_eq(empty.push(b""[:]).length(), 0)
  assert_eq(empty.finish().length(), 0)

  let short = @moonbit-cdc-snapshot.FastCdcStream::new(test_config)
  assert_eq(short.push(b"short"[:]).length(), 0)
  let tail = short.finish()
  assert_eq(tail.length(), 1)
  assert_eq(tail[0], b"short")
}
