#!/usr/bin/env bash
# Generate Huske.xcodeproj from project.yml, stamping the app version from the
# repo's single source of truth (../pyproject.toml) — never hardcode it.
set -euo pipefail
cd "$(dirname "$0")/.."
command -v xcodegen >/dev/null || { echo "xcodegen not found: brew install xcodegen" >&2; exit 1; }
HUSKE_VERSION=$(sed -n 's/^version = "\(.*\)"/\1/p' ../pyproject.toml | head -1)
[[ -n "$HUSKE_VERSION" ]] || { echo "could not read version from ../pyproject.toml" >&2; exit 1; }
export HUSKE_VERSION
exec xcodegen "$@"
