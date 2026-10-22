#!/bin/bash
# Build Prompt Paws.app. No Xcode and no Node.js needed: Swift and the macOS SDK come from Apple's
# Command Line Tools (xcode-select --install); three.js is vendored in Resources/web/vendor/three/.
#   ./build.sh               build "build/Prompt Paws.app" for this Mac's chip
#   ./build.sh --universal   build one app for Apple Silicon and Intel
#   ./build.sh --zip         universal build, then build/Prompt-Paws-<version>.zip for a release
#   ./build.sh --install     build, then copy to "~/Applications/Prompt Paws.app"
#   ./build.sh --web         only stage the web files (for tools/review.mjs), no compile
set -euo pipefail
cd "$(dirname "$0")"

MODE=${1:-}
case "$MODE" in
  ""|--universal|--zip|--install|--web) ;;
  *) echo "Unknown option: $MODE" >&2; sed -n '4,8p' "$0" >&2; exit 2 ;;
esac
APP="build/Prompt Paws.app"
RES="$APP/Contents/Resources"
BIN="$APP/Contents/MacOS/PromptPaws"
VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Info.plist)

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$RES"

# 1. Web page (with its vendored three.js) and the characters.
cp -R Resources/web Resources/characters "$RES/"
[[ "$MODE" == "--web" ]] && { echo "Staged web files in $RES"; exit 0; }

# 2. App metadata and the hook script (the self-test runs it from here; users get it from the plugin).
cp Info.plist "$APP/Contents/Info.plist"
cp plugin/hooks/pet-mood.sh "$RES/pet-mood.sh"

# 3. Compile for this Mac's chip, or for both chips joined into one universal binary.
SDK=$(xcrun --show-sdk-path)
compile() {   # compile <arch> <output file>
  swiftc -O -target "$1-apple-macos13.0" -sdk "$SDK" Sources/*.swift \
    -framework AppKit -framework WebKit -framework Carbon -o "$2"
}
if [[ "$MODE" == "--universal" || "$MODE" == "--zip" ]]; then
  compile arm64 build/PromptPaws-arm64
  compile x86_64 build/PromptPaws-x86_64
  lipo -create build/PromptPaws-arm64 build/PromptPaws-x86_64 -output "$BIN"
  rm -f build/PromptPaws-arm64 build/PromptPaws-x86_64
else
  compile "$(uname -m)" "$BIN"
fi

# 4. Ad-hoc signature (not notarized; README "Install" explains "Open Anyway").
codesign --force --deep --sign - "$APP"
echo "Built $APP ($(lipo -archs "$BIN"))"

if [[ "$MODE" == "--zip" ]]; then
  ZIP="build/Prompt-Paws-$VERSION.zip"
  rm -f "$ZIP"
  ditto -c -k --keepParent "$APP" "$ZIP"
  echo "Packed $ZIP"
fi

if [[ "$MODE" == "--install" ]]; then
  mkdir -p "$HOME/Applications"
  pkill -x PromptPaws 2>/dev/null && sleep 1 || true
  rm -rf "$HOME/Applications/Prompt Paws.app"
  cp -R "$APP" "$HOME/Applications/Prompt Paws.app"
  echo "Installed ~/Applications/Prompt Paws.app"
fi
