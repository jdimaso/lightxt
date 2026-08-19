# LighTxt

LighTxt is a native macOS text viewer and editor built for files that ordinary editors cannot handle comfortably. The document stays byte-backed on disk; at most a 512 KiB editing viewport is decoded and handed to TextKit, so opening a multi-gigabyte file does not create a second multi-gigabyte string. Pathological single-line content uses an 8 KiB, soft-wrapped horizontal window to keep native layout and compositor geometry bounded.

## What it supports

- TXT, JSON, Markdown, SQL, XML, CSV, YAML, and YML
- A purpose-built **View** mode: a whole-document JSON explorer, rendered Markdown, and a virtual CSV table with per-column sort, filter, and summary tools
- A bounded **Edit** mode for every supported format, with byte-preserving edits, syntax highlighting, and invalid-syntax diagnostics
- A full-path top-bar breadcrumb whose folder segments open in Finder, with safe same-window document navigation
- A resizable, collapsible JSON explorer with lazy expand/collapse, paged children, and exact jumps back into Edit mode
- Literal or regular-expression Find, Find All, Replace, and transactional Replace All
- Save, Save As, Save a Copy, Duplicate, undo, and redo
- Transactional CSV row and column insertion/deletion, with every operation represented as one Undo step
- Sparse line indexing and direct byte-position navigation with 64-bit offsets
- Native light/dark appearance, keyboard shortcuts, menus, line numbers, and multiple document windows

## Why it stays light

The original file stays behind one read-only descriptor and is fetched with fingerprint-validated, 1 MiB-bounded positional reads. Edits live in a persistent balanced piece table, with a 16 MiB in-memory budget and overflow stored in one private unlinked backing file. Searches, saves, replacements, syntax analysis, and line indexing stream through bounded buffers. Find All retains only a bounded UI result set. Unedited APFS duplicates use clone-on-write.

JSON View validates every byte but never constructs a decoded object graph. On machines with ample headroom, eligible documents are copied into anonymous RAM and indexed there; files through 4 GiB use a parallel simdjson traversal and native record pass, while larger files use an exact 64-bit native grammar/record pass with SIMD UTF-8 validation. Memory-ineligible documents retain the bounded streaming/unlinked-disk fallback. Primitive values are decoded only when their tree page is requested, and both resident source and index memory can be purged without losing navigation. CSV View keeps an adaptive sparse row index rather than one offset per row. Filters stream into an unlinked, temporary row map; stable sorts use bounded external runs with incremental merging, so neither operation constructs a whole-file row array. Column Summary uses a bounded, stratified sample for large tables. Markdown View renders only a bounded document window. No production path constructs a whole-file decoded `String`, `NSAttributedString`, JSON object tree, CSV row array, or line array. Large-file scrolling is coalesced so a drag materializes only its final requested viewport.

## Measured release behavior

On the audited Apple M3 Ultra host, the final RAM-accelerated path copied and fully validated a 3,530,392,986-byte JSON document in 2.560 seconds, producing the exact 31,793,316-container / 158,935,200-value index with zero diagnostics. The actual app reached its first complete JSON tree for that file in 2.928 seconds from a warm fresh Debug process and 2.975 seconds from a warm fresh Release process. The native scanner is explicitly optimized in both configurations while Swift remains debuggable; this prevents vendored simdjson from turning an ordinary Xcode Debug run into a minutes-long import. The exact 16,792,795,534-byte JSON fixture completed in 14.485 seconds instead of the measured 145.549-second Swift fallback, preserving all 64,457,954 containers and 1,380,618,731 values. An explicit pressure purge on that file returned 19.371 GB and reduced the live process to about 27 MB while lazy paging remained usable. The 11,424,306,645-byte CSV fixture indexed all 9,551,448 RFC-aware rows in 7.158 seconds while retaining only 74,624 bytes of sparse checkpoints; its first 64-row page decoded in 2.73 ms.

The accelerated JSON path is selected only when physical-memory headroom covers its measured worst-case transient. The 3.53 GB parallel-validation path briefly added about 8.12 GB while the independent source copy, compact records, and validator workspace coexisted. Native64 avoids the source-sized simdjson workspace and uses a separate admission threshold; a 16.79 GB source plus records added about 19.37 GB. Smaller-memory machines automatically use the bounded fallback rather than creating memory pressure. Close/reset unmaps resident JSON storage deterministically.

The largest ordinary editing viewport is 512 KiB; minified or giant-line content is constrained to an UTF-8-aligned 8 KiB, screen-width wrapped slice. See [Docs/Performance.md](Docs/Performance.md) for the complete measurements, latency results, and the documented macOS 26.4.1 compositor transient.

## Build and test

LighTxt requires macOS 14 or later and Xcode 26 or later.

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  xcodebuild -project LighTxt.xcodeproj -scheme LighTxt \
  -configuration Release -destination 'platform=macOS' \
  -derivedDataPath /tmp/LighTxtDerivedData build
```

The file engine, search, bulk replacement, syntax, and line-index suites can also run independently:

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  xcrun swift test --disable-sandbox --scratch-path /tmp/LighTxtSwiftPM
```

See [Docs/Performance.md](Docs/Performance.md) for the repeatable memory and latency release gates and [LighTxt/Core/README.md](LighTxt/Core/README.md) for the storage model and documented regex boundaries.

Direct-distribution builds use Sparkle for signed automatic updates. See
[Docs/AutomaticUpdates.md](Docs/AutomaticUpdates.md) for the sandbox design,
Keychain-only signing-key policy, and safe GitHub Release sequence.
