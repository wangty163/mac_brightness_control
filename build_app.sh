#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_NAME="Brightness Control"
EXECUTABLE_NAME="BrightnessControlApp"
SLEEP_HELPER_NAME="BrightnessControlSleepHelper"
CODE_SIGN_IDENTITY="${BRIGHTNESS_CODE_SIGN_IDENTITY:--}"
APP_VERSION="${APP_VERSION:-1.1.0}"
APP_BUILD_NUMBER="${APP_BUILD_NUMBER:-1}"

if [[ ! "$APP_VERSION" =~ ^[0-9]+(\.[0-9]+){0,2}$ ]]; then
  echo "APP_VERSION must contain one to three dot-separated integers." >&2
  exit 1
fi

if [[ ! "$APP_BUILD_NUMBER" =~ ^[0-9]+$ ]]; then
  echo "APP_BUILD_NUMBER must be an integer." >&2
  exit 1
fi

cd "$ROOT_DIR"
swift build --disable-sandbox -c release "$@"
BUILD_DIR="$(swift build -c release --show-bin-path "$@")"
APP_DIR="$BUILD_DIR/$APP_NAME.app"

rm -rf "$APP_DIR"
mkdir -p \
  "$APP_DIR/Contents/MacOS" \
  "$APP_DIR/Contents/Library/HelperTools" \
  "$APP_DIR/Contents/Library/LaunchDaemons" \
  "$APP_DIR/Contents/Resources"
cp "$BUILD_DIR/$EXECUTABLE_NAME" "$APP_DIR/Contents/MacOS/$EXECUTABLE_NAME"
cp "$BUILD_DIR/$SLEEP_HELPER_NAME" "$APP_DIR/Contents/Library/HelperTools/$SLEEP_HELPER_NAME"
cp \
  "$ROOT_DIR/Resources/local.wty.BrightnessControl.SleepHelper.plist" \
  "$APP_DIR/Contents/Library/LaunchDaemons/local.wty.BrightnessControl.SleepHelper.plist"
cp "$ROOT_DIR/Resources/AppIcon.icns" "$APP_DIR/Contents/Resources/AppIcon.icns"
cp \
  "$ROOT_DIR/Resources/local.wty.BrightnessControl.SleepHelper.legacy.plist" \
  "$APP_DIR/Contents/Resources/local.wty.BrightnessControl.SleepHelper.legacy.plist"
chmod +x "$APP_DIR/Contents/MacOS/$EXECUTABLE_NAME"
chmod +x "$APP_DIR/Contents/Library/HelperTools/$SLEEP_HELPER_NAME"

cat > "$APP_DIR/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key>
  <string>en</string>
  <key>CFBundleExecutable</key>
  <string>$EXECUTABLE_NAME</string>
  <key>CFBundleIdentifier</key>
  <string>local.wty.BrightnessControl</string>
  <key>CFBundleIconFile</key>
  <string>AppIcon</string>
  <key>CFBundleInfoDictionaryVersion</key>
  <string>6.0</string>
  <key>CFBundleName</key>
  <string>$APP_NAME</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>$APP_VERSION</string>
  <key>CFBundleVersion</key>
  <string>$APP_BUILD_NUMBER</string>
  <key>LSMinimumSystemVersion</key>
  <string>14.0</string>
  <key>NSHighResolutionCapable</key>
  <true/>
</dict>
</plist>
PLIST

printf 'APPL????' > "$APP_DIR/Contents/PkgInfo"
codesign \
  --force \
  --options runtime \
  --identifier "local.wty.BrightnessControl.SleepHelper" \
  --sign "$CODE_SIGN_IDENTITY" \
  "$APP_DIR/Contents/Library/HelperTools/$SLEEP_HELPER_NAME"
codesign --force --deep --options runtime --sign "$CODE_SIGN_IDENTITY" "$APP_DIR"
codesign --verify --deep --strict "$APP_DIR"
echo "$APP_DIR"
