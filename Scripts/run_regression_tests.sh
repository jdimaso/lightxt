#!/bin/zsh

# One-command, isolated regression coverage for LighTxt.
#
#   Scripts/run_regression_tests.sh          # full suite (the safe default)
#   Scripts/run_regression_tests.sh fast     # shorter inner-loop suite
#   Scripts/run_regression_tests.sh full     # explicit full suite
#
# Every build product, compiler module cache, generated fixture, and capture is
# written under a fresh temporary directory. A failed run keeps that directory
# for diagnosis; a passing run removes it unless LIGHTXT_KEEP_TEST_ARTIFACTS=1.

set -euo pipefail
setopt NO_NOMATCH

readonly SCRIPT_DIRECTORY="${0:A:h}"
readonly REPOSITORY_ROOT="${SCRIPT_DIRECTORY:h}"
readonly MODE="${1:-full}"

case "$MODE" in
    fast|full) ;;
    -h|--help)
        print "Usage: ${0:t} [fast|full]"
        print "  fast  SwiftPM tests, a Debug app build, and focused runtime QA"
        print "  full  SwiftPM tests, a Release app build, and every runtime QA (default)"
        exit 0
        ;;
    *)
        print -u2 "Unknown regression mode: $MODE"
        print -u2 "Usage: ${0:t} [fast|full]"
        exit 64
        ;;
esac

cd "$REPOSITORY_ROOT"

resolve_developer_directory() {
    local candidate="${DEVELOPER_DIR:-}"
    if [[ -n "$candidate" && -x "$candidate/usr/bin/xcodebuild" ]]; then
        print -r -- "$candidate"
        return
    fi

    candidate="$(/usr/bin/xcode-select -p 2>/dev/null || true)"
    if [[ -n "$candidate" && -x "$candidate/usr/bin/xcodebuild" ]]; then
        print -r -- "$candidate"
        return
    fi

    # A developer can keep Command Line Tools selected while a full Xcode is
    # installed elsewhere. Ask Spotlight for that installation before using
    # the conventional location. DEVELOPER_DIR remains the deterministic
    # override on multi-Xcode machines and CI hosts.
    if [[ -x /usr/bin/mdfind ]]; then
        local xcode_application
        while IFS= read -r xcode_application; do
            candidate="$xcode_application/Contents/Developer"
            if [[ -x "$candidate/usr/bin/xcodebuild" ]]; then
                print -r -- "$candidate"
                return
            fi
        done < <(/usr/bin/mdfind 'kMDItemCFBundleIdentifier == "com.apple.dt.Xcode"' 2>/dev/null)
    fi

    candidate="/Applications/Xcode.app/Contents/Developer"
    if [[ -x "$candidate/usr/bin/xcodebuild" ]]; then
        print -r -- "$candidate"
        return
    fi

    print -u2 "A full Xcode installation is required. Set DEVELOPER_DIR to its Contents/Developer directory."
    return 1
}

readonly RESOLVED_DEVELOPER_DIR="$(resolve_developer_directory)"
export DEVELOPER_DIR="$RESOLVED_DEVELOPER_DIR"
readonly XCRUN="/usr/bin/xcrun"
readonly XCODEBUILD="$RESOLVED_DEVELOPER_DIR/usr/bin/xcodebuild"
readonly HOST_ARCHITECTURE="$(/usr/bin/uname -m)"

case "$HOST_ARCHITECTURE" in
    arm64|x86_64) ;;
    *)
        print -u2 "Unsupported macOS architecture: $HOST_ARCHITECTURE"
        exit 65
        ;;
esac

readonly SCRATCH_PARENT="${LIGHTXT_REGRESSION_TMPDIR:-${TMPDIR:-/tmp}}"
/bin/mkdir -p "$SCRATCH_PARENT"
readonly SCRATCH_DIRECTORY="$(/usr/bin/mktemp -d "${SCRATCH_PARENT%/}/LighTxtRegression.XXXXXX")"
readonly SUITE_TEMP_DIRECTORY="$SCRATCH_DIRECTORY/tmp"
# Foundation's temporaryDirectory and lower-level mkstemp users inherit this.
# The trailing slash matches Darwin's ordinary TMPDIR convention.
export TMPDIR="$SUITE_TEMP_DIRECTORY/"
readonly ARTIFACT_DIRECTORY="$SCRATCH_DIRECTORY/artifacts"
readonly BIN_DIRECTORY="$SCRATCH_DIRECTORY/bin"
readonly MODULE_CACHE_DIRECTORY="$SCRATCH_DIRECTORY/module-cache"
readonly NATIVE_DIRECTORY="$SCRATCH_DIRECTORY/native"
readonly XCODE_DERIVED_DATA="$SCRATCH_DIRECTORY/XcodeDerivedData"
readonly WORKFLOW_QA_DERIVED_DATA="$SCRATCH_DIRECTORY/WorkflowQADerivedData"
readonly XCODE_SOURCE_PACKAGES="$SCRATCH_DIRECTORY/XcodeSourcePackages"
readonly SWIFTPM_SCRATCH="$SCRATCH_DIRECTORY/SwiftPM"
readonly SWIFTPM_PERFORMANCE_SCRATCH="$SCRATCH_DIRECTORY/SwiftPMPerformance"
readonly SWIFTPM_CACHE_DIRECTORY="$SCRATCH_DIRECTORY/SwiftPMCache"
readonly SWIFTPM_CONFIGURATION_DIRECTORY="$SCRATCH_DIRECTORY/SwiftPMConfiguration"
readonly SWIFTPM_SECURITY_DIRECTORY="$SCRATCH_DIRECTORY/SwiftPMSecurity"

/bin/mkdir -p \
    "$ARTIFACT_DIRECTORY" \
    "$BIN_DIRECTORY" \
    "$MODULE_CACHE_DIRECTORY" \
    "$NATIVE_DIRECTORY" \
    "$SUITE_TEMP_DIRECTORY" \
    "$SWIFTPM_CACHE_DIRECTORY" \
    "$SWIFTPM_CONFIGURATION_DIRECTORY" \
    "$SWIFTPM_SECURITY_DIRECTORY"

typeset -a PASSED_STEPS
CURRENT_STEP="preflight"
SUITE_STARTED_AT=$SECONDS

finish() {
    local exit_code=$?
    local elapsed=$((SECONDS - SUITE_STARTED_AT))
    print
    if [[ "$exit_code" == 0 ]]; then
        print "Regression suite passed (${MODE}, ${elapsed}s):"
        local step
        for step in "${PASSED_STEPS[@]}"; do
            print "  ✓ $step"
        done
        if [[ "${LIGHTXT_KEEP_TEST_ARTIFACTS:-0}" == 1 ]]; then
            print "Artifacts kept at: $SCRATCH_DIRECTORY"
        else
            /bin/rm -rf "$SCRATCH_DIRECTORY"
        fi
    else
        print -u2 "Regression suite FAILED during: $CURRENT_STEP"
        print -u2 "Diagnostic build output and captures were kept at: $SCRATCH_DIRECTORY"
    fi
}
trap 'finish' EXIT

run_step() {
    local label="$1"
    shift
    CURRENT_STEP="$label"
    local started=$SECONDS
    print
    print "==> $label"
    # Keep the call out of a shell conditional: zsh deliberately suppresses
    # `errexit` inside functions evaluated by `if`/`!`, which would let later
    # artifact checks obscure the command that actually failed.
    "$@"
    local elapsed=$((SECONDS - started))
    PASSED_STEPS+=("$label (${elapsed}s)")
}

require_file() {
    [[ -f "$1" ]] || {
        print -u2 "Required regression input is missing: $1"
        return 65
    }
}

preflight() {
    [[ "$(/usr/bin/uname -s)" == Darwin ]] || {
        print -u2 "LighTxt AppKit regression tests require macOS."
        return 65
    }
    "$XCRUN" swift --version
    "$XCODEBUILD" -version

    require_file Package.swift
    require_file LighTxt.xcodeproj/xcshareddata/xcschemes/LighTxt.xcscheme
    require_file LighTxt/LighTxt.entitlements
    require_file ThirdParty/DuckDB/libduckdb-osx-universal-v1.4.5.zip
    require_file Tests/Fixtures/RuntimeQA.csv
    require_file Tests/Fixtures/RuntimeQA.md
    require_file Tests/Fixtures/Parquet/query-service.parquet

    local printing_entitlement
    printing_entitlement="$(/usr/libexec/PlistBuddy \
        -c 'Print :com.apple.security.print' \
        LighTxt/LighTxt.entitlements 2>/dev/null || true)"
    [[ "$printing_entitlement" == true ]] || {
        print -u2 "The sandboxed app must include com.apple.security.print to support File > Print."
        return 65
    }

    # New standalone harnesses and drivers must be deliberately registered below. This is
    # intentionally a hard failure: a checked-in regression test must never be
    # silently omitted from the one-command full suite.
    typeset -a registered actual
    registered=(
        CSVSessionMutationRuntimeQA.swift
        CSVTableRuntimeQA.swift
        DocumentChromeRuntimeQA.swift
        EditorScrollingRuntimeQA.swift
        LighTxtRuntimeDriver.swift
        MarkdownRendererRuntimeQA.swift
        ParquetTableRuntimeQA.swift
        PrettifyLifecycleRuntimeQA.swift
        StructuredViewRuntimeQA.swift
    )
    actual=("${(@f)$(/usr/bin/grep -l '^#if LIGHTXT_STANDALONE_' Tests/Runtime/*.swift | /usr/bin/xargs -n 1 /usr/bin/basename | /usr/bin/sort)}")
    registered=("${(@on)registered}")
    if [[ "${(j:\n:)registered}" != "${(j:\n:)actual}" ]]; then
        print -u2 "Standalone runtime-QA registration drifted."
        print -u2 "Registered: ${(j:, :)registered}"
        print -u2 "On disk:    ${(j:, :)actual}"
        print -u2 "Add a compile/run recipe to Scripts/run_regression_tests.sh."
        return 65
    fi
}

run_swiftpm_tests() {
    env \
        DEVELOPER_DIR="$RESOLVED_DEVELOPER_DIR" \
        CLANG_MODULE_CACHE_PATH="$MODULE_CACHE_DIRECTORY" \
        SWIFTPM_MODULECACHE_OVERRIDE="$MODULE_CACHE_DIRECTORY" \
        "$XCRUN" swift test \
        --package-path "$REPOSITORY_ROOT" \
        --scratch-path "$SWIFTPM_SCRATCH" \
        --cache-path "$SWIFTPM_CACHE_DIRECTORY" \
        --config-path "$SWIFTPM_CONFIGURATION_DIRECTORY" \
        --security-path "$SWIFTPM_SECURITY_DIRECTORY" \
        --disable-sandbox \
        --quiet
}

run_release_performance_regression() {
    local performance_log="$ARTIFACT_DIRECTORY/release-250k-performance.log"
    env \
        DEVELOPER_DIR="$RESOLVED_DEVELOPER_DIR" \
        CLANG_MODULE_CACHE_PATH="$MODULE_CACHE_DIRECTORY" \
        SWIFTPM_MODULECACHE_OVERRIDE="$MODULE_CACHE_DIRECTORY" \
        LIGHTXT_RUN_PERFORMANCE_REGRESSIONS=1 \
        "$XCRUN" swift test \
        --package-path "$REPOSITORY_ROOT" \
        --scratch-path "$SWIFTPM_PERFORMANCE_SCRATCH" \
        --cache-path "$SWIFTPM_CACHE_DIRECTORY" \
        --config-path "$SWIFTPM_CONFIGURATION_DIRECTORY" \
        --security-path "$SWIFTPM_SECURITY_DIRECTORY" \
        --disable-sandbox \
        --configuration release \
        --quiet \
        --filter CSVScaleRegressionTests.testQuarterMillionRowInteractiveOperationsStayWithinReleaseBudget \
        2>&1 | /usr/bin/tee "$performance_log"
    /usr/bin/grep -Fq "LighTxt 250k CSV regression:" "$performance_log" || {
        print -u2 "The filtered Release performance test did not execute."
        return 65
    }
}

APP_CONFIGURATION=Debug
[[ "$MODE" == full ]] && APP_CONFIGURATION=Release
readonly APP_CONFIGURATION

build_application() {
    env DEVELOPER_DIR="$RESOLVED_DEVELOPER_DIR" \
        "$XCODEBUILD" \
        -project LighTxt.xcodeproj \
        -scheme LighTxt \
        -configuration "$APP_CONFIGURATION" \
        -destination "platform=macOS,arch=$HOST_ARCHITECTURE" \
        -derivedDataPath "$XCODE_DERIVED_DATA" \
        -clonedSourcePackagesDirPath "$XCODE_SOURCE_PACKAGES" \
        -packageCachePath "$SWIFTPM_CACHE_DIRECTORY" \
        -packageAuthorizationProvider netrc \
        -onlyUsePackageVersionsFromResolvedFile \
        -quiet \
        CODE_SIGNING_ALLOWED=NO \
        build

    require_file "$XCODE_DERIVED_DATA/Build/Products/$APP_CONFIGURATION/LighTxt.app/Contents/MacOS/LighTxt"
    require_file "$XCODE_DERIVED_DATA/Build/Products/$APP_CONFIGURATION/LighTxt.app/Contents/Frameworks/libduckdb.dylib"
}

build_workflow_qa_application() {
    env DEVELOPER_DIR="$RESOLVED_DEVELOPER_DIR" \
        "$XCODEBUILD" \
        -project LighTxt.xcodeproj \
        -scheme LighTxt \
        -configuration Debug \
        -destination "platform=macOS,arch=$HOST_ARCHITECTURE" \
        -derivedDataPath "$WORKFLOW_QA_DERIVED_DATA" \
        -clonedSourcePackagesDirPath "$XCODE_SOURCE_PACKAGES" \
        -packageCachePath "$SWIFTPM_CACHE_DIRECTORY" \
        -packageAuthorizationProvider netrc \
        -onlyUsePackageVersionsFromResolvedFile \
        -quiet \
        CODE_SIGNING_ALLOWED=NO \
        PRODUCT_BUNDLE_IDENTIFIER=app.lightext.LighTxt.RuntimeQA \
        'SWIFT_ACTIVE_COMPILATION_CONDITIONS=$(inherited) LIGHTXT_RUNTIME_QA' \
        build

    local application="$WORKFLOW_QA_DERIVED_DATA/Build/Products/Debug/LighTxt.app"
    require_file "$application/Contents/MacOS/LighTxt"
    require_file "$application/Contents/Frameworks/libduckdb.dylib"
    local bundle_identifier
    bundle_identifier="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$application/Contents/Info.plist")"
    [[ "$bundle_identifier" == app.lightext.LighTxt.RuntimeQA ]] || {
        print -u2 "Workflow QA build is not isolated: $bundle_identifier"
        return 65
    }
}

qa_hosted_document_workflow() {
    local application="$WORKFLOW_QA_DERIVED_DATA/Build/Products/Debug/LighTxt.app"
    local workspace="$SUITE_TEMP_DIRECTORY/hosted-document-workflow"
    local log="$ARTIFACT_DIRECTORY/hosted-document-workflow.log"
    local result="$workspace/workflow-runtime-qa.result"
    local app_pid_file="$workspace/workflow-runtime-qa.pid"
    /bin/mkdir -p "$workspace"
    /bin/rm -f "$result" "$app_pid_file"

    # LaunchServices is required here: a directly executed .app binary cannot
    # become the active application, so AppKit will never deliver genuine
    # key-window transitions. The QA app writes its own atomic result file.
    /usr/bin/open -W -n -F -a "$application" --args \
        -ApplePersistenceIgnoreState YES \
        --workflow-runtime-qa "$workspace" \
        --workflow-runtime-qa-recovery-root "$workspace/recovery" &
    local qa_pid=$!
    local ticks=0
    local timed_out=0
    while /bin/kill -0 "$qa_pid" 2>/dev/null && [[ ! -f "$result" ]]; do
        if (( ticks >= 600 )); then
            timed_out=1
            if [[ -r "$app_pid_file" ]]; then
                local qa_app_pid
                IFS= read -r qa_app_pid < "$app_pid_file"
                if [[ "$qa_app_pid" == <-> ]]; then
                    /bin/kill -TERM "$qa_app_pid" 2>/dev/null || true
                fi
            fi
            /bin/kill -TERM "$qa_pid" 2>/dev/null || true
            /bin/sleep 0.2
            /bin/kill -KILL "$qa_pid" 2>/dev/null || true
            break
        fi
        /bin/sleep 0.1
        (( ticks += 1 ))
    done

    local qa_status=0
    wait "$qa_pid" || qa_status=$?
    if (( timed_out )); then
        print -u2 "Hosted document-workflow QA timed out after 60 seconds."
        return 65
    fi
    if [[ ! -f "$result" ]]; then
        print -u2 "Hosted document-workflow QA exited without a result (launcher status $qa_status)."
        return 65
    fi
    /bin/cp "$result" "$log"
    /bin/cat "$log"
    /usr/bin/grep -Eq '^LIGHTXT_WORKFLOW_RUNTIME_QA_PASS assertions=[1-9][0-9]*$' "$log" || {
        print -u2 "Hosted document-workflow QA did not emit its PASS sentinel."
        return 65
    }
}

readonly DUCKDB_LIBRARY="$XCODE_DERIVED_DATA/Build/Products/$APP_CONFIGURATION/LighTxt.app/Contents/Frameworks/libduckdb.dylib"

verify_duckdb() {
    "$XCRUN" clang \
        -mmacosx-version-min=14.0 \
        Scripts/verify_duckdb_runtime.c \
        -o "$BIN_DIRECTORY/verify-duckdb"
    "$BIN_DIRECTORY/verify-duckdb" "$DUCKDB_LIBRARY" v1.4.5
}

typeset -a SWIFTC_COMMON
SWIFTC_COMMON=(
    -parse-as-library
    -swift-version 5
    -O
    -target "${HOST_ARCHITECTURE}-apple-macosx14.0"
    -module-cache-path "$MODULE_CACHE_DIRECTORY"
)

swift_qa() {
    local output="$1"
    shift
    "$XCRUN" swiftc "${SWIFTC_COMMON[@]}" "$@" -o "$output"
}

build_json_accelerator_objects() {
    if [[ -f "$NATIVE_DIRECTORY/LighTxtJSONAccelerator.o" \
          && -f "$NATIVE_DIRECTORY/simdjson.o" ]]; then
        return
    fi
    "$XCRUN" clang++ \
        -std=c++17 -O3 -mmacosx-version-min=14.0 \
        -I LighTxt/Vendor/JSONAccelerator/include \
        -I LighTxt/Vendor/JSONAccelerator/simdjson \
        -c LighTxt/Vendor/JSONAccelerator/LighTxtJSONAccelerator.cpp \
        -o "$NATIVE_DIRECTORY/LighTxtJSONAccelerator.o"
    "$XCRUN" clang++ \
        -std=c++17 -O3 -mmacosx-version-min=14.0 \
        -I LighTxt/Vendor/JSONAccelerator/simdjson \
        -c LighTxt/Vendor/JSONAccelerator/simdjson/simdjson.cpp \
        -o "$NATIVE_DIRECTORY/simdjson.o"
}

qa_document_chrome() {
    local executable="$BIN_DIRECTORY/DocumentChromeRuntimeQA"
    swift_qa "$executable" \
        -DLIGHTXT_STANDALONE_CHROME_QA \
        -DLIGHTXT_RUNTIME_QA \
        LighTxt/Core/LighTxtCoreError.swift \
        LighTxt/Core/ExternalFileMonitor.swift \
        LighTxt/UI/LighTxtTheme.swift \
        LighTxt/UI/DocumentChromeViews.swift \
        LighTxt/UI/ExternalChangeBannerView.swift \
        Tests/Runtime/DocumentChromeRuntimeQA.swift
    "$executable"
}

qa_runtime_driver_smoke() {
    local executable="$BIN_DIRECTORY/LighTxtRuntimeDriver"
    local fixture="$SUITE_TEMP_DIRECTORY/runtime-driver-smoke.json"
    swift_qa "$executable" \
        -DLIGHTXT_STANDALONE_RUNTIME_DRIVER \
        Tests/Runtime/LighTxtRuntimeDriver.swift
    "$executable" make-json \
        --path "$fixture" \
        --items 257 \
        --payload-bytes 0
    [[ -s "$fixture" ]] || {
        print -u2 "Runtime driver did not create its JSON smoke fixture: $fixture"
        return 65
    }
}

qa_structured_view() {
    local executable="$BIN_DIRECTORY/StructuredViewRuntimeQA"
    local output="$ARTIFACT_DIRECTORY/structured-view"
    /bin/mkdir -p "$output"
    swift_qa "$executable" \
        -DLIGHTXT_STANDALONE_STRUCTURE_QA \
        -DLIGHTXT_RUNTIME_QA \
        LighTxt/UI/FindBarView.swift \
        LighTxt/UI/StructureSearchResultBuilder.swift \
        LighTxt/UI/StructureSidebarView.swift \
        Tests/Runtime/StructuredViewRuntimeQA.swift
    "$executable" "$output"
}

qa_csv_session_mutation() {
    build_json_accelerator_objects
    local executable="$BIN_DIRECTORY/CSVSessionMutationRuntimeQA"
    swift_qa "$executable" \
        -DLIGHTXT_STANDALONE_CSV_SESSION_QA \
        -import-objc-header LighTxt/LighTxt-Bridging-Header.h \
        -Xcc -I -Xcc LighTxt/Vendor/JSONAccelerator/include \
        LighTxt/Core/LighTxtCoreError.swift \
        LighTxt/Core/LighTxtSignpost.swift \
        LighTxt/Core/MemoryMappedFile.swift \
        LighTxt/Core/StreamingFileWriter.swift \
        LighTxt/Core/StreamingUnicodeTranscoder.swift \
        LighTxt/Core/RecoveryJournal.swift \
        LighTxt/Core/FileBackedPieceTable.swift \
        LighTxt/Core/CSVDocumentIndex.swift \
        LighTxt/Core/CSVDataOperations.swift \
        LighTxt/Core/BulkReplace.swift \
        LighTxt/Core/StreamingSearch.swift \
        LighTxt/Core/ExternalFileMonitor.swift \
        LighTxt/Core/StreamingJSONStructureIndex.swift \
        LighTxt/Syntax/SyntaxTypes.swift \
        LighTxt/Syntax/SyntaxByteUtilities.swift \
        LighTxt/Syntax/SyntaxDiagnostics.swift \
        LighTxt/Syntax/SyntaxFoldDiscovery.swift \
        LighTxt/Syntax/ViewportSyntaxHighlighter.swift \
        LighTxt/Syntax/FileTypeDetector.swift \
        LighTxt/Syntax/DocumentDetectionTypes.swift \
        LighTxt/Syntax/SampledDocumentDetector.swift \
        LighTxt/Model/SparseUTF8LineIndex.swift \
        LighTxt/Model/JSONStructureController.swift \
        LighTxt/Model/DocumentSearchController.swift \
        LighTxt/Documents/DocumentRecoveryCoordinator.swift \
        LighTxt/UI/CSVMutationEditorDelegate.swift \
        LighTxt/Model/LighTxtDocumentSession.swift \
        Tests/Runtime/CSVSessionMutationRuntimeQA.swift \
        "$NATIVE_DIRECTORY/LighTxtJSONAccelerator.o" \
        "$NATIVE_DIRECTORY/simdjson.o" \
        -Xlinker -lc++
    "$executable"
}

qa_csv_table() {
    build_json_accelerator_objects
    local executable="$BIN_DIRECTORY/CSVTableRuntimeQA"
    local output="$ARTIFACT_DIRECTORY/csv-table"
    /bin/mkdir -p "$output"
    swift_qa "$executable" \
        -DLIGHTXT_STANDALONE_CSV_QA \
        -import-objc-header LighTxt/LighTxt-Bridging-Header.h \
        -Xcc -I -Xcc LighTxt/Vendor/JSONAccelerator/include \
        LighTxt/Core/LighTxtCoreError.swift \
        LighTxt/Core/MemoryMappedFile.swift \
        LighTxt/Core/StreamingFileWriter.swift \
        LighTxt/Core/RecoveryJournal.swift \
        LighTxt/Core/FileBackedPieceTable.swift \
        LighTxt/Core/CSVDocumentIndex.swift \
        LighTxt/Core/CSVDataOperations.swift \
        LighTxt/Core/TabularExport.swift \
        LighTxt/UI/LighTxtTheme.swift \
        LighTxt/UI/LighTxtComfortScroller.swift \
        LighTxt/UI/TabularExportAccessoryView.swift \
        LighTxt/UI/CSVTableView.swift \
        Tests/Runtime/CSVTableRuntimeQA.swift \
        "$NATIVE_DIRECTORY/LighTxtJSONAccelerator.o" \
        "$NATIVE_DIRECTORY/simdjson.o" \
        -Xlinker -lc++
    "$executable" Tests/Fixtures/RuntimeQA.csv "$output"
}

generate_editor_scrolling_fixture() {
    local destination="$1"
    /usr/bin/awk 'BEGIN {
        line = "0000000000abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-This-is-a-deliberately-wide-LighTxt-editor-regression-line-with-Unicode-safe-ASCII-padding-abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789"
        target = 57531
        written = 0
        lineBytes = length(line) + 1
        while (written + lineBytes <= target) {
            print line
            written += lineBytes
        }
        remaining = target - written
        for (i = 0; i < remaining; i++) printf "x"
    }' >| "$destination"
    [[ "$(/usr/bin/stat -f %z "$destination")" == 57531 ]] || {
        print -u2 "Generated editor fixture has the wrong byte count."
        return 65
    }
}

qa_editor_scrolling() {
    local executable="$BIN_DIRECTORY/EditorScrollingRuntimeQA"
    local fixture="$SCRATCH_DIRECTORY/editor-scrolling-fixture.txt"
    local output="$ARTIFACT_DIRECTORY/editor-scrolling-light.png"
    generate_editor_scrolling_fixture "$fixture"
    swift_qa "$executable" \
        -DLIGHTXT_STANDALONE_EDITOR_SCROLL_QA \
        -DLIGHTXT_RUNTIME_QA \
        LighTxt/Application/LighTxtFontController.swift \
        LighTxt/UI/LighTxtTheme.swift \
        LighTxt/UI/SyntaxPalette.swift \
        LighTxt/Syntax/SyntaxTypes.swift \
        LighTxt/Syntax/SyntaxByteUtilities.swift \
        LighTxt/Syntax/SyntaxDiagnostics.swift \
        LighTxt/Syntax/SyntaxFoldDiscovery.swift \
        LighTxt/Syntax/ViewportSyntaxHighlighter.swift \
        LighTxt/UI/LighTxtComfortScroller.swift \
        LighTxt/UI/VirtualTextEditorView.swift \
        Tests/Runtime/EditorScrollingRuntimeQA.swift
    "$executable" "$fixture" "$output"
}

qa_markdown_renderer() {
    local executable="$BIN_DIRECTORY/MarkdownRendererRuntimeQA"
    local output="$ARTIFACT_DIRECTORY/markdown-renderer"
    /bin/mkdir -p "$output"
    swift_qa "$executable" \
        -DLIGHTXT_STANDALONE_MARKDOWN_QA \
        -framework PDFKit \
        LighTxt/UI/LighTxtTheme.swift \
        LighTxt/UI/MarkdownPreviewView.swift \
        LighTxt/UI/DocumentPDFExporter.swift \
        Tests/Runtime/MarkdownRendererRuntimeQA.swift
    "$executable" Tests/Fixtures/RuntimeQA.md "$output"
}

qa_parquet_table() {
    local executable="$BIN_DIRECTORY/ParquetTableRuntimeQA"
    local output="$ARTIFACT_DIRECTORY/parquet-table"
    /bin/mkdir -p "$output"
    swift_qa "$executable" \
        -DLIGHTXT_STANDALONE_CSV_QA \
        -DLIGHTXT_STANDALONE_PARQUET_QA \
        LighTxt/Core/LighTxtCoreError.swift \
        LighTxt/Core/ExternalFileMonitor.swift \
        LighTxt/Core/MemoryMappedFile.swift \
        LighTxt/Core/TabularExport.swift \
        LighTxt/Core/ParquetQueryService.swift \
        LighTxt/UI/LighTxtComfortScroller.swift \
        LighTxt/UI/TabularExportAccessoryView.swift \
        LighTxt/UI/CSVTableView.swift \
        LighTxt/UI/ParquetTableView.swift \
        Tests/Runtime/ParquetTableRuntimeQA.swift
    LIGHTXT_DUCKDB_LIBRARY_PATH="$DUCKDB_LIBRARY" \
        "$executable" Tests/Fixtures/Parquet/query-service.parquet "$output"
}

qa_prettify_lifecycle() {
    local executable="$BIN_DIRECTORY/PrettifyLifecycleRuntimeQA"
    local output="$ARTIFACT_DIRECTORY/prettify-lifecycle"
    /bin/mkdir -p "$output"
    swift_qa "$executable" \
        -DLIGHTXT_STANDALONE_PRETTIFY_QA \
        -DLIGHTXT_RUNTIME_QA \
        LighTxt/Application/LighTxtFontController.swift \
        LighTxt/UI/LighTxtTheme.swift \
        LighTxt/UI/SyntaxPalette.swift \
        LighTxt/Syntax/SyntaxTypes.swift \
        LighTxt/Syntax/SyntaxByteUtilities.swift \
        LighTxt/Syntax/SyntaxDiagnostics.swift \
        LighTxt/Syntax/SyntaxFoldDiscovery.swift \
        LighTxt/Syntax/ViewportSyntaxHighlighter.swift \
        LighTxt/Syntax/ViewportPrettifier.swift \
        LighTxt/UI/LighTxtComfortScroller.swift \
        LighTxt/UI/VirtualTextEditorView.swift \
        LighTxt/UI/DocumentChromeViews.swift \
        LighTxt/UI/PrettifiedViewportView.swift \
        Tests/Runtime/PrettifyLifecycleRuntimeQA.swift
    "$executable" "$output"
}

run_selected_runtime_qa() {
    # Keep fast mode useful as a true inner-loop check while still crossing the
    # SwiftPM/AppKit boundary. Full mode is the release and handoff gate.
    if [[ "$MODE" == fast ]]; then
        run_step "Runtime QA: document chrome" qa_document_chrome
        run_step "Runtime QA: CSV mutation transaction" qa_csv_session_mutation
        run_step "Runtime QA: structured view" qa_structured_view
        return
    fi

    run_step "Runtime QA: document chrome" qa_document_chrome
    run_step "Runtime QA: non-AX driver smoke" qa_runtime_driver_smoke
    run_step "Runtime QA: CSV mutation transaction" qa_csv_session_mutation
    run_step "Runtime QA: CSV table" qa_csv_table
    run_step "Runtime QA: editor scrolling" qa_editor_scrolling
    run_step "Runtime QA: Markdown renderer" qa_markdown_renderer
    run_step "Runtime QA: Parquet table" qa_parquet_table
    run_step "Runtime QA: prettify lifecycle" qa_prettify_lifecycle
    run_step "Runtime QA: structured view" qa_structured_view
}

run_step "Preflight and runtime-QA registration" preflight
run_step "SwiftPM core, syntax, and line-index tests" run_swiftpm_tests
if [[ "$MODE" == full ]]; then
    run_step "Release 250,000-row interaction performance budget" run_release_performance_regression
fi
run_step "$APP_CONFIGURATION application build" build_application
run_step "Pinned DuckDB runtime verification" verify_duckdb
if [[ "$MODE" == full ]]; then
    run_step "QA-only hosted application build" build_workflow_qa_application
    run_step "Hosted multi-document workflow QA" qa_hosted_document_workflow
fi
run_selected_runtime_qa
