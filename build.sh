#!/bin/zsh
# Build JuiceBar.app and install to ~/Applications.
set -euo pipefail
cd "$(dirname "$0")"

APP_NAME="JuiceBar"
BUILD_DIR="build"
APP="$BUILD_DIR/$APP_NAME.app"
INSTALL_DIR="$HOME/Applications"

echo "── compiling…"
rm -rf "$BUILD_DIR"
mkdir -p "$APP/Contents/MacOS"

swiftc -O \
    Sources/main.swift Sources/BatterySampler.swift \
    Sources/IOReportSampler.swift Sources/Thermal.swift Sources/BarTitle.swift \
    Sources/SMCSampler.swift Sources/HIDTempSampler.swift \
    Sources/ChargeLimit.swift \
    Sources/DisplaySampler.swift Sources/SystemSampler.swift \
    -framework AppKit -framework IOKit -framework ServiceManagement \
    -o "$APP/Contents/MacOS/$APP_NAME"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key><string>JuiceBar</string>
    <key>CFBundleIdentifier</key><string>local.nicola.juicebar</string>
    <key>CFBundleName</key><string>JuiceBar</string>
    <key>CFBundleShortVersionString</key><string>1.1</string>
    <key>CFBundleVersion</key><string>2</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>LSMinimumSystemVersion</key><string>13.0</string>
    <key>LSUIElement</key><true/>
    <key>NSHumanReadableCopyright</key><string>Local build</string>
</dict>
</plist>
PLIST

echo "── signing (ad-hoc)…"
codesign --force --sign - "$APP"

echo "── installing to $INSTALL_DIR…"
mkdir -p "$INSTALL_DIR"
# Quit a running instance before replacing it
pkill -x "$APP_NAME" 2>/dev/null || true
sleep 0.5
rm -rf "$INSTALL_DIR/$APP_NAME.app"
cp -R "$APP" "$INSTALL_DIR/"

echo "── launching…"
open "$INSTALL_DIR/$APP_NAME.app"
echo "✓ done — look for ⌁ in the menu bar"
