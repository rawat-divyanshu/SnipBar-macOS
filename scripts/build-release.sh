#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

echo "==> Checking prerequisites..."
if ! command -v xcodegen >/dev/null 2>&1; then
  echo "Error: xcodegen is not installed. Run: brew install xcodegen" >&2
  exit 1
fi

echo "==> Cleaning previous targets, caches, and build artifacts..."
rm -rf \
  "$ROOT_DIR/.build" \
  "$ROOT_DIR/build" \
  "$ROOT_DIR/dist" \
  "$ROOT_DIR/SnipBar.xcodeproj"
rm -rf "$HOME/Library/Developer/Xcode/DerivedData/SnipBar-"* 2>/dev/null || true

echo "==> Running clean unit test suite..."
swift test --parallel

echo "==> Generating fresh SnipBar.xcodeproj..."
xcodegen generate

echo "==> Building clean Release SnipBar.app (Sign to Run Locally)..."
xcodebuild \
  -project SnipBar.xcodeproj \
  -scheme SnipBar \
  -configuration Release \
  -derivedDataPath build \
  CODE_SIGN_IDENTITY="-" \
  clean build

APP_PATH="build/Build/Products/Release/SnipBar.app"
if [ ! -d "$APP_PATH" ]; then
  echo "Error: Expected app bundle not found at $APP_PATH" >&2
  exit 1
fi
if [ ! -f "$APP_PATH/Contents/Resources/AppIcon.icns" ]; then
  echo "Warning: AppIcon.icns not found in $APP_PATH/Contents/Resources" >&2
fi

mkdir -p dist
ZIP_PATH="dist/SnipBar-macOS.zip"
rm -f "$ZIP_PATH"

echo "==> Packaging $ZIP_PATH..."
ditto -c -k --sequesterRsrc --keepParent "$APP_PATH" "$ZIP_PATH"

echo ""
echo "Clean release build complete!"
echo "  App Bundle : $ROOT_DIR/$APP_PATH"
echo "  App Icon   : $([ -f "$APP_PATH/Contents/Resources/AppIcon.icns" ] && echo "Bundled (AppIcon.icns)" || echo "Check Assets.xcassets")"
echo "  Tester Zip : $ROOT_DIR/$ZIP_PATH"
echo ""
echo "To install locally (quits any running SnipBar and refreshes Finder icon cache):"
echo "  killall SnipBar 2>/dev/null || true; rm -rf /Applications/SnipBar.app && cp -R \"$APP_PATH\" /Applications/SnipBar.app && touch /Applications/SnipBar.app && open /Applications/SnipBar.app"
