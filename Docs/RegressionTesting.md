# Regression testing

Run the complete local gate from the repository root:

```sh
Scripts/run_regression_tests.sh
```

The no-argument command deliberately means `full`. It runs the complete SwiftPM
test suite in a clean build directory, builds the optimized app, verifies the
exact pinned DuckDB runtime embedded by the real Xcode build, and then compiles
and runs every standalone AppKit runtime harness against production sources.
It also builds a separate QA-only app with an isolated bundle identifier and
launches that real app process to verify multi-file opening, independent
document windows, Open/Open As panel and menu wiring, optional tabs and forced
tab detachment, Previous/Next activation, the CSV header-to-export route,
inactive-window resident purge/reactivation, and last-task bookmark replay.
That hosted check needs no Accessibility permission, disables macOS state
restoration, has a 60-second watchdog, and must emit an explicit PASS sentinel.
It also runs the 250,000-row CSV interaction regression in an optimized build;
the default performance budget is five seconds each for indexing, distinct
value discovery, and filtering. Set `LIGHTXT_CSV_250K_MAX_SECONDS` to adjust
that per-operation budget on deliberately slower test hardware.
The runtime checks cover CSV, Parquet, document chrome, editor scrolling,
Markdown, prettify lifecycle, structure navigation, accessibility, light/dark
rendering, cancellation, bounded caches, and CSV/Parquet cache purge and reactivation.
Full mode also compiles the exact-process acceptance-test driver and exercises
its non-Accessibility JSON-fixture command, without launching the app or
requiring Accessibility permission.

For a shorter inner loop while developing:

```sh
Scripts/run_regression_tests.sh fast
```

Fast mode still runs every SwiftPM test and builds the complete Debug app. It
then runs focused document-chrome, CSV transaction, and structured-view runtime
checks. Use the full mode before a handoff, release, or merge.

## Isolation and failures

Every invocation creates a fresh directory below the system temporary
directory. SwiftPM scratch data, Xcode DerivedData, compiler module caches,
package caches/configuration/security state, generated fixtures, executables,
and image captures never use a developer's ordinary DerivedData or files.
The hosted workflow app uses a separate `app.lightext.LighTxt.RuntimeQA`
defaults domain under a disposable fixed user home and clears it after replay,
so even a crash or watchdog termination cannot replace the user's real Reopen
Last Task manifest.
SwiftPM subprocess sandboxing is disabled because its entire writable state is
already confined to that disposable directory. Passing runs remove the
directory. Failed runs retain it and print its location so the exact
executables and captures can be inspected.

Set `LIGHTXT_KEEP_TEST_ARTIFACTS=1` to retain artifacts from a successful run.
Set `LIGHTXT_REGRESSION_TMPDIR` to choose the parent of the isolated temporary
directory. On a machine with multiple Xcode versions, set `DEVELOPER_DIR` to
the intended Xcode `Contents/Developer` directory.

The tests use only tiny checked-in fixtures plus deterministic generated stress
data inside the disposable directory: a 57,531-byte editor fixture, bounded CSV
runtime data, and a roughly 220 MB 250,000-row performance fixture. They do not
inspect Downloads, customer data, or the private performance corpus.

## Adding regression coverage

Core and syntax behavior belongs in the appropriate SwiftPM test target. UI or
production-source integration behavior belongs in a guarded standalone file in
`Tests/Runtime`. Register its source recipe and invocation in
`run_regression_tests.sh` in the same change.

The runner compares the registered harness list with the guarded runtime-QA
files on disk and fails preflight when they differ. This prevents a newly added
test from looking covered while being silently skipped by the one-command
suite.
