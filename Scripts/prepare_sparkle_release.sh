#!/bin/zsh

set -euo pipefail

readonly REPOSITORY="jdimaso/lightxt"
readonly KEYCHAIN_ACCOUNT="jdimaso-lighttxt"
readonly EXPECTED_BUNDLE_ID="app.lightext.LighTxt"
readonly PROJECT_NAME="LighTxt.xcodeproj"
readonly SCHEME_NAME="LighTxt"
readonly EXPECTED_DUCKDB_VERSION="v1.4.5"
readonly EXPECTED_DUCKDB_LICENSE_SHA256="7e17fd31249fa875cb3b1c5e05c6c3e99b75509f6a2804ca176c217834de1dcb"

usage() {
    print -u2 "Usage: $0 /path/to/LighTxt.app /path/to/release-notes.md [output-directory]"
    exit 64
}

[[ $# -ge 2 && $# -le 3 ]] || usage

SCRIPT_DIR="${0:A:h}"
REPOSITORY_ROOT="${SCRIPT_DIR:h}"
APP_PATH="${1:A}"
RELEASE_NOTES_PATH="${2:A}"

[[ -d "$APP_PATH" ]] || { print -u2 "App bundle not found: $APP_PATH"; exit 66; }
[[ -f "$RELEASE_NOTES_PATH" ]] || { print -u2 "Release notes not found: $RELEASE_NOTES_PATH"; exit 66; }

INFO_PLIST="$APP_PATH/Contents/Info.plist"
[[ -f "$INFO_PLIST" ]] || { print -u2 "The app has no Info.plist: $APP_PATH"; exit 65; }

SHORT_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$INFO_PLIST")"
BUILD_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$INFO_PLIST")"
BUNDLE_ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$INFO_PLIST")"

[[ "$BUNDLE_ID" == "$EXPECTED_BUNDLE_ID" ]] || {
    print -u2 "Unexpected bundle identifier: $BUNDLE_ID"
    exit 65
}

OUTPUT_DIR="${3:-$REPOSITORY_ROOT/SparkleUpdates/v$SHORT_VERSION}"
OUTPUT_DIR="${OUTPUT_DIR:A}"
if [[ -e "$OUTPUT_DIR" && -n "$(ls -A "$OUTPUT_DIR" 2>/dev/null)" ]]; then
    print -u2 "Output directory must be empty: $OUTPUT_DIR"
    exit 73
fi
mkdir -p "$OUTPUT_DIR"

SPARKLE_CACHE="$REPOSITORY_ROOT/.sparkle-tools"
SPARKLE_BIN="${SPARKLE_BIN_OVERRIDE:-$SPARKLE_CACHE/artifacts/sparkle/Sparkle/bin}"
if [[ ! -x "$SPARKLE_BIN/generate_appcast" || ! -x "$SPARKLE_BIN/sign_update" ]]; then
    DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}" \
        xcodebuild -resolvePackageDependencies \
        -project "$REPOSITORY_ROOT/$PROJECT_NAME" \
        -scheme "$SCHEME_NAME" \
        -clonedSourcePackagesDirPath "$SPARKLE_CACHE"
fi

GENERATE_APPCAST="$SPARKLE_BIN/generate_appcast"
GENERATE_KEYS="$SPARKLE_BIN/generate_keys"
SIGN_UPDATE="$SPARKLE_BIN/sign_update"
[[ -x "$GENERATE_APPCAST" && -x "$GENERATE_KEYS" && -x "$SIGN_UPDATE" ]] || {
    print -u2 "Sparkle release tools were not resolved."
    exit 69
}

# Sparkle's -p lookup returns only the existing public key.
SIGNING_PUBLIC_KEY="$("$GENERATE_KEYS" --account "$KEYCHAIN_ACCOUNT" -p)"
APP_PUBLIC_KEY="$(/usr/libexec/PlistBuddy -c 'Print :SUPublicEDKey' "$INFO_PLIST")"
[[ -n "$APP_PUBLIC_KEY" && "$SIGNING_PUBLIC_KEY" == "$APP_PUBLIC_KEY" ]] || {
    print -u2 "The app's Sparkle public key does not match the release signing account."
    exit 65
}
PUBLISHED_FEED="$REPOSITORY_ROOT/appcast.xml"
"$SIGN_UPDATE" --account "$KEYCHAIN_ACCOUNT" --verify "$PUBLISHED_FEED"

codesign --verify --deep --strict --verbose=2 "$APP_PATH"
SIGNED_ENTITLEMENTS="$(codesign -d --entitlements - "$APP_PATH" 2>&1)"
SIGNED_PRINTING_ENTITLEMENT="$(
    print -r -- "$SIGNED_ENTITLEMENTS" |
        grep -A2 -F '[Key] com.apple.security.print' || true
)"
[[ "$SIGNED_PRINTING_ENTITLEMENT" == *"[Bool] true"* ]] || {
    print -u2 "The signed release is missing the App Sandbox printing entitlement."
    exit 65
}
CODESIGN_DETAILS="$(codesign -dv --verbose=4 "$APP_PATH" 2>&1)"
[[ "$CODESIGN_DETAILS" == *"Authority=Developer ID Application:"* ]] || {
    print -u2 "The app is not signed with a Developer ID Application certificate."
    exit 65
}
xcrun stapler validate "$APP_PATH"
spctl --assess --type execute --verbose=2 "$APP_PATH"

APP_ARCHS="$(lipo -archs "$APP_PATH/Contents/MacOS/LighTxt")"
[[ "$APP_ARCHS" == *arm64* && "$APP_ARCHS" == *x86_64* ]] || {
    print -u2 "The release must contain both arm64 and x86_64: $APP_ARCHS"
    exit 65
}

DUCKDB_LIBRARY="$APP_PATH/Contents/Frameworks/libduckdb.dylib"
DUCKDB_LICENSE="$APP_PATH/Contents/Resources/DuckDB-LICENSE.txt"
DUCKDB_LICENSE_DIRECTORY="$APP_PATH/Contents/Resources/DuckDB-Licenses"
THIRD_PARTY_NOTICES="$APP_PATH/Contents/Resources/ThirdPartyNotices.txt"
[[ -f "$DUCKDB_LIBRARY" ]] || { print -u2 "The DuckDB runtime is missing from the app."; exit 65; }
[[ -f "$DUCKDB_LICENSE" ]] || { print -u2 "The DuckDB license is missing from the app."; exit 65; }
[[ -f "$DUCKDB_LICENSE_DIRECTORY/LICENSE" ]] || {
    print -u2 "The DuckDB dependency license tree is missing from the app."
    exit 65
}
[[ -f "$THIRD_PARTY_NOTICES" ]] || { print -u2 "Third-party notices are missing from the app."; exit 65; }
/usr/bin/cmp -s "$DUCKDB_LICENSE" "$DUCKDB_LICENSE_DIRECTORY/LICENSE" || {
    print -u2 "The bundled DuckDB license copies do not match."
    exit 65
}
DUCKDB_LICENSE_SHA256="$(shasum -a 256 "$DUCKDB_LICENSE" | awk '{print $1}')"
[[ "$DUCKDB_LICENSE_SHA256" == "$EXPECTED_DUCKDB_LICENSE_SHA256" ]] || {
    print -u2 "The bundled DuckDB license does not match the pinned v1.4.5 license."
    exit 65
}
DUCKDB_LICENSE_FILE_COUNT="$(find "$DUCKDB_LICENSE_DIRECTORY" -type f | wc -l | tr -d ' ')"
[[ "$DUCKDB_LICENSE_FILE_COUNT" -ge 32 ]] || {
    print -u2 "The DuckDB dependency license tree is incomplete ($DUCKDB_LICENSE_FILE_COUNT files)."
    exit 65
}
grep -Fq "DuckDB 1.4.5" "$THIRD_PARTY_NOTICES" || {
    print -u2 "Third-party notices do not identify DuckDB 1.4.5."
    exit 65
}

DUCKDB_ARCHS="$(lipo -archs "$DUCKDB_LIBRARY")"
[[ "$DUCKDB_ARCHS" == *arm64* && "$DUCKDB_ARCHS" == *x86_64* ]] || {
    print -u2 "DuckDB must contain both arm64 and x86_64: $DUCKDB_ARCHS"
    exit 65
}
[[ "$(print -r -- "$DUCKDB_ARCHS" | wc -w | tr -d ' ')" == "2" ]] || {
    print -u2 "DuckDB contains unexpected architectures: $DUCKDB_ARCHS"
    exit 65
}
[[ "$(otool -D "$DUCKDB_LIBRARY" | tail -n 1 | xargs)" == "@rpath/libduckdb.dylib" ]] || {
    print -u2 "DuckDB has an unexpected install name."
    exit 65
}
for architecture in arm64 x86_64; do
    dependency_count=0
    while IFS= read -r dependency; do
        dependency_count=$((dependency_count + 1))
        case "$dependency" in
            "@rpath/libduckdb.dylib"|"/usr/lib/libc++.1.dylib"|"/usr/lib/libSystem.B.dylib") ;;
            *) print -u2 "DuckDB has an unexpected $architecture dependency: $dependency"; exit 65 ;;
        esac
    done < <(otool -arch "$architecture" -L "$DUCKDB_LIBRARY" | tail -n +2 | awk '{print $1}')
    [[ "$dependency_count" == "3" ]] || {
        print -u2 "DuckDB $architecture has $dependency_count dynamic dependencies; expected 3."
        exit 65
    }
done

codesign --verify --strict --verbose=2 "$DUCKDB_LIBRARY"
DUCKDB_CODESIGN_DETAILS="$(codesign -dv --verbose=4 "$DUCKDB_LIBRARY" 2>&1)"
[[ "$DUCKDB_CODESIGN_DETAILS" == *"Timestamp="* ]] || {
    print -u2 "DuckDB does not have the trusted timestamp required for a Developer ID release."
    exit 65
}
APP_TEAM="$(print -r -- "$CODESIGN_DETAILS" | awk -F= '/^TeamIdentifier=/{print $2; exit}')"
DUCKDB_TEAM="$(print -r -- "$DUCKDB_CODESIGN_DETAILS" | awk -F= '/^TeamIdentifier=/{print $2; exit}')"
[[ -n "$APP_TEAM" && "$DUCKDB_TEAM" == "$APP_TEAM" ]] || {
    print -u2 "DuckDB is not signed by the same team as the app."
    exit 65
}

VERIFY_DIRECTORY="$(mktemp -d "${TMPDIR:-/tmp}/lightxt-duckdb-verify.XXXXXX")"
trap '/bin/rm -rf "$VERIFY_DIRECTORY"' EXIT
DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}" \
    xcrun clang -O2 "$REPOSITORY_ROOT/Scripts/verify_duckdb_runtime.c" \
    -o "$VERIFY_DIRECTORY/verify-duckdb-runtime"
"$VERIFY_DIRECTORY/verify-duckdb-runtime" "$DUCKDB_LIBRARY" "$EXPECTED_DUCKDB_VERSION" >/dev/null

SHIPPED_DUCKDB_DEVELOPMENT_FILE="$(find "$APP_PATH" -type f \
    \( -name 'libduckdb*.zip' -o -name duckdb.h -o -name duckdb.hpp \) -print -quit)"
[[ -z "$SHIPPED_DUCKDB_DEVELOPMENT_FILE" ]] || {
    print -u2 "The app ships a DuckDB archive/header: $SHIPPED_DUCKDB_DEVELOPMENT_FILE"
    exit 65
}

[[ "$(/usr/libexec/PlistBuddy -c 'Print :SUFeedURL' "$INFO_PLIST")" == \
    "https://raw.githubusercontent.com/$REPOSITORY/main/appcast.xml" ]] || {
    print -u2 "The release contains an unexpected Sparkle feed URL."
    exit 65
}
[[ "$(/usr/libexec/PlistBuddy -c 'Print :SURequireSignedFeed' "$INFO_PLIST")" == "true" ]] || {
    print -u2 "The release does not require a signed appcast."
    exit 65
}

SPARKLE_PLIST="$APP_PATH/Contents/Frameworks/Sparkle.framework/Resources/Info.plist"
[[ -f "$SPARKLE_PLIST" ]] || { print -u2 "Sparkle.framework is missing from the app."; exit 65; }
SPARKLE_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$SPARKLE_PLIST")"
[[ "$SPARKLE_VERSION" == "2.9.6" ]] || {
    print -u2 "Expected Sparkle 2.9.6, found $SPARKLE_VERSION."
    exit 65
}

ARCHIVE_NAME="LighTxt-$SHORT_VERSION-macOS-universal.zip"
ARCHIVE_PATH="$OUTPUT_DIR/$ARCHIVE_NAME"
NOTES_PATH="$OUTPUT_DIR/${ARCHIVE_NAME:r}.md"
DOWNLOAD_PREFIX="https://github.com/$REPOSITORY/releases/download/v$SHORT_VERSION/"
GENERATED_FEED="$OUTPUT_DIR/appcast.xml"

ditto -c -k --sequesterRsrc --keepParent "$APP_PATH" "$ARCHIVE_PATH"
cp "$RELEASE_NOTES_PATH" "$NOTES_PATH"
cp "$PUBLISHED_FEED" "$GENERATED_FEED"

"$GENERATE_APPCAST" \
    --account "$KEYCHAIN_ACCOUNT" \
    --download-url-prefix "$DOWNLOAD_PREFIX" \
    --link "https://github.com/$REPOSITORY" \
    --embed-release-notes \
    --maximum-versions 0 \
    --maximum-deltas 0 \
    "$OUTPUT_DIR"

"$SIGN_UPDATE" --account "$KEYCHAIN_ACCOUNT" --verify "$GENERATED_FEED"
MINIMUM_SYSTEM="$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' "$INFO_PLIST")"
ARCHIVE_SIGNATURE="$(/usr/bin/python3 - "$PUBLISHED_FEED" "$GENERATED_FEED" \
    "$SHORT_VERSION" "$BUILD_VERSION" "$MINIMUM_SYSTEM" "$DOWNLOAD_PREFIX$ARCHIVE_NAME" "$ARCHIVE_PATH" <<'PY'
import os
import sys
import xml.etree.ElementTree as ET

published, generated, version, build, minimum_system, url, archive = sys.argv[1:]
sparkle = "{http://www.andymatuschak.org/xml-namespaces/sparkle}"
previous = ET.parse(published).findall("./channel/item")
items = ET.parse(generated).findall("./channel/item")
if len(items) != len(previous) + 1:
    sys.exit("Expected exactly one new release in the generated appcast.")

def canonical_item(item):
    return ET.canonicalize(ET.tostring(item, encoding="unicode"))

if any(canonical_item(old) != canonical_item(new) for old, new in zip(previous, items[1:])):
    sys.exit("The generated appcast changed a previously published item.")
for item in previous:
    if item.findtext(sparkle + "version") == build or any(el.get("url") == url for el in item.findall("enclosure")):
        sys.exit("This build or archive URL is already published.")

latest = items[0]
for key, expected in (("shortVersionString", version), ("version", build), ("minimumSystemVersion", minimum_system)):
    if latest.findtext(sparkle + key) != expected:
        sys.exit(f"The newest appcast item has an unexpected {key} (expected {expected}).")

enclosures = latest.findall("enclosure")
if len(enclosures) != 1 or enclosures[0].get("url") != url:
    sys.exit(f"The newest appcast item must enclose {url}.")
enclosure = enclosures[0]
if enclosure.get("length") != str(os.path.getsize(archive)):
    sys.exit("The archive length in the appcast differs from the release ZIP.")
signature = enclosure.get(sparkle + "edSignature")
if not signature:
    sys.exit("The newest appcast item is missing its archive signature.")
print(signature)
PY
)"
"$SIGN_UPDATE" --account "$KEYCHAIN_ACCOUNT" --verify "$ARCHIVE_PATH" "$ARCHIVE_SIGNATURE"

print "Prepared Sparkle release v$SHORT_VERSION (build $BUILD_VERSION)"
print "Sparkle framework: $SPARKLE_VERSION"
print "DuckDB runtime: $EXPECTED_DUCKDB_VERSION ($DUCKDB_ARCHS)"
print "Update archive: $ARCHIVE_PATH"
print "Signed appcast: $OUTPUT_DIR/appcast.xml"
shasum -a 256 "$ARCHIVE_PATH"
