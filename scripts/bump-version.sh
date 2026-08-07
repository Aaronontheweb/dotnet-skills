#!/usr/bin/env bash
# bump-version.sh <new-version>
# Bumps the version in BOTH plugin manifests (.claude-plugin/plugin.json and
# .codex-plugin/plugin.json) so they stay in lockstep, then runs the Codex
# validator to prove nothing drifted. Run this at the start of a release:
#
#   ./scripts/bump-version.sh 1.5.0
#
# It intentionally does NOT touch RELEASE_NOTES.md or commit — the release
# workflow still owns those steps.

set -euo pipefail

NEW_VERSION="${1:?Usage: $0 <new-version>}"

# Must be plain semver (the repo's CI only triggers on v-prefixed tags, so
# this is the bare version, e.g. 1.5.0, not v1.5.0)
if ! echo "$NEW_VERSION" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.-]+)?$'; then
  echo "ERROR: '$NEW_VERSION' is not valid semver (expected e.g. 1.5.0)" >&2
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"

MANIFESTS=(
  "$REPO_ROOT/.claude-plugin/plugin.json"
  "$REPO_ROOT/.codex-plugin/plugin.json"
)

for manifest in "${MANIFESTS[@]}"; do
  if [ ! -f "$manifest" ]; then
    echo "ERROR: Missing manifest: $manifest" >&2
    exit 1
  fi
  OLD_VERSION=$(jq -r '.version' "$manifest")
  jq --arg v "$NEW_VERSION" '.version = $v' "$manifest" > "$manifest.tmp" && mv "$manifest.tmp" "$manifest"
  echo "Bumped $(basename "$(dirname "$manifest")")/$(basename "$manifest"): $OLD_VERSION -> $NEW_VERSION"
done

echo ""
echo "Running Codex validator (lockstep check)..."
bash "$SCRIPT_DIR/validate-codex-plugin.sh"

echo ""
echo "Done. Next: update RELEASE_NOTES.md and commit."
