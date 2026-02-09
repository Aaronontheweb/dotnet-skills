# .NET Skills for Claude Code

A comprehensive Claude Code plugin with **30 skills** and **5 specialized agents** for professional .NET development. Battle-tested patterns from production systems covering C#, Akka.NET, Aspire, EF Core, testing, and performance optimization.

## Installation

This plugin works with multiple AI coding assistants that support skills/agents.

### Claude Code (CLI)

[Official Docs](https://code.claude.com/docs/en/discover-plugins)

Run these commands inside the Claude Code CLI (the terminal app, not the VSCode extension):

```
/plugin marketplace add Aaronontheweb/dotnet-skills
/plugin install dotnet-skills
```

To update:
```
/plugin marketplace update
```

### GitHub Copilot

[Official Docs](https://docs.github.com/en/copilot/concepts/agents/about-agent-skills)

Clone or copy skills to your project or global config:

**Project-level** (recommended):
```bash
# Clone to .github/skills/ in your project
git clone https://github.com/Aaronontheweb/dotnet-skills.git /tmp/dotnet-skills
cp -r /tmp/dotnet-skills/skills/* .github/skills/
```

**Global** (all projects):
```bash
mkdir -p ~/.copilot/skills
cp -r /tmp/dotnet-skills/skills/* ~/.copilot/skills/
```

### OpenCode

[Official Docs](https://opencode.ai/docs/skills)

```bash
git clone https://github.com/Aaronontheweb/dotnet-skills.git /tmp/dotnet-skills

# Global installation (directory names must match frontmatter 'name' field)
mkdir -p ~/.config/opencode/skills ~/.config/opencode/agents
for skill_file in /tmp/dotnet-skills/skills/*/SKILL.md; do
  skill_name=$(grep -m1 "^name:" "$skill_file" | sed 's/name: *//')
  mkdir -p ~/.config/opencode/skills/$skill_name
  cp "$skill_file" ~/.config/opencode/skills/$skill_name/SKILL.md
done
cp /tmp/dotnet-skills/agents/*.md ~/.config/opencode/agents/
```

---

## Suggested AGENTS.md / CLAUDE.md Snippets

These snippets go in your **project root** (the root directory of your codebase, next to your `.git` folder):
- Claude Code: `CLAUDE.md`
- OpenCode: `AGENTS.md`

Prerequisite: install/sync the dotnet-skills plugin in your assistant runtime (Claude Code or OpenCode) so the skill IDs below resolve.

To get consistent skill usage in downstream repos, add a small router snippet in `AGENTS.md` (OpenCode) or `CLAUDE.md` (Claude Code). These snippets tell the assistant which skills to use for common tasks.

### Readable snippet (copy/paste)

```markdown
# Agent Guidance: dotnet-skills

IMPORTANT: Prefer retrieval-led reasoning over pretraining for any .NET work.
Workflow: skim repo patterns -> consult dotnet-skills by name -> implement smallest-change -> note conflicts.

Routing (invoke by name)
- C# / code quality: modern-csharp-coding-standards, csharp-concurrency-patterns, api-design, type-design-performance
- ASP.NET Core / Web (incl. Aspire): aspire-service-defaults, aspire-integration-testing, transactional-emails
- Data: efcore-patterns, database-performance
- DI / config: dependency-injection-patterns, microsoft-extensions-configuration
- Testing: testcontainers-integration-tests, playwright-blazor-testing, snapshot-testing

Quality gates (use when applicable)
- dotnet-slopwatch: after substantial new/refactor/LLM-authored code
- crap-analysis: after tests added/changed in complex code

Specialist agents
- dotnet-concurrency-specialist, dotnet-performance-analyst, dotnet-benchmark-designer, akka-net-specialist, docfx-specialist
```

### Compressed snippet (generated)

Run `./scripts/generate-skill-index-snippets.sh --update-readme` to refresh the block below.

<!-- BEGIN DOTNET-SKILLS COMPRESSED INDEX -->
```markdown
[dotnet-skills]|IMPORTANT: Prefer retrieval-led reasoning over pretraining for any .NET work.
|flow:{skim repo patterns -> consult dotnet-skills by name -> implement smallest-change -> note conflicts}
|route:
|akka:{akka-net-best-practices,akka-net-testing-patterns,akka-hosting-actor-patterns,akka-net-aspire-configuration,akka-net-management}
|csharp:{modern-csharp-coding-standards,csharp-concurrency-patterns,api-design,type-design-performance}
|aspnetcore-web:{aspire-integration-testing,aspire-configuration,aspire-service-defaults,mailpit-integration,mjml-email-templates}
|data:{efcore-patterns,database-performance}
|di-config:{microsoft-extensions-configuration,dependency-injection-patterns}
|testing:{testcontainers-integration-tests,playwright-blazor-testing,snapshot-testing,verify-email-snapshots,playwright-ci-caching}
|dotnet:{dotnet-project-structure,dotnet-local-tools,package-management,serialization,dotnet-devcert-trust}
|quality-gates:{dotnet-slopwatch,crap-analysis}
|meta:{marketplace-publishing,skills-index-snippets}
|agents:{akka-net-specialist,docfx-specialist,dotnet-benchmark-designer,dotnet-concurrency-specialist,dotnet-performance-analyst}
```
<!-- END DOTNET-SKILLS COMPRESSED INDEX -->

## Specialized Agents

Agents are AI personas with deep domain expertise. They're invoked automatically when Claude Code detects relevant tasks.

| Agent                             | Expertise                                                              |
| --------------------------------- | ---------------------------------------------------------------------- |
| **akka-net-specialist**           | Actor systems, clustering, persistence, Akka.Streams, message patterns |
| **dotnet-concurrency-specialist** | Threading, async/await, race conditions, deadlock analysis             |
| **dotnet-benchmark-designer**     | BenchmarkDotNet setup, custom benchmarks, measurement strategies       |
| **dotnet-performance-analyst**    | Profiler analysis, benchmark interpretation, regression detection      |
| **docfx-specialist**              | DocFX builds, API documentation, markdown linting                      |

---

## Skills Library

### Akka.NET

Production patterns for building distributed systems with Akka.NET.

| Skill                      | What You'll Learn                                                           |
| -------------------------- | --------------------------------------------------------------------------- |
| **best-practices**         | EventStream vs DistributedPubSub, supervision strategies, actor hierarchies |
| **testing-patterns**       | Akka.Hosting.TestKit, async assertions, TestProbe patterns                  |
| **hosting-actor-patterns** | Props factories, `IRequiredActor<T>`, DI scope management in actors         |
| **aspire-configuration**   | Akka.NET + .NET Aspire integration, HOCON with IConfiguration               |
| **management**             | Akka.Management, health checks, cluster bootstrap                           |

### C# Language

Modern C# patterns for clean, performant code.

| Skill                       | What You'll Learn                                                       |
| --------------------------- | ----------------------------------------------------------------------- |
| **coding-standards**        | Records, pattern matching, nullable types, value objects, no AutoMapper |
| **concurrency-patterns**    | When to use Task vs Channel vs lock vs actors                           |
| **api-design**              | Extend-only design, API/wire compatibility, versioning strategies       |
| **type-design-performance** | Sealed classes, readonly structs, static pure functions, Span&lt;T&gt;  |

### Data Access

Database patterns that scale.

| Skill                    | What You'll Learn                                               |
| ------------------------ | --------------------------------------------------------------- |
| **efcore-patterns**      | Entity configuration, migrations, query optimization            |
| **database-performance** | Read/write separation, N+1 prevention, AsNoTracking, row limits |

### .NET Aspire

Cloud-native application orchestration.

| Skill                   | What You'll Learn                                            |
| ----------------------- | ------------------------------------------------------------ |
| **integration-testing** | DistributedApplicationTestingBuilder, Aspire.Hosting.Testing |
| **service-defaults**    | OpenTelemetry, health checks, resilience, service discovery  |
| **mailpit-integration** | Email testing with Mailpit container, SMTP config, test assertions |

### ASP.NET Core

Web application patterns.

| Skill                    | What You'll Learn                                         |
| ------------------------ | --------------------------------------------------------- |
| **mjml-email-templates** | MJML syntax, responsive layouts, template renderer, composer pattern |

### .NET Ecosystem

Core .NET development practices.

| Skill                  | What You'll Learn                                                      |
| ---------------------- | ---------------------------------------------------------------------- |
| **project-structure**  | Solution layout, Directory.Build.props, layered architecture           |
| **package-management** | Central Package Management (CPM), shared version variables, dotnet CLI |
| **serialization**      | Protobuf, MessagePack, System.Text.Json source generators, AOT         |
| **local-tools**        | dotnet tool manifests, team-shared tooling                             |
| **slopwatch**          | Detect LLM-generated anti-patterns in your codebase                    |

### Microsoft.Extensions

Dependency injection and configuration patterns.

| Skill                    | What You'll Learn                                                 |
| ------------------------ | ----------------------------------------------------------------- |
| **configuration**        | IOptions pattern, environment-specific config, secrets management |
| **dependency-injection** | IServiceCollection extensions, scope management, keyed services   |

### Testing

Comprehensive testing strategies.

| Skill                      | What You'll Learn                                             |
| -------------------------- | ------------------------------------------------------------- |
| **testcontainers**         | Docker-based integration tests, PostgreSQL, Redis, RabbitMQ   |
| **playwright-blazor**      | E2E testing for Blazor apps, page objects, async assertions   |
| **crap-analysis**          | CRAP scores, coverage thresholds, ReportGenerator integration |
| **snapshot-testing**       | Verify library, approval testing, API response validation     |
| **verify-email-snapshots** | Snapshot test email templates, catch rendering regressions    |

---

## Key Principles

These skills emphasize patterns that work in production:

- **Immutability by default** - Records, readonly structs, value objects
- **Type safety** - Nullable reference types, strongly-typed IDs
- **Composition over inheritance** - No abstract base classes, sealed by default
- **Performance-aware** - Span&lt;T&gt;, pooling, deferred enumeration
- **Testable** - DI everywhere, pure functions, explicit dependencies
- **No magic** - No AutoMapper, no reflection-heavy frameworks

---

## Repository Structure

```
dotnet-skills/
├── .claude-plugin/
│   └── plugin.json         # Plugin manifest
├── agents/                 # 5 specialized agents
│   ├── akka-net-specialist.md
│   ├── docfx-specialist.md
│   ├── dotnet-benchmark-designer.md
│   ├── dotnet-concurrency-specialist.md
│   └── dotnet-performance-analyst.md
└── skills/                 # Flat structure (30 skills)
    ├── akka-best-practices/SKILL.md
    ├── akka-hosting-actor-patterns/SKILL.md
    ├── akka-net-aspire-configuration/SKILL.md
    ├── aspire-configuration/SKILL.md
    ├── aspire-integration-testing/SKILL.md
    ├── csharp-concurrency-patterns/SKILL.md
    ├── testcontainers-integration-tests/SKILL.md
    └── ...                 # (prefixed by category)
```

---

## Contributing

Want to add a skill or agent? PRs welcome!

1. Create `skills/<skill-name>/SKILL.md` (use prefixes like `akka-`, `aspire-`, `csharp-` for category)
2. Add the path to `.claude-plugin/plugin.json`
3. Submit a PR

Skills should be comprehensive reference documents (10-40KB) with concrete examples and anti-patterns.

---

## Author

Created by [Aaron Stannard](https://aaronstannard.com/) ([@Aaronontheweb](https://github.com/Aaronontheweb))

Patterns drawn from production systems including [Akka.NET](https://getakka.net/), [Petabridge](https://petabridge.com/), and [Sdkbin](https://sdkbin.com/).

## License

MIT License - Copyright (c) 2025 Aaron Stannard

See [LICENSE](LICENSE) for full details.
