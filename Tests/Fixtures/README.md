# LighTxt fixture and benchmark corpus

This directory documents the test corpus. Do not commit multi-gigabyte generated files, customer data, or files from `~/Downloads`. Tiny deterministic correctness fixtures may live here; generated stress fixtures belong in a private disposable directory such as `/tmp/LighTxtFixtures` and should be identified by a manifest.

## Corpus rules

- Generators must stream with a fixed seed and a bounded buffer (16 MiB maximum). A generator that constructs its target content in one `String` is itself an invalid benchmark.
- Each generated fixture records: fixture ID, generator version, seed, exact byte size, SHA-256, encoding/BOM, newline convention, expected record/line count, expected valid/invalid syntax, and special offsets.
- Never log record values from a private fixture. Shared reports use only the fixture ID, basename if approved, size, hash, and structural statistics.
- Open private real-world files read-only for benchmarks. Do not Save, Replace, touch timestamps, normalize line endings, create sidecars beside them, or copy them into the repository.
- Generate enough fresh bytes for a cold-read run; keep warm and cold results labeled separately. APFS clones share blocks and may share cache behavior, so a clone is not automatically a cold fixture.
- Test assertions and expected outputs must stream. Avoid `Data(contentsOf:)`, `String(contentsOf:)`, whole-file hashes held in memory, or XCTest attachments containing a large document.

## Required tiny correctness fixtures

Keep these small enough for code review and give each a corresponding expected token/fold/diagnostic manifest.

| Family | Required cases |
| --- | --- |
| TXT | empty; one byte; no final newline; LF/CRLF/CR; whitespace-only; 1 MiB single line |
| Encoding | UTF-8; UTF-8 BOM; UTF-16 LE/BE BOM; multibyte character split at every read boundary; invalid UTF-8; embedded NUL |
| Unicode | combining sequence; emoji and ZWJ; regional indicators; RTL text; mixed normalization forms; grapheme split across a viewport |
| JSON | object/array/scalar roots; pretty/minified; escapes; huge number; deep nesting; incomplete string/container; bad comma/colon; JSONL candidate |
| Markdown | headings/lists/links; nested emphasis; variable-length fenced code; front matter; inline HTML; incomplete fence |
| SQL | comments; strings with escaped quotes; quoted identifiers; dollar quote; multiple statements; incomplete comment/string; dialect ambiguity |
| XML | namespaces/attributes; comment; CDATA; processing instruction; DOCTYPE; invalid entity/tag; incomplete element |
| CSV | plain; quoted delimiter; doubled quote; embedded LF/CRLF; empty/trailing cells; inconsistent width; alternate delimiter; giant field |
| YAML | map/sequence; documents; anchor/alias; literal/folded block; tag; deep indentation; invalid tab/indent; incomplete scalar |
| Filesystem | read-only; symlink; hard link; sparse; externally replaced; externally truncated; deleted while open |

Boundary variants must place a meaningful construct at `windowSize - 4 ... windowSize + 4`: UTF-8 scalars, CRLF pairs, escape sequences, comments, delimiters, search terms, regex captures, and fold delimiters. Repeat around 2 GiB and 4 GiB offsets using sparse/patterned fixtures to catch truncating integer conversions.

## Generated stress matrix

The standard byte-size tiers are 1 MiB, 100 MiB, 1 GiB, 10 GiB, and 24 GiB. Not every format needs every tier, but every release must cover the starred rows at their largest stated size.

| Fixture ID | Shape | Tiers | Primary risk |
| --- | --- | --- | --- |
| `txt-many-short-lines` | predictable LF records | 100 MiB, 1/10 GiB | compressed/sparse line index |
| `txt-one-line` * | one logical line with periodic Unicode | 1/10/24 GiB | horizontal layout and offset mapping |
| `json-pretty-wide` | valid nested object/array, many lines | 1/10 GiB | syntax and structural indexing |
| `json-minified` * | valid JSON with almost no newlines | 1/10/24 GiB | no line-based assumptions |
| `json-deep-invalid` | nesting past configured limit, truncated tail | 100 MiB | bounded diagnostics and parser depth |
| `jsonl-many-records` | one valid object per LF | 1/10 GiB | line throughput and random access |
| `csv-narrow-many-rows` * | many short rows | 1/10 GiB | record indexing and Find All cardinality |
| `csv-wide-quoted` * | hundreds of fields, quoting and embedded LF | 1/10 GiB | logical record boundaries |
| `csv-giant-field` | one quoted field at least 256 MiB | 1 GiB | bounded decode/layout and search overlap |
| `xml-deep-mixed` | tags, attributes, comments, CDATA | 1 GiB | streaming fold state and depth defense |
| `yaml-block-alias` | block scalars and bounded aliases | 1 GiB | indentation state and expansion defense |
| `sql-comment-string` | repeated dialect constructs | 1 GiB | resumable lexical checkpoints |
| `markdown-fences` | long/nested fence-like sequences | 1 GiB | stateful windowed highlighting |
| `match-every-byte` | simple text with enormous match count | 1 GiB | bounded Find All/Replace All state |
| `sparse-offset-8g` * | sparse file with markers around 2/4/8 GiB | 8 GiB logical | 64-bit offsets without disk cost |

Also generate edited-state workloads rather than only files:

- 100,000 single-byte inserts at pseudorandom positions;
- 100,000 alternating begin/end edits to force tree rebalancing;
- a 256 MiB paste backed by spill storage;
- deletions spanning original and inserted pieces;
- Replace All with zero, one, 100,000, and millions of matches;
- undo to empty history and redo to the exact final streaming hash.

## Read-only real-world files observed during the audit

The initial inventory read only metadata and three 1 MiB samples (beginning, middle, end). Later opt-in Release QA streamed the complete `local-json-16g` and `local-csv-11g` sources through their new View-mode indexes. No private file was modified. These are valuable local manual benchmarks but must not become repository or CI dependencies.

| Private benchmark ID | Size | Sampled shape |
| --- | ---: | --- |
| `local-json-23g` (`ELEVANCE_202602.json`) | 23,871,519,685 B | sampled UTF-8; object delimiters at file ends; only 6–11 LF/MiB; sampled no-newline run at least 266 KiB |
| `local-json-16g` (`95000001-100000000_output.json`) | 16,792,795,534 B | sampled UTF-8; object delimiters at file ends; CRLF near the header; middle and tail samples each contain a full 1 MiB without a newline |
| `local-json-4g` (`data_4f3318e4-e157-4e1b-adc9-25af556a1c60_2c6cb161-8a28-40e1-b94b-f91414fecec0.json`) | 4,087,381,146 B | sampled UTF-8; object delimiters at file ends; CRLF near outer structure; minified 1 MiB middle region |
| `local-csv-11g` (`npidata_pfile_20050523-20260510.csv`) | 11,424,306,645 B | sampled UTF-8/LF; quoted first field; about 841–884 physical lines/MiB and hundreds of delimiters per row |
| `local-csv-4g` (`PARTD_PRESCRIBER_PUF.csv`) | 4,057,615,134 B | sampled UTF-8/LF; about 7,200 short physical lines/MiB |
| `local-csv-2g` (`results_e9cd3800469048558e234266e8496fb6.csv`) | 2,592,239,961 B | sampled UTF-8/LF; about 1,900 physical lines/MiB and roughly 1.3 KiB maximum sampled line span |

The first three files exercise the most important failure mode: a viewport, line index, parser, or text system that assumes newlines are frequent. The CSV pair intentionally covers opposite regimes—very many short rows and much wider rows.

The complete read-only `local-json-16g` scan validated 16,792,795,534 bytes, 64,457,954 containers, and 1,380,618,731 values with zero diagnostics. The complete `local-csv-11g` scan indexed 9,551,448 RFC-aware records and verified sampled first, middle, and final rows. Source size and modification time were unchanged after both runs.

## Benchmark sequence per fixture

Use the same deterministic sequence so traces are comparable:

1. Start a fresh Release process and record the settled empty-app footprint.
2. Open the fixture and record descriptor-ready, first-decode, first-layout, first-present, and steady memory without waiting for a complete scan.
3. Jump to byte 0, 25%, 50%, 75%, EOF, then 100 seeded random offsets. Record paint latency and offset correctness.
4. Scroll vertically for 60 seconds, horizontally through the longest sampled line, and immediately reverse direction. Record frame hitches and memory high-water mark.
5. Insert/delete at beginning, middle, and end; paste 1 KiB and 16 MiB; then execute the fragmented-edit workloads.
6. Find first/next/all for present ASCII, present Unicode, cross-window, absent, and high-cardinality terms. Repeat with representative and adversarial regexes, including cancellation.
7. Replace one/all with shorter/equal/longer values, undo, redo, and stream-verify expected bytes.
8. Exercise visible syntax errors and fold operations while indexes are partial.
9. Save to a disposable destination, reopen, and stream-compare with the model. Test Save As, Save a Copy, and Duplicate separately.
10. Close the document, wait five seconds, and verify tasks, mappings, caches, temporary edit files, and physical footprint return to their gates.

Never use the private files for steps 5–9. Use generated equivalents so an accidental write cannot affect source data.

## Native Markdown rendering acceptance

`RuntimeQA.md` is the deterministic View-mode acceptance fixture. The standalone
AppKit harness in `Tests/Runtime/MarkdownRendererRuntimeQA.swift` renders it in
light and dark appearances, emits PNG captures, and fails unless Markdown is
genuinely presented: heading/emphasis/code/link attributes must exist while
heading markers, emphasis delimiters, backticks, fence lines, table separators,
and link destinations must be absent from the visible string. The harness uses
the production `MarkdownNativeRenderer`, not a duplicate parser.

## Correctness oracles

- For small randomized edit histories, compare every operation with a trusted in-memory reference representation and compare byte-for-byte after every step.
- For large histories, keep a streaming expected-piece manifest and SHA-256; verify selected byte windows after each edit and the full stream after save.
- For search, generate match offsets independently and compare batches plus total count. Include matches spanning every window boundary.
- For syntax/folds, store compact expected ranges and diagnostics for tiny fixtures. Large fixtures assert invariants and sampled checkpoints, not a giant golden file.
- For saving, preserve the original on every injected failure and verify destination content, mode, relevant extended attributes, encoding/BOM, newline bytes, and final-newline state after success.

## Fault injection

Abstract file operations so tests can deterministically return short reads/writes, `EINTR`, `EIO`, `ENOSPC`, `EACCES`, stale size/identity, cancellation, and disconnects at each boundary. Include external truncate/replace while a read, search, index, and save is in flight. A fault must produce a recoverable user-visible error, never a crash, infinite retry, corrupt atomic destination, or silent stale overwrite.
