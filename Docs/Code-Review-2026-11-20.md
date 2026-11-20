# LighTxt 1.9 code review

November 20, 2026 · Reviewed commit `2524700` on `main`

I would ship a correctness release first. The largest risks are losing crash recovery, applying a document command to part of the file, and operating on the wrong CSV record. The most valuable performance work is in the export paths. The piece table, sparse indexes, and DuckDB integration already provide most of what the fixes need.

## Fixes I would ship first

| Priority | Finding and evidence | Change and regression test |
|---|---|---|
| 1 | **The first edit can disable crash recovery.** The coordinator creates a journal with the *post-edit* caret, and the store validates it against the *pre-edit* length. In isolated tests, typing one byte into an empty document with the caret at 1, and appending to a three-byte file with the caret at 4, both raised `metadataLimitExceeded` and left zero recovery entries. [First flush][first-flush] · [Untitled validation][untitled] | Create the journal with metadata valid for the base. Commit the first edits and their resulting selection together. Reopen the journal in a fresh session and verify both the bytes and caret for untitled and file-backed documents. |
| 2 | **Replace All can delete an existing recovery journal.** A test started with one recoverable entry, replaced one match, and typed three more characters. The unsaved document contained `ABC123456` and the recovery store had zero candidates. CSV column rewrites call the same removal path. [Replace All][replace-all] · [Journal removal][pause] | Journal ordinary replacements. For a large rewrite, publish a new recovery checkpoint before retiring the previous one. Test a simulated interruption before and after the checkpoint switch, including edits made afterward. |
| 3 | **Select All selects only the loaded source window.** In the actual AppKit text view, ⌘A followed by typing `X` in a 1 MiB file left **524,289 bytes**. A 64 KiB single-line file retained 57,345 bytes. Copy, Cut, and Delete inherit the same selection boundary. [Menu command][select-menu] · [Edit handling][edit-handler] | Track document selection in global byte coordinates and render its intersection with the viewport. Verify replace, cut, copy, delete, and undo with both a multiline document and a giant line. Keep large clipboard operations bounded or make their size limit explicit. |
| 4 | **CSV row coordinates can diverge from the source.** Filling the first empty cell of `,b` with `abc` advances the row-start checkpoint past the inserted text. The active index still returns an empty cell while a fresh index returns `abc`. Separately, a UTF-8 BOM before a quoted multiline first field made both indexers count a valid two-row CSV as three. A row action can then target half a record. [Checkpoint update][rebase] · [Record scan][csv-scan] | Keep the record-start checkpoint anchored across insertions into its first field. Skip the BOM when interpreting quote state while retaining physical byte offsets. Test row zero, a later checkpoint row, paging, row deletion, and export. |
| 5 | **A long physical line can crash printing or Markdown PDF export.** A 1,000,000-byte ASCII line trapped in the production PDF line reader on its third fragment. Removing a prefix advances the `Data` start index, while the next UTF-8 boundary check still subscripts from zero. [PDF reader][pdf] | Index relative to `buffer.startIndex`. Exercise a line spanning at least three fragments with ASCII and with a multibyte scalar at a boundary. |
| 6 | **Save As followed by Reload loses the file association.** After Save As, the session records explicit UTF-8 conversion as its reopen policy. Reload therefore creates a private working copy. The reload probe produced a dirty scratch document that required a new destination. [Saved options][reopen] · [Reload route][reload] | Preserve the chosen format and delimiter, and reopen the saved UTF-8 file directly with validation. Verify its URL, clean state, and subsequent in-place Save. Retain explicit conversion for the user's Open As command. |

## Other correctness findings

- **Save As can fail to rescue edits after an external in-place change.** In a compiled probe, another writer appended to the same inode after a local edit. The conflict dialog's suggested Save As route then failed with `fileChangedExternally` because the local version still referenced bytes from the changed base. Keep fingerprint checks. Offer export of the local edits when the base is unavailable, or evaluate a copy-on-write snapshot on the first edit where the volume supports it. Test external append and atomic replacement separately. [Read validation][fingerprint] · [Conflict action][conflict-action]
- **Unicode regex navigation.** In a valid 36,000,001-byte file of euro signs followed by `X`, forward search found the final character and reverse regex search reported invalid UTF-8. Its 32 MiB search window started inside a scalar. A zero-width match before an emoji also advanced the next search by one byte into the emoji. Align decode windows and advance zero-width matches to the next scalar boundary while retaining original match coordinates. [Reverse search][reverse] · [Find Next][find-next]
- **Wraparound Find.** With the caret in the middle of the only occurrence of `needle`, Find Next returned no match. The two half-open scan ranges cut the candidate in half. Make wraparound select by match start from complete candidates and test a cursor inside the first and only occurrence. [Search ranges][wrap]
- **Markdown line endings.** A heading and two list items produced three preview blocks with LF. The same text produced one heading block with CRLF or CR. Derive block boundaries and byte offsets from one newline scanner covering all three conventions. [Markdown preparation][markdown]
- **JSON with a UTF-8 BOM.** The tree showed one object and zero diagnostics for `{"x":1}`. Adding a BOM produced two invalid rows and two diagnostics. Skip the marker at document offset zero in both root indexing and lazy paging. [JSON parser][json-start]
- **Duplicate JSON Lines keys.** Exporting a CSV with headers `id,id` produced `{"id":"left","id":"right"}`. Foundation retained only one value when reading it. Generate unique keys once per export, checking generated names against existing headers. [JSON Lines encoder][jsonl-output]
- **Save As to another volume warrants an integration test.** For a new destination, the writer stages in the system temporary directory and verifies the published file against the staging device and inode. A cross-volume move cannot preserve that identity. Stage on the destination volume and verify using an external drive or mounted share with the app's file-only grant. This finding comes from the save path. The review did not perform a cross-volume write. [Staging][staging] · [Final verification][verify-save]

## Performance work with measurable payoffs

| Change | Evidence | Implementation direction |
|---|---|---|
| **Stream Parquet exports through one ordered query.** | A filtered or sorted one-million-row export requires 15,625 nonempty 64-row page queries. On a synthetic 32,768-row, two-column Parquet file, the shipped DuckDB took **4.065 s** for 512 sorted page queries and **0.004–0.005 s** for one ordered query. This measured warm SQL execution only. Also, a 4,097-character cell can currently fail an otherwise valid export because it exceeds the display limit. [Export loop][parquet-export] · [Page SQL][page-sql] | Use a sequential DuckDB result stream or format-appropriate export query. Preserve stable ordering, existing output formats, cancellation, and atomic publication. Keep the grid's preview limits. |
| **Batch CSV row lookup for selected exports.** | Resolving 1,024 contiguous selected rows individually requested **1 GiB** from the index reader. The existing batch API returned identical record ranges with **1 MiB** requested. These are logical reads. [Selected export][csv-export] | Reuse the range lookup already used by full unfiltered exports. For filtered or sorted selections, batch by source location and emit in displayed order. |
| **Bound caret lookup on very long lines.** | One lookup near the end of an already-indexed 64 MiB line requested **67,108,863 bytes again**. The editor makes this call synchronously. [Caret lookup][caret] · [Index refinement][line-refine] | Supplement line-count checkpoints with sparse byte checkpoints that retain line number and line-start offset. Test the maximum bytes read per caret lookup. |
| **Give the editing viewport room to grow.** | On a full 512 KiB viewport, three consecutive one-character inserts triggered three full reloads. A 16 KiB single-line paste into a tiny document also bypassed the 8 KiB giant-line layout rule. [Viewport sizing][viewport] · [Insertion threshold][headroom] | Reserve edit headroom beneath the existing cap and recheck the affected line before sending the replacement to TextKit. |
| **Move explicit conversion off the main actor.** | An optimized, cache-warm explicit UTF-8 open took **1.87 s** for 128 MiB of ASCII and produced another 128 MiB file. Auto-detected UTF-16/32 can also trigger a validation pass over newly generated UTF-8. [Open path][conversion] | Prepare the converted file on a worker with the existing cancellation/progress API. Install the completed session on the main actor and reuse successful strict conversion as validation of its output. |
| **Benchmark literal Find All against its existing goal.** | Three warm runs per case mode on a generated 138 MiB ASCII log with an absent 18-byte query yielded **0.35–0.36 GiB/s** on an M3 Ultra. The repo's warm target is **1.5 GiB/s**. [Search loop][literal] · [Performance goal][perf-doc] | Add a fast path that skips noncandidate bytes in each slice. Benchmark present and absent terms, and retain coverage for cross-piece matches, whole words, and cancellation. |

One additional memory issue belongs with the recovery fixes. Eight separate 8 MiB inserts retained **64 MiB of replacement payloads in session recovery history** even though the piece table spilled the edits. Bound retained *bytes* across history or reference already-spooled payloads. The current limit counts transactions. [Recovery history][history]

## Legacy code and simplifications

- **Delete the UI-only `CSVFilterDraft.Predicate` and stored predicate.** All seven constructors supply `.contains`. Neither the CSV nor the Parquet adapter reads the value. The public core predicate enum still implements real query behavior. [Draft definition][draft]
- **Delete `StructureSidebarView.replaceChildren` and `VirtualTextEditorView.undoCoreEdit`.** Both are internal methods with no callers in source, tests, or menu wiring. JSON pagination uses the append path and Undo already routes through the active editor controller. [Sidebar method][replace-children] · [Editor method][undo-method]
- **Share the table loading overlay.** CSV and Parquet each implement nearly the same animated grid, layout, and palette. One view can accept the progress value, accessible label, and preferred width. Verify Reduce Motion in both table harnesses. [CSV overlay][overlay-csv] · [Parquet overlay][overlay-parquet]
- **Remove a redundant format-detection pass on normal UTF-8 opens.** The session reads the same unchanged prefix twice, then calls the full sniffer to ask whether the first four bytes are `PAR1`. Reuse the prefix and check the signature directly. The recovery fallback still uses the full sniffer. [Second read][sample] · [Magic check][magic]

## Features I would build

1. **Export Selected JSON Value…** This is the first feature I would ship. Someone inspecting a multi-gigabyte MRF could export a complete negotiated-rate object or array in a few clicks. The tree already knows the exact byte range, and the snapshot can stream it. Keep Copy Object as the bounded clipboard preview. [Indexed range][json-range] · [Snapshot streaming][slices]
2. **Open JSON Lines as records.** LighTxt already writes `.jsonl`, but opening it as ordinary JSON treats the second root as trailing content. Show one record per line, expand the selected record in the existing tree, and associate parse errors with their record. An export–reopen round trip would be the first acceptance test. [Recognized extensions][extensions] · [Single-root parser][json-root]
3. **Choose columns from the full Parquet schema.** The reader retains the full schema but presents only its first 256 columns by default. Let users search column names, then project the selected subset for viewing and export. A user could bring column 257 into a two-column view without increasing the grid's memory budget. [Schema projection][schema]

A small companion to the recovery fixes would be a chooser that lists **all recoverable documents**. The current launch dialog offers only the newest journal, so reaching a second one requires restarting the app. [Launch recovery][recovery-chooser]

## Verification

- Tested on macOS 27.0.1 with Xcode 27.0. The Debug package run passed 250 XCTest cases and four Swift Testing cases, with nine opt-in XCTest cases skipped. Temporary synthetic fixtures exercised the findings above. The original multi-gigabyte release corpus was outside this run.
- The separate optimized 250,000-row CSV benchmark passed. Indexing took **0.079 s**, distinct values **0.390 s**, and filtering **0.400 s** against the five-second budget for each operation. This run used the native SwiftPM build system after the default Release test build was denied permission to generate debug symbols.
- All application sources compiled and linked into an optimized arm64 executable using the pinned Sparkle framework. Nine of the ten standalone runtime harnesses passed, and the bundled DuckDB verified as **v1.4.5**. Parquet UI testing stopped at Copy Cell when the pasteboard returned no value. An independent private-pasteboard write also failed in this environment. The remaining Parquet UI assertions and the hosted multiwindow workflow remain unverified. Xcode package resolution for the packaged app was blocked by the runner's sandbox.

[first-flush]: ../LighTxt/Documents/DocumentRecoveryCoordinator.swift#L233
[untitled]: ../LighTxt/Core/RecoveryJournal.swift#L756
[replace-all]: ../LighTxt/Model/LighTxtDocumentSession.swift#L952
[pause]: ../LighTxt/Model/LighTxtDocumentSession.swift#L1201
[select-menu]: ../LighTxt/Application/LighTxtApplication.swift#L363
[edit-handler]: ../LighTxt/UI/VirtualTextEditorView.swift#L1047
[rebase]: ../LighTxt/Core/CSVDocumentIndex.swift#L405
[csv-scan]: ../LighTxt/Core/CSVDocumentIndex.swift#L181
[pdf]: ../LighTxt/UI/DocumentPDFExporter.swift#L524
[reopen]: ../LighTxt/Model/LighTxtDocumentSession.swift#L1083
[reload]: ../LighTxt/Documents/LighTxtDocument.swift#L1200
[reverse]: ../LighTxt/Model/DocumentSearchController.swift#L217
[find-next]: ../LighTxt/Model/LighTxtDocumentSession.swift#L743
[wrap]: ../LighTxt/Model/DocumentSearchController.swift#L81
[markdown]: ../LighTxt/UI/MarkdownPreviewView.swift#L641
[json-start]: ../LighTxt/Core/StreamingJSONStructureIndex.swift#L2287
[jsonl-output]: ../LighTxt/Core/TabularExport.swift#L239
[staging]: ../LighTxt/Core/StreamingFileWriter.swift#L54
[verify-save]: ../LighTxt/Core/StreamingFileWriter.swift#L280
[fingerprint]: ../LighTxt/Core/MemoryMappedFile.swift#L142
[conflict-action]: ../LighTxt/UI/LighTxtWindowController.swift#L531
[recovery-chooser]: ../LighTxt/Documents/LighTxtDocument.swift#L185
[parquet-export]: ../LighTxt/UI/ParquetTableView.swift#L2087
[page-sql]: ../LighTxt/Core/ParquetQueryService.swift#L615
[csv-export]: ../LighTxt/UI/CSVTableView.swift#L4056
[caret]: ../LighTxt/Model/LighTxtDocumentSession.swift#L640
[line-refine]: ../LighTxt/Model/SparseUTF8LineIndex.swift#L793
[viewport]: ../LighTxt/UI/VirtualTextEditorView.swift#L822
[headroom]: ../LighTxt/UI/VirtualTextEditorView.swift#L1064
[conversion]: ../LighTxt/Model/LighTxtDocumentSession.swift#L113
[literal]: ../LighTxt/Core/StreamingSearch.swift#L1471
[perf-doc]: Performance.md#L148
[history]: ../LighTxt/Model/LighTxtDocumentSession.swift#L1187
[draft]: ../LighTxt/UI/CSVTableView.swift#L4532
[replace-children]: ../LighTxt/UI/StructureSidebarView.swift#L286
[undo-method]: ../LighTxt/UI/VirtualTextEditorView.swift#L497
[overlay-csv]: ../LighTxt/UI/CSVTableView.swift#L4209
[overlay-parquet]: ../LighTxt/UI/ParquetTableView.swift#L2671
[sample]: ../LighTxt/Model/LighTxtDocumentSession.swift#L140
[magic]: ../LighTxt/Model/LighTxtDocumentSession.swift#L173
[json-range]: ../LighTxt/Core/StreamingJSONStructureIndex.swift#L1256
[slices]: ../LighTxt/Core/FileBackedPieceTable.swift#L234
[extensions]: ../LighTxt/Syntax/SyntaxTypes.swift#L19
[json-root]: ../LighTxt/Core/StreamingJSONStructureIndex.swift#L2388
[schema]: ../LighTxt/Core/ParquetQueryService.swift#L537
