#!/bin/bash
# Validates the Codex plugin (.codex-plugin/plugin.json) and repo
# marketplace (.agents/plugins/marketplace.json) for consistency with
# the skills on disk and lockstep with the Claude plugin.

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"
CODEX_PLUGIN_JSON="$REPO_ROOT/.codex-plugin/plugin.json"
CODEX_MARKETPLACE_JSON="$REPO_ROOT/.agents/plugins/marketplace.json"
CLAUDE_PLUGIN_JSON="$REPO_ROOT/.claude-plugin/plugin.json"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

errors=0
warnings=0

echo "Validating Codex plugin structure..."
echo ""

# Check JSON syntax
for f in "$CODEX_PLUGIN_JSON" "$CODEX_MARKETPLACE_JSON"; do
    if [ ! -f "$f" ]; then
        echo -e "${RED}ERROR: Missing file: $f${NC}"
        exit 1
    fi
    if ! jq . "$f" > /dev/null 2>&1; then
        echo -e "${RED}ERROR: Invalid JSON syntax in $f${NC}"
        exit 1
    fi
    echo -e "${GREEN}$(basename "$f") syntax: OK${NC}"
done

# Check required plugin manifest fields
echo ""
echo "Checking plugin manifest fields..."
for field in name version description skills; do
    if ! jq -e ".$field" "$CODEX_PLUGIN_JSON" > /dev/null 2>&1; then
        echo -e "${RED}ERROR: Missing required field '$field' in .codex-plugin/plugin.json${NC}"
        ((++errors))
    fi
done

# Plugin name must be kebab-case
plugin_name=$(jq -r '.name' "$CODEX_PLUGIN_JSON")
if ! echo "$plugin_name" | grep -qE '^[a-z0-9]+(-[a-z0-9]+)*$'; then
    echo -e "${RED}ERROR: Plugin name '$plugin_name' is not kebab-case${NC}"
    ((++errors))
else
    echo -e "${GREEN}Plugin name: $plugin_name${NC}"
fi

# Version must be semver
plugin_version=$(jq -r '.version' "$CODEX_PLUGIN_JSON")
if ! echo "$plugin_version" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.-]+)?$'; then
    echo -e "${RED}ERROR: Plugin version '$plugin_version' is not semver${NC}"
    ((++errors))
fi

# Version must match the Claude plugin (lockstep releases)
if [ -f "$CLAUDE_PLUGIN_JSON" ]; then
    claude_version=$(jq -r '.version' "$CLAUDE_PLUGIN_JSON")
    if [ "$plugin_version" != "$claude_version" ]; then
        echo -e "${RED}ERROR: Version mismatch - Codex: $plugin_version, Claude: $claude_version${NC}"
        echo -e "${RED}       Both manifests must be bumped together in lockstep.${NC}"
        ((++errors))
    else
        echo -e "${GREEN}Version lockstep OK: $plugin_version${NC}"
    fi
fi

# Check skills directory reference
echo ""
echo "Checking skills..."
skills_value=$(jq -r '.skills' "$CODEX_PLUGIN_JSON")
clean_skills="${skills_value#./}"
skills_dir="$REPO_ROOT/$clean_skills"

if [ ! -d "$skills_dir" ]; then
    echo -e "${RED}ERROR: Skills directory not found: $skills_dir${NC}"
    ((++errors))
else
    skill_count=$(find "$skills_dir" -maxdepth 2 -name "SKILL.md" 2>/dev/null | wc -l)
    if [ "$skill_count" -eq 0 ]; then
        echo -e "${RED}ERROR: No SKILL.md files found under $skills_dir${NC}"
        ((++errors))
    else
        echo -e "${GREEN}Skills directory OK: $skills_value ($skill_count SKILL.md files)${NC}"
    fi

    # Check YAML frontmatter (name + description required by Codex spec)
    while IFS= read -r file; do
        if ! head -1 "$file" | grep -q "^---$"; then
            echo -e "${RED}ERROR: Missing YAML frontmatter in $file${NC}"
            ((++errors))
        fi
        if ! grep -q "^name:" "$file"; then
            echo -e "${RED}ERROR: Missing 'name' in $file${NC}"
            ((++errors))
        fi
        if ! grep -q "^description:" "$file"; then
            echo -e "${RED}ERROR: Missing 'description' in $file${NC}"
            ((++errors))
        fi
    done < <(find "$skills_dir" -maxdepth 2 -name "SKILL.md" 2>/dev/null)
fi

# Check marketplace structure
echo ""
echo "Checking marketplace..."
if ! jq -e '.name' "$CODEX_MARKETPLACE_JSON" > /dev/null 2>&1; then
    echo -e "${RED}ERROR: Marketplace missing 'name'${NC}"
    ((++errors))
fi

plugin_count=$(jq '.plugins | length' "$CODEX_MARKETPLACE_JSON" 2>/dev/null || echo 0)
if [ "$plugin_count" -eq 0 ]; then
    echo -e "${RED}ERROR: Marketplace has no plugins${NC}"
    ((++errors))
fi

# Each plugin entry must resolve to a dir containing .codex-plugin/plugin.json
while IFS= read -r entry; do
    entry_name=$(echo "$entry" | jq -r '.name')
    entry_path=$(echo "$entry" | jq -r '.source.path // empty')
    entry_source=$(echo "$entry" | jq -r '.source.source // empty')
    entry_install=$(echo "$entry" | jq -r '.policy.installation // empty')
    entry_auth=$(echo "$entry" | jq -r '.policy.authentication // empty')
    entry_category=$(echo "$entry" | jq -r '.category // empty')

    if [ -z "$entry_name" ]; then
        echo -e "${RED}ERROR: Marketplace plugin entry missing 'name'${NC}"
        ((++errors))
    fi
    if [ "$entry_source" != "local" ]; then
        echo -e "${RED}ERROR: Plugin '$entry_name' source must be 'local', got '$entry_source'${NC}"
        ((++errors))
    fi
    if ! echo "$entry_path" | grep -q '^\./'; then
        echo -e "${RED}ERROR: Plugin '$entry_name' source.path must start with './'${NC}"
        ((++errors))
    fi
    if [ -z "$entry_install" ] || [ -z "$entry_auth" ] || [ -z "$entry_category" ]; then
        echo -e "${RED}ERROR: Plugin '$entry_name' must set policy.installation, policy.authentication, and category${NC}"
        ((++errors))
    fi

    # Resolve path relative to marketplace root (repo root, not .agents/plugins/)
    if [ -n "$entry_path" ]; then
        clean_path="${entry_path#./}"
        resolved="$REPO_ROOT/$clean_path"
        if [ ! -f "$resolved/.codex-plugin/plugin.json" ]; then
            echo -e "${RED}ERROR: Plugin '$entry_name' path '$entry_path' has no .codex-plugin/plugin.json${NC}"
            ((++errors))
        else
            echo -e "${GREEN}OK: plugin '$entry_name' -> $entry_path${NC}"
        fi
    fi
done < <(jq -c '.plugins[]' "$CODEX_MARKETPLACE_JSON")

# Cross-check skill parity with the Claude manifest: every skill registered
# there must exist on disk (Codex auto-includes the whole skills dir, so the
# Claude manifest is the one that can drift).
echo ""
echo "Checking Claude manifest parity..."
if [ -f "$CLAUDE_PLUGIN_JSON" ]; then
    claude_skills=$(jq -r '.skills[]' "$CLAUDE_PLUGIN_JSON" 2>/dev/null)
    if [ -n "$claude_skills" ]; then
        while IFS= read -r source; do
            clean_source="${source#./}"
            if [ ! -f "$REPO_ROOT/$clean_source/SKILL.md" ]; then
                echo -e "${RED}ERROR: Claude manifest references missing skill: $source${NC}"
                ((++errors))
            fi
        done <<< "$claude_skills"
    fi
fi

# Summary
echo ""
echo "=== Summary ==="
echo "Codex plugin: $plugin_name@$plugin_version"
echo "Skills: $(jq -r '.skills' "$CODEX_PLUGIN_JSON")"
echo "Marketplace plugins: $plugin_count"

if [ $errors -gt 0 ]; then
    echo -e "${RED}Errors: $errors${NC}"
    exit 1
fi

if [ $warnings -gt 0 ]; then
    echo -e "${YELLOW}Warnings: $warnings${NC}"
fi

echo -e "${GREEN}Codex validation passed!${NC}"
