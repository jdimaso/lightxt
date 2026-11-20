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
   compares the latter as its machine-readable update version. Write the
   user-facing notes in `Docs/ReleaseNotes/VERSION.md`. Run the regression
   suite and commit the tested release source, including new source files,
   version settings, and notes. Record the full commit with `git rev-parse HEAD`.
2. On the release Mac, unlock the login Keychain and sign in to the release
   team's account in Xcode. In Finder, double-click
   `Scripts/prepare_signed_release.command`, or run it in Terminal.

   ```sh
   ./Scripts/prepare_signed_release.command
   ```

   The command snapshots the working sources in a private directory under
   `/private/tmp`, builds a universal Release archive, submits the Developer ID
   export to Apple for notarization, and exports the ticketed app. Allow any
   Keychain requests for the release credentials. To use an existing
   `notarytool` Keychain profile, start the command with
   `LIGHTXT_NOTARY_PROFILE="your-profile-name" ./Scripts/prepare_signed_release.command`.
   If interrupted, run the printed `--resume` command. It uses the same source
   snapshot and notarization method. Start a new run for source changes.

3. Find the verified ZIP, signed appcast, and release notes in
   `SparkleUpdates/vVERSION/`. The command prints the ZIP's SHA-256 and the
   path to the notarized app. Keep the temporary workspace until QA is complete.
   If you already have a notarized, stapled universal Developer ID export,
   you can run the same packaging checks directly with
   `./Scripts/prepare_sparkle_release.sh /path/to/LighTxt.app Docs/ReleaseNotes/VERSION.md`.
   The signing tools use the Sparkle key in Keychain. Both commands leave the
   repository's production feed untouched.

4. Inspect the ZIP and signed appcast. Tag the exact tested source commit
   recorded in step 1, then push that tag before creating a draft GitHub
   Release. Replace `VERSION` and `TESTED_COMMIT` below. If the tag already
   exists, confirm that it resolves to the same commit locally and on GitHub.
   Upload the immutable ZIP (and optional DMG) to the draft.

   ```sh
   git tag -a "vVERSION" TESTED_COMMIT -m "LighTxt VERSION"
   git push origin "refs/tags/vVERSION"
   gh release create "vVERSION" \
     "SparkleUpdates/vVERSION/LighTxt-VERSION-macOS-universal.zip" \
     --repo jdimaso/lightxt \
     --title "LighTxt VERSION" \
     --notes-file "Docs/ReleaseNotes/VERSION.md" \
     --verify-tag \
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
