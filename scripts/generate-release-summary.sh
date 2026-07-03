#!/usr/bin/env bash
set -euo pipefail

# generate-release-summary.sh
# Usage: ./scripts/generate-release-summary.sh <prev-tag>
# Outputs a markdown summary line showing new/updated skills and agents since the previous tag.

PREV_TAG="${1:?Usage: $0 <prev-tag>}"

if [ "$(git tag -l "$PREV_TAG")" = "" ]; then
  echo "ERROR: Tag '$PREV_TAG' not found" >&2
  exit 1
fi

TOTAL_SKILLS=$(jq '.skills | length' .claude-plugin/plugin.json)
TOTAL_AGENTS=$(jq '.agents | length' .claude-plugin/plugin.json)

# --- Skills ---
git show "$PREV_TAG:.claude-plugin/plugin.json" | jq -r '.skills[]' | sort > /tmp/pb_prev_skills.txt
jq -r '.skills[]' .claude-plugin/plugin.json | sort > /tmp/pb_curr_skills.txt

# New skills = in current but not in previous
NEW_SKILLS=$(comm -23 /tmp/pb_curr_skills.txt /tmp/pb_prev_skills.txt | wc -l | tr -d ' ')

# Updated skills = in both, but SKILL.md changed
UPDATED_SKILLS=0
while IFS= read -r skill; do
  clean="${skill#./}"
  if ! git diff --quiet "$PREV_TAG" HEAD -- "$clean/SKILL.md" 2>/dev/null; then
    ((UPDATED_SKILLS++)) || true
  fi
done < <(comm -12 /tmp/pb_curr_skills.txt /tmp/pb_prev_skills.txt)

# --- Agents ---
NEW_AGENTS=$(git diff --diff-filter=A --name-only "$PREV_TAG" HEAD -- agents/ 2>/dev/null | wc -l | tr -d ' ')
UPDATED_AGENTS=$(git diff --diff-filter=M --name-only "$PREV_TAG" HEAD -- agents/ 2>/dev/null | wc -l | tr -d ' ')

# --- Build summary ---
SKILL_NOTE=""
if [ "$NEW_SKILLS" -gt 0 ] || [ "$UPDATED_SKILLS" -gt 0 ]; then
  parts=()
  [ "$NEW_SKILLS" -gt 0 ] && parts+=("$NEW_SKILLS new")
  [ "$UPDATED_SKILLS" -gt 0 ] && parts+=("$UPDATED_SKILLS updated")
  SKILL_NOTE=" (${parts[*]})"
fi

AGENT_NOTE=""
if [ "$NEW_AGENTS" -gt 0 ] || [ "$UPDATED_AGENTS" -gt 0 ]; then
  parts=()
  [ "$NEW_AGENTS" -gt 0 ] && parts+=("$NEW_AGENTS new")
  [ "$UPDATED_AGENTS" -gt 0 ] && parts+=("$UPDATED_AGENTS updated")
  AGENT_NOTE=" (${parts[*]})"
fi

echo "This release includes **${TOTAL_SKILLS} skills${SKILL_NOTE}** and **${TOTAL_AGENTS} agents${AGENT_NOTE}** for .NET development."

# Cleanup
rm -f /tmp/pb_prev_skills.txt /tmp/pb_curr_skills.txt