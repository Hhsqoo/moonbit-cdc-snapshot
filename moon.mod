// Learn more about moon.mod configuration:
// https://docs.moonbitlang.com/en/latest/toolchain/moon/module.html
//
// To add a dependency, run this command in your terminal:
//   moon add moonbitlang/x
//
// Or manually declare it in `import`, for example:
// import {
//   "moonbitlang/x@0.4.6",
// }

name = "Hhsqoo/moonbit-cdc-snapshot"

version = "0.1.0"

readme = "README.md"

repository = "https://github.com/Hhsqoo/moonbit-cdc-snapshot"

license = "Apache-2.0"

keywords = [ "fastcdc", "backup", "deduplication", "snapshot" ]

preferred_target = "native"

description = "A local content-defined snapshot and verification CLI written in MoonBit."

import {
  "moonbitlang/x@0.5.6",
  "moonbitstack/mooncrypt@0.4.2",
  "moonbitstack/moonbase@0.4.0",
  "moonbitlang/async@0.21.3",
}
