#!/bin/bash
# Builds Portside.app (universal: Apple Silicon + Intel), ad-hoc signed for local use.
#   ./build.sh               -> dist/Portside.app
#   ./build.sh --install     -> also copies it to /Applications and (re)launches it
#   ./build.sh --compile-only
set -euo pipefail
cd "$(dirname "$0")"

install=false
compile_only=false
for argument in "$@"; do
  case "$argument" in
    --install) install=true ;;
    --compile-only) compile_only=true ;;
    *) echo "unknown option: $argument" >&2; exit 2 ;;
  esac
done

# The compiler also writes every localizable key it sees (Text("…"), String(localized:), …)
# so check-localizations can compare them with Localization/*.lproj.
# (kept between builds: an incremental build only rewrites the files it recompiles)
swift build -c release --arch arm64 --arch x86_64 \
  -Xswiftc -emit-localized-strings -Xswiftc -emit-localized-strings-path -Xswiftc "$PWD/.build/localized-strings"
xcrun swift Tools/check-localizations.swift .build/localized-strings Localization

$compile_only && exit 0

binary="$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)/Portside"
app="$PWD/dist/Portside.app"
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$binary" "$app/Contents/MacOS/Portside"
cp Packaging/Info.plist "$app/Contents/Info.plist"
for lproj in Localization/*.lproj; do cp -R "$lproj" "$app/Contents/Resources/"; done

# actool resolves relative paths against its own service, so every path is absolute.
xcrun actool "$PWD/Packaging/Portside.icon" \
  --compile "$app/Contents/Resources" \
  --output-format human-readable-text --errors \
  --output-partial-info-plist "$PWD/.build/Portside-icon-info.plist" \
  --app-icon Portside --platform macosx \
  --minimum-deployment-target 14.0 --target-device mac >/dev/null
test -s "$app/Contents/Resources/Portside.icns"

codesign --force --sign - "$app"
lipo -archs "$app/Contents/MacOS/Portside"
echo "$app"

if $install; then
  pkill -x Portside || true
  rm -rf /Applications/Portside.app
  cp -R "$app" /Applications/Portside.app
  open /Applications/Portside.app
  echo "installed: /Applications/Portside.app"
fi
