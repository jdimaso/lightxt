#!/bin/zsh

set -euo pipefail

readonly DUCKDB_VERSION="v1.4.5"
readonly DUCKDB_ARCHIVE_SHA256="33f840404e3b420600936d5b59d342680aa4af41cc06d9a5589711e43cd75766"
readonly DUCKDB_ARCHIVE="${SRCROOT:?}/ThirdParty/DuckDB/libduckdb-osx-universal-${DUCKDB_VERSION}.zip"
readonly DUCKDB_LICENSE_FILE_LIST="${SRCROOT}/ThirdParty/DuckDB/DuckDBLicenses.xcfilelist"
readonly DUCKDB_LICENSE_MANIFEST_PREFIX='$(SRCROOT)/ThirdParty/DuckDB/Licenses/'
readonly EXTRACT_DIRECTORY="${DERIVED_FILE_DIR:?}/LighTxt-DuckDB-${DUCKDB_VERSION}"
readonly FRAMEWORKS_DIRECTORY="${TARGET_BUILD_DIR:?}/${FRAMEWORKS_FOLDER_PATH:?}"
readonly LIBRARY_DESTINATION="${FRAMEWORKS_DIRECTORY}/libduckdb.dylib"
readonly RESOURCES_DIRECTORY="${TARGET_BUILD_DIR}/${UNLOCALIZED_RESOURCES_FOLDER_PATH:?}"
readonly LICENSE_DESTINATION="${RESOURCES_DIRECTORY}/DuckDB-Licenses"
readonly COMPLETION_STAMP="${DERIVED_FILE_DIR}/LighTxt-DuckDB-${DUCKDB_VERSION}.stamp"

fail() {
    print -u2 "DuckDB embed failed: $1"
    exit 65
}

[[ -f "$DUCKDB_ARCHIVE" ]] || fail "Pinned archive is missing: $DUCKDB_ARCHIVE"
[[ -f "$DUCKDB_LICENSE_FILE_LIST" ]] || fail "License manifest is missing: $DUCKDB_LICENSE_FILE_LIST"

ACTUAL_SHA256="$(/usr/bin/shasum -a 256 "$DUCKDB_ARCHIVE" | /usr/bin/awk '{print $1}')"
[[ "$ACTUAL_SHA256" == "$DUCKDB_ARCHIVE_SHA256" ]] || {
    fail "Archive SHA-256 is $ACTUAL_SHA256, expected $DUCKDB_ARCHIVE_SHA256."
}

# Both destinations are confined to Xcode-owned build directories. Recreate
# them so a version change cannot leave stale headers or license files behind.
/bin/rm -rf "$EXTRACT_DIRECTORY"
/bin/mkdir -p "$EXTRACT_DIRECTORY" "$FRAMEWORKS_DIRECTORY" "$RESOURCES_DIRECTORY"
/usr/bin/ditto -x -k "$DUCKDB_ARCHIVE" "$EXTRACT_DIRECTORY"
readonly EXTRACTED_LIBRARY="${EXTRACT_DIRECTORY}/libduckdb.dylib"
[[ -f "$EXTRACTED_LIBRARY" ]] || fail "Archive did not contain libduckdb.dylib."

ARCHITECTURES="$(/usr/bin/lipo -archs "$EXTRACTED_LIBRARY")"
[[ " $ARCHITECTURES " == *" arm64 "* && " $ARCHITECTURES " == *" x86_64 "* ]] || {
    fail "Runtime is not universal arm64+x86_64: $ARCHITECTURES"
}
[[ "$(print -r -- "$ARCHITECTURES" | /usr/bin/wc -w | /usr/bin/tr -d ' ')" == "2" ]] || {
    fail "Runtime contains unexpected architectures: $ARCHITECTURES"
}

INSTALL_NAME="$(/usr/bin/otool -D "$EXTRACTED_LIBRARY" | /usr/bin/tail -n 1 | /usr/bin/xargs)"
[[ "$INSTALL_NAME" == "@rpath/libduckdb.dylib" ]] || fail "Unexpected install name: $INSTALL_NAME"

for architecture in arm64 x86_64; do
    dependency_count=0
    while IFS= read -r dependency; do
        dependency_count=$((dependency_count + 1))
        case "$dependency" in
            "@rpath/libduckdb.dylib"|"/usr/lib/libc++.1.dylib"|"/usr/lib/libSystem.B.dylib") ;;
            *) fail "Unexpected $architecture dynamic dependency: $dependency" ;;
        esac
    done < <(/usr/bin/otool -arch "$architecture" -L "$EXTRACTED_LIBRARY" \
        | /usr/bin/tail -n +2 | /usr/bin/awk '{print $1}')
    [[ "$dependency_count" == "3" ]] || {
        fail "$architecture slice has $dependency_count dynamic dependencies; expected 3."
    }
done

/usr/bin/ditto "$EXTRACTED_LIBRARY" "$LIBRARY_DESTINATION"
/bin/rm -rf "$LICENSE_DESTINATION"
/bin/mkdir -p "$LICENSE_DESTINATION"
license_file_count=0
while IFS= read -r declared_license; do
    [[ -n "$declared_license" && "$declared_license" != \#* ]] || continue
    [[ "$declared_license" == "$DUCKDB_LICENSE_MANIFEST_PREFIX"* ]] || {
        fail "License manifest contains an unexpected path: $declared_license"
    }
    readonly_relative_source="${declared_license#\$\(SRCROOT\)/}"
    relative_license="${declared_license#*Licenses/}"
    license_source="${SRCROOT}/${readonly_relative_source}"
    license_destination="${LICENSE_DESTINATION}/${relative_license}"
    [[ -f "$license_source" ]] || fail "Declared license is missing: $license_source"
    /bin/mkdir -p "${license_destination:h}"
    /bin/cp -X "$license_source" "$license_destination"
    license_file_count=$((license_file_count + 1))
done < "$DUCKDB_LICENSE_FILE_LIST"
[[ "$license_file_count" == "32" ]] || fail "Expected 32 license files, copied $license_file_count."

if [[ "${CODE_SIGNING_ALLOWED:-YES}" == "NO" ]]; then
    /usr/bin/codesign --force --sign - --timestamp=none "$LIBRARY_DESTINATION"
else
    readonly SIGNING_IDENTITY="${EXPANDED_CODE_SIGN_IDENTITY:-}"
    [[ -n "$SIGNING_IDENTITY" ]] || fail "Xcode did not provide an expanded signing identity."
    # Build phases must be deterministic/offline. Archive export or the
    # existing Developer-ID release signing pass applies the trusted timestamp
    # when it re-signs the complete bundle inside-out.
    /usr/bin/codesign --force --sign "$SIGNING_IDENTITY" --options runtime --timestamp=none "$LIBRARY_DESTINATION"
fi

/usr/bin/codesign --verify --strict --verbose=2 "$LIBRARY_DESTINATION"
[[ -f "$LICENSE_DESTINATION/LICENSE" ]] || fail "DuckDB license was not copied."
[[ ! -e "$FRAMEWORKS_DIRECTORY/duckdb.h" && ! -e "$FRAMEWORKS_DIRECTORY/duckdb.hpp" ]] || {
    fail "DuckDB headers must not be shipped."
}

print -r -- "$DUCKDB_VERSION $DUCKDB_ARCHIVE_SHA256" >| "$COMPLETION_STAMP"
