#!/usr/bin/env bash
# Cut a release: Developer ID build + notarise (scripts/bundle.sh) → zip → Sparkle EdDSA signature → appcast.xml →
# GitHub release with both files. See docs/RELEASING.md.
#
#   VERSION=0.2.0 ./scripts/release.sh            # publish v0.2.0
#   VERSION=0.2.0 ./scripts/release.sh --dry-run  # everything except `gh release create`
#
# Needs (environment or build.env): SIGN_IDENTITY, TEAM_ID, NOTARY_PROFILE, PROFILE, SPARKLE_PUBLIC_KEY.
# PROFILE is the Developer ID provisioning profile. Without it macOS kills the app at launch (SIGKILL, exit 137):
# keychain-access-groups / application-identifier are restricted entitlements, and notarisation does not catch it.
# Optional: BUILD_NUMBER (default: commit count of HEAD), SPARKLE_FEED_URL, GH_REPO (default: taken from the feed URL),
#           SPARKLE_ACCOUNT (keychain account of the EdDSA key, default ed25519), RELEASE_NOTES (markdown file),
#           RELEASE_DIR (output directory, default build/release/$VERSION).
# The Sparkle private key never leaves the keychain: sign_update reads it there; this script never prints or exports it.
# --dry-run without SIGN_IDENTITY builds ad-hoc and, if the keychain has no Sparkle key yet, uses a placeholder
# signature, so the zip/appcast steps can be checked before the one-time setup.
set -euo pipefail
cd "$(dirname "$0")/.."

DRY_RUN=0
for a in "$@"; do
  case "$a" in
    --dry-run) DRY_RUN=1 ;;
    -h|--help) sed -n 2,16p "$0"; exit 0 ;;
    *) echo "unknown argument: $a" >&2; exit 2 ;;
  esac
done
die() { echo "release: $*" >&2; exit 1; }

# 1. Clean, pushed tree: the release must be reproducible from the tag.
[[ -z "$(git status --porcelain)" ]] || die "working tree is dirty; commit or stash first"
HEAD_SHA="$(git rev-parse HEAD)"

# Same env-over-build.env rule as bundle.sh (which re-reads build.env itself; we export what it needs).
_ENV_VARS=(SIGN_IDENTITY TEAM_ID NOTARY_PROFILE PROFILE SPARKLE_PUBLIC_KEY SPARKLE_FEED_URL VERSION BUILD_NUMBER GH_REPO SPARKLE_ACCOUNT)
_env_saved=()
for v in "${_ENV_VARS[@]}"; do _env_saved+=("${!v-__unset__}"); done
if [[ -f build.env ]]; then set -a; source build.env; set +a; fi
for i in "${!_ENV_VARS[@]}"; do
  if [[ "${_env_saved[$i]}" != __unset__ ]]; then printf -v "${_ENV_VARS[$i]}" '%s' "${_env_saved[$i]}"; fi
done

VERSION="${VERSION:-}"
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+([-.][0-9A-Za-z.]+)?$ ]] || die "set VERSION=x.y.z (got '${VERSION}')"
BUILD_NUMBER="${BUILD_NUMBER:-$(git rev-list --count HEAD)}"
[[ "$BUILD_NUMBER" =~ ^[0-9]+$ ]] || die "BUILD_NUMBER must be an integer"
SPARKLE_FEED_URL="${SPARKLE_FEED_URL:-https://github.com/rdbartram/niivo-mail-mac/releases/latest/download/appcast.xml}"
SPARKLE_ACCOUNT="${SPARKLE_ACCOUNT:-ed25519}"
SPARKLE_PUBLIC_KEY="${SPARKLE_PUBLIC_KEY:-}"
if [[ -z "${GH_REPO:-}" ]]; then
  [[ "$SPARKLE_FEED_URL" =~ ^https://github\.com/([^/]+/[^/]+)/releases/latest/download/appcast\.xml$ ]] \
    || die "SPARKLE_FEED_URL isn't a GitHub 'latest release' URL; set GH_REPO=owner/repo"
  GH_REPO="${BASH_REMATCH[1]}"
fi
TAG="v$VERSION"
ZIP_NAME="niivo-mail-$VERSION.zip"
DOWNLOAD_URL="https://github.com/$GH_REPO/releases/download/$TAG/$ZIP_NAME"

if [[ $DRY_RUN == 0 ]]; then
  for v in SIGN_IDENTITY TEAM_ID NOTARY_PROFILE PROFILE SPARKLE_PUBLIC_KEY; do
    [[ -n "${!v:-}" ]] || die "$v is not set (environment or build.env)"
  done
  [[ -f "$PROFILE" ]] || die "PROFILE $PROFILE not found"
  command -v gh >/dev/null || die "gh (GitHub CLI) not found"
  git branch -r --contains "$HEAD_SHA" | grep -q . || die "HEAD $HEAD_SHA is not on any remote branch; push first"
  if gh release view "$TAG" --repo "$GH_REPO" >/dev/null 2>&1; then die "release $TAG already exists on $GH_REPO"; fi
fi
[[ -n "$SPARKLE_PUBLIC_KEY" ]] || echo "release: warning: SPARKLE_PUBLIC_KEY empty — this build would ship with updates off" >&2

# Sparkle tools come with the SwiftPM artifact (Sparkle-for-Swift-Package-Manager.zip → bin/).
swift package resolve >/dev/null
SPARKLE_BIN="$(find .build/artifacts -type d -path '*sparkle/Sparkle/bin' -maxdepth 4 | head -1)"
[[ -x "$SPARKLE_BIN/sign_update" ]] || die "Sparkle's sign_update not found under .build/artifacts"

# 2. The keychain key must be the one the shipped app trusts, or every update would be rejected by Sparkle.
#    `generate_keys -p` only looks up and prints the PUBLIC key; it never creates or exports anything.
#    In a dry run, a `security` probe first checks the item exists (attributes only, no secret, no prompt; service and
#    account as in Sparkle's generate_keys/main.swift), so a Mac without a key doesn't stall. A real release always
#    asks generate_keys, which may prompt once for keychain access.
HAVE_KEY=0
PROBE_OK=1
if [[ $DRY_RUN == 1 ]] && ! security find-generic-password -s "https://sparkle-project.org" -a "$SPARKLE_ACCOUNT" >/dev/null 2>&1; then
  PROBE_OK=0
fi
if [[ $PROBE_OK == 1 ]] \
   && KEYCHAIN_PUB="$("$SPARKLE_BIN/generate_keys" --account "$SPARKLE_ACCOUNT" -p 2>/dev/null)" && [[ -n "$KEYCHAIN_PUB" ]]; then
  HAVE_KEY=1
  if [[ -n "$SPARKLE_PUBLIC_KEY" && "$KEYCHAIN_PUB" != "$SPARKLE_PUBLIC_KEY" ]]; then
    die "SPARKLE_PUBLIC_KEY doesn't match the keychain's Sparkle key (account $SPARKLE_ACCOUNT)"
  fi
elif [[ $DRY_RUN == 0 ]]; then
  die "no Sparkle key in the keychain (account $SPARKLE_ACCOUNT); see docs/RELEASING.md, one-time setup"
fi

# 3. Build, sign, notarise, staple (bundle.sh does all of it when SIGN_IDENTITY/TEAM_ID/NOTARY_PROFILE are set).
OUT="${RELEASE_DIR:-build/release/$VERSION}"
rm -rf "$OUT"; mkdir -p "$OUT"
APP="$OUT/niivo mail.app"
# Public releases leave the MIP SDK out unless asked: redistributing it needs Microsoft's IPIA (docs/MIP.md).
BUNDLE_MIP="${BUNDLE_MIP:-0}"
export APP VERSION BUILD_NUMBER SPARKLE_PUBLIC_KEY SPARKLE_FEED_URL BUNDLE_MIP
if [[ $DRY_RUN == 1 && -z "${SIGN_IDENTITY:-}" ]]; then
  echo "release: dry run without SIGN_IDENTITY — ad-hoc build, no notarisation"
  SIGN_IDENTITY="" TEAM_ID="" NOTARY_PROFILE="" ./scripts/bundle.sh release
else
  export SIGN_IDENTITY TEAM_ID NOTARY_PROFILE="${NOTARY_PROFILE:-}" PROFILE="${PROFILE:-}"
  ./scripts/bundle.sh release
  # Notarised + stapled → Gatekeeper accepts it (bundle.sh already ran spctl; this is the release gate).
  if [[ -n "$NOTARY_PROFILE" ]]; then xcrun stapler validate "$APP"; fi
  # Launch gate: restricted entitlements need an embedded profile that grants this app identifier, or the app is
  # SIGKILLed before main(). spctl and notarisation both pass such a build (v0.1.0 shipped like that).
  ENTS="$(codesign -d --entitlements - --xml "$APP" 2>/dev/null)"
  if grep -q -e keychain-access-groups -e application-identifier <<<"$ENTS"; then
    EMB="$APP/Contents/embedded.provisionprofile"
    [[ -f "$EMB" ]] || die "app has restricted entitlements but no embedded.provisionprofile (set PROFILE)"
    APPID="$(plutil -extract 'com\.apple\.application-identifier' raw - <<<"$ENTS")"
    PAPPID="$(security cms -D -i "$EMB" | plutil -extract 'Entitlements.com\.apple\.application-identifier' raw -)"
    [[ "$PAPPID" == "$APPID" || "$PAPPID" == "${APPID%%.*}.*" ]] || die "profile grants $PAPPID, app is $APPID"
    PEXP="$(security cms -D -i "$EMB" | plutil -extract ExpirationDate raw -)"
    [[ "$(date -u +%Y-%m-%dT%H:%M:%SZ)" < "$PEXP" ]] || die "provisioning profile expired $PEXP"
    echo "release: launch gate ok (profile grants $PAPPID, expires $PEXP)"
  fi
fi

# 4. Archive exactly as Sparkle's publishing guide says (ditto keeps the framework symlinks and signatures valid).
ZIP="$OUT/$ZIP_NAME"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"
LENGTH="$(stat -f%z "$ZIP")"

# 5. EdDSA signature of the archive; -p prints only the signature (the private key stays in the keychain).
if [[ $HAVE_KEY == 1 ]]; then
  ED_SIG="$("$SPARKLE_BIN/sign_update" --account "$SPARKLE_ACCOUNT" -p "$ZIP")"
  "$SPARKLE_BIN/sign_update" --account "$SPARKLE_ACCOUNT" --verify "$ZIP" "$ED_SIG" >/dev/null \
    || die "sign_update could not verify its own signature"
else
  echo "release: dry run, no Sparkle key in the keychain — placeholder signature" >&2
  ED_SIG="DRY-RUN-PLACEHOLDER"
fi

# 6. appcast.xml with this one item. The feed URL always resolves to the latest release's appcast, and Sparkle
#    only needs the newest item (no delta updates), so older items aren't carried forward.
xml_escape() { sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g'; }
NOTES_HTML="<p>niivo mail $VERSION</p>"
if [[ -n "${RELEASE_NOTES:-}" ]]; then
  [[ -f "$RELEASE_NOTES" ]] || die "RELEASE_NOTES file not found: $RELEASE_NOTES"
  NOTES_HTML="<pre>$(xml_escape < "$RELEASE_NOTES")</pre>"
fi
MIN_OS="$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' "$APP/Contents/Info.plist")"
cat > "$OUT/appcast.xml" <<XML
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>niivo mail</title>
    <link>https://github.com/$GH_REPO/releases</link>
    <description>niivo mail for macOS updates</description>
    <language>en</language>
    <item>
      <title>$VERSION</title>
      <pubDate>$(LC_ALL=C date -u '+%a, %d %b %Y %H:%M:%S +0000')</pubDate>
      <sparkle:version>$BUILD_NUMBER</sparkle:version>
      <sparkle:shortVersionString>$VERSION</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>$MIN_OS</sparkle:minimumSystemVersion>
      <sparkle:fullReleaseNotesLink>https://github.com/$GH_REPO/releases/tag/$TAG</sparkle:fullReleaseNotesLink>
      <description><![CDATA[$NOTES_HTML]]></description>
      <enclosure url="$DOWNLOAD_URL" length="$LENGTH" type="application/octet-stream" sparkle:edSignature="$ED_SIG"/>
    </item>
  </channel>
</rss>
XML
if command -v xmllint >/dev/null; then xmllint --noout "$OUT/appcast.xml" || die "appcast.xml is not well-formed"; fi

echo "release: $TAG (build $BUILD_NUMBER) → $GH_REPO"
echo "  archive  $ZIP ($LENGTH bytes)"
echo "  appcast  $OUT/appcast.xml"
if [[ $DRY_RUN == 1 ]]; then
  echo "release: --dry-run, stopping before 'gh release create $TAG'"
  exit 0
fi

# 7. Publish. The tag is created at the exact commit that was built; the newest release becomes "latest", which is
#    what SUFeedURL (…/releases/latest/download/appcast.xml) points at.
NOTES_ARGS=(--generate-notes)
[[ -n "${RELEASE_NOTES:-}" ]] && NOTES_ARGS=(--notes-file "$RELEASE_NOTES")
gh release create "$TAG" "$ZIP" "$OUT/appcast.xml" --repo "$GH_REPO" --target "$HEAD_SHA" \
  --title "niivo mail $VERSION" --latest "${NOTES_ARGS[@]}"
echo "release: published $TAG"
