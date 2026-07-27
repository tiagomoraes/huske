#!/usr/bin/env bash
# Build Huske.app from the SwiftPM package.
#
#   macos/scripts/build-app.sh [--debug]
#
# Output: macos/dist/Huske.app (ad-hoc signed, ready for `open`).
# The bundle version is read from pyproject.toml — the repo's single source
# of truth — so the app and the engine report the same version.
set -euo pipefail

cd "$(dirname "$0")/.."
CONFIG=release
if [[ "${1:-}" == "--debug" ]]; then
    CONFIG=debug
fi

VERSION=$(sed -n 's/^version = "\(.*\)"/\1/p' ../pyproject.toml | head -1)
if [[ -z "$VERSION" ]]; then
    echo "could not read version from pyproject.toml" >&2
    exit 1
fi

echo "==> swift build -c $CONFIG (version $VERSION)"
swift build -c "$CONFIG" --product Huske

BIN=$(swift build -c "$CONFIG" --product Huske --show-bin-path)/Huske
APP=dist/Huske.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

echo "==> icon"
if [[ ! -f .cache/AppIcon.icns ]]; then
    mkdir -p .cache
    swift scripts/generate-icon.swift .cache
fi
cp .cache/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

echo "==> bundle"
cp "$BIN" "$APP/Contents/MacOS/Huske"
# SwiftPM resource bundle (IBM Plex fonts) — Bundle.module finds it in
# Contents/Resources at runtime.
BUNDLE_DIR=$(dirname "$BIN")
if [[ -d "$BUNDLE_DIR/Huske_Huske.bundle" ]]; then
    cp -R "$BUNDLE_DIR/Huske_Huske.bundle" "$APP/Contents/Resources/"
fi

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>
    <string>Huske</string>
    <key>CFBundleDisplayName</key>
    <string>Huske</string>
    <key>CFBundleIdentifier</key>
    <string>cloud.tiagomoraes.huske</string>
    <key>CFBundleExecutable</key>
    <string>Huske</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>${VERSION}</string>
    <key>CFBundleVersion</key>
    <string>${VERSION}</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>LSApplicationCategoryType</key>
    <string>public.app-category.productivity</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSHumanReadableCopyright</key>
    <string>© Tiago Moraes. MIT License.</string>
    <key>NSMicrophoneUsageDescription</key>
    <string>Huske records your microphone to transcribe your conversations locally on this Mac. Audio never leaves your machine.</string>
    <key>NSAudioCaptureUsageDescription</key>
    <string>Huske captures system audio (calls, videos) to transcribe both sides of a conversation locally on this Mac.</string>
</dict>
</plist>
PLIST

echo "==> codesign (ad-hoc)"
codesign --force --deep --sign - "$APP"

echo "==> done: macos/$APP"
