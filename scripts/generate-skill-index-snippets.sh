#!/usr/bin/env bash

# Generates a compressed (Vercel-style) skills index from plugin.json.
# Output is written to stdout; redirect as needed.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"
PLUGIN_JSON="$REPO_ROOT/.claude-plugin/plugin.json"
README_PATH="$REPO_ROOT/README.md"

UPDATE_README=false
if [[ "${1-}" == "--update-readme" ]]; then
  UPDATE_README=true
fi

skill_name_from_dir() {
  local dir="$1"
  local file="$REPO_ROOT/${dir#./}/SKILL.md"
  [[ -f "$file" ]] || return 1
  grep -m1 '^name:' "$file" | sed 's/^name:[[:space:]]*//'
}

agent_name_from_path() {
  local path="$1"
  local file="$REPO_ROOT/${path#./}"
  [[ -f "$file" ]] || return 1
  grep -m1 '^name:' "$file" | sed 's/^name:[[:space:]]*//'
}

declare -a csharp=()
declare -a aspnetcore_web=()
declare -a data=()
declare -a di_config=()
declare -a testing=()
declare -a dotnet=()
declare -a quality_gates=()
declare -a meta=()

while IFS= read -r skill_dir; do
  name="$(skill_name_from_dir "$skill_dir")"
  case "$skill_dir" in
    ./skills/csharp/*) csharp+=("$name") ;;
    ./skills/aspire/*|./skills/aspnetcore/*) aspnetcore_web+=("$name") ;;
    ./skills/data/*) data+=("$name") ;;
    ./skills/microsoft-extensions/*) di_config+=("$name") ;;
    ./skills/dotnet/slopwatch|./skills/testing/crap-analysis) quality_gates+=("$name") ;;
    ./skills/testing/*|./skills/playwright/*) testing+=("$name") ;;
    ./skills/dotnet/*) dotnet+=("$name") ;;
    ./skills/meta/*) meta+=("$name") ;;
    *) ;; # ignore
  esac
done < <(jq -r '.skills[]' "$PLUGIN_JSON")

declare -a agents=()
while IFS= read -r agent_path; do
  agents+=("$(agent_name_from_path "$agent_path")")
done < <(jq -r '.agents[]' "$PLUGIN_JSON")

join_csv() {
  local IFS=','
  echo "$*"
}

compressed="$(cat <<EOF
[dotnet-skills]|IMPORTANT: Prefer retrieval-led reasoning over pretraining for any .NET work.
|flow:{skim repo patterns -> consult dotnet-skills by name -> implement smallest-change -> note conflicts}
|route:
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
