# LighTxt performance, integration, and QA contract

This document is the release gate for LighTxt. It translates “ultra-lightweight” into measurements that can be repeated, and it treats a 24 GB file as a normal document rather than an exceptional import job.

## Environment audited on 2026-08-15

| Item | Observed value |
| --- | --- |
| Host | Mac Studio, Apple M3 Ultra, 32 CPU cores, 512 GB RAM, arm64 |
| macOS | 26.4.1 (25E253) |
| Stable Xcode | `/Applications/Xcode.app`, Xcode 26.6 (17F113), macOS 26.5 SDK |
| Beta Xcode | `/Applications/Xcode-beta.app`, Xcode 27.0 (27A5228h) |
| Active developer directory | `/Library/Developer/CommandLineTools` |
| Standalone Swift | Apple Swift 6.2.3, arm64-apple-macosx26.0 |
| Storage | Workspace and Downloads are on the same APFS 3.6 TiB data volume; 2.6 TiB was free during the audit. A local HFS+ volume and SMB mounts were also present for separately authorized fallback tests. |

Full Xcode is installed, but it is not the active `xcode-select` toolchain. A plain `xcodebuild` therefore fails. Do not change the machine-wide selection; choose stable Xcode per command:

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  /usr/bin/xcodebuild -project LighTxt.xcodeproj -scheme LighTxt \
  -configuration Release -destination 'platform=macOS' \
  -derivedDataPath /tmp/LighTxtDerivedData \
  CODE_SIGNING_ALLOWED=NO build
```

The explicit derived-data directory makes the command usable in restricted automation environments. Use the same `DEVELOPER_DIR` prefix for `xcrun xctrace`, `swift`, and test commands. The Instruments CLI is installed; a restricted runner may need permission to write its normal cache under `~/Library/Caches`.

The starter project was a single SwiftUI “Hello, world” source file with no tests or editor model. Its settings exposed four integration blockers:

- The target, product reference, scheme, and project used the starter name instead of `LighTxt`.
- `SUPPORTED_PLATFORMS` included iOS, macOS, and visionOS with `SDKROOT = auto`; this product should be macOS-only.
- App Sandbox was enabled with `ENABLE_USER_SELECTED_FILES = readonly`. Save, Save As, Replace All, and Duplicate require user-selected read/write access.
- The deployment target was tied to the build host (`26.4.1`) instead of an intentional minimum supported macOS version.

Before release, verify the final generated Info.plist, entitlements, product name, bundle identifier, app icon, target, scheme, and menu commands—not just the labels visible in Xcode.

Declare macOS document types/UTTypes for `txt`, `json`, `md`, `sql`, `xml`, `csv`, `yml`, and `yaml`, then verify Finder “Open With,” drag/drop, command-line `open`, recent documents, and restoration. The `NSDocument` integration must not route reads or writes through its default whole-`Data` methods. Decide explicitly whether autosave-in-place is disabled or implemented as the same cancellable, constant-memory atomic save path; an implicit synchronous autosave of a 24 GB document is unacceptable.

## What “near-zero memory” means

A GUI process has a fixed AppKit/TextKit framework cost even when the document is empty. Edit mode never reserves a file-sized mapping; it reads validated file slices into bounded buffers. JSON View has a separate, explicitly measured RAM-first accelerator: on machines with ample headroom it copies eligible raw bytes into an anonymous mapping and builds compact anonymous records, while lower-memory/larger files retain the bounded streaming fallback. The primary metric is therefore **incremental physical footprint over an idle, settled LighTxt process**, accompanied by private dirty memory and resident size. Virtual size alone is not a useful failure signal.

Clean file-backed pages must be reported separately from anonymous/private pages. Any file-sized anonymous allocation outside the documented JSON View fast path is release-blocking. The fast path must budget its full transient before selection, purge to a still-readable bounded fallback under memory pressure, and deterministically unmap on close.

Measure a signed/unsigned Release build after five seconds idle, with no debugger, previews, or diagnostic malloc flags attached.

| Memory metric | Release gate |
| --- | --- |
| Empty app physical footprint | no more than 80 MiB after settling |
| Open-to-first-paint incremental footprint, files through 100 MiB | no more than 48 MiB |
| Open-to-first-paint incremental footprint, 1–24 GiB files | no more than 96 MiB, independent of file size |
| Peak transient increment during scroll, syntax, or search | no more than 160 MiB; return to the steady gate within 5 seconds |
| Private dirty increment for an unedited document | no more than 64 MiB |
| Live edit memory | no more than 96 MiB plus the bytes inserted since the last save; larger undo/edit payloads spill to a temporary backing store |
| Resident line, token, and CSV-row working set | no more than 96 MiB, independent of source size |
| JSON View RAM fast path | select only with ample physical headroom; measured transient must stay within the preflight budget and purge on warning/critical pressure |
| JSON structure fallback/index disk usage | no more than 16% of source size for the audited container-heavy corpus; immediately unlinked and reclaimed on close |
| Save/Save As working buffer | no more than 32 MiB above the edited steady state |
| Find All retained results | bounded to 100,000 displayed matches or 16 MiB; counting and Replace All continue as streams |
| After closing the final document | within 32 MiB of the empty-app footprint in 5 seconds |

Run `vmmap -summary <pid>` during each scenario and preserve the report. Use `phys_footprint`/Physical Footprint as the pass/fail number; record resident size, private dirty, compressed memory, mapped-file regions, and peak RSS from `/usr/bin/time -l` as supporting data.

## Measured Release results

### Bounded editor/open baseline

The following eight-process matrix predates the format-specific whole-document View modes and is retained as the bounded editor/open baseline, not as the final JSON View steady-state measurement. “First” and “warm” identify the first and second launch for that scenario; the host cache was not purged. Window time is the interval from process launch until Core Graphics reported the document window. Footprint and RSS were sampled after five seconds. Disk reads are the process's cumulative physical-read counter, not the logical bytes requested, and are cache-dependent.

| Scenario | Exact source size | Run | Window visible | Physical footprint at +5 s | RSS at +5 s | Physical disk reads |
| --- | ---: | --- | ---: | ---: | ---: | ---: |
| Untitled baseline | 0 B | first | 712.742 ms | 37,225,432 B (35.50 MiB) | 112,459,776 B (107.25 MiB) | 8,192 B |
| Untitled baseline | 0 B | warm | 510.598 ms | 36,701,192 B (35.00 MiB) | 111,886,336 B (106.70 MiB) | 0 B |
| Minified JSON | 1,048,576 B | first | 499.372 ms | 40,748,016 B (38.86 MiB) | 120,766,464 B (115.17 MiB) | 225,280 B |
| Minified JSON | 1,048,576 B | warm | 523.519 ms | 49,939,488 B (47.63 MiB) | 128,040,960 B (122.11 MiB) | 0 B |
| `local-json-23g` | 23,871,519,685 B | first | 501.333 ms | 45,663,240 B (43.55 MiB) | 130,646,016 B (124.59 MiB) | 4,096 B |
| `local-json-23g` | 23,871,519,685 B | warm | 505.615 ms | 51,627,064 B (49.24 MiB) | 135,643,136 B (129.36 MiB) | 0 B |
| `local-csv-11g` | 11,424,306,645 B | first | 539.843 ms | 52,216,912 B (49.80 MiB) | 135,626,752 B (129.34 MiB) | 69,632 B |
| `local-csv-11g` | 11,424,306,645 B | warm | 533.770 ms | 43,156,488 B (41.16 MiB) | 128,385,024 B (122.44 MiB) | 0 B |

The largest bounded-editor footprint in that reference was 49.80 MiB and did not grow with document size. Its large-JSON signposts recorded 133.661 ms from benchmark-open request through initial open completion; the 524,288-byte request reduced to an 8,192-byte long-line window in 0.110 ms, and Core Graphics reported the window after 525.661 ms. Whole-document JSON View intentionally adds the separately budgeted resident memory reported below. These window-visible timings include process and AppKit startup and must not be presented as satisfying the stricter interaction gates.

The renderer exposes at most 512 KiB of ordinary line-oriented content to TextKit. When a candidate viewport contains a logical line longer than 8 KiB, it instead exposes an UTF-8-aligned 8 KiB slice with screen-width character wrapping. A source-identical Release probe verified 524,288 characters for the ordinary CSV viewport and 8,192 characters with approximately 700 x 2,000-point bounded geometry for the minified JSON viewport. Direct long-line materialization took about 10.8 ms. Eight rapid far-offset requests were coalesced: request setters had a 0.106 ms median, only the final target was materialized, and its exact expected prefix appeared about 202 ms after the last request, including the intentional 150 ms debounce. Steady physical footprint returned to roughly 65–67 MiB after the jump.

### Whole-document View modes

The raw editor remains immediately available through a bounded byte window. Format-specific View modes add whole-document navigation without constructing a decoded object graph or attributed whole-document view.

| View mode | Exact corpus | Result |
| --- | --- | --- |
| JSON explorer, parallel SIMD path | 3,530,392,986 B JSON | Anonymous source copy 0.396 s; native records 2.161 s and full simdjson validation 1.722 s overlapped; publication 0.000046 s; 2.560 s total; 31,793,316 containers; 158,935,200 values; zero diagnostics |
| JSON explorer, native64 path | 16,792,795,534 B JSON | Anonymous source copy 1.934 s; exact 64-bit grammar+record pass 12.549 s and SIMD UTF-8 validation 0.226 s overlapped; publication 0.000021 s; 14.485 s total versus 145.549 s bounded-Swift baseline; 64,457,954 containers; 1,380,618,731 values; depth 7; zero diagnostics |
| JSON memory pressure/close | 16,792,795,534 B corpus | 19,374,473,216 B peak incremental resident footprint; 19,371,204,638 B finished resident source+records; purge reclaimed all reported resident storage and reduced RSS from 19.398 GB to 26.95 MB while paging remained valid; close left zero mappings |
| CSV table | 11,424,306,645 B CSV | 9,551,448 RFC-4180-aware rows indexed in 7.158 s; 9,328 adaptive checkpoints retained (74,624 B); first 64-row page 2.73 ms; 1 MiB source reads with 64 KiB cancellation slices |
| Markdown preview | exact 57,531 B reported fixture | One whole-document scroller; true EOF stable in View and Edit; View/Edit round-trip retained tail position and leading edge; native light/dark semantic rendering |

The JSON scanner retains container records only. Primitive children are parsed lazily from source byte ranges as each 256-row tree page is opened. Through 4 GiB, the native 40-byte-record builder and vendored simdjson semantic traversal run concurrently over an owned source copy. Larger resident files use a forced-parity-tested exact 64-bit grammar/record emitter alongside simdjson's size-independent SIMD UTF-8 validator. Malformed, depth/capacity-rejected, or memory-ineligible inputs use the Swift streaming diagnostics parser. All paths are cancellable and preserve the source unchanged. The CSV row index thins itself as files grow rather than retaining one offset per record, and its native lexical scanner is forced against the Swift reference across randomized RFC-4180 chunk boundaries.

#### Exact app visible-ready regression

The multi-gigabyte native scanner is deliberately compiled at `-O3` in both app configurations while Swift remains `-Onone` in Debug. This is a functional requirement, not a benchmark-only setting: an ordinary Xcode Debug build previously compiled vendored simdjson at `-O0`, making the exact 3,530,392,986-byte file take 150.066 seconds and appear frozen near 50% after the record pass finished. With the target-level optimization, the same Debug core path takes 2.575 seconds with identical counts. A current-source, alternating three-run Release bridge comparison also justified retaining `-O3`: `-Os` averaged 2.621 seconds while `-O3` averaged 2.123 seconds (19.0% faster), with identical structure/value/depth results in every run.

End-to-end runs opened the `2026-07-31_Connecticare_CCI_COM_index.json` fixture through the actual app window and measured from the benchmark-open request until the first complete JSON tree was published:

| App build | Run | Visible-ready | Source copy | Parser/index | UI publication |
| --- | --- | ---: | ---: | ---: | ---: |
| Xcode Debug | first process | 6.151 s | 0.423 s | 2.228 s | 0.003 s |
| Xcode Debug | warm fresh process | 2.928 s | 0.442 s | 2.344 s | 0.003 s |
| Xcode Release | warm fresh process | 2.975 s | 0.443 s | 2.417 s | 0.005 s |

The first Debug process includes 3.50 seconds of one-time debugger/development app initialization before JSON admission. A newly copied and ad-hoc-signed Release QA bundle had a 13.490-second first launch because macOS performed one-time launch/signature validation; its next fresh process was 3.202 seconds. These startup costs are recorded separately from parser time and must not be attributed to JSON indexing. Signposts confirmed automatic resident admission, accelerated parsing, and first-tree publication for every run. A sample during the Release parse showed the native record builder and semantic validator executing concurrently on worker threads while the main thread spent 659 of 741 samples in the AppKit event loop. Completed Release RSS was about 4.60 GiB, with a 7.6 GB transient peak for the owned source, compact records, and validator workspace. Terminating the single-window QA app reclaimed the process and every mapping in 0.179 seconds; the core close and pressure-purge suites separately verify deterministic unmapping and that paging remains valid after resident storage is released.

### Breadcrumb shell and same-window navigation

The signed sandboxed app uses AppKit's actual close/minimize/zoom controls and presents the current document's full path as a native clickable breadcrumb in the top bar. Folder segments open directly in Finder through `NSWorkspace`; the app does not retain a separate folder grant or persistent folder bookmark. A same-window navigation matrix kept one `LighTxtDocument`, one standard window, the exact 1400 x 900 frame, and the same Core Graphics window ID throughout:

- **Save** persisted the old document's pending edit before loading the selected sibling.
- **Don't Save** discarded only the old in-memory edit and left its source bytes unchanged.
- **Cancel** preserved the old title, content, selection, and edit state.
- A forced permission failure kept the old document and edit alive and allowed navigation to be retried after dismissing the error.

Open and Save continue to use user-selected read/write scope for the selected document. During the asynchronous save review, the session suspends every mutation path—typing/paste, CSV commits, undo/redo, Replace Current, and Replace All—so an edit newer than the save snapshot cannot be discarded by an approved navigation.

### macOS 26.4.1 compositor observation

This host has a reproducible short-lived graphics charge on any visible AppKit text mutation. In the final matrix, current physical footprint momentarily reached 545,162,272 B for the 1 MiB minified fixture, 547,062,840 B for the 23.87 GB JSON, and 547,505,232 B for the 11.42 GB CSV, then settled to 49,939,488 B, 51,627,064 B, and 52,216,912 B respectively by five seconds; RSS remained at or below 135,659,520 B. A separate one-character edit in a six-byte native text view raised current physical footprint from 38.2 MB to 546.8 MB and returned to 51.3 MB within two seconds. The sampling loop made no Accessibility calls during the edit. `vmmap` attributed the transient almost entirely to `owned unmapped (graphics)`, not LighTxt's heap, file source, edit store, syntax engine, or line index.

To determine whether TextKit caused it, an independent fixed-size 900 x 620 custom `NSView`/CoreText prototype rendered only about 35 visible lines, invalidated one line, disabled Accessibility notifications, and contained no `NSTextView`, `NSTextStorage`, or `NSLayoutManager`. It settled at 21.7 MiB, then a one-character model edit plus one-line redraw produced the same approximately 505 MiB current footprint; `vmmap` attributed about 454 MiB to `owned unmapped (graphics)`. A no-op telemetry control stayed at 21.7 MiB. Layer-backed and non-layer-backed variants behaved the same.

The 160 MiB transient gate is therefore not met on macOS 26.4.1, but the excess is a host AppKit/WindowServer compositor transaction reproduced outside LighTxt and reclaimed within the five-second steady-state gate. Replacing the native editor with the custom CoreText surface did not improve it and would materially regress IME composition, bidirectional text, grapheme navigation, selection, and VoiceOver. The release retains the bounded native editor and treats this OS-specific graphics transient separately from application-managed and document-proportional memory. Re-run this test on each supported macOS release; a persistent or document-size-scaled charge remains a release blocker.

## Latency and throughput gates

These gates apply to Release builds on the audited M3 Ultra using a local file on the internal data volume. Record slower reference hardware before lowering a gate; do not silently normalize results by file size when the operation should be constant-time.

| Interaction | Gate |
| --- | --- |
| Warm launch to interactive window | p95 at or below 200 ms |
| Cold launch to interactive window | p95 at or below 500 ms |
| Open request to first editable viewport, 1 MiB–24 GiB | p95 at or below 150 ms warm; 500 ms cold |
| Jump to a known byte offset and paint | p95 at or below 25 ms warm; 100 ms cold |
| Core insert/delete in a 24 GiB document | p95 at or below 250 microseconds across 10,000 mixed edits |
| Key event to presented frame | p50 at or below 4 ms, p95 at or below 8 ms, p99 at or below 16 ms |
| Continuous scroll | 60 fps target; fewer than 1% frames over 16.7 ms and no frame over 100 ms |
| Visible-window syntax refresh | p95 at or below 8 ms; invalid-syntax feedback within 100 ms after the edit debounce |
| Toggle an already-indexed fold | p95 at or below 8 ms |
| Literal Find All | at least 1.5 GiB/s after warm-up; first nearby match within 100 ms |
| Representative regex Find All | at least 350 MiB/s; cancellation acknowledged within 50 ms |
| Replace one / undo / redo | p95 at or below 8 ms |
| Save or Save As to local APFS | at least 1 GiB/s streaming throughput, bounded memory, main thread always responsive |
| Duplicate an unedited local APFS file | at or below 300 ms using clone-on-write, independent of source size |
| Quit or close with unsaved changes | prompt visible within 100 ms; no synchronous full-document work |

“Editable in nanoseconds” is interpreted as no operation proportional to total file size on the input path. Display refresh is constrained by the 16.7 ms frame budget; the edit model itself has the tighter 250-microsecond gate.

Cold-cache results are inherently affected by storage and OS caching. Treat the first run after reboot or the first read of a newly generated fixture as cold, label it, and never use `purge` in routine automation. Use at least 30 repetitions for micro/interaction percentiles and at least five fresh-process repetitions for multi-gigabyte end-to-end scenarios.

## Architecture constraints that make the gates achievable

### Byte source and offsets

- Keep Edit mode and all generic source access byte-backed with `open` plus bounded `pread` windows. Never map the user-controlled inode permanently or construct a whole-file decoded `String`, `NSString`, `NSAttributedString`, syntax tree, or array of lines. JSON View may use an independently owned anonymous raw-byte copy only after the physical-headroom gate succeeds.
- Use 64-bit byte offsets (`off_t`/`UInt64`) end to end. Include tests across 2 GiB and 4 GiB boundaries and reject arithmetic overflow explicitly.
- Bound decoded viewport windows and include overlap for UTF-8 sequences, grapheme clusters, CRLF, tokens, regex matches, and syntax state that cross a window boundary.
- Windowing is preferred to one permanent mapping because an external truncate can turn access beyond the new EOF into `SIGBUS`. Every asynchronous read must validate the current file identity and size.
- Treat clean file-backed pages and read buffers as disposable. Release old windows promptly so a complete scroll/search does not leave the entire file resident.

### Edit model

- Use a piece table or balanced rope: immutable spans reference the original file and inserted spans reference append-only edit storage. Nodes cache byte length, decoded length where needed, and newline aggregates.
- Insert, delete, offset lookup, and undo must be logarithmic in piece count, never in document size. Coalesce sequential typing and periodically rebalance adversarial edit patterns.
- Bound undo RAM. Spill large inserted/deleted payloads to a private temporary file, and remove it on close/crash recovery according to an explicit policy.
- Keep UI selections and diagnostics in document coordinates. A viewport must not silently change selection offsets when it is recycled.

### Rendering

- Do not hand the whole document to `TextEditor`, `NSTextView` backed by a whole-file `NSTextStorage`, or SwiftUI `Text`; each can force UTF-16, glyph, layout, and attribute copies.
- Feed AppKit/TextKit only a bounded visible slice (plus overscan), or use a custom tiled view. Cap both vertical and horizontal layout. A 24 GB minified JSON line must not create one 24 GB layout fragment.
- Syntax attributes are ephemeral viewport data. Cache compact token state/checkpoints, not one attribute object per token or character.
- Audit accessibility, Services, spelling, grammar, automatic substitutions, and drag/clipboard paths. macOS can request the entire text value through these paths unless the editor deliberately exposes ranges.

### Search and replace

- Literal search streams bytes with overlap and skips efficiently; matching must be correct across chunk and UTF-8 boundaries.
- Regex search has a documented supported subset or an engine that can resume across chunks. Unbounded lookbehind/backtracking cannot be made safely streaming: detect it, bound work, provide cancellation, and never freeze the main actor.
- Find All streams counts and a bounded result window. Replace All builds a new piece sequence or streams an atomic output file; it must not materialize all matches or the new document.
- Empty matches, zero-width Unicode matches, overlapping matches, capture expansion, invalid replacement groups, and regexes matching newline boundaries need dedicated tests.

### Syntax and structure

- Detect format from extension, then validate with a small content sample. A wrong extension must not trigger a full parse or block opening.
- Tokenize only the visible region immediately. Maintain sparse lexical checkpoints so random access restarts from a bounded earlier point.
- JSON/XML/YAML folding must be based on a streaming, cancellable structural index—not a decoded object model. Initially expose visible/top-level nodes and refine in the background.
- Put explicit limits on nesting depth, token length, entity expansion, aliases, and diagnostic count. Invalid or incomplete syntax is normal while editing and must never be fatal.
- Preserve the exact bytes of untouched spans, including original encoding, BOM, newline convention, final-newline state, and invalid UTF-8.

### Saving and duplication

- Save by streaming pieces to a Foundation item-replacement location (with a private app-temp fallback), flushing, and publishing only to the exact user-authorized destination. Never overwrite the only good copy before every write and flush succeeds.
- Preserve permissions and appropriate extended attributes; coordinate with other presenters. Verify behavior for symlinks and hard links rather than following them accidentally.
- Before replacing, compare file identity, size, and modification state captured at open. If another process changed/replaced/truncated the file, require a user decision.
- Report progress and support cancellation before the atomic commit. Check free space early but still handle `ENOSPC`, short writes, `EIO`, permission changes, and disconnects.
- Duplicate an unchanged file with APFS clone-on-write (`clonefile`/equivalent) when possible. Fall back to a bounded streaming copy on unsupported or cross-volume destinations. A Save Copy containing edits must stream the piece table.
- Sandbox integration must use user-selected read/write access, security-scoped URLs/bookmarks where persistence is intended, `NSOpenPanel`/`NSSavePanel`, and file coordination/presentation for external changes.

## Instrumentation contract

Add signposts with a stable subsystem and document-size metadata, never filenames or file contents. Required intervals/events:

- process launch, app interactive, open requested, descriptor ready, first viewport decoded, first viewport presented;
- read/mapping window miss, line-index batch, syntax batch, structure-index batch;
- key event received, edit model committed, layout complete, frame presented;
- search start, first result, result batch, completion/cancel;
- save start, bytes streamed, flush, atomic replace, completion/cancel;
- memory-pressure response and document close/deallocation.

At minimum, capture Time Profiler, Allocations, Leaks, File Activity, VM Tracker, and Points of Interest. A representative CLI capture after adding a benchmark launch argument is:

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  /usr/bin/xcrun xctrace record --template 'Time Profiler' \
  --output /tmp/LighTxt-Time.trace \
  --launch -- /tmp/LighTxtDerivedData/Build/Products/Release/LighTxt.app/Contents/MacOS/LighTxt \
  --benchmark-open /path/to/fixture
```

Store raw measurements as artifacts with app commit, build configuration, macOS/Xcode versions, hardware identifier, fixture ID/size/hash, cache state, run number, elapsed time, footprint, and pass/fail. Do not store private source paths in shared CI logs.

## Benchmark scenarios

Run the full matrix against 0 B, 1 KiB, 1 MiB, 100 MiB, 1 GiB, 10 GiB, and the 24 GiB real-world class. The fixture catalog is in `Tests/Fixtures/README.md`.

1. Launch empty; open via Finder, Open panel, drag/drop, and recent-document bookmark.
2. First paint at byte zero without waiting for whole-file line count, syntax, or structure indexing.
3. Jump to beginning/middle/end and 100 deterministic random offsets; scroll vertically and horizontally through giant lines.
4. Type, paste, delete, cut, undo, and redo at beginning/middle/end after 1, 1,000, and 100,000 fragmented edits.
5. Search literal ASCII, multibyte Unicode, a chunk-boundary token, absent text, empty regex, captures, multiline regex, and a deliberately expensive regex; cancel each phase.
6. Replace one and Replace All with shorter, equal, and longer substitutions. Verify count, byte output, selection, undo, and cancellation.
7. Fold/unfold top-level and deeply nested JSON/XML/YAML while background indexing is incomplete and while syntax is invalid.
8. Save in place, Save As, Save a Copy, and Duplicate. Reopen and stream-compare bytes against the expected model. Kill the process before commit and verify the original survives.
9. Modify, rename, replace, truncate, and delete the source externally while it is open. No crash, stale overwrite, or `SIGBUS` is acceptable.
10. Exercise read-only files, locked files, missing parents, full disk, short writes, network/removable disconnects, iCloud placeholders, symlinks, hard links, sparse files, and non-APFS volumes through fault injection where needed.
11. Send memory pressure during indexing/search/save. Background work must shed caches first and remain cancellable.
12. Open several large documents concurrently. Per-document caches must remain bounded and inactive tabs must release decoded/layout windows.

## Format and platform correctness checklist

- Text: empty file; no final newline; LF, CRLF, and CR; UTF-8 BOM; UTF-16 LE/BE; combining marks; emoji/ZWJ; right-to-left text; invalid byte sequences; NULs; one enormous line.
- JSON: scalar root; arrays/objects; escaped quotes/backslashes; surrogate escapes; huge numbers; deep nesting; minified input; trailing/incomplete tokens; invalid commas/colons; JSON Lines as a separate mode if supported.
- Markdown: fenced blocks with embedded languages, nested backticks, front matter, long links, inline HTML, incomplete emphasis.
- SQL: line/block comments, nested comments where the dialect permits, quoted identifiers, dollar-quoted strings, alternate dialect keywords, and incomplete literals.
- XML: namespaces, attributes, comments, CDATA, processing instructions, DOCTYPE, invalid entities, and explicit protection from entity expansion.
- CSV: commas/tabs/semicolons when detected, quoted delimiters, doubled quotes, embedded CR/LF, trailing empty fields, inconsistent column counts, and a field larger than a viewport window.
- YAML: indentation, sequences/maps, multi-document separators, anchors/aliases, block scalars, tags, tabs, deep nesting, and incomplete edits; alias expansion must be bounded.
- macOS: standard Edit/Find/Save menu routing, keyboard navigation, VoiceOver range access, appearance/contrast, Retina and scaled displays, Spaces/full screen, multiple windows, state restoration, and termination with unsaved changes.

## Definition of done

LighTxt is not performance-complete until all of the following are true:

- [x] The app is macOS-only, consistently named LighTxt, and sandboxed user-selected files are read/write.
- [x] No production open/render/edit/syntax/search/save path creates a whole-document decoded or attributed copy.
- [ ] Every memory and latency gate above has a repeatable Release-build result attached to the tested commit.
- [x] The 23.9 GB JSON and 11.4 GB CSV classes reach an editable first viewport without a whole-file scan.
- [ ] Giant single-line/minified content scrolls and edits within the frame/input gates.
- [x] Literal and regex search are bounded, correct across windows, and promptly cancellable.
- [x] Find All and Replace All remain constant-memory even with millions of matches.
- [x] Invalid syntax is highlighted incrementally and never blocks editing.
- [x] Save failure cannot corrupt the prior file; external modification cannot be overwritten silently.
- [x] Untouched bytes, encoding, BOM, line endings, metadata, and final-newline state round-trip as specified.
- [x] Close and memory-pressure tests prove that JSON resident mappings/index descriptors are released and the fallback remains readable; editor/search/save cleanup retains its existing targeted gates.
- [x] Automated model/property tests compare randomized edit histories against a trusted small reference model.
- [ ] Instruments shows no main-thread file scan, parse, regex scan, save loop, or work proportional to total file size during input.
