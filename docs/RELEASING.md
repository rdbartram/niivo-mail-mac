# Releasing niivo mail

Releases are GitHub Releases on this repository. Each release carries two files:

- `niivo-mail-<version>.zip`: the Developer ID-signed, notarised and stapled app, zipped with `ditto`.
- `appcast.xml`: the Sparkle feed. It has a single item, the zip, with its EdDSA signature.

The app's `SUFeedURL` is `https://github.com/rdbartram/niivo-mail-mac/releases/latest/download/appcast.xml`. GitHub
always resolves that to the newest release's `appcast.xml`, so publishing a release is all it takes to ship an update.
Sparkle installs an update only when both of these hold:

1. The zip's EdDSA signature verifies against `SUPublicEDKey` in the running app.
2. The new app's code signature matches the installed app's: same Developer ID team.

## One-time setup

1. **Generate the Sparkle signing key.** The tools come with the SwiftPM artifact:

   ```bash
   swift package resolve
   .build/artifacts/sparkle/Sparkle/bin/generate_keys
   ```

   The private key goes into your **login keychain** (service `https://sparkle-project.org`, account `ed25519`), and
   the tool prints the public key. Running it again prints the existing key and doesn't replace it. Use one key for
   the app's whole life. If you lose the private key, you can't ship updates to existing installs.

2. **Put the public key in `build.env`.** That file is git-ignored and also holds `NIIVO_CLIENT_ID` /
   `NIIVO_TENANT_ID`:

   ```bash
   SPARKLE_PUBLIC_KEY=<the base64 key generate_keys printed>
   SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)"
   TEAM_ID=TEAMID
   NOTARY_PROFILE=<notarytool keychain profile>     # xcrun notarytool store-credentials <name> ...
   ```

   The public key isn't a secret. It's kept out of the scripts so a fork builds against its own key and feed. Forks
   also set `SPARKLE_FEED_URL`.

3. **Back up the private key** to your password manager, then delete the export file:

   ```bash
   .build/artifacts/sparkle/Sparkle/bin/generate_keys -x sparkle-private-key.txt
   # store the file's contents in 1Password, then:
   rm -P sparkle-private-key.txt
   ```

   To restore it on another Mac, run `generate_keys -f <file>`. Never commit the key, never paste it into CI logs, and
   never pass it with `-s`.

## Cutting a release

From a clean `main` that has been pushed:

```bash
VERSION=0.2.0 ./scripts/release.sh --dry-run     # build, sign, notarise, zip, sign_update, appcast; no publish
VERSION=0.2.0 ./scripts/release.sh               # same, then gh release create v0.2.0
```

`scripts/release.sh` does the following, in order:

1. Refuses to run if the working tree is dirty. For a real release it also refuses if `HEAD` isn't on a remote branch
   or the tag already exists.
2. Checks that the keychain's Sparkle public key (`generate_keys -p`) equals `SPARKLE_PUBLIC_KEY`. A mismatch would
   ship an app whose updates every existing install rejects.
3. Runs `scripts/bundle.sh release` with `VERSION`, `BUILD_NUMBER`, `SIGN_IDENTITY`, `TEAM_ID` and `NOTARY_PROFILE`.
   That builds, strips, embeds and signs Sparkle inside-out (`Autoupdate`, `Updater.app`, then the framework), signs
   the app with hardened runtime and a timestamp, notarises, staples and runs `spctl --assess`.
4. Zips the app with `ditto -c -k --sequesterRsrc --keepParent`.
5. Runs `sign_update -p` on the zip. The private key is read from the keychain and never printed. The script then
   verifies the signature.
6. Writes `appcast.xml`, which records `sparkle:version` = `CFBundleVersion`, the short version, the minimum macOS,
   the length and the signature.
7. Runs `gh release create v$VERSION` at the built commit and marks it as latest. It uploads the zip and
   `appcast.xml`. Notes come from `RELEASE_NOTES=<file.md>` if given, otherwise from `--generate-notes`.

Output goes to `build/release/<version>/`, or to `RELEASE_DIR` if you set it.

### Versions

- `VERSION` becomes `CFBundleShortVersionString`, the version people see.
- `BUILD_NUMBER` becomes `CFBundleVersion`. **Sparkle compares this one**, so it must strictly increase from one
  release to the next. It defaults to `git rev-list --count HEAD`, which only goes up on a linear `main`. Set it
  explicitly if you ever release from another branch or rewrite history.

### What a release does not include

`release.sh` sets `BUNDLE_MIP=0` unless you override it. Redistributing the MIP SDK requires Microsoft's IPIA, so
read `docs/MIP.md` before you change that.

## Existing installs

Builds from before Sparkle have no updater. Their users have to install the first Sparkle-enabled release by hand:
download the zip from Releases and replace the app in `/Applications`. Every later release arrives through
**Check for Updates…** or the automatic check.

## Managed Macs

These keys go in the app's preference domain, through an MDM configuration profile:

| Key | Effect |
|---|---|
| `disableUpdates` (Bool) | `true` turns the updater off: no checks, no menu item. Settings says updates are managed by your organisation |
| `SUEnableAutomaticChecks` (Bool) | Forced: Sparkle uses it and the Settings toggle is locked |

## Not verified yet

- Notarisation of the re-signed Sparkle helpers (`Autoupdate`, `Updater.app`) hasn't been tested end to end. The
  signing order follows Sparkle's documentation, but only a real Developer ID run with `notarytool` proves it. On the
  first release, run `xcrun notarytool log <id>` if the submission is rejected.
- Sparkle's XPC services are removed from the bundle because the app isn't sandboxed. Sparkle's sandboxing guide
  allows this. If the app is ever sandboxed, restore them and sign `Installer.xpc`, then `Downloader.xpc` with
  `--preserve-metadata=entitlements`, before `Autoupdate`. Also set `SUEnableInstallerLauncherService`.
