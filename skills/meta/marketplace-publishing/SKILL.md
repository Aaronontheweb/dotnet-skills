---
name: marketplace-publishing
description: Workflow for publishing skills and agents to the dotnet-skills Claude Code marketplace. Covers adding new content, updating plugin.json, validation, and release tagging.
invocable: true
---

# Marketplace Publishing Workflow

This skill documents how to publish skills and agents to the dotnet-skills Claude Code marketplace.

## Repository Structure

```
dotnet-skills/
├── .claude-plugin/
│   ├── marketplace.json      # Marketplace catalog
│   └── plugin.json           # Plugin metadata + skill/agent registry
├── .github/workflows/
│   └── release.yml           # Release automation
├── skills/
│   ├── akka/                 # Akka.NET skills
│   │   ├── best-practices/SKILL.md
│   │   ├── testing-patterns/SKILL.md
│   │   └── ...
│   ├── aspire/               # .NET Aspire skills
│   ├── csharp/               # C# language skills
│   ├── testing/              # Testing framework skills
│   └── meta/                 # Meta skills
├── agents/
│   └── *.md                  # Agent definitions
└── scripts/
    └── validate-marketplace.sh
```

## Adding a New Skill

### Step 1: Choose a Category

Skills are organized by domain:

| Category | Purpose |
|----------|---------|
| `akka/` | Akka.NET actor patterns, testing, clustering |
| `aspire/` | .NET Aspire orchestration, testing, configuration |
| `csharp/` | C# language features, coding standards |
| `testing/` | Testing frameworks (xUnit, Playwright, Testcontainers) |
| `meta/` | Meta skills about this marketplace |

Create a new category folder if none fits.

### Step 2: Create the Skill Folder

Create a folder with `SKILL.md` inside:

```
skills/<category>/<skill-name>/SKILL.md
```

Example: `skills/akka/cluster-sharding/SKILL.md`

### Step 3: Write the SKILL.md

```markdown
---
name: my-new-skill
description: Brief description of what this skill does and when to use it.
---

# My New Skill

## When to Use This Skill

Use this skill when:
- [List specific scenarios]

---

## Content

[Comprehensive guide with examples, patterns, and anti-patterns]
```

**Requirements:**
- `name` must be lowercase with hyphens (e.g., `cluster-sharding`)
- `description` should be 1-2 sentences explaining when Claude should use this skill
- Content should be 10-40KB covering the topic comprehensively
- Include concrete code examples with modern C# patterns

### Step 4: Register in plugin.json

Add the skill path to `.claude-plugin/plugin.json` in the `skills` array:

```json
{
  "skills": [
    "./skills/akka/best-practices",
    "./skills/akka/cluster-sharding"  // Add new skill here
  ]
}
```

### Step 5: Validate

Run the validation script:

```bash
./scripts/validate-marketplace.sh
```

### Step 6: Commit Together

```bash
git add skills/akka/cluster-sharding/ .claude-plugin/plugin.json
git commit -m "Add cluster-sharding skill for Akka.NET Cluster Sharding patterns"
```

---

## Adding a New Agent

### Step 1: Create the Agent File

Create a markdown file in `/agents/`:

```markdown
---
name: my-agent-name
description: Expert in [domain]. Specializes in [specific areas]. Use for [scenarios].
model: sonnet
color: blue
---

You are a [domain] specialist with deep expertise in [areas].

**Reference Materials:**
- [Official docs and resources]

**Core Expertise Areas:**
[List expertise areas]

**Diagnostic Approach:**
[How the agent analyzes problems]
```

**Requirements:**
- `name` must be lowercase with hyphens
- `model` must be one of: `haiku`, `sonnet`, `opus`
- `color` is optional (used for UI display)

### Step 2: Register in plugin.json

Add to the `agents` array:

```json
{
  "agents": [
    "./agents/akka-net-specialist",
    "./agents/my-agent-name"  // Add new agent here
  ]
}
```

### Step 3: Commit Together

```bash
git add agents/my-agent-name.md .claude-plugin/plugin.json
git commit -m "Add my-agent-name agent for [domain] expertise"
```

---

## Publishing a Release

### Versioning

Update the version in `.claude-plugin/plugin.json`:

```json
{
  "version": "1.1.0"
}
```

Use semantic versioning (`MAJOR.MINOR.PATCH`):
- **MAJOR**: Breaking changes (renamed/removed skills)
- **MINOR**: New skills or agents added
- **PATCH**: Fixes or improvements to existing content

### Release Process

1. **Update version in plugin.json**

2. **Validate**
   ```bash
   ./scripts/validate-marketplace.sh
   ```

3. **Commit version bump**
   ```bash
   git add .claude-plugin/plugin.json
   git commit -m "Bump version to 1.1.0"
   ```

4. **Create and push tag**
   ```bash
   git tag v1.1.0
   git push origin master --tags
   ```

5. **GitHub Actions will automatically:**
   - Validate the marketplace structure
   - Create a GitHub release with auto-generated notes

---

## User Installation

Users install the complete plugin (all skills and agents):

```bash
# Add the marketplace (one-time)
/plugin marketplace add Aaronontheweb/dotnet-skills

# Install the plugin (gets everything)
/plugin install dotnet-skills

# Update to latest version
/plugin marketplace update
```

---

## Validation Checklist

Before committing:

- [ ] SKILL.md has valid YAML frontmatter with `name` and `description`
- [ ] Skill folder is under appropriate category
- [ ] Path added to `plugin.json` skills array
- [ ] For agents: `model` is specified (haiku/sonnet/opus)
- [ ] `./scripts/validate-marketplace.sh` passes

---

## Troubleshooting

### Skill not appearing after install

- Verify the path in plugin.json matches the folder structure
- Check that SKILL.md exists in the folder
- Try reinstalling: `/plugin uninstall dotnet-skills && /plugin install dotnet-skills`

### Validation errors

- Ensure JSON is valid: `jq . .claude-plugin/plugin.json`
- Check for trailing commas in arrays
- Verify all referenced folders contain SKILL.md

### Release not created

- Ensure tag follows semver format (`v1.0.0`)
- Check GitHub Actions logs for errors
- Verify plugin.json version matches the tag
