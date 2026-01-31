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
│   ├── marketplace.json    # Marketplace catalog (lists all plugins)
│   └── plugin.json         # Root plugin metadata
├── plugins/                    # Each category is a separate installable plugin
│   ├── akka/
│   │   ├── .claude-plugin/
│   │   │   └── plugin.json     # Plugin-specific metadata (required)
│   │   ├── skills/             # Skills for this plugin
│   │   │   ├── best-practices/SKILL.md
│   │   │   └── ...
│   │   └── agents/             # Agents for this plugin
│   │       ├── akka-net-specialist.md
│   │       └── docfx-specialist.md
│   ├── csharp/
│   ├── testing/
│   └── ...
└── scripts/                    # Validation and sync scripts
```

## Plugins

The marketplace contains 9 category-based plugins:

| Plugin | Skills | Agents |
|--------|--------|--------|
| akka | 5 | 2 |
| aspire | 2 | 0 |
| aspnetcore | 1 | 0 |
| csharp | 4 | 1 |
| data | 2 | 0 |
| dotnet | 5 | 0 |
| meta | 2 | 0 |
| microsoft-extensions | 2 | 0 |
| testing | 4 | 2 |

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

1. Create a folder under the appropriate plugin: `plugins/<plugin>/skills/<skill-name>/SKILL.md`
2. Skill will be auto-discovered when the plugin is installed
3. Commit your changes

## Adding New Agents

1. Create the agent file: `plugins/<plugin>/agents/<agent-name>.md`
2. Agent will be auto-discovered when the plugin is installed
3. Commit your changes

## Adding a New Plugin (Category)

1. Create the plugin directory: `plugins/<plugin-name>/`
2. Create the plugin metadata: `plugins/<plugin-name>/.claude-plugin/plugin.json`:
   ```json
   {
     "name": "<plugin-name>",
     "description": "Description of the plugin",
     "version": "1.0.0",
     "author": {
       "name": "Author Name",
       "url": "https://github.com/username"
     }
   }
   ```
3. Create skills folder: `plugins/<plugin-name>/skills/`
4. Add at least one skill: `plugins/<plugin-name>/skills/<skill-name>/SKILL.md`
5. Register in marketplace: Add entry to `.claude-plugin/marketplace.json`:
   ```json
   {
     "name": "<plugin-name>",
     "source": "./plugins/<plugin-name>",
     "version": "1.0.0",
     "description": "Description of the plugin"
   }
   ```

## Marketplace Publishing

**Users install with:**
```bash
# Add the marketplace (one-time)
/plugin marketplace add Aaronontheweb/dotnet-skills

# Install specific plugins
/plugin install akka@dotnet-skills
/plugin install csharp@dotnet-skills
/plugin install testing@dotnet-skills
```

## Content Guidelines

- Skills should be comprehensive reference documents (10-40KB)
- Include concrete code examples with modern C# patterns
- Reference authoritative sources rather than duplicating content
- Agents define personas with expertise areas and diagnostic approaches


## Router / Index Snippets

When skills/agents change, keep the copy/paste snippet indexes up to date:
- See `plugins/meta/skills/skills-index-snippets/SKILL.md`
- Generate a compressed index with `./scripts/generate-skill-index-snippets.sh`
