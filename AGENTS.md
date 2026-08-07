# AGENTS.md

This repo supports Claude Code, Codex, and OpenCode.

When adding/removing skills or agents, keep the router/index snippets up to date so downstream repos can copy/paste them.

Reference:
- `skills/meta/skills-index-snippets/SKILL.md`

Maintenance:
1. Update `.claude-plugin/plugin.json`
2. Run `./scripts/validate-marketplace.sh`
3. Run `./scripts/validate-codex-plugin.sh` (Codex manifest + marketplace, version lockstep with Claude plugin)
4. Regenerate the compressed index: `./scripts/generate-skill-index-snippets.sh`
