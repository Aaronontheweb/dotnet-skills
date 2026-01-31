# .NET Skills for Coding Agents

A comprehensive plugin marketplace with **27 skills** and **5 specialized agents** for professional .NET development. Battle-tested patterns from production systems covering C#, Akka.NET, Aspire, EF Core, testing, and performance optimization.

## Installation (Claude Code / GitHub Copilot)

Add the marketplace (one-time):

```
/plugin marketplace add Aaronontheweb/dotnet-skills
```

Install plugins by category:

```
/plugin install akka@dotnet-skills
/plugin install csharp@dotnet-skills
/plugin install testing@dotnet-skills
```

To see available plugins:

```
/plugin marketplace list dotnet-skills
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
for skill_file in $(find plugins -name "SKILL.md"); do
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
for agent_file in $(find plugins -path "*/agents/*.md"); do
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
4. Copy agent files from plugins/*/agents/ to ~/.config/opencode/agents/
   Installed Locations
   | Type | Location |
   |------|----------|
   | Skills | ~/.config/opencode/skills/<skill-name>/SKILL.md |
   | Agents | ~/.config/opencode/agents/<agent-name>.md |
   Compatibility Note
   The SKILL.md and agent markdown formats follow the Agent Skills open standard (https://opencode.ai/docs/skills/), which is compatible with multiple AI coding tools including Claude Code and OpenCode.
```

## Available Plugins

| Plugin | Skills | Agents | Description |
|--------|--------|--------|-------------|
| **akka** | 5 | 2 | Akka.NET actor systems, clustering, persistence |
| **aspire** | 2 | 0 | .NET Aspire cloud-native orchestration |
| **aspnetcore** | 1 | 0 | ASP.NET Core web patterns |
| **csharp** | 4 | 1 | Modern C# language patterns |
| **data** | 2 | 0 | EF Core and database patterns |
| **dotnet** | 5 | 0 | Core .NET development practices |
| **meta** | 2 | 0 | Marketplace publishing skills |
| **microsoft-extensions** | 2 | 0 | DI and configuration patterns |
| **testing** | 4 | 2 | Testing frameworks and patterns |

---

## Suggested AGENTS.md / CLAUDE.md Snippets

Prerequisite: install the plugins from dotnet-skills marketplace so the skill IDs below resolve.

To get consistent skill usage in downstream repos, add a small router snippet in `AGENTS.md` (OpenCode, GitHub Copilot) or `CLAUDE.md` (Claude Code). These snippets tell the assistant which skills to use for common tasks.

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
|testing:{testcontainers-integration-tests,playwright-blazor-testing,snapshot-testing}
|dotnet:{dotnet-project-structure,dotnet-local-tools,package-management,serialization}
|quality-gates:{dotnet-slopwatch,crap-analysis}
|meta:{marketplace-publishing,skills-index-snippets}
|agents:{akka-net-specialist,docfx-specialist,dotnet-benchmark-designer,dotnet-concurrency-specialist,dotnet-performance-analyst}
```
<!-- END DOTNET-SKILLS COMPRESSED INDEX -->

## Specialized Agents

Agents are AI personas with deep domain expertise. They're bundled with the relevant plugin.

| Agent                             | Plugin | Expertise                                                              |
| --------------------------------- | ------ | ---------------------------------------------------------------------- |
| **akka-net-specialist**           | akka   | Actor systems, clustering, persistence, Akka.Streams, message patterns |
| **docfx-specialist**              | akka   | DocFX builds, API documentation, markdown linting                      |
| **dotnet-concurrency-specialist** | csharp | Threading, async/await, race conditions, deadlock analysis             |
| **dotnet-benchmark-designer**     | testing | BenchmarkDotNet setup, custom benchmarks, measurement strategies       |
| **dotnet-performance-analyst**    | testing | Profiler analysis, benchmark interpretation, regression detection      |

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

---

## Repository Structure

```
dotnet-skills/
├── .github/
│   └── plugin/
│       └── marketplace.json    # Plugin registry
└── plugins/                    # 9 category-based plugins
    ├── akka/
    │   ├── skills/             # 5 Akka.NET skills
    │   └── agents/             # 2 agents
    ├── csharp/
    │   ├── skills/             # 4 C# skills
    │   └── agents/             # 1 agent
    ├── testing/
    │   ├── skills/             # 4 testing skills
    │   └── agents/             # 2 agents
    └── ...
```

---

## Contributing

Want to add a skill or agent? PRs welcome!

1. Skills: Create `plugins/<plugin>/skills/<skill-name>/SKILL.md`
2. Agents: Create `plugins/<plugin>/agents/<agent-name>.md`
3. Submit a PR

For a new category, also add the plugin to `.github/plugin/marketplace.json`.

Skills should be comprehensive reference documents (10-40KB) with concrete examples and anti-patterns.

---

## Author

Created by [Aaron Stannard](https://aaronstannard.com/) ([@Aaronontheweb](https://github.com/Aaronontheweb))

Patterns drawn from production systems including [Akka.NET](https://getakka.net/), [Petabridge](https://petabridge.com/), and [Sdkbin](https://sdkbin.com/).

## License

MIT License - Copyright (c) 2025 Aaron Stannard

See [LICENSE](LICENSE) for full details.
