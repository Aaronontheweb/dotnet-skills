---
name: dotnet-local-tools
description: Managing local .NET tools with dotnet-tools.json for consistent tooling across development environments and CI/CD pipelines.
invocable: false
---

# .NET Local Tools

## When to Use This Skill

Use this skill when:
- Setting up consistent tooling across a development team
- Ensuring CI/CD pipelines use the same tool versions as local development
- Managing project-specific CLI tools (docfx, incrementalist, dotnet-ef, etc.)
- Avoiding global tool version conflicts between projects

## What Are Local Tools?

Local tools are .NET CLI tools that are installed and versioned per-repository rather than globally. They're defined in `.config/dotnet-tools.json` and restored with `dotnet tool restore`.

### Local vs Global Tools

| Aspect | Global Tools | Local Tools |
|--------|--------------|-------------|
| Installation | `dotnet tool install -g` | `dotnet tool restore` |
| Scope | Machine-wide | Per-repository |
| Version control | Manual | In `.config/dotnet-tools.json` |
| CI/CD | Must install each tool | Single restore command |
| Conflicts | Can have version conflicts | Isolated per project |

---

## Setting Up Local Tools

### Initialize the Manifest

```bash
# Create .config/dotnet-tools.json
dotnet new tool-manifest
```

This creates:
```
.config/
└── dotnet-tools.json
```

### Install Tools Locally

```bash
# Install a tool locally
dotnet tool install docfx

# Install specific version
dotnet tool install docfx --version 2.78.3

# Install from a specific source
dotnet tool install MyTool --add-source https://mycompany.pkgs.visualstudio.com/_packaging/feed/nuget/v3/index.json
```

### Restore Tools

```bash
# Restore all tools from manifest
dotnet tool restore
```

---

## dotnet-tools.json Format

```json
{
  "version": 1,
  "isRoot": true,
  "tools": {
    "docfx": {
      "version": "2.78.3",
      "commands": [
        "docfx"
      ],
      "rollForward": false
    },
    "dotnet-ef": {
      "version": "9.0.0",
      "commands": [
        "dotnet-ef"
      ],
      "rollForward": false
    },
    "incrementalist.cmd": {
      "version": "1.2.0",
      "commands": [
        "incrementalist"
      ],
      "rollForward": false
    },
    "dotnet-reportgenerator-globaltool": {
      "version": "5.4.1",
      "commands": [
        "reportgenerator"
      ],
      "rollForward": false
    }
  }
}
```

### Fields

| Field | Description |
|-------|-------------|
| `version` | Manifest schema version (always 1) |
| `isRoot` | Marks this as the root manifest (prevents searching parent directories) |
| `tools` | Dictionary of tool configurations |
| `tools.<name>.version` | Exact version to install |
| `tools.<name>.commands` | CLI commands the tool provides |
| `tools.<name>.rollForward` | Allow newer versions (usually false for reproducibility) |

---

## Common Tools

### Documentation

```bash
# DocFX - API documentation generator
dotnet tool install docfx
```

```json
"docfx": {
  "version": "2.78.3",
  "commands": ["docfx"],
  "rollForward": false
}
```

**Usage:**
```bash
dotnet docfx docfx.json
dotnet docfx serve _site
```

### Entity Framework Core

```bash
# EF Core CLI for migrations
dotnet tool install dotnet-ef
```

```json
"dotnet-ef": {
  "version": "9.0.0",
  "commands": ["dotnet-ef"],
  "rollForward": false
}
```

**Usage:**
```bash
dotnet ef migrations add InitialCreate
dotnet ef database update
```

### Code Coverage

```bash
# ReportGenerator for coverage reports
dotnet tool install dotnet-reportgenerator-globaltool
```

```json
"dotnet-reportgenerator-globaltool": {
  "version": "5.4.1",
  "commands": ["reportgenerator"],
  "rollForward": false
}
```

**Usage:**
```bash
dotnet reportgenerator -reports:coverage.cobertura.xml -targetdir:coveragereport -reporttypes:Html
```

### Incremental Builds

```bash
# Incrementalist - build only changed projects
dotnet tool install incrementalist.cmd
```

```json
"incrementalist.cmd": {
  "version": "1.2.0",
  "commands": ["incrementalist"],
  "rollForward": false
}
```

**Usage:**
```bash
# Get projects affected by changes since main branch
incrementalist --branch main
```

### Code Formatting

```bash
# CSharpier - opinionated C# formatter
dotnet tool install csharpier
```

```json
"csharpier": {
  "version": "0.30.3",
  "commands": ["dotnet-csharpier"],
  "rollForward": false
}
```

**Usage:**
```bash
dotnet csharpier .
dotnet csharpier --check .  # CI mode - fails if changes needed
```

### Code Analysis

```bash
# JB dotnet-inspect (requires license)
dotnet tool install jb
```

```json
"jb": {
  "version": "2024.3.4",
  "commands": ["jb"],
  "rollForward": false
}
```

---

## CI/CD Integration

### GitHub Actions

```yaml
jobs:
  build:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4

      - name: Setup .NET
        uses: actions/setup-dotnet@v4
        with:
          global-json-file: global.json

      - name: Restore tools
        run: dotnet tool restore

      - name: Build
        run: dotnet build

      - name: Test with coverage
        run: dotnet test --collect:"XPlat Code Coverage"

      - name: Generate coverage report
        run: dotnet reportgenerator -reports:**/coverage.cobertura.xml -targetdir:coveragereport

      - name: Build documentation
        run: dotnet docfx docs/docfx.json
```

### Azure Pipelines

```yaml
steps:
  - task: UseDotNet@2
    inputs:
      useGlobalJson: true

  - script: dotnet tool restore
    displayName: 'Restore .NET tools'

  - script: dotnet build -c Release
    displayName: 'Build'

  - script: dotnet test -c Release --collect:"XPlat Code Coverage"
    displayName: 'Test'

  - script: dotnet reportgenerator -reports:**/coverage.cobertura.xml -targetdir:$(Build.ArtifactStagingDirectory)/coverage
    displayName: 'Generate coverage report'
```

---

## Managing Tool Versions

### Update a Tool

```bash
# Update to latest version
dotnet tool update docfx

# Update to specific version
dotnet tool update docfx --version 2.79.0
```

### List Installed Tools

```bash
# List local tools
dotnet tool list

# List with outdated check
dotnet tool list --outdated
```

### Remove a Tool

```bash
dotnet tool uninstall docfx
```

---

## Best Practices

### 1. Always Set `isRoot: true`

Prevents MSBuild from searching parent directories for tool manifests:

```json
{
  "version": 1,
  "isRoot": true,
  ...
}
```

### 2. Pin Exact Versions

Use `"rollForward": false` for reproducible builds:

```json
"docfx": {
  "version": "2.78.3",
  "rollForward": false
}
```

### 3. Restore in CI Before Use

Always run `dotnet tool restore` before using any local tool:

```yaml
- run: dotnet tool restore
- run: dotnet docfx docs/docfx.json
```

### 4. Document Tool Requirements

Add a comment or section in README:

```markdown
## Development Setup

1. Restore tools: `dotnet tool restore`
2. Build: `dotnet build`
3. Test: `dotnet test`
```

### 5. Use Dependabot for Updates

```yaml
# .github/dependabot.yml
version: 2
updates:
  - package-ecosystem: "nuget"
    directory: "/"
    schedule:
      interval: "weekly"
    # Includes local tools in .config/dotnet-tools.json
```

---

## Troubleshooting

### Tool Not Found After Restore

Ensure you're running from the repository root:

```bash
# Wrong - running from subdirectory
cd src/MyApp
dotnet docfx  # Error: tool not found

# Correct - run from solution root
cd ../..
dotnet docfx docs/docfx.json
```

### Version Conflicts

If you see version conflicts, check for:
1. Global tool with different version: `dotnet tool list -g`
2. Multiple tool manifests: Look for `.config/dotnet-tools.json` in parent directories

### Clearing Tool Cache

```bash
# Clear NuGet tool cache
dotnet nuget locals all --clear

# Re-restore tools
dotnet tool restore
```

---

## Example: Complete Development Setup

```json
{
  "version": 1,
  "isRoot": true,
  "tools": {
    "docfx": {
      "version": "2.78.3",
      "commands": ["docfx"],
      "rollForward": false
    },
    "dotnet-ef": {
      "version": "9.0.0",
      "commands": ["dotnet-ef"],
      "rollForward": false
    },
    "dotnet-reportgenerator-globaltool": {
      "version": "5.4.1",
      "commands": ["reportgenerator"],
      "rollForward": false
    },
    "csharpier": {
      "version": "0.30.3",
      "commands": ["dotnet-csharpier"],
      "rollForward": false
    },
    "incrementalist.cmd": {
      "version": "1.2.0",
      "commands": ["incrementalist"],
      "rollForward": false
    }
  }
}
```

**Development workflow:**
```bash
# Initial setup
dotnet tool restore

# Format code before commit
dotnet csharpier .

# Run tests with coverage
dotnet test --collect:"XPlat Code Coverage"
dotnet reportgenerator -reports:**/coverage.cobertura.xml -targetdir:coverage

# Build documentation
dotnet docfx docs/docfx.json

# Check which projects changed (for large repos)
incrementalist --branch main
```
