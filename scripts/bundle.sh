#!/usr/bin/env bash
# Assemble a real .app from the SwiftPM build (no Xcode needed).
# Needed because MSAL's redirect URI (msauth.<bundle-id>://auth) and Keychain access need a bundle identity.
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG="${1:-release}"
# Your own reverse-DNS bundle ID; it must match an App ID on your Apple team and the msauth redirect on your Entra app.
BUNDLE_ID="${BUNDLE_ID:-ch.rdbartram.niivooffice}"
APP="${APP:-build/niivo mail.app}"
# Tenant defaults baked into Info.plist (BACKLOG §17): an Entra client ID and tenant ID aren't secrets, but they're
# deployment-specific, so they come from a git-ignored build.env (NIIVO_CLIENT_ID=..., NIIVO_TENANT_ID=...) or the
# environment, never from this script. Empty = the app asks for config.json / shows "not configured".
# The environment wins over build.env (NIIVO_CLIENT_ID= with an empty value builds an unconfigured app).
_env_cid="${NIIVO_CLIENT_ID-__unset__}"; _env_tid="${NIIVO_TENANT_ID-__unset__}"
if [[ -f build.env ]]; then set -a; source build.env; set +a; fi
[[ "$_env_cid" != __unset__ ]] && NIIVO_CLIENT_ID="$_env_cid"
[[ "$_env_tid" != __unset__ ]] && NIIVO_TENANT_ID="$_env_tid"
NIIVO_CLIENT_ID="${NIIVO_CLIENT_ID:-}"
NIIVO_TENANT_ID="${NIIVO_TENANT_ID:-}"

swift build -c "$CONFIG" --product CompliantCalendar
swift build -c "$CONFIG" --product OfficeMCP
BIN_DIR="$(swift build -c "$CONFIG" --show-bin-path)"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Frameworks" "$APP/Contents/Resources"
cp "$BIN_DIR/CompliantCalendar" "$APP/Contents/MacOS/"
cp "$BIN_DIR/OfficeMCP" "$APP/Contents/MacOS/"   # relay for the Claude CLI agent (MCPSocketHost)
# Release: drop debug and local symbols (the unstripped executables were most of the bundle). Before signing.
if [[ "$CONFIG" == "release" ]]; then
  strip -S -x "$APP/Contents/MacOS/CompliantCalendar" "$APP/Contents/MacOS/OfficeMCP"
fi
# niivo brand fonts (SwiftPM resource bundle). Without it the app falls back to system fonts.
if [[ -d "$BIN_DIR/CompliantOffice_CompliantCalendar.bundle" ]]; then
  cp -R "$BIN_DIR/CompliantOffice_CompliantCalendar.bundle" "$APP/Contents/Resources/"
fi
# niivo app icon (rendered by `CompliantCalendar --render-icon build/icon`). Optional: no icon → generic app icon.
ICON_PLIST=""
if [[ -f build/icon/AppIcon.icns ]]; then
  cp build/icon/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
  ICON_PLIST="<key>CFBundleIconFile</key><string>AppIcon</string>"
fi

MSAL_FW="$(find .build/artifacts -path '*macos-arm64_x86_64/MSAL.framework' -maxdepth 6 | head -1)"
cp -R "$MSAL_FW" "$APP/Contents/Frameworks/"
install_name_tool -add_rpath "@executable_path/../Frameworks" "$APP/Contents/MacOS/CompliantCalendar" 2>/dev/null || true

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>${BUNDLE_ID}</string>
  <key>CFBundleName</key><string>niivo mail</string>
  <key>CFBundleDisplayName</key><string>niivo mail</string>
  <key>CFBundleExecutable</key><string>CompliantCalendar</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>15.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>LSApplicationCategoryType</key><string>public.app-category.productivity</string>
  <key>CCTeamID</key><string>${TEAM_ID:-}</string>
  <key>NiivoClientID</key><string>${NIIVO_CLIENT_ID}</string>
  <key>NiivoTenantID</key><string>${NIIVO_TENANT_ID}</string>
  ${ICON_PLIST}
  <key>CFBundleURLTypes</key><array><dict>
    <key>CFBundleURLSchemes</key><array><string>msauth.${BUNDLE_ID}</string></array>
  </dict><dict>
    <key>CFBundleURLName</key><string>Email Address URL</string>
    <key>CFBundleTypeRole</key><string>Viewer</string>
    <key>CFBundleURLSchemes</key><array><string>mailto</string></array>
  </dict></array>
  <key>CFBundleDevelopmentRegion</key><string>en</string>
  <key>CFBundleLocalizations</key><array><string>en</string><string>de</string><string>fr</string><string>it</string></array>
  <key>CFBundleDocumentTypes</key><array><dict>
    <key>CFBundleTypeName</key><string>Calendar File</string>
    <key>CFBundleTypeRole</key><string>Viewer</string>
    <key>LSHandlerRank</key><string>Alternate</string>
    <key>LSItemContentTypes</key><array><string>com.apple.ical.ics</string></array>
  </dict></array>
</dict></plist>
PLIST

# Signing.
#   Ad-hoc (default): runs in --fixtures mode only — MSAL's token cache fails with -34018 without entitlements.
#   Real:  SIGN_IDENTITY="Developer ID Application: … (TEAMID)" TEAM_ID=TEAMID [PROFILE=path.provisionprofile] ./scripts/bundle.sh
#   keychain-access-groups lets MSAL use its shared cache group and our cache key live in the data-protection keychain.
if [[ -n "${SIGN_IDENTITY:-}" && -n "${TEAM_ID:-}" ]]; then
  ENT="build/CompliantCalendar.entitlements"
  cat > "$ENT" <<ENTPLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>com.apple.application-identifier</key><string>${TEAM_ID}.${BUNDLE_ID}</string>
  <key>com.apple.developer.team-identifier</key><string>${TEAM_ID}</string>
  <key>keychain-access-groups</key><array>
    <string>${TEAM_ID}.com.microsoft.identity.universalstorage</string>
    <string>${TEAM_ID}.${BUNDLE_ID}</string>
  </array>
</dict></plist>
ENTPLIST
  # A provisioning profile authorising these entitlements may be required (UNVERIFIED for Developer ID on macOS 27).
  if [[ -n "${PROFILE:-}" ]]; then cp "$PROFILE" "$APP/Contents/embedded.provisionprofile"; fi
  # MIP SDK (decryption): bundle the bridge + the four redistributable SDK dylibs (vendor/mip/sdk/redist.txt) into
  # Contents/Frameworks and sign them with our identity, so the hardened runtime's library validation accepts them.
  # Skipped when the SDK isn't checked out (vendor/ is gitignored). Licence: see docs/MIP.md before any distribution.
  MIPBIN="vendor/mip/sdk/bins/release/arm64"
  if [[ -f vendor/mip/lib/libniivo_mipbridge.dylib && -d "$MIPBIN" && "${BUNDLE_MIP:-1}" == "1" ]]; then
    mkdir -p "$APP/Contents/Frameworks"
    # All runtime dylibs the SDK ships (OpenSSL, glib/gmime, gpgme, …), not just the four mip_* ones: libmip_core
    # links @rpath/libssl.3.dylib etc. Skip *_nostrip variants (debug duplicates).
    for f in "$MIPBIN"/*.dylib; do
      case "$f" in *_nostrip.dylib) continue;; esac
      cp -f "$f" "$APP/Contents/Frameworks/"
    done
    cp -f vendor/mip/lib/libniivo_mipbridge.dylib "$APP/Contents/Frameworks/"
    install_name_tool -add_rpath @loader_path "$APP/Contents/Frameworks/libniivo_mipbridge.dylib" 2>/dev/null || true
    for f in "$APP"/Contents/Frameworks/lib*.dylib; do
      install_name_tool -add_rpath @loader_path "$f" 2>/dev/null || true
      codesign --force --options runtime --timestamp --sign "$SIGN_IDENTITY" "$f"
    done
    echo "Bundled MIP SDK into Frameworks"
  fi
  codesign --force --options runtime --timestamp --sign "$SIGN_IDENTITY" "$APP/Contents/Frameworks/MSAL.framework"
  codesign --force --options runtime --timestamp --sign "$SIGN_IDENTITY" "$APP/Contents/MacOS/OfficeMCP"
  codesign --force --options runtime --timestamp --entitlements "$ENT" --sign "$SIGN_IDENTITY" "$APP"
  codesign --verify --strict --verbose=2 "$APP"
  echo "Built $APP (signed: $SIGN_IDENTITY)"
  # Notarise + staple when a notarytool keychain profile is given (xcrun notarytool store-credentials <name> ...).
  if [[ -n "${NOTARY_PROFILE:-}" ]]; then
    ZIP="build/notarize-upload.zip"
    rm -f "$ZIP"; ditto -c -k --keepParent "$APP" "$ZIP"
    xcrun notarytool submit "$ZIP" --keychain-profile "$NOTARY_PROFILE" --wait
    xcrun stapler staple "$APP"
    rm -f "$ZIP"
    spctl --assess --type execute --verbose=2 "$APP"
  fi
else
  codesign --force --deep --sign - "$APP"
  echo "Built $APP (ad-hoc — fixtures only)"
fi
