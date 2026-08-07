# AGENTS.md

This file provides guidance to AI coding agents (Claude Code, Codex, OpenCode, and others) when working in this repository. It is the canonical file; `CLAUDE.md` is a symlink to it.

## Repository Purpose

**Canonical repository:** https://github.com/Aaronontheweb/dotnet-skills

This is the official marketplace for .NET development skills and agents, covering the entire .NET ecosystem: C#, F#, MSBuild, NuGet, Aspire, testing frameworks, and specialized tools like DocFX and BenchmarkDotNet.

This is a knowledge base repository - not a traditional code project. There is no build system, tests, or compiled output.

## Structure

```
dotnet-skills/
├── .claude-plugin/
│   ├── marketplace.json    # Claude Code marketplace catalog
│   └── plugin.json         # Claude Code plugin metadata + skill/agent registry
├── .codex-plugin/
│   └── plugin.json         # Codex plugin metadata (skills auto-discovered from ./skills/)
├── .agents/
│   └── plugins/
│       └── marketplace.json  # Codex marketplace
├── skills/                 # Flat structure for Copilot compatibility
│   ├── akka-best-practices/SKILL.md
│   ├── aspire-integration-testing/SKILL.md
│   ├── csharp-coding-standards/SKILL.md
│   ├── testcontainers/SKILL.md
│   └── ...
├── agents/                 # Agent definitions (flat .md files, Claude Code only)
└── scripts/                # Validation and sync scripts
```

### Skill Naming Convention

Skills use a flat directory structure with prefixes for framework-specific skills:
- `akka-*` - Akka.NET skills
- `aspire-*` - .NET Aspire skills
- `csharp-*` - C# language skills
- `microsoft-extensions-*` - Microsoft.Extensions.* packages
- `playwright-*` - Playwright-specific skills
- No prefix for general .NET skills (e.g., `testcontainers`, `efcore-patterns`)

## File Formats

**Skills** are folders with `SKILL.md`:
```yaml
---
name: skill-name
description: Brief description used for matching
---
```

**Agents** are markdown files with YAML frontmatter:
```yaml
---
name: agent-name
description: Brief description used for matching
model: sonnet  # sonnet, opus, or haiku
color: purple  # optional
---
```

## Adding New Skills

1. Create a folder: `skills/<skill-name>/SKILL.md`
   - Use appropriate prefix for framework-specific skills (see naming convention above)
   - No prefix for general .NET skills
2. Add the skill path to `.claude-plugin/plugin.json` in the `skills` array
   - The Codex plugin (`.codex-plugin/plugin.json`) auto-discovers the whole `skills/` dir — no manifest change needed there
3. Run `./scripts/validate-marketplace.sh` to verify
4. Run `./scripts/validate-codex-plugin.sh` to verify the Codex plugin (frontmatter, version lockstep)
5. Run `./scripts/generate-skill-index-snippets.sh --update-readme` to regenerate the compressed index
6. Commit all changes together (SKILL.md, plugin.json, and README.md)

### Adding Skills to Index Categories

When adding a skill with a **new prefix pattern**, update `scripts/generate-skill-index-snippets.sh` to handle the new pattern in its `case` statement. Otherwise the skill will be silently ignored when generating the index.

## Adding New Agents

1. Create the agent file: `agents/<agent-name>.md`
2. Add the agent path to `.claude-plugin/plugin.json` in the `agents` array
3. Run `./scripts/validate-marketplace.sh` to verify
4. Run `./scripts/generate-skill-index-snippets.sh --update-readme` to regenerate the compressed index
5. Commit all changes together (agent .md, plugin.json, and README.md)

## Marketplace Publishing

**To publish a release:**
1. Bump versions with `./scripts/bump-version.sh <version>` — updates `.claude-plugin/plugin.json` **and** `.codex-plugin/plugin.json` together and runs the lockstep validator. Never edit the version fields by hand.
2. Update `RELEASE_NOTES.md`
3. Push a semver tag: `git tag v<version> && git push origin v<version>` — CI verifies the tag matches both manifests, then creates the release automatically

**Users install with:**
```bash
# Claude Code
/plugin marketplace add Aaronontheweb/dotnet-skills
/plugin install dotnet-skills

# Codex
codex plugin marketplace add Aaronontheweb/dotnet-skills
codex plugin add dotnet-skills@dotnet-skills
```

See `skills/marketplace-publishing/SKILL.md` for detailed workflow.

## Content Guidelines

- Skills should be comprehensive reference documents (10-40KB)
- Include concrete code examples with modern C# patterns
- Reference authoritative sources rather than duplicating content
- Agents define personas with expertise areas and diagnostic approaches

## Router / Index Snippets

When skills/agents change, keep the copy/paste snippet indexes up to date:
- See `skills/skills-index-snippets/SKILL.md`
- Generate a compressed index with `./scripts/generate-skill-index-snippets.sh`

## Maintenance

1. Update `.claude-plugin/plugin.json` when skills/agents change
2. Run `./scripts/validate-marketplace.sh`
3. Run `./scripts/validate-codex-plugin.sh` (Codex manifest + marketplace, version lockstep with Claude plugin)
4. Regenerate the compressed index: `./scripts/generate-skill-index-snippets.sh`

Keep `CLAUDE.md` a symlink to this file — edits go here, never to the symlink target copy.
