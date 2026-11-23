#!/usr/bin/env bash
# Launch the packaged Huske.app the way a user's Mac sees it: with this
# checkout's .build folder out of reach.
#
#   macos/scripts/smoke-launch.sh [path/to/Huske.app]   (default: dist/Huske.app)
#
# SwiftPM's generated `Bundle.module` accessor can fall back to the *build
# machine's* `.build` path. v0.15.0 passed every check on the machine that
# built it, then crashed on launch everywhere else. This runs the app's
# offscreen `--render-screens` mode, which initialises the app the way a
# launch does (fonts included), renders the main screens without the window
# server, and exits. It fails if the app traps, registers no brand fonts, or
# renders nothing.
set -euo pipefail
cd "$(dirname "$0")/.."

app="${1:-dist/Huske.app}"
binary="$app/Contents/MacOS/Huske"
[[ -x "$binary" ]] || { echo "smoke launch: no app at $app" >&2; exit 1; }

out="$(mktemp -d)"
aside=".build-smoke-aside"
moved=false
if [[ -d .build ]]; then
  rm -rf "$aside"
  mv .build "$aside"   # a rename in place: instant, and the absolute path is gone
  moved=true
fi
restore() {
  if $moved && [[ -d "$aside" ]]; then mv "$aside" .build; fi
  rm -rf "$out"
}
trap restore EXIT

set +e
log="$(HUSKE_NO_UPDATE_CHECK=1 "$binary" --render-screens "$out/screens" 2>&1)"
status=$?
set -e
echo "$log" | tail -n 20

if [[ $status -ne 0 ]]; then
  echo "smoke launch: Huske exited with status $status" >&2
  exit 1
fi
if ! grep -q "brand fonts registered: true" <<<"$log"; then
  echo "smoke launch: the brand fonts did not register (resource bundle not found?)" >&2
  exit 1
fi
count=$(find "$out/screens" -name '*.png' | wc -l | tr -d ' ')
if [[ "$count" -eq 0 ]]; then
  echo "smoke launch: no screens rendered" >&2
  exit 1
fi
echo "smoke launch: ok, $count screens rendered with the brand fonts"
