#!/bin/zsh

set -euo pipefail

readonly REPOSITORY="jdimaso/lightxt"
readonly KEYCHAIN_ACCOUNT="jdimaso-lighttxt"
readonly EXPECTED_BUNDLE_ID="app.lightext.LighTxt"
readonly PROJECT_NAME="LighTxt.xcodeproj"
readonly SCHEME_NAME="LighTxt"

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

# This lookup proves the signing identity exists without exporting or printing
# the private key. Sparkle reads it directly from the login Keychain.
"$GENERATE_KEYS" --account "$KEYCHAIN_ACCOUNT" -p >/dev/null

codesign --verify --deep --strict --verbose=2 "$APP_PATH"
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

ditto -c -k --sequesterRsrc --keepParent "$APP_PATH" "$ARCHIVE_PATH"
cp "$RELEASE_NOTES_PATH" "$NOTES_PATH"
cp "$REPOSITORY_ROOT/appcast.xml" "$OUTPUT_DIR/appcast.xml"

"$GENERATE_APPCAST" \
    --account "$KEYCHAIN_ACCOUNT" \
    --download-url-prefix "https://github.com/$REPOSITORY/releases/download/v$SHORT_VERSION/" \
    --link "https://github.com/$REPOSITORY" \
    --embed-release-notes \
    --maximum-versions 0 \
    --maximum-deltas 0 \
    "$OUTPUT_DIR"

"$SIGN_UPDATE" --account "$KEYCHAIN_ACCOUNT" --verify "$OUTPUT_DIR/appcast.xml"
xmllint --noout "$OUTPUT_DIR/appcast.xml"
grep -q "sparkle:edSignature=" "$OUTPUT_DIR/appcast.xml"
grep -q "sparkle-signatures:" "$OUTPUT_DIR/appcast.xml"

print "Prepared Sparkle release v$SHORT_VERSION (build $BUILD_VERSION)"
print "Sparkle framework: $SPARKLE_VERSION"
print "Update archive: $ARCHIVE_PATH"
print "Signed appcast: $OUTPUT_DIR/appcast.xml"
shasum -a 256 "$ARCHIVE_PATH"
