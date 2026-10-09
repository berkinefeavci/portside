#!/bin/bash
# Release packaging: check -> build -> Developer ID sign (Hardened Runtime) -> DMG -> notarize -> staple.
#
#   ./release.sh                 signed DMG, notarized and stapled
#   ./release.sh --no-notarize   signed DMG only (for a local look before submitting to Apple)
#
# Env:
#   PORTSIDE_SIGN_IDENTITY   Signing identity (name or SHA-1). Default: the first
#                            "Developer ID Application:" identity in the keychain.
#   PORTSIDE_NOTARY_PROFILE  `xcrun notarytool store-credentials` profile. Default: portside-notary.
set -euo pipefail
cd "$(dirname "$0")"

notarize=true
[[ "${1:-}" == "--no-notarize" ]] && notarize=false

identity="${PORTSIDE_SIGN_IDENTITY:-}"
if [[ -z "$identity" ]]; then
  identity="$(security find-identity -v -p codesigning | awk -F'"' '/Developer ID Application:/ { print $2; exit }')"
fi
if [[ -z "$identity" ]]; then
  echo "ERROR: no Developer ID Application identity found. Use ./build.sh for a local, ad-hoc signed app." >&2
  exit 1
fi
profile="${PORTSIDE_NOTARY_PROFILE:-portside-notary}"
if $notarize && ! xcrun notarytool history --keychain-profile "$profile" >/dev/null 2>&1; then
  echo "ERROR: notarization profile '$profile' is missing or unusable (xcrun notarytool store-credentials)." >&2
  exit 1
fi
echo "==> identity: $identity"

./check.sh
./build.sh

app=dist/Portside.app
version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Packaging/Info.plist)"
dmg="dist/Portside-$version.dmg"

echo "==> signing"
codesign --force --options runtime --timestamp \
  --entitlements Packaging/Portside.entitlements --sign "$identity" "$app"
codesign --verify --deep --strict --verbose=2 "$app"

if $notarize; then
  echo "==> notarizing the app"
  zip="dist/Portside-$version-app.zip"
  ditto -c -k --keepParent "$app" "$zip"
  xcrun notarytool submit "$zip" --keychain-profile "$profile" --wait
  rm -f "$zip"
  xcrun stapler staple "$app"
fi

echo "==> dmg"
staging="$(mktemp -d)"
trap 'rm -rf "$staging"' EXIT
cp -R "$app" "$staging/"
ln -s /Applications "$staging/Applications"
rm -f "$dmg"
hdiutil create -volname "Portside" -srcfolder "$staging" -ov -format UDZO "$dmg" >/dev/null
codesign --force --timestamp --sign "$identity" "$dmg"

if $notarize; then
  echo "==> notarizing the dmg"
  xcrun notarytool submit "$dmg" --keychain-profile "$profile" --wait
  xcrun stapler staple "$dmg"
  spctl --assess --type open --context context:primary-signature --verbose "$dmg"
fi

shasum -a 256 "$dmg" | tee "$dmg.sha256"
echo "==> $dmg"
