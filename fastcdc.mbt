///|
///  FastCDC cut-point parameters. `average` must be a power of two.
pub(all) struct FastCdcConfig {
  min : Int32
  average : Int32
  max : Int32
} derive(Eq, Debug)

///|
pub extend FastCdcConfig with Eq::{not_equal, equal}

///|
pub extend FastCdcConfig with @debug.Debug::{to_repr}

///|
/// Byte range of one chunk in an input buffer.
pub(all) struct ChunkRange {
  start : Int32
  length : Int32
} derive(Eq, Debug)

///|
pub extend ChunkRange with Eq::{not_equal, equal}

///|
pub extend ChunkRange with @debug.Debug::{to_repr}

///|
/// Default chunk sizes are 16 KiB, 64 KiB and 256 KiB.
pub let default_config : FastCdcConfig = {
  min: 16 * 1024,
  average: 64 * 1024,
  max: 256 * 1024,
}

///|
/// Incremental chunker with a bounded ring buffer. A cut is committed only
/// after one byte beyond the maximum window arrives; that preserves the
/// short-final-chunk rule used by `fastcdc_ranges`.
pub struct FastCdcStream {
  config : FastCdcConfig
  buffer : FixedArray[Byte]
  mut head : Int32
  mut length : Int32
  mut emitted : Int32
  mask_small : UInt64
  mask_large : UInt64
}

///|
pub fn FastCdcStream::new(
  config : FastCdcConfig,
) -> FastCdcStream raise SnapshotError {
  config.validate()
  let bits = log2_power_of_two(config.average)
  {
    config,
    buffer: FixedArray::make(config.max + 1, b'\x00'),
    head: 0,
    length: 0,
    emitted: 0,
    mask_small: (1UL << (bits + 1)) - 1UL,
    mask_large: (1UL << (bits - 1)) - 1UL,
  }
}

///|
/// Feed any number of bytes. Emitted chunks are byte-identical regardless of
/// how the caller divides the input into read buffers.
pub fn FastCdcStream::push(
  self : FastCdcStream,
  input : BytesView,
) -> Array[Bytes] raise SnapshotError {
  let ready : Array[Bytes] = []
  let capacity = self.config.max + 1
  for byte in input {
    let tail = (self.head + self.length) % capacity
    self.buffer[tail] = byte
    self.length += 1
    if self.length > self.config.max {
      let cut = self.find_cut()
      guard self.emitted < max_chunk_count else {
        raise SnapshotError("snapshot exceeds the 1,000,000 chunk limit")
      }
      let bytes : Array[Byte] = []
      for index in 0..<cut {
        bytes.push(self.buffer[(self.head + index) % capacity])
      }
      ready.push(Bytes::from_array(bytes))
      self.head = (self.head + cut) % capacity
      self.length -= cut
      self.emitted += 1
    }
  }
  ready
}

///|
/// Flush the remaining short final chunk. Calling `finish` more than once is
/// safe and returns an empty array after the first call.
pub fn FastCdcStream::finish(
  self : FastCdcStream,
) -> Array[Bytes] raise SnapshotError {
  if self.length == 0 {
    return []
  }
  guard self.emitted < max_chunk_count else {
    raise SnapshotError("snapshot exceeds the 1,000,000 chunk limit")
  }
  let capacity = self.config.max + 1
  let bytes : Array[Byte] = []
  for index in 0..<self.length {
    bytes.push(self.buffer[(self.head + index) % capacity])
  }
  self.length = 0
  self.emitted += 1
  [Bytes::from_array(bytes)]
}

///|
fn FastCdcStream::find_cut(self : FastCdcStream) -> Int32 {
  let capacity = self.config.max + 1
  let mut hash = 0UL
  let mut index = self.config.min - 1
  while index < self.config.average {
    hash = (hash << 1) + gear(self.buffer[(self.head + index) % capacity])
    if (hash & self.mask_small) == 0UL {
      return index + 1
    }
    index += 1
  }
  while index < self.config.max {
    hash = (hash << 1) + gear(self.buffer[(self.head + index) % capacity])
    if (hash & self.mask_large) == 0UL {
      return index + 1
    }
    index += 1
  }
  self.config.max
}

///|
/// Validate parameters before a manifest or file is processed.
pub fn FastCdcConfig::validate(
  self : FastCdcConfig,
) -> Unit raise SnapshotError {
  guard self.min > 0 else {
    raise SnapshotError("minimum chunk size must be positive")
  }
  guard self.average >= 2 else {
    raise SnapshotError("average chunk size must be at least two bytes")
  }
  guard self.average >= self.min else {
    raise SnapshotError("average chunk size must be at least the minimum")
  }
  guard self.max >= self.average else {
    raise SnapshotError("maximum chunk size must be at least the average")
  }
  guard self.max <= max_chunk_size else {
    raise SnapshotError("maximum chunk size exceeds the 4 MiB safety limit")
  }
  let mut n = self.average
  while n > 1 && n % 2 == 0 {
    n /= 2
  }
  guard n == 1 else {
    raise SnapshotError("average chunk size must be a power of two")
  }
}

///|
/// Find deterministic FastCDC boundaries using the project's seeded Gear table.
/// The caller can concatenate these ranges to recover the exact input bytes.
pub fn fastcdc_ranges(
  input : BytesView,
  config~ : FastCdcConfig = default_config,
) -> Array[ChunkRange] raise SnapshotError {
  let stream = FastCdcStream::new(config)
  let chunks = stream.push(input)
  let final_chunks = stream.finish()
  let ranges : Array[ChunkRange] = []
  let mut start = 0
  for chunk in chunks {
    ranges.push({ start, length: chunk.length(), })
    start += chunk.length()
  }
  for chunk in final_chunks {
    ranges.push({ start, length: chunk.length(), })
    start += chunk.length()
  }
  ranges
}

///|
fn log2_power_of_two(value : Int32) -> Int32 {
  let mut n = value
  let mut bits = 0
  while n > 1 {
    n /= 2
    bits += 1
  }
  bits
}

///|
/// SplitMix64 provides a fixed, reproducible 256-entry Gear table. The seed is
/// part of the file format contract and must not change for manifest version 2.
fn gear(byte : Byte) -> UInt64 {
  let mut z = 0x6D6F6F6E62697431UL +
    byte.to_int().to_uint64() * 0x9E3779B97F4A7C15UL
  z += 0x9E3779B97F4A7C15UL
  z = (z ^ (z >> 30)) * 0xBF58476D1CE4E5B9UL
  z = (z ^ (z >> 27)) * 0x94D049BB133111EBUL
  z ^ (z >> 31)
}
