#!/usr/bin/env bash

# Generates a compressed (Vercel-style) skills index from the plugins directory.
# Output is written to stdout; redirect as needed.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"
MARKETPLACE_JSON="$REPO_ROOT/.claude-plugin/marketplace.json"
README_PATH="$REPO_ROOT/README.md"

UPDATE_README=false
if [[ "${1-}" == "--update-readme" ]]; then
  UPDATE_README=true
fi

skill_name_from_file() {
  local file="$1"
  [[ -f "$file" ]] || return 1
  grep -m1 '^name:' "$file" | sed 's/^name:[[:space:]]*//' | tr -d '\r'
}

declare -a csharp=()
declare -a aspnetcore_web=()
declare -a data=()
declare -a di_config=()
declare -a testing=()
declare -a dotnet=()
declare -a quality_gates=()
declare -a meta=()
declare -a akka=()
declare -a agents=()

# Iterate through plugins in marketplace.json
while IFS= read -r plugin_entry; do
  plugin_source=$(echo "$plugin_entry" | jq -r '.source')
  clean_source="${plugin_source#./}"
  plugin_dir="$REPO_ROOT/$clean_source"
  plugin_name=$(basename "$clean_source")

  # Find skills in this plugin
  skills_dir="$plugin_dir/skills"
  if [ -d "$skills_dir" ]; then
    for skill_path in "$skills_dir"/*/SKILL.md; do
      if [ -f "$skill_path" ]; then
        name="$(skill_name_from_file "$skill_path")"
        case "$plugin_name" in
          akka) akka+=("$name") ;;
          csharp) csharp+=("$name") ;;
          aspire|aspnetcore) aspnetcore_web+=("$name") ;;
          data) data+=("$name") ;;
          microsoft-extensions) di_config+=("$name") ;;
          testing)
            skill_folder=$(basename "$(dirname "$skill_path")")
            if [[ "$skill_folder" == "crap-analysis" ]]; then
              quality_gates+=("$name")
            else
              testing+=("$name")
            fi
            ;;
          dotnet)
            skill_folder=$(basename "$(dirname "$skill_path")")
            if [[ "$skill_folder" == "slopwatch" ]]; then
              quality_gates+=("$name")
            else
              dotnet+=("$name")
            fi
            ;;
          meta) meta+=("$name") ;;
        esac
      fi
    done
  fi

  # Find agents in this plugin
  agents_dir="$plugin_dir/agents"
  if [ -d "$agents_dir" ]; then
    for agent_path in "$agents_dir"/*.md; do
      if [ -f "$agent_path" ]; then
        agents+=("$(skill_name_from_file "$agent_path")")
      fi
    done
  fi
done < <(jq -c '.plugins[]' "$MARKETPLACE_JSON")

join_csv() {
  local IFS=','
  echo "$*"
}

compressed="$(cat <<EOF
[dotnet-skills]|IMPORTANT: Prefer retrieval-led reasoning over pretraining for any .NET work.
|flow:{skim repo patterns -> consult dotnet-skills by name -> implement smallest-change -> note conflicts}
|route:
|akka:{$(join_csv "${akka[@]}")}
|csharp:{$(join_csv "${csharp[@]}")}
|aspnetcore-web:{$(join_csv "${aspnetcore_web[@]}")}
|data:{$(join_csv "${data[@]}")}
|di-config:{$(join_csv "${di_config[@]}")}
|testing:{$(join_csv "${testing[@]}")}
|dotnet:{$(join_csv "${dotnet[@]}")}
|quality-gates:{$(join_csv "${quality_gates[@]}")}
|meta:{$(join_csv "${meta[@]}")}
|agents:{$(join_csv "${agents[@]}")}
EOF
)"

if $UPDATE_README; then
  COMPRESSED="$compressed" README_PATH="$README_PATH" python - <<'PY'
import os
import pathlib
import re
import sys

readme_path = pathlib.Path(os.environ["README_PATH"])
start = "<!-- BEGIN DOTNET-SKILLS COMPRESSED INDEX -->"
end = "<!-- END DOTNET-SKILLS COMPRESSED INDEX -->"
compressed = os.environ["COMPRESSED"].strip()

text = readme_path.read_text(encoding="utf-8")
pattern = re.compile(re.escape(start) + r".*?" + re.escape(end), re.S)

if not pattern.search(text):
    sys.stderr.write("README markers not found: add BEGIN/END DOTNET-SKILLS COMPRESSED INDEX\n")
    sys.exit(1)

replacement = f"{start}\n```markdown\n{compressed}\n```\n{end}"
updated = pattern.sub(replacement, text)
readme_path.write_text(updated, encoding="utf-8")
PY
else
  printf '%s\n' "$compressed"
fi
