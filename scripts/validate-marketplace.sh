#!/bin/bash
# Validates that marketplace.json plugins are consistent with actual skill/agent files

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"
PLUGIN_JSON="$REPO_ROOT/.claude-plugin/plugin.json"
MARKETPLACE_JSON="$REPO_ROOT/.claude-plugin/marketplace.json"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

errors=0
warnings=0
total_skills=0
total_agents=0

echo "Validating marketplace structure..."
echo ""

# Check JSON syntax
if ! jq . "$MARKETPLACE_JSON" > /dev/null 2>&1; then
    echo -e "${RED}ERROR: Invalid JSON syntax in marketplace.json${NC}"
    exit 1
fi
echo -e "${GREEN}marketplace.json syntax: OK${NC}"

if ! jq . "$PLUGIN_JSON" > /dev/null 2>&1; then
    echo -e "${RED}ERROR: Invalid JSON syntax in plugin.json${NC}"
    exit 1
fi
echo -e "${GREEN}plugin.json syntax: OK${NC}"

# Iterate through each plugin in marketplace.json
echo ""
echo "Checking plugins..."
while IFS= read -r plugin_entry; do
    plugin_name=$(echo "$plugin_entry" | jq -r '.name')
    plugin_source=$(echo "$plugin_entry" | jq -r '.source')

    # Remove leading ./ if present
    clean_source="${plugin_source#./}"
    plugin_dir="$REPO_ROOT/$clean_source"

    echo ""
    echo "=== Plugin: $plugin_name ==="

    if [ ! -d "$plugin_dir" ]; then
        echo -e "${RED}ERROR: Plugin directory not found: $plugin_dir${NC}"
        ((++errors))
        continue
    fi

    # Check plugin.json exists and is valid
    plugin_config="$plugin_dir/.claude-plugin/plugin.json"
    if [ ! -f "$plugin_config" ]; then
        echo -e "${RED}ERROR: Missing plugin.json: $plugin_config${NC}"
        ((++errors))
    elif ! jq . "$plugin_config" > /dev/null 2>&1; then
        echo -e "${RED}ERROR: Invalid JSON syntax in $plugin_config${NC}"
        ((++errors))
    else
        echo -e "${GREEN}  plugin.json: OK${NC}"
    fi

    # Check skills in this plugin
    skills_dir="$plugin_dir/skills"
    if [ -d "$skills_dir" ]; then
        skill_count=0
        for skill_path in "$skills_dir"/*/SKILL.md; do
            if [ -f "$skill_path" ]; then
                skill_name=$(grep "^name:" "$skill_path" | head -1 | sed 's/^name: *//')
                echo -e "${GREEN}  Skill: $skill_name${NC}"
                ((++skill_count))
                ((++total_skills))
            fi
        done
        echo "  Skills found: $skill_count"
    else
        echo -e "${YELLOW}  No skills directory${NC}"
    fi

    # Check agents in this plugin
    agents_dir="$plugin_dir/agents"
    if [ -d "$agents_dir" ]; then
        agent_count=0
        for agent_path in "$agents_dir"/*.md; do
            if [ -f "$agent_path" ]; then
                agent_name=$(grep "^name:" "$agent_path" | head -1 | sed 's/^name: *//')
                echo -e "${GREEN}  Agent: $agent_name${NC}"
                ((++agent_count))
                ((++total_agents))
            fi
        done
        echo "  Agents found: $agent_count"
    fi

done < <(jq -c '.plugins[]' "$MARKETPLACE_JSON")

# Summary
echo ""
echo "=== Summary ==="
echo "Plugins: $(jq '.plugins | length' "$MARKETPLACE_JSON")"
echo "Total skills: $total_skills"
echo "Total agents: $total_agents"
echo "Marketplace version: $(jq -r '.plugins[0].version // "1.0.0"' "$MARKETPLACE_JSON")"

if [ $errors -gt 0 ]; then
    echo -e "${RED}Errors: $errors${NC}"
    exit 1
fi

if [ $warnings -gt 0 ]; then
    echo -e "${YELLOW}Warnings: $warnings${NC}"
fi

echo -e "${GREEN}Validation passed!${NC}"
