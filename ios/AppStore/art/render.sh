#!/usr/bin/env bash
# Render the App Store art with headless Chrome, as JPEG without an alpha
# channel (App Store Connect rejects alpha):
# - header.html → the universal creative asset (5244×2950) for the product
#   page header and the search results card;
# - panels.html → five screenshots at 6.9" (1320×2868) and 6.3" (1206×2622).
#
#   ios/AppStore/art/render.sh   → ios/AppStore/art/out/universal.jpg, <size>-<n>.jpg
#
# Needs the phone captures in captures/ (capture.sh) and Google Chrome.
set -euo pipefail
cd "$(dirname "$0")"

CHROME="${CHROME:-/Applications/Google Chrome.app/Contents/MacOS/Google Chrome}"
[[ -x "$CHROME" ]] || { echo "error: Chrome not found at $CHROME (set CHROME=…)" >&2; exit 1; }
PROFILE=$(mktemp -d)            # never the user's own Chrome profile
trap 'rm -rf "$PROFILE"' EXIT
mkdir -p out

render() {   # <panel> <size> <CSS px wide> <CSS px tall>  (rendered at 2×)
    local png="out/$2-$1.png"
    "$CHROME" --headless=new --user-data-dir="$PROFILE" --hide-scrollbars \
        --allow-file-access-from-files --force-device-scale-factor=2 \
        --window-size="$3,$4" --virtual-time-budget=4000 \
        --screenshot="$PWD/$png" "file://$PWD/panels.html?panel=$1&size=$2" >/dev/null 2>&1
    sips -s format jpeg -s formatOptions 92 "$png" --out "out/$2-$1.jpg" >/dev/null
    rm -f "$png"
    echo "  out/$2-$1.jpg  $(sips -g pixelWidth -g pixelHeight "out/$2-$1.jpg" | awk '/pixel/{printf $2" "}')"
}

# The universal creative asset: product page header and search results.
"$CHROME" --headless=new --user-data-dir="$PROFILE" --hide-scrollbars \
    --allow-file-access-from-files --force-device-scale-factor=2 \
    --window-size=2622,1475 --virtual-time-budget=4000 \
    --screenshot="$PWD/out/universal.png" "file://$PWD/header.html" >/dev/null 2>&1
sips -s format jpeg -s formatOptions 92 out/universal.png --out out/universal.jpg >/dev/null
rm -f out/universal.png
echo "  out/universal.jpg  $(sips -g pixelWidth -g pixelHeight out/universal.jpg | awk '/pixel/{printf $2" "}')"

for panel in 1 2 3 4 5; do
    # Headless Chrome won't make a window narrower than about 500 px, so the
    # panels render at 2× on a wider viewport; panels.html sizes everything
    # from the viewport width.
    render "$panel" 69 660 1434
    render "$panel" 63 603 1311
done
