#!/usr/bin/env bash
# bump-version.sh <new-version>
# Bumps the version in both plugin manifests (.claude-plugin/plugin.json and
# .codex-plugin/plugin.json) plus the Claude marketplace catalog
# (.claude-plugin/marketplace.json) so they stay in lockstep, then runs the
# Codex validator to prove nothing drifted. Run this at the start of a release:
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

# The Claude marketplace catalog (.claude-plugin/marketplace.json) embeds a
# display-only per-plugin version. Keep it in lockstep — the Codex validator
# checks it, so a drift would fail the next bump.
CLAUDE_MARKETPLACE_JSON="$REPO_ROOT/.claude-plugin/marketplace.json"
if [ -f "$CLAUDE_MARKETPLACE_JSON" ]; then
  OLD_MKTVERSION=$(jq -r '.plugins[0].version // empty' "$CLAUDE_MARKETPLACE_JSON")
  if [ -n "$OLD_MKTVERSION" ]; then
    jq --arg v "$NEW_VERSION" '.plugins[0].version = $v' "$CLAUDE_MARKETPLACE_JSON" > "$CLAUDE_MARKETPLACE_JSON.tmp" && mv "$CLAUDE_MARKETPLACE_JSON.tmp" "$CLAUDE_MARKETPLACE_JSON"
    echo "Bumped .claude-plugin/marketplace.json: $OLD_MKTVERSION -> $NEW_VERSION"
  fi

  # Derive the catalog description's skill/agent counts from the Claude
  # manifest so the marketplace never advertises stale numbers. Only rewrites
  # when the description uses the expected "with N skills and M specialized
  # agents" template; hand-written descriptions pass through untouched.
  CLAUDE_PLUGIN_JSON="$REPO_ROOT/.claude-plugin/plugin.json"
  if [ -f "$CLAUDE_PLUGIN_JSON" ]; then
    SKILL_COUNT=$(jq '.skills | length' "$CLAUDE_PLUGIN_JSON")
    AGENT_COUNT=$(jq '.agents | length' "$CLAUDE_PLUGIN_JSON")
    OLD_DESC=$(jq -r '.plugins[0].description // empty' "$CLAUDE_MARKETPLACE_JSON")
    if [ -n "$OLD_DESC" ]; then
      NEW_DESC=$(jq -r --argjson s "$SKILL_COUNT" --argjson a "$AGENT_COUNT" \
        '.plugins[0].description | select(. != null) | sub("with [0-9]+ skills and [0-9]+ specialized agents"; "with \($s) skills and \($a) specialized agents")' \
        "$CLAUDE_MARKETPLACE_JSON")
      if [ -n "$NEW_DESC" ] && [ "$NEW_DESC" != "$OLD_DESC" ]; then
        jq --arg d "$NEW_DESC" '.plugins[0].description = $d' "$CLAUDE_MARKETPLACE_JSON" > "$CLAUDE_MARKETPLACE_JSON.tmp" && mv "$CLAUDE_MARKETPLACE_JSON.tmp" "$CLAUDE_MARKETPLACE_JSON"
        echo "Updated .claude-plugin/marketplace.json description counts: $SKILL_COUNT skills / $AGENT_COUNT agents"
      fi
    fi
  fi
fi

echo ""
echo "Running Codex validator (lockstep check)..."
bash "$SCRIPT_DIR/validate-codex-plugin.sh"

echo ""
echo "Done. Next: update RELEASE_NOTES.md and commit."
