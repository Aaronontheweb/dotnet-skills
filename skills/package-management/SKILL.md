---
name: package-management
description: Manage NuGet packages using Central Package Management (CPM) and dotnet CLI commands. Never edit XML directly - use dotnet add/remove/list commands. Use shared version variables for related packages.
invocable: false
---

# NuGet Package Management

## When to Use This Skill

Use this skill when:
- Adding, removing, or updating NuGet packages
- Setting up Central Package Management (CPM) for a solution
- Managing package versions across multiple projects
- Troubleshooting package conflicts or restore issues

---

## Golden Rule: Never Edit XML Directly

**Always use `dotnet` CLI commands to manage packages.** Never manually edit `.csproj` or `Directory.Packages.props` files.

```bash
# DO: Use CLI commands
dotnet add package Newtonsoft.Json
dotnet remove package Newtonsoft.Json
dotnet list package --outdated

# DON'T: Edit XML directly
# <PackageReference Include="Newtonsoft.Json" Version="13.0.3" />
```

**Why:**
- CLI validates package exists and resolves correct version
- Handles transitive dependencies correctly
- Updates lock files if present
- Avoids typos and malformed XML
- Works correctly with CPM

---

## Central Package Management (CPM)

CPM centralizes all package versions in one file, eliminating version conflicts across projects.

### Enable CPM

Create `Directory.Packages.props` in solution root:

```xml
<Project>
  <PropertyGroup>
    <ManagePackageVersionsCentrally>true</ManagePackageVersionsCentrally>
  </PropertyGroup>

  <ItemGroup>
    <PackageVersion Include="Newtonsoft.Json" Version="13.0.3" />
    <PackageVersion Include="Serilog" Version="4.0.0" />
    <PackageVersion Include="xunit" Version="2.9.2" />
  </ItemGroup>
</Project>
```

### Project Files with CPM

Projects reference packages **without versions**:

```xml
<!-- src/MyApp/MyApp.csproj -->
<Project Sdk="Microsoft.NET.Sdk">
  <ItemGroup>
    <PackageReference Include="Newtonsoft.Json" />
    <PackageReference Include="Serilog" />
  </ItemGroup>
</Project>
```

### Adding Packages with CPM

```bash
# Adds to Directory.Packages.props AND project file
dotnet add package Serilog.Sinks.Console

# Result in Directory.Packages.props:
# <PackageVersion Include="Serilog.Sinks.Console" Version="6.0.0" />

# Result in project file:
# <PackageReference Include="Serilog.Sinks.Console" />
```

---

## Shared Version Variables

Group related packages with shared version variables:

```xml
<Project>
  <PropertyGroup>
    <ManagePackageVersionsCentrally>true</ManagePackageVersionsCentrally>
  </PropertyGroup>

  <!-- Shared version variables -->
  <PropertyGroup Label="SharedVersions">
    <AkkaVersion>1.5.59</AkkaVersion>
    <AkkaHostingVersion>1.5.59</AkkaHostingVersion>
    <AspireVersion>9.0.0</AspireVersion>
    <OpenTelemetryVersion>1.11.0</OpenTelemetryVersion>
    <XunitVersion>2.9.2</XunitVersion>
  </PropertyGroup>

  <!-- Akka.NET packages - all use same version -->
  <ItemGroup Label="Akka.NET">
    <PackageVersion Include="Akka" Version="$(AkkaVersion)" />
    <PackageVersion Include="Akka.Cluster" Version="$(AkkaVersion)" />
    <PackageVersion Include="Akka.Cluster.Sharding" Version="$(AkkaVersion)" />
    <PackageVersion Include="Akka.Cluster.Tools" Version="$(AkkaVersion)" />
    <PackageVersion Include="Akka.Persistence" Version="$(AkkaVersion)" />
    <PackageVersion Include="Akka.Streams" Version="$(AkkaVersion)" />
    <PackageVersion Include="Akka.Hosting" Version="$(AkkaHostingVersion)" />
    <PackageVersion Include="Akka.Cluster.Hosting" Version="$(AkkaHostingVersion)" />
  </ItemGroup>

  <!-- Aspire packages -->
  <ItemGroup Label="Aspire">
    <PackageVersion Include="Aspire.Hosting" Version="$(AspireVersion)" />
    <PackageVersion Include="Aspire.Hosting.AppHost" Version="$(AspireVersion)" />
    <PackageVersion Include="Aspire.Hosting.PostgreSQL" Version="$(AspireVersion)" />
    <PackageVersion Include="Aspire.Hosting.Testing" Version="$(AspireVersion)" />
  </ItemGroup>

  <!-- OpenTelemetry packages -->
  <ItemGroup Label="OpenTelemetry">
    <PackageVersion Include="OpenTelemetry.Exporter.OpenTelemetryProtocol" Version="$(OpenTelemetryVersion)" />
    <PackageVersion Include="OpenTelemetry.Extensions.Hosting" Version="$(OpenTelemetryVersion)" />
    <PackageVersion Include="OpenTelemetry.Instrumentation.AspNetCore" Version="$(OpenTelemetryVersion)" />
    <PackageVersion Include="OpenTelemetry.Instrumentation.Http" Version="$(OpenTelemetryVersion)" />
  </ItemGroup>

  <!-- Testing -->
  <ItemGroup Label="Testing">
    <PackageVersion Include="xunit" Version="$(XunitVersion)" />
    <PackageVersion Include="xunit.runner.visualstudio" Version="$(XunitVersion)" />
    <PackageVersion Include="FluentAssertions" Version="6.12.0" />
    <PackageVersion Include="Verify.Xunit" Version="26.0.0" />
  </ItemGroup>
</Project>
```

**Benefits:**
- Update all Akka packages by changing one variable
- Clear organization with labeled ItemGroups
- Prevents version mismatches in related packages

---

## When NOT to Use CPM

Central Package Management isn't always the right choice:

### Legacy Projects

Migrating an existing large solution to CPM can introduce issues:
- Existing version conflicts become visible all at once
- Some packages may have intentional version differences
- Migration requires touching many files simultaneously

**Recommendation**: For legacy projects, migrate incrementally or stick with per-project versioning if it's working.

### Version Ranges

CPM requires exact versions - it doesn't support version ranges:

```xml
<!-- NOT supported with CPM -->
<PackageVersion Include="Newtonsoft.Json" Version="[13.0,14.0)" />

<!-- Must use exact version -->
<PackageVersion Include="Newtonsoft.Json" Version="13.0.3" />
```

If you need version ranges (rare, but some library scenarios require it), CPM won't work.

### Older .NET Versions

CPM requires:
- **.NET SDK 6.0.300+** or later
- **NuGet 6.2+** or later
- **Visual Studio 2022 17.2+** or later

If you're targeting older SDK versions or have team members on older tooling, CPM may cause build failures.

### Multi-Repo Solutions

If your solution spans multiple repositories that are built independently, CPM's single `Directory.Packages.props` won't help - each repo needs its own.

---

## CLI Command Reference

### Adding Packages

```bash
# Add latest stable version
dotnet add package Serilog

# Add specific version
dotnet add package Serilog --version 4.0.0

# Add prerelease
dotnet add package Serilog --prerelease

# Add to specific project
dotnet add src/MyApp/MyApp.csproj package Serilog
```

### Removing Packages

```bash
# Remove from current project
dotnet remove package Serilog

# Remove from specific project
dotnet remove src/MyApp/MyApp.csproj package Serilog
```

### Listing Packages

```bash
# List all packages in solution
dotnet list package

# Show outdated packages
dotnet list package --outdated

# Include transitive dependencies
dotnet list package --include-transitive

# Show vulnerable packages
dotnet list package --vulnerable

# Show deprecated packages
dotnet list package --deprecated
```

### Updating Packages

```bash
# With CPM: Edit the version in Directory.Packages.props
# Then restore to apply
dotnet restore

# Without CPM: Remove and add with new version
dotnet remove package Serilog
dotnet add package Serilog --version 4.1.0

# Or use dotnet-outdated tool (recommended)
dotnet tool install --global dotnet-outdated-tool
dotnet outdated --upgrade
```

### Restore and Clean

```bash
# Restore packages
dotnet restore

# Clear local cache (troubleshooting)
dotnet nuget locals all --clear

# Force restore (ignore cache)
dotnet restore --force
```

---

## Package Sources

### List Sources

```bash
dotnet nuget list source
```

### Add Private Feed

```bash
# Add authenticated feed
dotnet nuget add source https://pkgs.dev.azure.com/myorg/_packaging/myfeed/nuget/v3/index.json \
  --name MyFeed \
  --username az \
  --password $PAT \
  --store-password-in-clear-text
```

### NuGet.config

For solution-specific sources, create `NuGet.config`:

```xml
<?xml version="1.0" encoding="utf-8"?>
<configuration>
  <packageSources>
    <clear />
    <add key="nuget.org" value="https://api.nuget.org/v3/index.json" />
    <add key="MyPrivateFeed" value="https://pkgs.dev.azure.com/myorg/_packaging/myfeed/nuget/v3/index.json" />
  </packageSources>
  <packageSourceCredentials>
    <MyPrivateFeed>
      <add key="Username" value="az" />
      <add key="ClearTextPassword" value="%NUGET_PAT%" />
    </MyPrivateFeed>
  </packageSourceCredentials>
</configuration>
```

---

## Common Patterns

### Development-Only Packages

```xml
<!-- Directory.Packages.props -->
<PackageVersion Include="Microsoft.SourceLink.GitHub" Version="8.0.0" />

<!-- Project file - mark as development dependency -->
<PackageReference Include="Microsoft.SourceLink.GitHub" PrivateAssets="All" />
```

### Conditional Packages

```xml
<!-- Only include in Debug builds -->
<ItemGroup Condition="'$(Configuration)' == 'Debug'">
  <PackageReference Include="JetBrains.Annotations" />
</ItemGroup>

<!-- Platform-specific -->
<ItemGroup Condition="'$(TargetFramework)' == 'net8.0'">
  <PackageReference Include="System.Text.Json" />
</ItemGroup>
```

### Version Override (Escape Hatch)

When you must override CPM for one project (rare):

```xml
<!-- Project file - use sparingly! -->
<PackageReference Include="Newtonsoft.Json" VersionOverride="12.0.3" />
```

**Warning**: This is detected by Slopwatch (see `dotnet/slopwatch` skill) as potential slop.

---

## Troubleshooting

### Version Conflicts

```bash
# See full dependency tree
dotnet list package --include-transitive

# Find what's pulling in a specific package
dotnet list package --include-transitive | grep -i "PackageName"
```

### Restore Failures

```bash
# Clear all caches
dotnet nuget locals all --clear

# Restore with detailed logging
dotnet restore --verbosity detailed

# Check for locked packages
cat packages.lock.json
```

### Lock Files

For reproducible builds, use package lock files:

```xml
<!-- Directory.Build.props -->
<PropertyGroup>
  <RestorePackagesWithLockFile>true</RestorePackagesWithLockFile>
</PropertyGroup>
```

Then commit `packages.lock.json` files.

---

## Anti-Patterns

### Don't: Edit XML Directly

```xml
<!-- BAD: Manual XML editing -->
<PackageReference Include="Typo.Package" Version="1.0.0" />
<!-- Package might not exist! CLI would catch this. -->
```

### Don't: Inline Versions with CPM

```xml
<!-- BAD: Bypasses CPM -->
<PackageReference Include="Serilog" Version="4.0.0" />

<!-- GOOD: Version comes from Directory.Packages.props -->
<PackageReference Include="Serilog" />
```

### Don't: Mix Version Management

```xml
<!-- BAD: Some versions in CPM, some inline -->
<PackageReference Include="Serilog" />  <!-- From CPM -->
<PackageReference Include="Newtonsoft.Json" Version="13.0.3" />  <!-- Inline -->
```

### Don't: Forget Shared Variables

```xml
<!-- BAD: Related packages with different versions -->
<PackageVersion Include="Akka" Version="1.5.59" />
<PackageVersion Include="Akka.Cluster" Version="1.5.58" />  <!-- Mismatch! -->

<!-- GOOD: Use shared variable -->
<PackageVersion Include="Akka" Version="$(AkkaVersion)" />
<PackageVersion Include="Akka.Cluster" Version="$(AkkaVersion)" />
```

---

## Quick Reference

| Task | Command |
|------|---------|
| Add package | `dotnet add package <name>` |
| Add specific version | `dotnet add package <name> --version <ver>` |
| Remove package | `dotnet remove package <name>` |
| List packages | `dotnet list package` |
| Show outdated | `dotnet list package --outdated` |
| Show vulnerable | `dotnet list package --vulnerable` |
| Restore | `dotnet restore` |
| Clear cache | `dotnet nuget locals all --clear` |

---

## Resources

- **Central Package Management**: https://learn.microsoft.com/en-us/nuget/consume-packages/central-package-management
- **dotnet CLI Reference**: https://learn.microsoft.com/en-us/dotnet/core/tools/
- **NuGet.config Reference**: https://learn.microsoft.com/en-us/nuget/reference/nuget-config-file
