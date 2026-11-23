#!/usr/bin/env bash
# Capture the phone screens that panels.html frames, in the app's DEBUG demo
# mode (made-up recordings and a made-up Mac), on the two simulator sizes the
# App Store asks for:
#   69 → 6.9" iPhone (1320×2868)   63 → 6.3" iPhone (1206×2622)
#
#   ios/AppStore/art/capture.sh        → ios/AppStore/art/captures/<size>-<screen>.png
#
# Then run render.sh. Override the simulators with SIM_69 / SIM_63 (names or
# UDIDs). Never capture a real library: everything here must be demo data.
# Run it with nothing else using the simulators (a parallel test run slows
# them down enough to catch a screen before the demo data is on it), and look
# at every capture before rendering: no prompt, no "◀ App" breadcrumb, and
# the demo library, not the simulator's own.
set -euo pipefail
cd "$(dirname "$0")"
ART="$PWD"
IOS="$(cd ../.. && pwd)"
BUNDLE=cloud.tiagomoraes.huske.ios
SIM_69="${SIM_69:-iPhone 17 Pro Max}"
SIM_63="${SIM_63:-iPhone 17 Pro}"
DERIVED="${DERIVED:-$(mktemp -d)}"
mkdir -p captures

udid() {   # name or UDID → UDID of an available simulator
    if [[ "$1" =~ ^[0-9A-F-]{36}$ ]]; then echo "$1"; return; fi
    xcrun simctl list devices available | sed -n "s/^ *$1 (\([0-9A-F-]\{36\}\)).*/\1/p" | head -1
}

echo "==> build (Debug, simulator)"
(cd "$IOS" && ./scripts/generate.sh >/dev/null)
xcodebuild build -project "$IOS/Huske.xcodeproj" -scheme Huske \
    -destination "generic/platform=iOS Simulator" -derivedDataPath "$DERIVED" -quiet
APP="$DERIVED/Build/Products/Debug-iphonesimulator/Huske.app"

# The Lock Screen needs the lock button, so a UI test takes it. Xcode 27
# writes the .xctestrun's UITargetAppPath without ".app" (the app target and
# the Huske Swift package share a name), so build for testing, patch that,
# and run test-without-building from the patched file.
xcodebuild build-for-testing -project "$IOS/Huske.xcodeproj" -scheme HuskeScreenshots \
    -destination "generic/platform=iOS Simulator" -derivedDataPath "$DERIVED/ui" -quiet
XCTESTRUN=$(ls "$DERIVED"/ui/Build/Products/*.xctestrun | head -1)
python3 - "$XCTESTRUN" <<'PY'
import plistlib, sys
path = sys.argv[1]
with open(path, "rb") as f: run = plistlib.load(f)
def fix(node):
    if isinstance(node, dict):
        for k, v in node.items():
            if k == "UITargetAppPath" and isinstance(v, str) and not v.endswith(".app"):
                node[k] = v + ".app"
            else:
                fix(v)
    elif isinstance(node, list):
        for v in node: fix(v)
fix(run)
with open(path, "wb") as f: plistlib.dump(run, f)
PY

lock_screen() {   # <udid> → captures/.lock/12-lock-screen.png
    rm -rf captures/.lock
    TEST_RUNNER_HUSKE_SHOT_DIR="$ART/captures/.lock" xcodebuild test-without-building \
        -xctestrun "$XCTESTRUN" -destination "id=$1" \
        -only-testing:HuskeUITests/ScreenshotTests/testLockScreenOfRunningSession \
        >"$DERIVED/lock.log" 2>&1 &
    local pid=$! waited=0
    # xcodebuild can sit for minutes after the test has finished: stop it as
    # soon as the capture exists.
    until [[ -f captures/.lock/12-lock-screen.png ]] || (( waited >= 300 )) || ! kill -0 "$pid" 2>/dev/null; do
        sleep 2; waited=$((waited + 2))
    done
    sleep 2
    kill "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
    [[ -f captures/.lock/12-lock-screen.png ]] || { echo "error: no Lock Screen capture; see $DERIVED/lock.log" >&2; return 1; }
}

for size in 69 63; do
    var="SIM_$size"; dev=$(udid "${!var}")
    [[ -n "$dev" ]] || { echo "error: no simulator named ${!var}" >&2; exit 1; }
    echo "==> $size: ${!var} ($dev)"
    xcrun simctl boot "$dev" 2>/dev/null || true
    xcrun simctl bootstatus "$dev" -b >/dev/null
    xcrun simctl ui "$dev" appearance light
    xcrun simctl status_bar "$dev" override --time "9:41" --operatorName "" \
        --dataNetwork wifi --wifiMode active --wifiBars 3 \
        --cellularMode active --cellularBars 4 --batteryState charged --batteryLevel 100
    xcrun simctl install "$dev" "$APP"

    shoot() {   # <screen name> [launch arguments…]
        local name="$1"; shift
        xcrun simctl terminate "$dev" "$BUNDLE" 2>/dev/null || true
        sleep 1
        xcrun simctl launch "$dev" "$BUNDLE" -HuskeDemoData YES "$@" >/dev/null
        sleep 8   # the demo library and the simulated recording need a moment
        xcrun simctl io "$dev" screenshot "captures/$size-$name.png" >/dev/null 2>&1
        echo "    captures/$size-$name.png"
    }
    shoot library
    shoot recording -HuskeDemoRecording YES
    shoot transcript -HuskeDemoRoute detail
    shoot mac -HuskeDemoRoute mac

    # The first run may stop at iOS's "Allow Live Activities?" (the test taps
    # Allow), so it runs twice and keeps the second, clean capture.
    for _ in 1 2; do
        xcrun simctl terminate "$dev" "$BUNDLE" 2>/dev/null || true
        xcrun simctl launch "$dev" "$BUNDLE" -HuskeDemoData YES -HuskeDemoRecording YES >/dev/null
        sleep 4
        lock_screen "$dev"
    done
    mv "captures/.lock/12-lock-screen.png" "captures/$size-lock-screen.png"
    rm -rf captures/.lock
    echo "    captures/$size-lock-screen.png"
    xcrun simctl status_bar "$dev" clear
done

echo "==> look at every capture before rendering: no prompt, no \"◀ App\" breadcrumb, demo data only"
