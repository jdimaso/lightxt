#!/bin/zsh

set -euo pipefail
# mktemp keeps the working directory private. Distributed app files need normal read permissions.
umask 022
command_path="${0:A}"

usage() {
    print -r -- "Usage: ${command_path:t} [--resume /private/tmp/LighTxt-release.XXXXXX]"
    print -r -- "Uses the signed-in Xcode account, or an existing LIGHTXT_NOTARY_PROFILE in Keychain."
}

fail() { print -ru2 -- "$*"; exit 1; }
check_sparkle_key() {
    local public_key
    public_key="$("$sparkle/generate_keys" --account jdimaso-lighttxt -p)" ||
        fail "Unlock the release login Keychain and resume to access the existing Sparkle key."
    [[ -n "$public_key" && "$public_key" == "$(/usr/libexec/PlistBuddy -c 'Print :SUPublicEDKey' "$1")" ]] ||
        fail "The release Keychain's Sparkle public key differs from the app."
}
repo="${command_path:h:h}"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"

if [[ $# == 1 && "$1" == --help ]]; then
    usage
    exit 0
elif [[ $# == 0 ]]; then
    work="$(mktemp -d /private/tmp/LighTxt-release.XXXXXX)"
    print -r -- "$repo" > "$work/repository"
    print -r -- "${LIGHTXT_NOTARY_PROFILE:-}" > "$work/notary-profile"
elif [[ $# == 2 && "$1" == --resume ]]; then
    work="${2:A}"
    [[ "${work:h}" == /private/tmp && "${work:t}" == LighTxt-release.* &&
       -O "$work" && -f "$work/repository" && "$(<"$work/repository")" == "$repo" ]] ||
        fail "Choose a workspace created by this command for this repository."
else
    usage >&2
    exit 64
fi

print -r -- "Working directory: $work"
print -r -- "To resume: ${(q)command_path} --resume ${(q)work}"
zmodload zsh/system
zsystem flock -t 0 "$work/repository" || fail "This release workspace is already in use."
profile="$(<"$work/notary-profile")"
archive="$work/LighTxt.xcarchive"
packages="$work/SourcePackages"
if [[ ! -d "$packages" && -x "$repo/.sparkle-tools/artifacts/sparkle/Sparkle/bin/generate_keys" ]]; then
    packages="$repo/.sparkle-tools"
fi
sparkle="$packages/artifacts/sparkle/Sparkle/bin"
if [[ ! -f "$work/archived" ]]; then
    if [[ -x "$sparkle/generate_keys" ]]; then
        check_sparkle_key "$repo/LighTxt/Info.plist"
    fi
    # ditto strips FinderInfo and resource forks inherited from synced source directories.
    if [[ ! -d "$work/source" ]]; then
        snapshot="$(mktemp -d "$work/source.XXXXXX")"
        for input in LighTxt LighTxt.xcodeproj ThirdParty Scripts; do
            /usr/bin/ditto --norsrc --noextattr --noacl "$repo/$input" "$snapshot/$input"
        done
        mv "$snapshot" "$work/source"
    fi
    xcrun xcodebuild -project "$work/source/LighTxt.xcodeproj" -scheme LighTxt \
        -configuration Release -destination 'generic/platform=macOS' \
        -archivePath "$archive" -derivedDataPath "$work/DerivedData" \
        -clonedSourcePackagesDirPath "$packages" -onlyUsePackageVersionsFromResolvedFile -skipPackageUpdates \
        -allowProvisioningUpdates 'ARCHS=arm64 x86_64' ONLY_ACTIVE_ARCH=NO archive
    touch "$work/archived"
fi

info="$archive/Products/Applications/LighTxt.app/Contents/Info.plist"
version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$info")"
[[ "$version" =~ '^[0-9]+([.][0-9]+)*$' ]] || fail "Unexpected marketing version: $version"
notes="$repo/Docs/ReleaseNotes/$version.md"
[[ -s "$notes" ]] || fail "Add release notes at $notes and resume."
updates="$repo/SparkleUpdates"
output="$updates/v$version"
[[ ! -e "$output" && ! -L "$output" ]] || fail "Release output already exists: $output"
check_sparkle_key "$info"

app="$work/export/LighTxt.app"
if [[ ! -f "$work/notarized" ]]; then
    export_plist="$work/ExportOptions.plist"
    target=upload
    [[ -z "$profile" ]] || target=export
    plutil -create xml1 "$export_plist"
    plutil -insert method -string developer-id "$export_plist"
    plutil -insert destination -string "$target" "$export_plist"
    plutil -insert signingStyle -string automatic "$export_plist"
    plutil -insert manageAppVersionAndBuildNumber -bool false "$export_plist"

    if [[ ! -f "$work/exported" && ! -d "$app" ]]; then
        export_dir="$(mktemp -d "$work/developer-id.XXXXXX")"
        xcrun xcodebuild -exportArchive -archivePath "$archive" -exportPath "$export_dir" \
            -exportOptionsPlist "$export_plist" -allowProvisioningUpdates
        if [[ -n "$profile" ]]; then
            mv "$export_dir" "$work/export"
        fi
        touch "$work/exported"
    fi

    if [[ -z "$profile" && ! -d "$app" ]]; then
        # Apple's ticket may still be processing when the upload finishes.
        while true; do
            export_dir="$(mktemp -d "$work/notarized.XXXXXX")"
            if xcrun xcodebuild -exportNotarizedApp -archivePath "$archive" -exportPath "$export_dir" \
                    2>&1 | tee "$work/export-notarized.log"; then
                mv "$export_dir" "$work/export"
                break
            fi
            if ! /usr/bin/grep -Eiq \
                    -e 'archive ("[^"]+" )?(is (processing and not ready for distribution|pending|in progress|still processing|not yet notarized)|has not (yet )?been notarized)' \
                    -e 'notari[sz]ation( status)?[[:space:]:]+(is )?(pending|in progress|still processing)' \
                    "$work/export-notarized.log"; then
                fail "Xcode could not export the notarized app. Review $work/export-notarized.log and the archive in Xcode Organizer."
            fi
            rmdir "$export_dir" 2>/dev/null || true
            print -r -- "Apple is processing the archive. Checking again in 60 seconds. Press Control-C to pause."
            sleep 60
        done
    elif [[ -n "$profile" ]]; then
        if [[ ! -s "$work/submission.plist" ]]; then
            ditto -c -k --sequesterRsrc --keepParent "$app" "$work/notary.zip"
            xcrun notarytool submit "$work/notary.zip" --keychain-profile "$profile" \
                --output-format plist > "$work/submission.pending"
            mv "$work/submission.pending" "$work/submission.plist"
        fi
        submission="$(plutil -extract id raw "$work/submission.plist")"
        print -r -- "Waiting for Apple notarization $submission"
        xcrun notarytool wait "$submission" --keychain-profile "$profile" \
            --output-format plist > "$work/result.plist"
        result="$(plutil -extract status raw "$work/result.plist")"
        [[ "$result" == Accepted ]] || fail "Notarization $submission ended with status $result."
        xcrun stapler staple "$app"
    fi
    xcrun stapler validate "$app"
    touch "$work/notarized"
fi

mkdir -p "$updates"
staging="$(mktemp -d "$updates/.pending.XXXXXX")"
trap '/bin/rm -rf "$staging"' EXIT
SPARKLE_BIN_OVERRIDE="$sparkle" \
    "$repo/Scripts/prepare_sparkle_release.sh" "$app" "$notes" "$staging/v$version"
/bin/mv -n "$staging/v$version" "$updates/"
[[ ! -d "$staging/v$version" ]] || fail "Another release already occupies $output."
print -r -- "Signed ZIP, release notes, and appcast: $output"
print -r -- "Notarized app: $app"
