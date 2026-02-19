# Release Notes

## v1.3.0 (2026-02-19)

### New Skills

- **ilspy-decompile** - Added skill for decompiling .NET assemblies with ILSpy, including prerequisites, quick start guide, common assembly locations, core workflow, and decompilation commands. ([#45](https://github.com/Aaronontheweb/dotnet-skills/pull/45))

- **dotnet-devcert-trust** - Added skill for diagnosing and resolving HTTPS dev certificate trust failures on Linux. Covers the full 5-point diagnostic procedure, recovery workflow, distro-specific guidance (Ubuntu, Fedora, Arch, WSL2), and Aspire 13.1.0+ Redis TLS context. ([#44](https://github.com/Aaronontheweb/dotnet-skills/pull/44))

### New Agents

- **Roslyn Incremental Generator Specialist** - Added agent documenting the role and design principles for Roslyn incremental source generator development, including guidelines for maintainability and performance. ([#46](https://github.com/Aaronontheweb/dotnet-skills/pull/46))

### Skill Enhancements

- **BenchmarkDotNet guidelines** - Clarified correct usage of `[Benchmark(Baseline = true)]`: only one benchmark per category group may use `Baseline = true`. Documents the recommended pattern of using `[GroupBenchmarksBy(BenchmarkLogicalGroupRule.ByCategory)]` with `[CategoriesColumn]` to compare multiple implementations across scenarios. ([#41](https://github.com/Aaronontheweb/dotnet-skills/pull/41))

### Bug Fixes

- **OpenCode install script** - Fixed the OpenCode installation script to extract skill directory names from YAML frontmatter (`name` field in SKILL.md) rather than the filesystem directory name. OpenCode requires directory names to match the frontmatter `name` field (e.g., `akka-net-best-practices` rather than `akka-best-practices`). ([#40](https://github.com/Aaronontheweb/dotnet-skills/pull/40))

- **Index generation script** - Fixed `generate-skill-index-snippets.sh` to use `python3` instead of `python`, resolving failures on systems where `python` is not in PATH or resolves to Python 2.

---

## v1.2.0 (2026-02-05)

### Breaking Changes

- **Flattened skills directory structure** - Skills moved from `skills/category/skill-name/` to `skills/skill-name/` for GitHub Copilot plugin compatibility. Framework-specific skills use prefixes (`akka-*`, `aspire-*`, `csharp-*`, `microsoft-extensions-*`, `playwright-*`). General .NET skills have no prefix. ([#34](https://github.com/Aaronontheweb/dotnet-skills/pull/34))

### Documentation Improvements

- **Clarified installation instructions** - Added platform-specific installation sections for Claude Code CLI, GitHub Copilot, and OpenCode. Clarified that `/plugin` commands run in Claude Code CLI, not the VSCode extension. Updated repository structure documentation for the new flat skills layout. ([#35](https://github.com/Aaronontheweb/dotnet-skills/pull/35), fixes [#32](https://github.com/Aaronontheweb/dotnet-skills/issues/32))

### Skill Enhancements

- **Akka.NET best practices** - Added actor logging guidance using `ILoggingAdapter` from `Context.GetLogger()` instead of DI-injected `ILogger<T>`, including semantic logging support in v1.5.59+. Added guidance on managing async operations with `CancellationToken` - actor-scoped CancellationTokenSource in PostStop(), linked CTS for per-operation timeouts, and graceful shutdown handling. ([#36](https://github.com/Aaronontheweb/dotnet-skills/pull/36), fixes [#29](https://github.com/Aaronontheweb/dotnet-skills/issues/29), [#31](https://github.com/Aaronontheweb/dotnet-skills/issues/31))

- **C# concurrency patterns** - Added guidance to prefer async local functions over `Task.Run(async () => ...)` and `ContinueWith()` for better stack traces, cleaner exception handling, and self-documenting code. Includes Akka.NET PipeTo example. ([#37](https://github.com/Aaronontheweb/dotnet-skills/pull/37), fixes [#30](https://github.com/Aaronontheweb/dotnet-skills/issues/30))

- **CRAP analysis** - Added exclusions for Blazor generated code (`*.razor.g.cs`, `*.razor.css.g.cs`), EF Core migrations (`**/Migrations/**/*`), and `ExcludeFromCodeCoverageAttribute` to the coverage configuration guidance. ([#38](https://github.com/Aaronontheweb/dotnet-skills/pull/38), fixes [#6](https://github.com/Aaronontheweb/dotnet-skills/issues/6))

### Issues Fixed

- [#6](https://github.com/Aaronontheweb/dotnet-skills/issues/6) - Update crap-analysis skill to exclude generated code by default
- [#29](https://github.com/Aaronontheweb/dotnet-skills/issues/29) - Add actor logging guidance to akka-net-best-practices skill
- [#30](https://github.com/Aaronontheweb/dotnet-skills/issues/30) - Add guidance on async local functions vs Task.Run/ContinueWith
- [#31](https://github.com/Aaronontheweb/dotnet-skills/issues/31) - Add guidance on cancellation tokens for long-running async operations in actors
- [#32](https://github.com/Aaronontheweb/dotnet-skills/issues/32) - Please clarify the install instructions

---

## v1.1.0 (2026-02-01)

Initial marketplace release with 30 skills and 5 agents covering the .NET ecosystem.

See [GitHub Release v1.1.0](https://github.com/Aaronontheweb/dotnet-skills/releases/tag/v1.1.0) for full details.

## v1.0.0 (2026-01-28)

Initial release.
