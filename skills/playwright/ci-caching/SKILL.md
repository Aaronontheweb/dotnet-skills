---
name: playwright-ci-caching
description: Cache Playwright browser binaries in CI/CD pipelines (GitHub Actions, Azure DevOps) to avoid 1-2 minute download overhead on every build.
invocable: false
---

# Caching Playwright Browsers in CI/CD

## When to Use This Skill

Use this skill when:
- Setting up CI/CD for a project with Playwright E2E tests
- Build times are slow due to browser downloads (~400MB, 1-2 minutes)
- You want automatic cache invalidation when Playwright version changes
- Using GitHub Actions or Azure DevOps pipelines

## The Problem

Playwright browsers (~400MB) must be downloaded on every CI run by default. This:
- Adds 1-2 minutes to every build
- Wastes bandwidth
- Can fail on transient network issues
- Slows down PR feedback loops

## Core Pattern

1. **Extract Playwright version** from `Directory.Packages.props` (CPM) to use as cache key
2. **Cache browser binaries** using platform-appropriate paths
3. **Conditional install** - only download on cache miss
4. **Automatic cache bust** - key includes version, so package upgrades invalidate cache

## Cache Paths by OS

| OS | Path |
|----|------|
| Linux | `~/.cache/ms-playwright` |
| macOS | `~/Library/Caches/ms-playwright` |
| Windows | `%USERPROFILE%\AppData\Local\ms-playwright` |

## GitHub Actions

```yaml
- name: Get Playwright Version
  shell: pwsh
  run: |
    $propsPath = "Directory.Packages.props"
    [xml]$props = Get-Content $propsPath
    $version = $props.Project.ItemGroup.PackageVersion |
      Where-Object { $_.Include -eq "Microsoft.Playwright" } |
      Select-Object -ExpandProperty Version
    echo "PlaywrightVersion=$version" >> $env:GITHUB_ENV

- name: Cache Playwright Browsers
  id: playwright-cache
  uses: actions/cache@v4
  with:
    path: ~/.cache/ms-playwright
    key: ${{ runner.os }}-playwright-${{ env.PlaywrightVersion }}

- name: Install Playwright Browsers
  if: steps.playwright-cache.outputs.cache-hit != 'true'
  shell: pwsh
  run: ./build/playwright.ps1 install --with-deps
```

### Multi-OS GitHub Actions

For workflows that run on multiple operating systems:

```yaml
- name: Cache Playwright Browsers
  id: playwright-cache
  uses: actions/cache@v4
  with:
    path: |
      ~/.cache/ms-playwright
      ~/Library/Caches/ms-playwright
      ~/AppData/Local/ms-playwright
    key: ${{ runner.os }}-playwright-${{ env.PlaywrightVersion }}
```

## Azure DevOps

```yaml
- task: PowerShell@2
  displayName: 'Get Playwright Version'
  inputs:
    targetType: 'inline'
    script: |
      [xml]$props = Get-Content "Directory.Packages.props"
      $version = $props.Project.ItemGroup.PackageVersion |
        Where-Object { $_.Include -eq "Microsoft.Playwright" } |
        Select-Object -ExpandProperty Version
      Write-Host "##vso[task.setvariable variable=PlaywrightVersion]$version"

- task: Cache@2
  displayName: 'Cache Playwright Browsers'
  inputs:
    key: 'playwright | "$(Agent.OS)" | $(PlaywrightVersion)'
    path: '$(HOME)/.cache/ms-playwright'
    cacheHitVar: 'PlaywrightCacheHit'

- task: PowerShell@2
  displayName: 'Install Playwright Browsers'
  condition: ne(variables['PlaywrightCacheHit'], 'true')
  inputs:
    filePath: 'build/playwright.ps1'
    arguments: 'install --with-deps'
```

## Helper Script: playwright.ps1

Create a `build/playwright.ps1` script that discovers and runs the Playwright CLI. This abstracts away the Playwright CLI location which varies by project structure.

```powershell
# build/playwright.ps1
# Discovers Microsoft.Playwright.dll and runs the bundled Playwright CLI

param(
    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]]$Arguments
)

# Find the Playwright DLL (after dotnet build/restore)
$playwrightDll = Get-ChildItem -Path . -Recurse -Filter "Microsoft.Playwright.dll" -ErrorAction SilentlyContinue |
    Select-Object -First 1

if (-not $playwrightDll) {
    Write-Error "Microsoft.Playwright.dll not found. Run 'dotnet build' first."
    exit 1
}

$playwrightDir = $playwrightDll.DirectoryName

# Find the playwright CLI (path varies by OS and node version)
$playwrightCmd = Get-ChildItem -Path "$playwrightDir/.playwright/node" -Recurse -Filter "playwright.cmd" -ErrorAction SilentlyContinue |
    Select-Object -First 1

if (-not $playwrightCmd) {
    # Try Unix executable
    $playwrightCmd = Get-ChildItem -Path "$playwrightDir/.playwright/node" -Recurse -Filter "playwright" -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -eq "playwright" } |
        Select-Object -First 1
}

if (-not $playwrightCmd) {
    Write-Error "Playwright CLI not found in $playwrightDir/.playwright/node"
    exit 1
}

Write-Host "Using Playwright CLI: $($playwrightCmd.FullName)"
& $playwrightCmd.FullName @Arguments
```

Usage:
```bash
# Install browsers
./build/playwright.ps1 install --with-deps

# Install specific browser
./build/playwright.ps1 install chromium

# Show installed browsers
./build/playwright.ps1 install --dry-run
```

## Prerequisites

This pattern assumes:

1. **Central Package Management (CPM)** with `Directory.Packages.props`:
   ```xml
   <Project>
     <ItemGroup>
       <PackageVersion Include="Microsoft.Playwright" Version="1.40.0" />
     </ItemGroup>
   </Project>
   ```

2. **Project has been built** before running `playwright.ps1` (so DLLs exist)

3. **PowerShell available** on CI agents (pre-installed on GitHub Actions and Azure DevOps)

## Why Version-Based Cache Keys Matter

Using the Playwright version in the cache key ensures:

- **Automatic invalidation** when you upgrade Playwright
- **No stale browser binaries** that don't match the SDK version
- **No manual cache clearing** needed after version bumps

If you hardcode the cache key (e.g., `playwright-browsers-v1`), you'll need to manually bump it every time you upgrade Playwright, or you'll get cryptic version mismatch errors.

## Troubleshooting

### Cache not being used

1. Verify the version extraction step outputs the correct version
2. Check that the cache path matches your OS
3. Ensure `Directory.Packages.props` exists and has the Playwright package

### "Browser not found" after cache hit

The cached browsers don't match the Playwright SDK version. This happens when:
- The cache key doesn't include the version
- The version extraction failed silently

Fix: Ensure the Playwright version is in the cache key.

### playwright.ps1 can't find the DLL

Run `dotnet build` or `dotnet restore` before running the script. The Playwright DLL only exists after NuGet restore.

## References

This pattern is battle-tested in production projects:
- [petabridge/geekedin](https://github.com/petabridge/geekedin)
- [petabridge/DrawTogether.NET](https://github.com/petabridge/DrawTogether.NET)

## Related Skills

- `dotnet-skills:playwright-blazor` - Writing Playwright tests for Blazor applications
- `dotnet-skills:project-structure` - Central Package Management setup
