# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Repository Purpose

**Canonical repository:** https://github.com/Aaronontheweb/dotnet-skills

This is the official Claude Code Marketplace for .NET development skills and agents. It covers the entire .NET ecosystem: C#, F#, MSBuild, NuGet, Aspire, testing frameworks, and specialized tools like DocFX and BenchmarkDotNet.

This is a knowledge base repository - not a traditional code project. There is no build system, tests, or compiled output.

## Structure

```
dotnet-skills/
├── .claude-plugin/
│   ├── marketplace.json    # Marketplace catalog
│   └── plugin.json         # Plugin metadata + skill/agent registry
├── skills/                 # Flat structure for Copilot compatibility
│   ├── akka-best-practices/SKILL.md
│   ├── aspire-integration-testing/SKILL.md
│   ├── csharp-coding-standards/SKILL.md
│   ├── testcontainers/SKILL.md
│   └── ...
├── agents/                 # Agent definitions (flat .md files)
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
3. Run `./scripts/validate-marketplace.sh` to verify
4. Run `./scripts/generate-skill-index-snippets.sh --update-readme` to regenerate the compressed index
5. Commit all changes together (SKILL.md, plugin.json, and README.md)

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
1. Update version in `.claude-plugin/plugin.json`
2. Push a semver tag: `git tag v1.0.0 && git push origin v1.0.0`
3. GitHub Actions creates the release automatically

**Users install with:**
```bash
/plugin marketplace add Aaronontheweb/dotnet-skills
/plugin install dotnet-skills
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
