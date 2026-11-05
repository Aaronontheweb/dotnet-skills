---
name: crap-analysis
description: Analyze code coverage and CRAP (Change Risk Anti-Patterns) scores to identify high-risk code. Use OpenCover format with ReportGenerator for Risk Hotspots showing cyclomatic complexity and untested code paths.
---

# CRAP Score Analysis

## When to Use This Skill

Use this skill when:
- Evaluating code quality and test coverage before changes
- Identifying high-risk code that needs refactoring or testing
- Setting up coverage collection for a .NET project
- Prioritizing which code to test based on risk
- Establishing coverage thresholds for CI/CD pipelines

---

## What is CRAP?

**CRAP Score = Complexity^2 x (1 - Coverage)^3 + Complexity**

The CRAP (Change Risk Anti-Patterns) score combines cyclomatic complexity with test coverage to identify risky code. Coverage is a fraction from 0.0 to 1.0.

| CRAP Score | Risk Level | Action Required |
|------------|------------|-----------------|
| **< 5** | Low | Well-tested, maintainable code |
| **5-30** | Medium | Acceptable but watch complexity |
| **> 30** | High | Needs tests or refactoring |

The score has a floor of `Complexity`: at 100% coverage it equals the complexity exactly, so a method whose complexity already reaches the threshold cannot be rescued by tests. Reduce the complexity first.

### Why CRAP Matters

- **High complexity + low coverage = danger**: Code that's hard to understand AND untested is risky to modify
- **Complexity alone isn't enough**: A complex method with 100% coverage is safer than a simple method with 0%
- **Focuses effort**: Prioritize testing on complex code, not simple getters/setters

---

## Coverage Collection Setup

### coverage.runsettings

Create a `coverage.runsettings` file in your repository root. The **OpenCover format is required** for CRAP score calculation because it includes cyclomatic complexity metrics.

```xml
<?xml version="1.0" encoding="utf-8" ?>
<RunSettings>
  <DataCollectionRunSettings>
    <DataCollectors>
      <DataCollector friendlyName="XPlat code coverage">
        <Configuration>
          <!-- OpenCover format includes cyclomatic complexity for CRAP scores -->
          <Format>cobertura,opencover</Format>

          <!-- Exclude test and benchmark assemblies -->
          <Exclude>[*.Tests]*,[*.Benchmark]*,[*.Migrations]*</Exclude>

          <!-- Exclude generated code, obsolete members, and explicit exclusions -->
          <ExcludeByAttribute>Obsolete,GeneratedCodeAttribute,CompilerGeneratedAttribute,ExcludeFromCodeCoverageAttribute</ExcludeByAttribute>

          <!-- Exclude source-generated files, Blazor generated code, and migrations -->
          <ExcludeByFile>**/obj/**/*,**/*.g.cs,**/*.designer.cs,**/*.razor.g.cs,**/*.razor.css.g.cs,**/Migrations/**/*</ExcludeByFile>

          <!-- Exclude test projects -->
          <IncludeTestAssembly>false</IncludeTestAssembly>

          <!-- Optimization flags -->
          <SingleHit>false</SingleHit>
          <UseSourceLink>true</UseSourceLink>
          <SkipAutoProps>true</SkipAutoProps>
        </Configuration>
      </DataCollector>
    </DataCollectors>
  </DataCollectionRunSettings>
</RunSettings>
```

### Key Configuration Options

| Option | Purpose |
|--------|---------|
| `Format` | Must include `opencover` for complexity metrics |
| `Exclude` | Exclude test/benchmark assemblies by pattern |
| `ExcludeByAttribute` | Skip generated, obsolete, and explicitly excluded code (includes `ExcludeFromCodeCoverageAttribute`) |
| `ExcludeByFile` | Skip source-generated files, Blazor components, and migrations |
| `SkipAutoProps` | Don't count auto-properties as branches |

---

## ReportGenerator Installation

Install ReportGenerator as a local tool for generating HTML reports with Risk Hotspots.

### Add to .config/dotnet-tools.json

```json
{
  "version": 1,
  "isRoot": true,
  "tools": {
    "dotnet-reportgenerator-globaltool": {
      "version": "5.4.5",
      "commands": ["reportgenerator"],
      "rollForward": false
    }
  }
}
```

Then restore:

```bash
dotnet tool restore
```

### Or Install Globally

```bash
dotnet tool install --global dotnet-reportgenerator-globaltool
```

---

## Collecting Coverage

### Run Tests with Coverage Collection

```bash
# Clean previous results
rm -rf coverage/ TestResults/

# Run unit tests with coverage
dotnet test tests/MyApp.Tests.Unit \
  --settings coverage.runsettings \
  --collect:"XPlat Code Coverage" \
  --results-directory ./TestResults

# Run integration tests (optional, adds to coverage)
dotnet test tests/MyApp.Tests.Integration \
  --settings coverage.runsettings \
  --collect:"XPlat Code Coverage" \
  --results-directory ./TestResults
```

### Generate HTML Report

```bash
dotnet reportgenerator \
  -reports:"TestResults/**/coverage.opencover.xml" \
  -targetdir:"coverage" \
  -reporttypes:"Html;TextSummary;MarkdownSummaryGithub"
```

### Report Types

| Type | Description | Output |
|------|-------------|--------|
| `Html` | Full interactive report | `coverage/index.html` |
| `TextSummary` | Plain text summary | `coverage/Summary.txt` |
| `MarkdownSummaryGithub` | GitHub-compatible markdown | `coverage/SummaryGithub.md` |
| `Badges` | SVG badges for README | `coverage/badge_*.svg` |
| `Cobertura` | Merged Cobertura XML | `coverage/Cobertura.xml` |

---

## Reading the Report

### Risk Hotspots Section

The HTML report includes a **Risk Hotspots** section showing methods sorted by complexity:

- **Cyclomatic Complexity**: Number of independent paths through code (if/else, switch cases, loops)
- **NPath Complexity**: Number of acyclic execution paths (exponential growth with nesting)
- **Crap Score**: Calculated from complexity and coverage

### Interpreting Results

Read the rows from the highest `Crap Score` down. ReportGenerator computes that column from the complexity and coverage data already in this report. Do not recompute it by hand: quote the tool value together with the inputs it used.

**Action items:**
- Highest score with low coverage: add tests or refactor
- High complexity with high coverage: acceptable, keep an eye on the complexity
- Low complexity with high coverage: safe to modify

A method that is absent from the report is failed collection or filtering, not 0% coverage. Regenerate the report rather than scoring it as zero.

---

## Coverage Thresholds

### Recommended Standards

| Coverage Type | Target | Action |
|---------------|--------|--------|
| Line Coverage | > 80% | Good for most projects |
| Branch Coverage | > 60% | Catches conditional logic |
| CRAP Score | < 30 | Maximum for new code |

### Configuring Thresholds

Create `coverage.props` in your repository:

```xml
<Project>
  <PropertyGroup>
    <!-- Coverage thresholds for CI enforcement -->
    <CoverageThresholdLine>80</CoverageThresholdLine>
    <CoverageThresholdBranch>60</CoverageThresholdBranch>
  </PropertyGroup>
</Project>
```

---

## CI/CD Integration

### GitHub Actions

```yaml
name: Coverage

on:
  pull_request:
    branches: [main, dev]

jobs:
  coverage:
    runs-on: ubuntu-latest

    steps:
      - uses: actions/checkout@v4

      - name: Setup .NET
        uses: actions/setup-dotnet@v4
        with:
          dotnet-version: '9.0.x'

      - name: Restore tools
        run: dotnet tool restore

      - name: Run tests with coverage
        run: |
          dotnet test \
            --settings coverage.runsettings \
            --collect:"XPlat Code Coverage" \
            --results-directory ./TestResults

      - name: Generate report
        run: |
          dotnet reportgenerator \
            -reports:"TestResults/**/coverage.opencover.xml" \
            -targetdir:"coverage" \
            -reporttypes:"Html;MarkdownSummaryGithub;Cobertura"

      - name: Upload coverage report
        uses: actions/upload-artifact@v4
        with:
          name: coverage-report
          path: coverage/

      - name: Add coverage to PR
        uses: marocchino/sticky-pull-request-comment@v2
        with:
          path: coverage/SummaryGithub.md
```

### Azure Pipelines

```yaml
- task: DotNetCoreCLI@2
  displayName: 'Run tests with coverage'
  inputs:
    command: 'test'
    arguments: '--settings coverage.runsettings --collect:"XPlat Code Coverage" --results-directory $(Build.SourcesDirectory)/TestResults'

- task: DotNetCoreCLI@2
  displayName: 'Generate coverage report'
  inputs:
    command: 'custom'
    custom: 'reportgenerator'
    arguments: '-reports:"$(Build.SourcesDirectory)/TestResults/**/coverage.opencover.xml" -targetdir:"$(Build.SourcesDirectory)/coverage" -reporttypes:"HtmlInline_AzurePipelines;Cobertura"'

- task: PublishCodeCoverageResults@2
  displayName: 'Publish coverage'
  inputs:
    codeCoverageTool: 'Cobertura'
    summaryFileLocation: '$(Build.SourcesDirectory)/coverage/Cobertura.xml'
```

---

## Quick Reference

### One-Liner Commands

```bash
# Full analysis workflow
rm -rf coverage/ TestResults/ && \
dotnet test --settings coverage.runsettings \
  --collect:"XPlat Code Coverage" \
  --results-directory ./TestResults && \
dotnet reportgenerator \
  -reports:"TestResults/**/coverage.opencover.xml" \
  -targetdir:"coverage" \
  -reporttypes:"Html;TextSummary"

# View summary
cat coverage/Summary.txt

# Open HTML report (Linux)
xdg-open coverage/index.html

# Open HTML report (macOS)
open coverage/index.html

# Open HTML report (Windows)
start coverage/index.html
```

### Project Standards

| Metric | New Code | Legacy Code |
|--------|----------|-------------|
| Line Coverage | 80%+ | 60%+ (improve gradually) |
| Branch Coverage | 60%+ | 40%+ (improve gradually) |
| Maximum CRAP | 30 | Document exceptions |
| High-risk methods | Must have tests | Add tests before modifying |

---

## What Gets Excluded

The recommended `coverage.runsettings` excludes:

| Pattern | Reason |
|---------|--------|
| `[*.Tests]*` | Test assemblies aren't production code |
| `[*.Benchmark]*` | Benchmark projects |
| `[*.Migrations]*` | Database migrations (generated) |
| `GeneratedCodeAttribute` | Source generators |
| `CompilerGeneratedAttribute` | Compiler-generated code |
| `ExcludeFromCodeCoverageAttribute` | Explicit developer opt-out |
| `*.g.cs`, `*.designer.cs` | Generated files |
| `*.razor.g.cs` | Blazor component generated code |
| `*.razor.css.g.cs` | Blazor CSS isolation generated code |
| `**/Migrations/**/*` | EF Core migrations (auto-generated) |
| `SkipAutoProps` | Auto-properties (trivial branches) |

---

## When to Update Thresholds

**Lower thresholds temporarily for:**
- Legacy codebases being modernized (document in README)
- Generated code that can't be modified
- Third-party wrapper code

**Never lower thresholds for:**
- "It's too hard to test" - refactor instead
- "We'll add tests later" - add them now
- New features - should meet standards from the start

---

## Additional Resources

- **Coverlet Documentation**: https://github.com/coverlet-coverage/coverlet
- **ReportGenerator**: https://github.com/danielpalme/ReportGenerator
- **CRAP Score Original Paper**: http://www.artima.com/weblogs/viewpost.jsp?thread=215899
