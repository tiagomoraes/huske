#!/usr/bin/env bash
# Check an archive of Huske for iPhone before it goes to App Store Connect.
# Each check is a rejection that the upload or App Review would otherwise
# report minutes or days later.
#
#   ios/scripts/verify-app-store-archive.sh <Huske.xcarchive> [build number]
set -euo pipefail

ARCHIVE="$1"
EXPECTED_BUILD="${2:-}"
APP="$ARCHIVE/Products/Applications/Huske.app"
EXT="$APP/PlugIns/HuskeLiveActivity.appex"
failures=0
fail() { echo "  ✗ $*" >&2; failures=$((failures + 1)); }
ok() { echo "  ✓ $*"; }

echo "==> verify $(basename "$ARCHIVE")"
[[ -d "$APP" ]] || { echo "error: no Huske.app in $ARCHIVE" >&2; exit 1; }
plist() { /usr/libexec/PlistBuddy -c "Print :$2" "$1/Info.plist" 2>/dev/null || true; }

# Export compliance: without the key, every upload stops at the questionnaire.
[[ "$(plist "$APP" ITSAppUsesNonExemptEncryption)" == "false" ]] \
    && ok "ITSAppUsesNonExemptEncryption = NO" \
    || fail "ITSAppUsesNonExemptEncryption missing or not NO"

# Privacy manifests, in every bundle with an executable.
for bundle in "$APP" "$EXT"; do
    if [[ -f "$bundle/PrivacyInfo.xcprivacy" ]] && plutil -lint -s "$bundle/PrivacyInfo.xcprivacy"; then
        ok "privacy manifest in $(basename "$bundle")"
    else
        fail "no valid PrivacyInfo.xcprivacy in $(basename "$bundle")"
    fi
done

# Versions: the extension must match the app, and the build is the one asked for.
app_version=$(plist "$APP" CFBundleShortVersionString)
app_build=$(plist "$APP" CFBundleVersion)
[[ "$(plist "$EXT" CFBundleShortVersionString)" == "$app_version" && "$(plist "$EXT" CFBundleVersion)" == "$app_build" ]] \
    && ok "version $app_version ($app_build), extension matches" \
    || fail "extension version $(plist "$EXT" CFBundleShortVersionString) ($(plist "$EXT" CFBundleVersion)) != app $app_version ($app_build)"
[[ "$app_version" =~ ^[0-9]+\.[0-9]+(\.[0-9]+)?$ ]] \
    || fail "CFBundleShortVersionString '$app_version' is not one to three integers"
if [[ -n "$EXPECTED_BUILD" && "$app_build" != "$EXPECTED_BUILD" ]]; then
    fail "CFBundleVersion is $app_build, expected $EXPECTED_BUILD"
fi

# iPad multitasking: App Store Connect rejects an iPhone app whose iPad
# orientations aren't all four (it runs on iPad in compatibility mode).
ipad_orientations=$(/usr/libexec/PlistBuddy -c "Print :UISupportedInterfaceOrientations~ipad" "$APP/Info.plist" 2>/dev/null | grep -c UIInterfaceOrientation || true)
[[ "$ipad_orientations" == 4 ]] \
    && ok "all four iPad orientations" \
    || fail "UISupportedInterfaceOrientations~ipad lists $ipad_orientations of 4 orientations (iPad multitasking)"

# Purpose strings the app's features need.
for key in NSMicrophoneUsageDescription NSCameraUsageDescription NSLocalNetworkUsageDescription; do
    [[ -n "$(plist "$APP" "$key")" ]] && ok "$key" || fail "$key missing"
done

# Distribution signing: no debugger entitlement, the right team, and an App
# Store profile (no device list).
for bundle in "$APP" "$EXT"; do
    name=$(basename "$bundle")
    entitlements=$(codesign -d --entitlements :- "$bundle" 2>/dev/null || true)
    if grep -q "get-task-allow" <<<"$entitlements" && \
       [[ "$(plutil -extract get-task-allow raw -o - - <<<"$entitlements" 2>/dev/null)" == "true" ]]; then
        fail "$name is signed with get-task-allow (a development signature)"
    else
        ok "$name has no get-task-allow"
    fi
    authority=$(codesign -dvv "$bundle" 2>&1 | sed -n 's/^Authority=//p' | head -1)
    [[ "$authority" == "Apple Distribution: "* ]] \
        && ok "$name signed by $authority" \
        || fail "$name signed by '${authority:-nothing}', not Apple Distribution"
    if [[ -f "$bundle/embedded.mobileprovision" ]] && \
       security cms -D -i "$bundle/embedded.mobileprovision" 2>/dev/null | grep -q ProvisionedDevices; then
        fail "$name embeds a profile with devices (not App Store)"
    fi
done

# The DEBUG demo mode must not ship (guideline 2.5.19: no hidden features).
if strings "$APP/Huske" | grep -q "HuskeDemoData"; then
    fail "the binary contains the DEBUG demo mode (HuskeDemoData)"
else
    ok "no DEBUG demo mode in the binary"
fi

if (( failures > 0 )); then
    echo "error: $failures check(s) failed" >&2
    exit 1
fi
