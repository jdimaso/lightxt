# LighTxt core

`FileBackedPieceTable` is the byte-addressed document engine. Opening a file
keeps one read-only descriptor and one tree node; it does not create a second
whole-file heap copy or virtual mapping. Edits path-copy an implicit treap and
retain immutable edit segments, so lookup/edit and undo snapshots are expected
O(log *pieces*).

## UI-facing path

1. Open with `FileBackedPieceTable(opening:)`.
2. Take a cheap `snapshot()` for a render, parse, or background search pass.
3. Request only the visible UTF-8 byte range with `snapshot.data(in:)` or stream
   slices using `forEachByteSlice(in:_:)`.
4. Apply `insert`, `delete`, or `replace` using UTF-8 byte ranges.
5. Use `snapshot.search` for streamed results, or `firstMatch` / `allMatches`
   for bounded convenience operations.
6. Call `save`, `saveAs`, or `saveCopy`. Saves stream to a Foundation item-
   replacement location (with a private app-temp fallback), then publish only
   to the exact authorized URL; the source descriptor remains readable throughout.
7. Use `replaceAll(matching:...)` for bulk changes. It streams a captured
   revision into one private temp inode and commits one file-backed root/undo state,
   rather than building a match array or one piece per replacement.

The API intentionally has no unbounded `snapshot.data()` or `utf8String()`.
Whole-document consumers must opt into `materializedData(maximumByteCount:)`,
whose default ceiling is 64 MiB.

## Whole-document View accelerators

View mode is deliberately separate from the edit engine above. Eligible JSON
files may use a physical-headroom-gated anonymous raw-byte copy plus anonymous
40-byte container records. Through 4 GiB the native record pass overlaps a full
simdjson traversal; larger files use an exact 64-bit grammar/record pass plus
SIMD UTF-8 validation. The copy is never a mapping of the user-controlled inode;
malformed and memory-ineligible documents use the bounded Swift/unlinked-disk fallback.
Memory pressure can flush the compact records and discard the raw copy while
lazy tree pages continue through the retained snapshot. Close unmaps both.

CSV View never retains a whole-file copy. A native RFC-4180 lexical scanner
consumes the same bounded source slices and emits only adaptive sparse row
checkpoints; cell lookup rescans from the nearest checkpoint. The native and
Swift reference scanners are parity-tested across quote, CRLF, chunk, and
cancellation boundaries. Filters stream matching source ordinals into an
unlinked temporary row map. Stable sorts persist exact comparison keys in
bounded external runs and compact them incrementally with fixed fan-in, keeping
both memory and live file descriptors bounded. Column profiles use bounded,
stratified sampling for large tables. Row mutations are atomic byte-edit batches;
column mutations stream into a replacement mapping and publish as one undo root.

## Memory behavior

- Original bytes are served with thread-safe `pread` calls into buffers of at
  most 1 MiB per callback. Physical and anonymous memory therefore stay bounded
  independently of file size, with no file-sized virtual address reservation.
- Edit bytes use at most `maximumResidentEditBytes` of heap memory between save
  rebases (16 MiB by default). Large or over-budget additions share one private,
  unlinked, append-only temporary pread store per document.
- Undo roots structurally share tree nodes and are level-bounded (512 by
  default). A successful default save rebases to one descriptor-backed piece,
  releases edit backing, and clears undo/redo to return to the low-memory baseline.
- An unchanged Save Copy first tries APFS `clonefile`, making Duplicate nearly
  constant-time and copy-on-write. Other copies stream.

## Search guarantees and limits

Literal matching is exact, crosses arbitrary piece/slice boundaries, allocates
O(pattern length), and checks cancellation every 64 KiB. Case-insensitive
literal mode folds ASCII only so byte ranges remain exact.

Documents up to 16 MiB use Foundation's full-document regex semantics, including
anchors, boundaries, lookarounds, captures, and unbounded quantifiers. An
independent structural preflight rejects catastrophic nested or ambiguous
repetition, and Foundation progress callbacks enforce a monotonic two-second
deadline without publishing partial results.

Larger documents remain file-size independent: LighTxt proves a conservative
UTF-8 width for a streaming-safe subset, gives each bounded window sufficient
context, and carries one global non-overlap cursor across chunks. Constructs whose
meaning depends on the whole document, or whose maximum width cannot be proven,
fail explicitly before returning results rather than producing window-dependent
matches. Results stream directly, retained memory does not grow with match count,
and invalid UTF-8 is reported.

## File-system safety

Atomic saves preserve mode plus best-effort ACL/extended metadata. A file
fingerprint (device, inode, size, nanosecond mtime) is checked before writing and
again before rename, preventing silent overwrite when another process changes
the destination. The completed temporary inode is opened before rename and that
exact descriptor becomes the clean root. The destination path is checked again
after rename and while committing document state, so a pathname substitution can
never make LighTxt adopt foreign bytes or clear the user's undo history.

Every positional read checks the open descriptor's captured size and modification
fingerprint before and after I/O. In-place truncation or rewriting is surfaced as
`fileChangedExternally` (including for background search/save/index work), while
normal atomic replacement remains safe because snapshots retain the old inode.
