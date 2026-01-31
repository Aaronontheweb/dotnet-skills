# AGENTS.md

This repo supports Claude Code, OpenCode, and GitHub Copilot.

When adding/removing skills or agents, keep the router/index snippets up to date so downstream repos can copy/paste them.

## Structure

Each category is a separate plugin with its own skills and agents:

```
plugins/
├── akka/
├── csharp/
├── testing/
└── ...
```

## Adding Skills/Agents

1. Skills: Create `plugins/<plugin>/skills/<skill-name>/SKILL.md`
2. Agents: Create `plugins/<plugin>/agents/<agent-name>.md`
3. They auto-discover when plugin is installed

## Adding a New Plugin

1. Create directory: `plugins/<plugin-name>/`
2. Create plugin metadata: `plugins/<plugin-name>/.claude-plugin/plugin.json`
   ```json
   { "name": "<plugin-name>", "description": "...", "version": "1.0.0", "author": { "name": "...", "url": "..." } }
   ```
3. Create skills folder: `plugins/<plugin-name>/skills/`
4. Add at least one skill
5. Register in `.claude-plugin/marketplace.json`:
   ```json
   { "name": "<plugin-name>", "source": "./plugins/<plugin-name>", "version": "1.0.0", "description": "..." }
   ```

## Maintenance

1. Run `./scripts/validate-marketplace.sh` to verify structure
2. Run `./scripts/generate-skill-index-snippets.sh --update-readme` to update README index
