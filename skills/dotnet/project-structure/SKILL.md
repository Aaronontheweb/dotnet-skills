---
name: dotnet-project-structure
description: Modern .NET project structure including .slnx solution format, Directory.Build.props, central package management, SourceLink, version management with RELEASE_NOTES.md, and SDK pinning with global.json.
invocable: false
---

# .NET Project Structure and Build Configuration

## When to Use This Skill

Use this skill when:
- Setting up a new .NET solution with modern best practices
- Configuring centralized build properties across multiple projects
- Implementing central package version management
- Setting up SourceLink for debugging and NuGet packages
- Automating version management with release notes
- Pinning SDK versions for consistent builds

## Related Skills

- **`dotnet-local-tools`** - Managing local .NET tools with dotnet-tools.json
- **`microsoft-extensions-configuration`** - Configuration validation patterns

---

## Solution File Format (.slnx)

The `.slnx` format is the modern XML-based solution file format introduced in .NET 9. It replaces the traditional `.sln` format.

### Benefits Over Traditional .sln

| Aspect | .sln (Legacy) | .slnx (Modern) |
|--------|---------------|----------------|
| Format | Custom text format | Standard XML |
| Readability | GUIDs, cryptic syntax | Clean, human-readable |
| Version control | Hard to diff/merge | Easy to diff/merge |
| Editing | IDE required | Any text editor |

### Version Requirements

| Tool | Minimum Version |
|------|-----------------|
| .NET SDK | 9.0.200 |
| Visual Studio | 17.13 |
| MSBuild | Visual Studio Build Tools 17.13 |

**Note:** Starting with .NET 10, `dotnet new sln` creates `.slnx` files by default. In .NET 9, you must explicitly migrate or specify the format.

### Example .slnx File

```xml
<Solution>
  <Folder Name="/build/">
    <File Path="Directory.Build.props" />
    <File Path="Directory.Packages.props" />
    <File Path="global.json" />
    <File Path="NuGet.Config" />
    <File Path="README.md" />
  </Folder>
  <Folder Name="/src/">
    <Project Path="src/MyApp/MyApp.csproj" />
    <Project Path="src/MyApp.Core/MyApp.Core.csproj" />
  </Folder>
  <Folder Name="/tests/">
    <Project Path="tests/MyApp.Tests/MyApp.Tests.csproj" />
  </Folder>
</Solution>
```

### Migrating from .sln to .slnx

Use the `dotnet sln migrate` command to convert existing solutions:

```bash
# Migrate a specific solution file
dotnet sln MySolution.sln migrate

# Or if only one .sln exists in the directory, just run:
dotnet sln migrate
```

**Important:** Do not keep both `.sln` and `.slnx` files in the same repository. This causes issues with automatic solution detection and can lead to sync problems. After migration, delete the old `.sln` file.

You can also migrate in Visual Studio:
1. Open the solution
2. Select the Solution in Solution Explorer
3. Go to **File > Save Solution As...**
4. Change "Save as type" to **Xml Solution File (*.slnx)**

### Creating a New .slnx Solution

```bash
# .NET 10+: Creates .slnx by default
dotnet new sln --name MySolution

# .NET 9: Specify the format explicitly
dotnet new sln --name MySolution --format slnx

# Add projects (works the same for both formats)
dotnet sln add src/MyApp/MyApp.csproj
```

### Recommendation

**If you're using .NET 9.0.200 or later, migrate your solutions to .slnx.** The benefits are significant:
- Dramatically fewer merge conflicts (no random GUIDs changing)
- Human-readable and editable in any text editor
- Consistent with modern `.csproj` format
- Better diff/review experience in pull requests

---

## Directory.Build.props

`Directory.Build.props` provides centralized build configuration that applies to all projects in a directory tree. Place it at the solution root.

### Complete Example

```xml
<Project>
  <!-- Metadata -->
  <PropertyGroup>
    <Authors>Your Team</Authors>
    <Company>Your Company</Company>
    <!-- Dynamic copyright year - updates automatically -->
    <Copyright>Copyright © 2020-$([System.DateTime]::Now.Year) Your Company</Copyright>
    <Product>Your Product</Product>
    <PackageProjectUrl>https://github.com/yourorg/yourrepo</PackageProjectUrl>
    <RepositoryUrl>https://github.com/yourorg/yourrepo</RepositoryUrl>
    <PackageLicenseExpression>Apache-2.0</PackageLicenseExpression>
    <PackageTags>your;tags;here</PackageTags>
  </PropertyGroup>

  <!-- C# Language Settings -->
  <PropertyGroup>
    <LangVersion>latest</LangVersion>
    <Nullable>enable</Nullable>
    <ImplicitUsings>enable</ImplicitUsings>
    <TreatWarningsAsErrors>true</TreatWarningsAsErrors>
    <NoWarn>$(NoWarn);CS1591</NoWarn> <!-- Missing XML comments -->
  </PropertyGroup>

  <!-- Version Management -->
  <PropertyGroup>
    <VersionPrefix>1.0.0</VersionPrefix>
    <PackageReleaseNotes>See RELEASE_NOTES.md</PackageReleaseNotes>
  </PropertyGroup>

  <!-- Target Framework Definitions (reusable properties) -->
  <PropertyGroup>
    <NetStandardLibVersion>netstandard2.0</NetStandardLibVersion>
    <NetLibVersion>net8.0</NetLibVersion>
    <NetTestVersion>net9.0</NetTestVersion>
  </PropertyGroup>

  <!-- SourceLink Configuration -->
  <PropertyGroup>
    <PublishRepositoryUrl>true</PublishRepositoryUrl>
    <EmbedUntrackedSources>true</EmbedUntrackedSources>
    <IncludeSymbols>true</IncludeSymbols>
    <SymbolPackageFormat>snupkg</SymbolPackageFormat>
  </PropertyGroup>

  <ItemGroup>
    <PackageReference Include="Microsoft.SourceLink.GitHub" PrivateAssets="All" />
  </ItemGroup>

  <!-- NuGet Package Assets -->
  <ItemGroup>
    <None Include="$(MSBuildThisFileDirectory)logo.png" Pack="true" PackagePath="\" />
    <None Include="$(MSBuildThisFileDirectory)README.md" Pack="true" PackagePath="\" />
  </ItemGroup>

  <PropertyGroup>
    <PackageIcon>logo.png</PackageIcon>
    <PackageReadmeFile>README.md</PackageReadmeFile>
  </PropertyGroup>

  <!-- Global Using Statements -->
  <ItemGroup>
    <Using Include="System.Collections.Immutable" />
  </ItemGroup>
</Project>
```

### Key Patterns

#### Dynamic Copyright Year

```xml
<Copyright>Copyright © 2020-$([System.DateTime]::Now.Year) Your Company</Copyright>
```

Uses MSBuild property functions to insert current year at build time. No manual updates needed.

#### Reusable Target Framework Properties

Define target frameworks once, reference everywhere:

```xml
<!-- In Directory.Build.props -->
<PropertyGroup>
  <NetLibVersion>net8.0</NetLibVersion>
  <NetTestVersion>net9.0</NetTestVersion>
</PropertyGroup>

<!-- In MyApp.csproj -->
<PropertyGroup>
  <TargetFramework>$(NetLibVersion)</TargetFramework>
</PropertyGroup>

<!-- In MyApp.Tests.csproj -->
<PropertyGroup>
  <TargetFramework>$(NetTestVersion)</TargetFramework>
</PropertyGroup>
```

#### SourceLink for NuGet Packages

SourceLink enables step-through debugging of NuGet packages:

```xml
<PropertyGroup>
  <PublishRepositoryUrl>true</PublishRepositoryUrl>
  <EmbedUntrackedSources>true</EmbedUntrackedSources>
  <IncludeSymbols>true</IncludeSymbols>
  <SymbolPackageFormat>snupkg</SymbolPackageFormat>
</PropertyGroup>

<ItemGroup>
  <!-- Choose the right provider for your source control -->
  <PackageReference Include="Microsoft.SourceLink.GitHub" PrivateAssets="All" />
  <!-- Or: Microsoft.SourceLink.AzureRepos.Git -->
  <!-- Or: Microsoft.SourceLink.GitLab -->
  <!-- Or: Microsoft.SourceLink.Bitbucket.Git -->
</ItemGroup>
```

---

## Directory.Packages.props - Central Package Management

Central Package Management (CPM) provides a single source of truth for all NuGet package versions.

### Setup

```xml
<Project>
  <PropertyGroup>
    <ManagePackageVersionsCentrally>true</ManagePackageVersionsCentrally>
  </PropertyGroup>

  <!-- Define version variables for related packages -->
  <PropertyGroup>
    <AkkaVersion>1.5.35</AkkaVersion>
    <AspireVersion>9.1.0</AspireVersion>
  </PropertyGroup>

  <!-- Application Dependencies -->
  <ItemGroup Label="App Dependencies">
    <PackageVersion Include="Akka" Version="$(AkkaVersion)" />
    <PackageVersion Include="Akka.Cluster" Version="$(AkkaVersion)" />
    <PackageVersion Include="Akka.Persistence" Version="$(AkkaVersion)" />
    <PackageVersion Include="Microsoft.Extensions.Hosting" Version="9.0.0" />
  </ItemGroup>

  <!-- Build/Tooling Dependencies -->
  <ItemGroup Label="Build Dependencies">
    <PackageVersion Include="Microsoft.SourceLink.GitHub" Version="8.0.0" />
  </ItemGroup>

  <!-- Test Dependencies -->
  <ItemGroup Label="Test Dependencies">
    <PackageVersion Include="xunit" Version="2.9.3" />
    <PackageVersion Include="xunit.runner.visualstudio" Version="3.0.1" />
    <PackageVersion Include="FluentAssertions" Version="7.0.0" />
    <PackageVersion Include="Microsoft.NET.Test.Sdk" Version="17.12.0" />
    <PackageVersion Include="coverlet.collector" Version="6.0.3" />
  </ItemGroup>
</Project>
```

### Consuming Packages (No Version Needed)

```xml
<!-- In MyApp.csproj -->
<ItemGroup>
  <PackageReference Include="Akka" />
  <PackageReference Include="Akka.Cluster" />
  <PackageReference Include="Microsoft.Extensions.Hosting" />
</ItemGroup>

<!-- In MyApp.Tests.csproj -->
<ItemGroup>
  <PackageReference Include="xunit" />
  <PackageReference Include="FluentAssertions" />
  <PackageReference Include="Microsoft.NET.Test.Sdk" />
</ItemGroup>
```

### Benefits

1. **Single source of truth** - All versions in one file
2. **No version drift** - All projects use same versions
3. **Easy updates** - Change once, applies everywhere
4. **Grouped packages** - Version variables for related packages (e.g., all Akka packages)

---

## global.json - SDK Version Pinning

Pin the .NET SDK version for consistent builds across all environments.

```json
{
  "sdk": {
    "version": "9.0.200",
    "rollForward": "latestFeature"
  }
}
```

### Roll Forward Policies

| Policy | Behavior |
|--------|----------|
| `disable` | Exact version required |
| `patch` | Same major.minor, latest patch |
| `feature` | Same major, latest minor.patch |
| `latestFeature` | Same major, latest feature band |
| `minor` | Same major, latest minor |
| `latestMinor` | Same major, latest minor |
| `major` | Latest SDK (not recommended) |

**Recommended:** `latestFeature` - Allows patch updates within the same feature band.

---

## Version Management with RELEASE_NOTES.md

### Release Notes Format

```markdown
#### 1.2.0 January 15th 2025 ####

- Added new feature X
- Fixed bug in Y
- Improved performance of Z

#### 1.1.0 December 10th 2024 ####

- Initial release with features A, B, C
```

### Parsing Script (getReleaseNotes.ps1)

```powershell
function Get-ReleaseNotes {
    param (
        [Parameter(Mandatory=$true)]
        [string]$MarkdownFile
    )

    $content = Get-Content -Path $MarkdownFile -Raw
    $sections = $content -split "####"

    $result = [PSCustomObject]@{
        Version      = $null
        Date         = $null
        ReleaseNotes = $null
    }

    if ($sections.Count -ge 3) {
        $header = $sections[1].Trim()
        $releaseNotes = $sections[2].Trim()

        $headerParts = $header -split " ", 2
        if ($headerParts.Count -eq 2) {
            $result.Version = $headerParts[0]
            $result.Date = $headerParts[1]
        }

        $result.ReleaseNotes = $releaseNotes
    }

    return $result
}
```

### Version Bump Script (bumpVersion.ps1)

```powershell
function UpdateVersionAndReleaseNotes {
    param (
        [Parameter(Mandatory=$true)]
        [PSCustomObject]$ReleaseNotesResult,
        [Parameter(Mandatory=$true)]
        [string]$XmlFilePath
    )

    $xmlContent = New-Object XML
    $xmlContent.Load($XmlFilePath)

    # Update VersionPrefix
    $versionElement = $xmlContent.SelectSingleNode("//VersionPrefix")
    $versionElement.InnerText = $ReleaseNotesResult.Version

    # Update PackageReleaseNotes
    $notesElement = $xmlContent.SelectSingleNode("//PackageReleaseNotes")
    $notesElement.InnerText = $ReleaseNotesResult.ReleaseNotes

    $xmlContent.Save($XmlFilePath)
}
```

### Build Script (build.ps1)

```powershell
# Load helper scripts
. "$PSScriptRoot\scripts\getReleaseNotes.ps1"
. "$PSScriptRoot\scripts\bumpVersion.ps1"

# Parse release notes and update Directory.Build.props
$releaseNotes = Get-ReleaseNotes -MarkdownFile (Join-Path -Path $PSScriptRoot -ChildPath "RELEASE_NOTES.md")
UpdateVersionAndReleaseNotes -ReleaseNotesResult $releaseNotes -XmlFilePath (Join-Path -Path $PSScriptRoot -ChildPath "Directory.Build.props")

Write-Output "Updated to version $($releaseNotes.Version)"
```

### CI/CD Integration

```yaml
# GitHub Actions example
- name: Update version from release notes
  shell: pwsh
  run: ./build.ps1

- name: Build
  run: dotnet build -c Release

- name: Pack with tag version
  run: dotnet pack -c Release /p:PackageVersion=${{ github.ref_name }}

- name: Push to NuGet
  run: dotnet nuget push **/*.nupkg --api-key ${{ secrets.NUGET_API_KEY }} --source https://api.nuget.org/v3/index.json
```

---

## NuGet.Config

Configure NuGet sources and behavior:

```xml
<?xml version="1.0" encoding="utf-8"?>
<configuration>
  <solution>
    <add key="disableSourceControlIntegration" value="true" />
  </solution>

  <packageSources>
    <clear />
    <add key="nuget.org" value="https://api.nuget.org/v3/index.json" />
    <!-- Add private feeds if needed -->
    <!-- <add key="MyCompany" value="https://pkgs.dev.azure.com/myorg/_packaging/myfeed/nuget/v3/index.json" /> -->
  </packageSources>
</configuration>
```

**Key Settings:**
- `<clear />` - Remove inherited/default sources for reproducible builds
- `disableSourceControlIntegration` - Prevents TFS/Git integration issues

---

## Complete Project Structure

```
MySolution/
├── .config/
│   └── dotnet-tools.json           # Local .NET tools
├── .github/
│   └── workflows/
│       ├── pr-validation.yml       # PR checks
│       └── release.yml             # NuGet publishing
├── scripts/
│   ├── getReleaseNotes.ps1         # Parse RELEASE_NOTES.md
│   └── bumpVersion.ps1             # Update Directory.Build.props
├── src/
│   ├── MyApp/
│   │   └── MyApp.csproj
│   └── MyApp.Core/
│       └── MyApp.Core.csproj
├── tests/
│   └── MyApp.Tests/
│       └── MyApp.Tests.csproj
├── Directory.Build.props           # Centralized build config
├── Directory.Packages.props        # Central package versions
├── MySolution.slnx                 # Modern solution file
├── global.json                     # SDK version pinning
├── NuGet.Config                    # Package source config
├── build.ps1                       # Build orchestration
├── RELEASE_NOTES.md                # Version history
├── README.md                       # Project documentation
└── logo.png                        # Package icon
```

---

## Quick Reference

| File | Purpose |
|------|---------|
| `MySolution.slnx` | Modern XML solution file |
| `Directory.Build.props` | Centralized build properties |
| `Directory.Packages.props` | Central package version management |
| `global.json` | SDK version pinning |
| `NuGet.Config` | Package source configuration |
| `RELEASE_NOTES.md` | Version history (parsed by build) |
| `build.ps1` | Build orchestration script |
| `.config/dotnet-tools.json` | Local .NET tools |
