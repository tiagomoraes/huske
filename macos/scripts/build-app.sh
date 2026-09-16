#!/usr/bin/env bash
# Build Huske.app from the SwiftPM package.
#
#   macos/scripts/build-app.sh [--debug]
#
# Output: macos/dist/Huske.app.
# The bundle version is read from pyproject.toml — the repo's single source
# of truth — so the app and the engine report the same version.
#
# Signing. HUSKE_CODESIGN_IDENTITY selects the identity:
#   unset   auto-detect a "Developer ID Application" identity, ad-hoc if none
#   "-"     force ad-hoc — what a contributor without a certificate gets
#   other   used verbatim (common name or SHA-1 hash)
# HUSKE_CODESIGN_KEYCHAIN pins the keychain to search, which is how CI signs
# out of a throwaway keychain without touching the default one.
#
# Both paths apply the hardened runtime and Huske.entitlements, so a local
# build hits the same TCC rules as the shipped one. That matters because the
# audio-input entitlement only becomes load-bearing under `--options runtime`:
# without it TCC denies the engine's microphone access *without prompting*.
# See docs/adr/0010-developer-id-signing-and-notarization.md. A secure
# timestamp needs a real identity, so the ad-hoc path skips it.
#
# Notarization is a separate step: macos/scripts/notarize-app.sh.
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

ENTITLEMENTS=Huske.entitlements
if [[ ! -f "$ENTITLEMENTS" ]]; then
    echo "missing $PWD/$ENTITLEMENTS" >&2
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

# --- signing ---------------------------------------------------------------

KEYCHAIN="${HUSKE_CODESIGN_KEYCHAIN:-}"

IDENTITY="${HUSKE_CODESIGN_IDENTITY:-}"
if [[ -z "$IDENTITY" ]]; then
    # `security find-identity` prints `  1) <sha1> "<name>"`. Match the hash
    # rather than the name so a keychain holding two Developer ID certs still
    # signs deterministically. Finding none is the normal contributor case.
    IDENTITY=$(security find-identity -v -p codesigning ${KEYCHAIN:+"$KEYCHAIN"} 2>/dev/null |
        sed -n 's/^ *[0-9][0-9]*) \([0-9A-F][0-9A-F]*\) "Developer ID Application.*"$/\1/p' |
        head -1)
    IDENTITY="${IDENTITY:--}"
fi

# Nested code is sealed without entitlements: entitlements belong to the
# executable the system launches, and the font bundle has no executable.
NESTED_ARGS=(--force --options runtime)
if [[ -n "$KEYCHAIN" ]]; then
    NESTED_ARGS+=(--keychain "$KEYCHAIN")
fi
if [[ "$IDENTITY" == "-" ]]; then
    echo "==> codesign (ad-hoc — not distributable)"
else
    # Notarization rejects a signature without a secure timestamp.
    NESTED_ARGS+=(--timestamp)
    echo "==> codesign ($IDENTITY)"
fi
APP_ARGS=("${NESTED_ARGS[@]}" --entitlements "$ENTITLEMENTS")

# Inside out: the outer seal covers the nested seals, so nested code must be
# signed first. `-depth` keeps that true if a bundle is ever nested in another.
# (`--deep` would do this in one call, but Apple deprecated it for signing and
# it would copy the app's entitlements onto everything it touches.)
while IFS= read -r -d '' nested; do
    echo "    nested: ${nested#"$APP"/}"
    codesign "${NESTED_ARGS[@]}" --sign "$IDENTITY" "$nested"
done < <(find "$APP/Contents" -depth -name '*.bundle' -type d -print0)

codesign "${APP_ARGS[@]}" --sign "$IDENTITY" "$APP"
codesign --verify --deep --strict "$APP"

echo "==> done: macos/$APP"
if [[ "$IDENTITY" != "-" ]]; then
    echo "    next: macos/scripts/notarize-app.sh"
fi
