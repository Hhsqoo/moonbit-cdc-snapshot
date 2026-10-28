# MoonBit CDC Snapshot

A local command-line tool for creating, inspecting, comparing, verifying, and
restoring content-defined snapshots of files and directory trees. The storage
engine, manifest validation, chunker, and command-line program are implemented
in MoonBit.

## Build and test

Install the stable MoonBit CLI and Python 3, then run:

```sh
moon update
moon fmt --check
moon check --target native
moon build --target native
moon test --target native
python3 scripts/cli_smoke.py
```

The command-line program currently targets MoonBit Native. Tests include a
64 MiB+ input to check that snapshots stream file data instead of loading whole
files into memory.

## Quick start

Initialize a repository outside the directory you plan to snapshot:

```sh
moon run --target native cmd/main -- init ./backup-store
moon run --target native cmd/main -- snapshot ./backup-store ./project before-upgrade
moon run --target native cmd/main -- list ./backup-store
```

Change or add a file under `./project`, then create and inspect a second
snapshot:

```sh
moon run --target native cmd/main -- snapshot ./backup-store ./project after-upgrade
moon run --target native cmd/main -- compare ./backup-store before-upgrade after-upgrade
moon run --target native cmd/main -- analyze ./backup-store before-upgrade after-upgrade
moon run --target native cmd/main -- verify ./backup-store after-upgrade
```

Restore the selected snapshot to a new destination:

```sh
moon run --target native cmd/main -- restore ./backup-store after-upgrade ./project-restored
```

The `analyze` output separates reused and new chunk references for every file
in the second snapshot. The repository must be outside the source directory.

The destination passed to `restore` must not already exist. Restores are
assembled in a temporary path and published with a same-volume rename after
their chunks and complete-file digests have been checked.

## Commands

```text
init <repository>
snapshot <repository> <source-file-or-directory> <id> [--exclude GLOB] [--skip-symlinks] [--min N --average N --max N]
list <repository>
show <repository> <id>
verify <repository> [id]
restore <repository> <id> <new-destination>
compare <repository> <old-id> <new-id>
analyze <repository> <old-id> <new-id>
stats <repository>
gc <repository> [--apply]
forget <repository> <id> [--apply]
```

Snapshot IDs use lowercase letters, digits, `_`, and `-`. Exclusion patterns
use `/` separators: `*` matches within one path component and `**` can cross
directory separators. A matched directory and its contents are skipped.
Symbolic links are rejected by default. `--skip-symlinks` omits them without
following their targets. Other special files are rejected. Manifest paths also
reject Windows device names, trailing periods/spaces, control characters and
filename characters that Windows cannot represent; manifests with such paths
are rejected so restores remain portable across Windows and Unix systems.
Chunk sizes are in bytes; the average must be a power of two, and the values
must satisfy `min <= average <= max <= 4 MiB`.

`compare` reports path-level additions, removals, changes, and unchanged files,
plus the number of current chunk-reference bytes whose digests occur in the
older snapshot. Repeated identical chunks are counted once per reference, so
that figure describes reusable logical bytes and is not a physical-space or
runtime benchmark.

`analyze` expands that summary by current file. It reports whether each path is
added, changed, or unchanged, then counts chunk references and logical bytes
reused from the older manifest versus new to it. It reads the two validated
manifests only; it does not reread source files or verify object payloads. A
repeated chunk reference is counted for every file that uses it, so the result
is not a physical storage savings estimate. The snapshots must use the same
chunking settings, as with `compare`.

`gc` and `forget` show a preview by default. Pass `--apply` to remove orphaned
objects and interrupted `.part` files, or to remove a snapshot manifest.
Forgetting a snapshot does not immediately delete its objects; run GC afterward.
GC validates every manifest and refuses to remove objects when referenced
objects are missing or have invalid sizes. Repository mutations use an advisory
lock shared by this CLI, so GC can safely scan the temporary directory while
the lock is held.

## Storage and limits

- Objects are immutable files addressed by lowercase SHA-256, stored under
  `objects/<first-two-hex>/<remaining-hex>`.
- Snapshot manifests use format 2 JSON and contain sorted relative paths,
  FastCDC parameters, per-file hashes, and chunk references.
- Chunking defaults to 16 KiB minimum, 64 KiB average, and 256 KiB maximum.
  The configured maximum cannot exceed 4 MiB. Reads use a fixed 256 KiB buffer.
- The manifest parser caps each manifest at 64 MiB and 100,000 file or
  directory entries. A snapshot is capped at 1,000,000 chunk references.
- Data is stored locally without encryption or compression. The repository does
  not preserve ownership, permissions, timestamps, hard links, sparse extents,
  extended attributes, or symbolic links.
- Snapshotting checks file size and modification time before and after reading.
  This detects common concurrent edits, but does not lock source files.
- The repository must be outside the source directory. Use a separate path for
  backup data so a snapshot cannot recursively include its own objects.

## Chunking method

Chunk boundaries use a deterministic FastCDC-style gear-hash scan. It skips the
minimum region, applies a stricter mask before the average size, a looser mask
after it, and cuts at the maximum if neither mask matches. The project
generates a fixed Gear table with SplitMix64 and seed
`0x6D6F6F6E62697431`. This is a project-specific variant; its boundaries are
not promised to match other FastCDC implementations. The cut-point strategy is
based on the [FastCDC paper](https://www.usenix.org/conference/atc16/technical-sessions/presentation/xia).

SHA-256 uses the pinned
[`moonbitstack/mooncrypt`](https://mooncakes.io/docs/moonbitstack/mooncrypt)
dependency. The project does not claim a new chunking algorithm; its work is in
the MoonBit streaming implementation, repository layout, validated manifests,
safe local operations, and end-to-end tooling.

## Relationship to MoonRestore

The projects share a problem area and several basic capabilities: file
snapshots, CDC/content-addressed chunks, verification, comparison, and restore.
This project does not claim those features or the FastCDC approach as unique.

This repository is an independent implementation and does not reuse
MoonRestore source code.
The execution path is also different: this project's file and repository
commands are built for MoonBit Native (`moon run --target native`), while
MoonRestore's documented CLI entry is `node bin/moonrestore.mjs` and its
documented full disk, network, and GUI runtime depends on Node. This is a
runtime and packaging distinction, not a claim that MoonRestore lacks Native
MoonBit code.

The functional extension here is `analyze`, which expands the aggregate reuse
figures already reported by `compare` into per-file counts of reusable and new
CDC chunk references and their logical bytes. It reads two validated manifests;
it does not introduce a different backup or deduplication mechanism. MoonRestore
documents a broader recovery application, including a workbench, database
workflows, and remote copies; those are outside this project's current scope.
The per-file report is not a disk-space or speed benchmark, and this project
does not present itself as a replacement for MoonRestore.
