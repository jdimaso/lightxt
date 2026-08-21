# Automatic updates

LighTxt uses Sparkle 2.9.6 for updates outside the Mac App Store. The Xcode
project pins that exact stable version so a dependency change cannot silently
alter a release. The app checks the signed feed at:

`https://raw.githubusercontent.com/jdimaso/lightxt/main/appcast.xml`

The checked-in feed contains only immutable, publicly available releases. A new
item is promoted only after its signed ZIP is downloadable and an isolated
copy of the previous public version has completed an end-to-end update. A user
can run **LighTxt > Check for Updates…**, and Sparkle also checks once per day.
Automatic download and installation are enabled by default; the user can
change that choice in Sparkle's update UI.

## Security and sandboxing

- Update archives are signed with Sparkle EdDSA and must also contain a
  Developer ID-signed app.
- The feed itself is signed (`SURequireSignedFeed`) and archives are verified
  before extraction (`SUVerifyUpdateBeforeExtraction`).
- The public EdDSA key is expected in `LighTxt/Info.plist`.
- The private EdDSA key exists only in the login Keychain under Sparkle account
  `jdimaso-lighttxt`. It must never be pasted into a command, log, source file,
  GitHub secret, or repository. Do not export it into the project tree.
- Because LighTxt is sandboxed, Sparkle's installer and downloader XPC services
  are enabled. The app receives only Sparkle's two documented Mach lookup
  exceptions; LighTxt itself does not receive unrestricted network access.
- Archive and export with Xcode's Developer ID workflow. Xcode re-signs the
  embedded Sparkle helpers correctly during that workflow.

## Prepare a real release

1. Increase both `MARKETING_VERSION` and `CURRENT_PROJECT_VERSION`. Sparkle
   compares the latter as its machine-readable update version.
2. Create a universal Release archive in Xcode, export it with **Developer
   ID**, notarize the app, and staple the notarization ticket to the app.
3. Write Markdown release notes, then run:

   ```sh
   ./Scripts/prepare_sparkle_release.sh \
     /path/to/export/LighTxt.app \
     /path/to/release-notes.md
   ```

   The script refuses unsigned, unstapled, wrong-bundle, or wrong-Sparkle
   builds. It creates `SparkleUpdates/vVERSION/` (gitignored), packages the app
   with `ditto` so framework symlinks survive, signs the archive entry, embeds
   the release notes, signs the feed, verifies the feed, and prints a SHA-256.
   The signing tools read the private key directly from Keychain.

4. Inspect the ZIP and signed appcast. Create the GitHub Release as a draft and
   upload the immutable ZIP (and optional DMG), but do not publish it or change
   the production feed yet:

   ```sh
   gh release create "vVERSION" \
     "SparkleUpdates/vVERSION/LighTxt-VERSION-macOS-universal.zip" \
     --repo jdimaso/lightxt \
     --title "LighTxt VERSION" \
     --notes-file /path/to/release-notes.md \
     --draft
   ```

5. Before publishing the release or changing the production feed, expose a
   separately signed QA feed and archive at a temporary QA-only URL. Launch a
   fresh copy of the previous public version with that process-only feed
   override and complete one end-to-end install and relaunch. Verify that only
   the disposable copy changed.
6. Publish the GitHub Release as Latest. Verify that both public assets are
   downloadable and exactly match the signed/notarized local artifacts.
7. Only after the release assets are public and verified, promote the generated
   production feed and review the exact diff:

   ```sh
   cp "SparkleUpdates/vVERSION/appcast.xml" appcast.xml
   git diff -- appcast.xml
   git add appcast.xml
   git commit -m "Publish LighTxt VERSION update"
   git push
   ```

8. After promoting the signed feed, repeat the update from another fresh copy of
   the previous public version with no override. Keep every GitHub asset
   immutable after the feed is live; replacing it invalidates its EdDSA
   signature.

The user-facing DMG may be attached to the same GitHub Release, but Sparkle
uses the ZIP containing only `LighTxt.app`. Do not put the DMG layout helpers
or an Applications symlink in the Sparkle archive.

## Key checks and recovery

To print only the existing public key (never the private key), resolve the
package tools and run `generate_keys --account jdimaso-lighttxt -p`. If the
private key is lost, stop publishing and follow Sparkle's Developer ID key
rotation procedure; do not generate a replacement under the same feed without
planning the rotation.
