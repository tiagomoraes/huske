#!/usr/bin/env bash
# Select the newest stable Xcode at or above a minimum major version.
#
#   macos/scripts/select-xcode.sh [MIN_MAJOR]     (default 26)
#
# Huske.app bundles huske-apple-llm, which only reaches Apple Intelligence when
# built with an SDK that has FoundationModels — Xcode 26 or newer (ADR 0013).
# GitHub's runner images carry several Xcodes and the default moves between
# image updates, so CI picks one explicitly: the highest stable version
# installed as /Applications/Xcode_<version>.app (betas and release candidates,
# whose names carry a suffix, are skipped). Fails when none qualifies, so a
# release can never silently fall back to an SDK without the framework.
set -euo pipefail

MIN_MAJOR="${1:-26}"

best=""
best_version=""
for app in /Applications/Xcode_*.app; do
    [[ -d "$app" ]] || continue
    name=$(basename "$app" .app)
    version="${name#Xcode_}"
    # Stable releases only: digits and dots ("26.6", "26.4.1").
    [[ "$version" =~ ^[0-9]+(\.[0-9]+)*$ ]] || continue
    major="${version%%.*}"
    (( major >= MIN_MAJOR )) || continue
    if [[ -z "$best_version" ]] || [[ "$(printf '%s\n%s\n' "$best_version" "$version" | sort -V | tail -1)" == "$version" ]]; then
        best="$app"
        best_version="$version"
    fi
done

if [[ -z "$best" ]]; then
    echo "error: no stable Xcode ${MIN_MAJOR} or newer in /Applications" >&2
    ls -d /Applications/Xcode*.app 2>/dev/null >&2 || true
    exit 1
fi

echo "==> selecting $best"
sudo xcode-select --switch "$best/Contents/Developer"
xcodebuild -version
swift --version
