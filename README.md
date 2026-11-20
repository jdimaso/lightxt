# LighTxt

LighTxt is a native macOS text viewer and editor built for files that ordinary editors cannot handle comfortably. The document stays byte-backed on disk; at most a 512 KiB editing viewport is decoded and handed to TextKit, so opening a multi-gigabyte file does not create a second multi-gigabyte string. Pathological single-line content uses an 8 KiB, soft-wrapped horizontal window to keep native layout and compositor geometry bounded.

## What it supports

- TXT, SCRIPT, JSON, JSON Lines, Markdown, SQL, XML, CSV/TSV/PSV, YAML/YML, and read-only Parquet
- Bounded content, Unicode-encoding, and table-dialect detection, with **Open As** overrides and an inferred extension the first time an untitled document is saved
- Contextual **Tree / Source**, **Table / Source**, and **Preview / Source** presentations, with explicit editability and unsaved-state labels; plain text keeps a single focused editing surface
- A bounded **Source** presentation for supported text formats, with byte-preserving edits, SQL and other syntax highlighting, invalid-syntax diagnostics, and syntax-colored read-only JSON/YAML Prettify previews
- A full-path top-bar breadcrumb whose folder segments open in Finder, with safe same-window document navigation
- A resizable JSON explorer with lazy paged children, gray field names, and compact type badges. Wide windows show each field beside its value. Narrow panes put the value on a second line. Click a row to expand it, double-click to collapse it, and adjust the remembered reading size with the text controls.
- **Records / Source** for `.jsonl` and `.ndjson`. Open an object or array to inspect its children, or use **Go to Record…** to jump by number. Blank and malformed records show their first syntax error, and later records remain browsable. LF and CRLF line endings are supported.
- Independent **Outline** and **Results** tabs retain navigation while searching; JSON matches open source context without replacing the outline or result list. Source and editable CSV tables also provide Replace and transactional Replace All
- A position/activity/save-state status bar, inline line or table-row navigation with visible validation, and an information popover for storage details
- **Inspect Value** in CSV and Parquet tables opens a resizable, wrapped, read-only cell preview with copying and explicit preview limits; Escape returns to the same table selection. The shortcut is **Command-Option-I**
- Save, Save As, Save a Copy, Duplicate, undo, and redo
- View-mode Markdown export to paginated PDF, plus native printing for Markdown and plain-text documents through the same complete-document PDF pipeline
- External-change monitoring with safe reload review, optional automatic reload for clean files, and follow-at-end behavior for growing logs
- Crash recovery restores unsaved edits, selection, viewport, presentation, search, and delimiter state. At launch, choose **Recover**, **Keep for Later**, or **Discard** for each document.
- Atomic, cancellable export of a table's current filtered/sorted view or selected rows as CSV, TSV, pipe-delimited text, or JSON Lines
- **Columns…** in Parquet tables searches the full schema. The selected columns appear in the grid and its exports in display order.
- Transactional CSV row and column insertion/deletion, with every operation represented as one Undo step
- Sparse line indexing and direct byte-position navigation with 64-bit offsets
- Native light/dark appearance, keyboard shortcuts, menus, line numbers, multi-select Open, optional document tabs, visit history, and Reopen Last Task; inactive large documents shed rebuildable resident state automatically

## Analyze a CSV

In CSV Table view, click a data cell or drag across a rectangle. Shift-click or Shift-arrow extends the selection. Click a row number to select the whole row, Shift-click for consecutive rows, or Command-click for separate rows. Command-A selects the whole displayed table. The footer shows selected cells, filled cells, numeric values, sum, average, median, minimum, and maximum. It follows the displayed sort, filters, and column order. Dollar amounts such as `$7,558.33` and accounting negatives such as `($205.02)` are numeric in selections and PivotViz. Numeric calculations ignore empty cells, text, and non-finite values. Large selections use a private temporary database for the exact median.

**PivotViz…** opens a separate window for the current filtered CSV. Choose a row dimension, an optional column dimension, and up to eight metrics. Available aggregations are row count, filled-value count, sum, average, minimum, and maximum. With two dimensions, the pivot table puts the second dimension across columns. Bar and line charts accept one dimension with multiple metrics, or two dimensions with one metric. Scatter plots accept one or two dimensions with exactly two metrics. A pivot with no dimensions shows totals. For high-cardinality fields, filter the CSV first. Each pivot supports up to 10,000 groups and 16 MiB of group labels.

If another application replaces the open file, **Save As** can still write the edited
document from its original open descriptor. If another application modifies that
descriptor's bytes in place, **Export Local Edits…** in the change banner writes a
JSON Lines rescue file. It contains the original filename, size and file revision,
plus ordered copy ranges and inserted text or Base64 bytes. The first record explains
how to reconstruct the edited file from a byte-identical copy of the original.
Inserted content can be recovered directly from the rescue file.

## Why it stays light

The original file stays behind one read-only descriptor and is fetched with fingerprint-validated, 1 MiB-bounded positional reads. Edits live in a persistent balanced piece table, with a 16 MiB in-memory budget and overflow stored in one private unlinked backing file. Searches, saves, replacements, syntax analysis, and line indexing stream through bounded buffers. Find All retains only a bounded UI result set. Unedited APFS duplicates use clone-on-write.

JSON View validates every byte but never constructs a decoded object graph. On machines with ample headroom, eligible documents are copied into anonymous RAM and indexed there; files through 4 GiB use a parallel simdjson traversal and native record pass, while larger files use an exact 64-bit native grammar/record pass with SIMD UTF-8 validation. Memory-ineligible documents retain the bounded streaming/unlinked-disk fallback. Primitive values are decoded only when their tree page is requested, and both resident source and index memory can be purged without losing navigation. CSV View keeps an adaptive sparse row index rather than one offset per row. Filters stream into an unlinked, temporary row map; stable sorts use bounded external runs with incremental merging, so neither operation constructs a whole-file row array. Column Summary uses a bounded, stratified sample for large tables. Parquet View uses the pinned DuckDB LTS library to scan the selected file directly with projection and filter pushdown, stable source-row paging, and hard limits on returned rows and text; it never imports the file into a second database. Markdown View renders only a bounded document window, while PDF export and printing stream a pinned document revision into bounded attributed fragments and paginated Core Text frames. Content detection inspects at most 64 KiB, external monitoring samples metadata rather than contents, ordinary edits journal their inserted bytes, and bulk rewrites stream a durable recovery checkpoint. CSV exports batch sparse row lookups. Parquet and in-memory CSV exports stream one ordered DuckDB result. No production path constructs a whole-file decoded `String`, `NSAttributedString`, JSON object tree, CSV row array, Parquet row array, or line array. Large-file scrolling is coalesced so a drag materializes only its final requested viewport.

JSON Lines streams the source and builds a private temporary index with 32 bytes per physical record, in addition to the usual entries for nested containers and diagnostics. It reads descriptors in pages and decodes previews on demand. Closing the index releases the temporary file.

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
