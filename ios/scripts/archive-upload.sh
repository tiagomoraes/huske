#!/usr/bin/env bash
# Archive Huske for iPhone, sign it for the App Store, and upload it to App
# Store Connect (TestFlight). The same script runs in CI
# (.github/workflows/ios-app-store.yml) and on a maintainer's Mac.
#
# Signing is manual and self-contained: the Apple Distribution identity goes
# into a throwaway keychain, the two App Store profiles are installed for this
# run, and the upload authenticates with an App Store Connect API key. Nothing
# depends on the login keychain or on Xcode's account settings.
# See docs/research/app-store-distribution.md (§3.6).
#
# Environment:
#   IOS_DIST_P12            path to the Apple Distribution identity (.p12)
#   IOS_DIST_P12_PASSWORD   its password
#   IOS_PROFILE_APP         path to the app's App Store profile
#   IOS_PROFILE_LIVEACTIVITY path to the widget extension's App Store profile
#   ASC_KEY_PATH            path to the App Store Connect API key (.p8)
#   ASC_KEY_ID, ASC_ISSUER_ID
#   BUILD_NUMBER            optional; default: UTC "YYYYMMDD.HHMM" without
#                           leading zeros (20261123.520), which only ever grows
#                           and never collides with a manual upload's number
#   UPLOAD                  1 (default) uploads; 0 exports an .ipa only
#   OUT_DIR                 optional; default: ios/build/app-store
set -euo pipefail

cd "$(dirname "$0")/.."   # ios/

: "${IOS_DIST_P12:?}" "${IOS_DIST_P12_PASSWORD:?}" "${IOS_PROFILE_APP:?}" \
  "${IOS_PROFILE_LIVEACTIVITY:?}" "${ASC_KEY_PATH:?}" "${ASC_KEY_ID:?}" \
  "${ASC_ISSUER_ID:?}"

TEAM_ID=QD5A8CZK76
APP_ID=cloud.tiagomoraes.huske.ios
EXT_ID=cloud.tiagomoraes.huske.ios.LiveActivity
# UTC date, then the time as a plain number (05:20 → 520): App Store Connect
# drops leading zeros, and HHMM read as a number still only grows.
BUILD_NUMBER="${BUILD_NUMBER:-$(date -u +%Y%m%d).$((10#$(date -u +%H%M)))}"
UPLOAD="${UPLOAD:-1}"
OUT_DIR="${OUT_DIR:-$PWD/build/app-store}"
ARCHIVE="$OUT_DIR/Huske.xcarchive"
EXPORT_DIR="$OUT_DIR/export"
WORK=$(mktemp -d)
KEYCHAIN="$WORK/huske-ios-signing.keychain-db"

# Restore the keychain search list and remove the signing material, however
# the script ends.
ORIGINAL_KEYCHAINS=$(security list-keychains -d user | tr -d '"' | xargs)
cleanup() {
    # shellcheck disable=SC2086
    security list-keychains -d user -s $ORIGINAL_KEYCHAINS >/dev/null 2>&1 || true
    security delete-keychain "$KEYCHAIN" >/dev/null 2>&1 || true
    rm -rf "$WORK"
}
trap cleanup EXIT

echo "==> signing identity (throwaway keychain)"
KEYCHAIN_PASSWORD=$(uuidgen)
security create-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN"
security set-keychain-settings -lut 3600 "$KEYCHAIN"
security unlock-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN"
security import "$IOS_DIST_P12" -k "$KEYCHAIN" -P "$IOS_DIST_P12_PASSWORD" \
    -f pkcs12 -T /usr/bin/codesign -T /usr/bin/security >/dev/null
# Without the partition list, codesign waits on a GUI prompt that never comes.
security set-key-partition-list -S apple-tool:,apple:,codesign: -s \
    -k "$KEYCHAIN_PASSWORD" "$KEYCHAIN" >/dev/null
# shellcheck disable=SC2086
security list-keychains -d user -s "$KEYCHAIN" $ORIGINAL_KEYCHAINS
IDENTITY=$(security find-identity -v -p codesigning "$KEYCHAIN" |
    sed -n 's/^ *[0-9][0-9]*) \([0-9A-F]\{40\}\) "Apple Distribution: .*"$/\1/p' | head -1)
[[ -n "$IDENTITY" ]] || { echo "error: no Apple Distribution identity in $IOS_DIST_P12" >&2; exit 1; }

echo "==> provisioning profiles"
install_profile() {   # <profile> <expected bundle id> → prints the profile's name
    local profile="$1" bundle="$2" plist="$WORK/$(basename "$1").plist"
    security cms -D -i "$profile" > "$plist"
    local name uuid appid
    name=$(/usr/libexec/PlistBuddy -c 'Print :Name' "$plist")
    uuid=$(/usr/libexec/PlistBuddy -c 'Print :UUID' "$plist")
    appid=$(/usr/libexec/PlistBuddy -c 'Print :Entitlements:application-identifier' "$plist")
    [[ "$appid" == "$TEAM_ID.$bundle" ]] || { echo "error: $profile is for $appid, not $bundle" >&2; exit 1; }
    # An App Store profile lists no devices; one that does is Ad Hoc or development.
    if /usr/libexec/PlistBuddy -c 'Print :ProvisionedDevices' "$plist" >/dev/null 2>&1; then
        echo "error: $profile lists devices, so it is not an App Store profile" >&2; exit 1
    fi
    for dir in "$HOME/Library/MobileDevice/Provisioning Profiles" \
               "$HOME/Library/Developer/Xcode/UserData/Provisioning Profiles"; do
        mkdir -p "$dir"
        cp "$profile" "$dir/$uuid.mobileprovision"
    done
    echo "    $bundle → $name (expires $(/usr/libexec/PlistBuddy -c 'Print :ExpirationDate' "$plist"))" >&2
    printf '%s' "$name"
}
APP_PROFILE=$(install_profile "$IOS_PROFILE_APP" "$APP_ID")
EXT_PROFILE=$(install_profile "$IOS_PROFILE_LIVEACTIVITY" "$EXT_ID")

echo "==> project"
./scripts/generate.sh >/dev/null
VERSION=$(sed -n 's/^version = "\(.*\)"/\1/p' ../pyproject.toml | head -1)
echo "    version $VERSION, build $BUILD_NUMBER"

echo "==> archive"
rm -rf "$ARCHIVE" "$EXPORT_DIR"
mkdir -p "$OUT_DIR"
xcodebuild archive \
    -project Huske.xcodeproj -scheme Huske -configuration Release \
    -destination 'generic/platform=iOS' -archivePath "$ARCHIVE" \
    DEVELOPMENT_TEAM="$TEAM_ID" CODE_SIGN_STYLE=Manual \
    CODE_SIGN_IDENTITY="$IDENTITY" \
    HUSKE_APP_PROFILE="$APP_PROFILE" HUSKE_LIVEACTIVITY_PROFILE="$EXT_PROFILE" \
    CURRENT_PROJECT_VERSION="$BUILD_NUMBER" \
    OTHER_CODE_SIGN_FLAGS="--keychain $KEYCHAIN" \
    -quiet

./scripts/verify-app-store-archive.sh "$ARCHIVE" "$BUILD_NUMBER"

echo "==> export$([[ "$UPLOAD" == 1 ]] && echo ' and upload')"
EXPORT_OPTIONS="$WORK/ExportOptions.plist"
cat > "$EXPORT_OPTIONS" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>method</key><string>app-store-connect</string>
    <key>destination</key><string>$([[ "$UPLOAD" == 1 ]] && echo upload || echo export)</string>
    <key>teamID</key><string>$TEAM_ID</string>
    <key>signingStyle</key><string>manual</string>
    <key>signingCertificate</key><string>$IDENTITY</string>
    <key>provisioningProfiles</key>
    <dict>
        <key>$APP_ID</key><string>$APP_PROFILE</string>
        <key>$EXT_ID</key><string>$EXT_PROFILE</string>
    </dict>
    <key>manageAppVersionAndBuildNumber</key><false/>
    <key>uploadSymbols</key><true/>
</dict>
</plist>
PLIST
xcodebuild -exportArchive -archivePath "$ARCHIVE" -exportPath "$EXPORT_DIR" \
    -exportOptionsPlist "$EXPORT_OPTIONS" \
    -authenticationKeyPath "$ASC_KEY_PATH" -authenticationKeyID "$ASC_KEY_ID" \
    -authenticationKeyIssuerID "$ASC_ISSUER_ID"

if [[ "$UPLOAD" == 1 ]]; then
    echo "==> uploaded Huske $VERSION ($BUILD_NUMBER). App Store Connect processes it before it appears in TestFlight."
else
    echo "==> exported $(ls "$EXPORT_DIR"/*.ipa)"
fi
