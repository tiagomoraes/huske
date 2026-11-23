#!/usr/bin/env bash
# Notarize a built Huske.app and produce the stapled release archive.
#
#   macos/scripts/notarize-app.sh [--app PATH] [--output PATH]
#                                 [--keychain-profile NAME]
#
# Defaults: --app macos/dist/Huske.app, --output macos/dist/Huske.app.zip.
#
# Apple notarizes an *archive* but the ticket staples to the *bundle*, so the
# order is zip -> submit -> staple the .app -> re-zip. There is no such thing
# as a stapled zip; `stapler staple` on one fails. The submission archive is a
# throwaway in a temp directory — only the re-zip is a release asset.
#
# Credentials, in precedence order:
#   --keychain-profile NAME, or HUSKE_NOTARY_PROFILE
#       a profile saved with `xcrun notarytool store-credentials`. Best for a
#       maintainer laptop: the secret stays in the keychain.
#   HUSKE_ASC_KEY_PATH + HUSKE_ASC_KEY_ID + HUSKE_ASC_ISSUER_ID
#       an App Store Connect API key (.p8). This is what CI uses. It has to be
#       a *Team* key — Individual keys are not eligible for the Notary API —
#       so the issuer UUID is always required. The issuer is still optional
#       here so a misconfigured key fails at Apple with a readable error
#       instead of in an argument check.
#
# See docs/adr/0010-developer-id-signing-and-notarization.md and
# docs/releasing.md for the one-time credential setup.
set -euo pipefail

# Resolve before the cd, so --help can still read this file's own header and
# so a relative --app/--output means what it meant where it was typed.
SELF="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"
CALLER_PWD="$PWD"
cd "$(dirname "$0")/.."
MACOS_DIR="$PWD"

APP=""
OUTPUT=""
PROFILE="${HUSKE_NOTARY_PROFILE:-}"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --app) APP="$2"; shift 2 ;;
        --output) OUTPUT="$2"; shift 2 ;;
        --keychain-profile) PROFILE="$2"; shift 2 ;;
        -h|--help) sed -n '2,26p' "$SELF" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "unknown argument: $1" >&2; exit 2 ;;
    esac
done
if [[ -n "$APP" ]]; then
    [[ "$APP" = /* ]] || APP="$CALLER_PWD/$APP"
else
    APP="$MACOS_DIR/dist/Huske.app"
fi
if [[ -n "$OUTPUT" ]]; then
    [[ "$OUTPUT" = /* ]] || OUTPUT="$CALLER_PWD/$OUTPUT"
else
    OUTPUT="${APP%.app}.app.zip"
fi

if [[ ! -d "$APP" ]]; then
    echo "no app bundle at $APP — run macos/scripts/build-app.sh first" >&2
    exit 1
fi

# --- credentials -----------------------------------------------------------

CRED=()
if [[ -n "$PROFILE" ]]; then
    CRED=(--keychain-profile "$PROFILE")
elif [[ -n "${HUSKE_ASC_KEY_PATH:-}" && -n "${HUSKE_ASC_KEY_ID:-}" ]]; then
    if [[ ! -f "$HUSKE_ASC_KEY_PATH" ]]; then
        echo "HUSKE_ASC_KEY_PATH does not exist: $HUSKE_ASC_KEY_PATH" >&2
        exit 1
    fi
    CRED=(--key "$HUSKE_ASC_KEY_PATH" --key-id "$HUSKE_ASC_KEY_ID")
    if [[ -n "${HUSKE_ASC_ISSUER_ID:-}" ]]; then
        CRED+=(--issuer "$HUSKE_ASC_ISSUER_ID")
    fi
else
    cat >&2 <<'MSG'
No notary credentials configured. Nothing here can be stubbed — Apple has to
sign the ticket. Pick one:

  1. Keychain profile (maintainer laptop), once:
       xcrun notarytool store-credentials huske-notary \
         --key ~/private_keys/AuthKey_XXXXXXXXXX.p8 \
         --key-id XXXXXXXXXX --issuer <issuer-uuid>
     then re-run with --keychain-profile huske-notary (or set
     HUSKE_NOTARY_PROFILE).

  2. App Store Connect API key (CI):
       export HUSKE_ASC_KEY_PATH=/path/to/AuthKey_XXXXXXXXXX.p8
       export HUSKE_ASC_KEY_ID=XXXXXXXXXX
       export HUSKE_ASC_ISSUER_ID=<issuer-uuid>

Notarization needs a Team key with the Developer role. The issuer UUID sits
above the key list at App Store Connect -> Users and Access -> Integrations ->
App Store Connect API. See docs/releasing.md.
MSG
    exit 1
fi

# --- pre-flight ------------------------------------------------------------

# Apple rejects an ad-hoc signature and a signature without the hardened
# runtime. Catching that here costs a second; catching it from the notary
# service costs a round trip.
SIGINFO=$(codesign -dvv "$APP" 2>&1)
if grep -q "Signature=adhoc" <<<"$SIGINFO"; then
    echo "$APP is ad-hoc signed — notarization needs a Developer ID identity." >&2
    echo "Set HUSKE_CODESIGN_IDENTITY and re-run macos/scripts/build-app.sh." >&2
    exit 1
fi
if ! grep -qE 'flags=0x[0-9a-f]*\(.*runtime' <<<"$SIGINFO"; then
    echo "$APP is not signed with the hardened runtime — notarization would fail." >&2
    exit 1
fi

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
SUBMIT_ZIP="$WORK/Huske.app.zip"
LOG="$WORK/notarytool.log"

echo "==> archive for submission"
ditto -c -k --keepParent "$APP" "$SUBMIT_ZIP"

echo "==> notarytool submit --wait (this takes minutes)"
set +e
xcrun notarytool submit "$SUBMIT_ZIP" "${CRED[@]}" --wait --timeout 30m 2>&1 | tee "$LOG"
SUBMIT_STATUS=${PIPESTATUS[0]}
set -e

SUBMISSION_ID=$(sed -n 's/^ *id: \([0-9a-fA-F-][0-9a-fA-F-]*\)$/\1/p' "$LOG" | head -1)
FINAL_STATUS=$(sed -n 's/^ *status: \(.*\)$/\1/p' "$LOG" | tail -1)

if [[ "$SUBMIT_STATUS" -ne 0 || "$FINAL_STATUS" != "Accepted" ]]; then
    echo "==> notarization failed (status: ${FINAL_STATUS:-unknown})" >&2
    if [[ -n "$SUBMISSION_ID" ]]; then
        # The submit output only says "Invalid"; the log says which binary and
        # why, and it is the only way to debug a rejection.
        echo "==> notarytool log $SUBMISSION_ID" >&2
        xcrun notarytool log "$SUBMISSION_ID" "${CRED[@]}" >&2 || true
    fi
    exit 1
fi

echo "==> staple the bundle"
xcrun stapler staple "$APP"
xcrun stapler validate "$APP"

echo "==> gatekeeper assessment"
spctl -a -vvv -t exec "$APP"

echo "==> archive for release: $OUTPUT"
rm -f "$OUTPUT"
mkdir -p "$(dirname "$OUTPUT")"
ditto -c -k --keepParent "$APP" "$OUTPUT"

echo "==> done: $OUTPUT (notarized, stapled)"
