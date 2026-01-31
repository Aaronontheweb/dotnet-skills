# .NET Skills for Claude Code

A comprehensive Claude Code plugin with **27 skills** and **5 specialized agents** for professional .NET development. Battle-tested patterns from production systems covering C#, Akka.NET, Aspire, EF Core, testing, and performance optimization.

## Installation

Add the marketplace (one-time):

```
/plugin marketplace add Aaronontheweb/dotnet-skills
```

Install the plugin:

```
/plugin install dotnet-skills
```

To update:

```
/plugin marketplace update
```

---

## OpenCode Installation

OpenCode (https://opencode.ai/) is an open-source AI coding assistant that supports the same skill/agent format. These skills and agents are fully compatible with OpenCode.

### Manual Installation

#### 1.Clone the repository:

```bash
git clone https://github.com/Aaronontheweb/dotnet-skills.git
cd dotnet-skills
```

#### 2.Install skills:

```bash
# Create OpenCode skills directory
mkdir -p ~/.config/opencode/skills

# Install each skill (skill name must match frontmatter 'name' field)
for skill_file in $(find skills -name "SKILL.md"); do
    skill_name=$(grep -m1 "^name:" "$skill_file" | sed 's/name: *//')
    mkdir -p ~/.config/opencode/skills/$skill_name
cp "$skill_file" ~/.config/opencode/skills/$skill_name/SKILL.md
done
```

#### 3.Install agents:

```bash
# Create OpenCode agents directory
mkdir -p ~/.config/opencode/agents

# Install each agent
for agent_file in agents/\*.md; do
cp "$agent_file" ~/.config/opencode/agents/
done
```

#### 4. Restart OpenCode to load the new skills and agents.

### AI-Assisted Installation

If you're using OpenCode or another AI coding assistant, you can ask it to install these skills automatically:

```
Install the .NET skills from https://github.com/Aaronontheweb/dotnet-skills to my OpenCode configuration
```

> The AI will:

```
1. Clone the repository
2. Extract skill names from SKILL.md frontmatter
3. Create properly structured directories in ~/.config/opencode/skills/
4. Copy agent files to ~/.config/opencode/agents/
   Installed Locations
   | Type | Location |
   |------|----------|
   | Skills | ~/.config/opencode/skills/<skill-name>/SKILL.md |
   | Agents | ~/.config/opencode/agents/<agent-name>.md |
   Compatibility Note
   The SKILL.md and agent markdown formats follow the Agent Skills open standard (https://opencode.ai/docs/skills/), which is compatible with multiple AI coding tools including Claude Code and OpenCode.
```

---

## Suggested AGENTS.md / CLAUDE.md Snippets

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
|csharp:{modern-csharp-coding-standards,csharp-concurrency-patterns,api-design,type-design-performance}
|aspnetcore-web:{aspire-integration-testing,aspire-service-defaults,transactional-emails}
|data:{efcore-patterns,database-performance}
|di-config:{microsoft-extensions-configuration,dependency-injection-patterns}
|testing:{testcontainers-integration-tests,playwright-blazor-testing,snapshot-testing,playwright-ci-caching}
|dotnet:{dotnet-project-structure,dotnet-local-tools,package-management,serialization}
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

### ASP.NET Core

Web application patterns.

| Skill                    | What You'll Learn                                      |
| ------------------------ | ------------------------------------------------------ |
| **transactional-emails** | MJML templates, variable substitution, Mailpit testing |

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

| Skill                 | What You'll Learn                                             |
| --------------------- | ------------------------------------------------------------- |
| **testcontainers**    | Docker-based integration tests, PostgreSQL, Redis, RabbitMQ   |
| **playwright-blazor** | E2E testing for Blazor apps, page objects, async assertions   |
| **crap-analysis**     | CRAP scores, coverage thresholds, ReportGenerator integration |
| **snapshot-testing**  | Verify library, approval testing, API response validation     |

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
└── skills/                 # 25 comprehensive skills
    ├── akka/               # Akka.NET (5 skills)
    ├── aspire/             # .NET Aspire (2 skills)
    ├── aspnetcore/         # ASP.NET Core (1 skill)
    ├── csharp/             # C# language (4 skills)
    ├── data/               # Data access (2 skills)
    ├── dotnet/             # .NET ecosystem (5 skills)
    ├── microsoft-extensions/  # DI & config (2 skills)
    └── testing/            # Testing (4 skills)
```

---

## Contributing

Want to add a skill or agent? PRs welcome!

1. Create `skills/<category>/<skill-name>/SKILL.md` (or `agents/<name>/AGENT.md`)
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
