# .NET Skills for Claude Code

A Claude Code plugin marketplace with comprehensive skills and specialized agents for modern .NET development.

## Installation

```bash
# Add the marketplace (one-time)
/plugin marketplace add Aaronontheweb/dotnet-skills

# Install the plugin (includes all skills and agents)
/plugin install dotnet-skills
```

To update to the latest version:
```bash
/plugin marketplace update
```

## What's Included

This plugin includes **5 specialized agents** and **9 comprehensive skills** for C# and .NET development.

### Agents

| Agent | Expertise |
|-------|-----------|
| **akka-net-specialist** | Akka.NET architecture, actor systems, distributed computing |
| **dotnet-concurrency-specialist** | .NET concurrency, threading, race condition analysis |
| **dotnet-benchmark-designer** | Designing effective .NET performance benchmarks |
| **dotnet-performance-analyst** | Analyzing .NET performance data and profiling results |
| **docfx-specialist** | DocFX documentation system and markdown formatting |

### Skills

#### Akka.NET (`skills/akka/`)
- **best-practices** - EventStream vs DistributedPubSub, supervision strategies, error handling patterns
- **testing-patterns** - Testing Akka.NET actors with Akka.Hosting.TestKit
- **hosting-actor-patterns** - Props, IRequiredActor<T>, and dependency injection
- **aspire-configuration** - Configuring Akka.NET with .NET Aspire

#### .NET Aspire (`skills/aspire/`)
- **integration-testing** - Testing strategies for .NET Aspire applications

#### C# (`skills/csharp/`)
- **coding-standards** - Modern C# best practices: records, pattern matching, nullable types, Span<T>

#### Testing (`skills/testing/`)
- **testcontainers** - Using Testcontainers for .NET integration testing
- **playwright-blazor** - End-to-end testing for Blazor with Playwright

#### Meta (`skills/meta/`)
- **marketplace-publishing** - How to contribute to this marketplace

## Repository Structure

```
dotnet-skills/
├── .claude-plugin/
│   ├── marketplace.json    # Marketplace catalog
│   └── plugin.json         # Plugin metadata (version, skills, agents)
├── skills/
│   ├── akka/               # Akka.NET skills
│   ├── aspire/             # .NET Aspire skills
│   ├── csharp/             # C# language skills
│   ├── testing/            # Testing framework skills
│   └── meta/               # Meta skills
├── agents/                 # Specialized agent definitions
└── scripts/
    └── validate-marketplace.sh
```

## Key Principles

These skills emphasize:

- **Immutability by default** - Records and value objects
- **Type safety** - Nullable reference types and strong typing
- **Modern patterns** - Pattern matching, async/await everywhere
- **Performance** - Zero-allocation patterns with Span<T>/Memory<T>
- **Composition over inheritance** - Avoid abstract base classes

## Contributing

See `skills/meta/marketplace-publishing/SKILL.md` for the full workflow.

**Quick start:**
1. Create a skill folder: `skills/<category>/<skill-name>/SKILL.md`
2. Add the path to `.claude-plugin/plugin.json`
3. Run `./scripts/validate-marketplace.sh`
4. Submit a PR

## License

MIT License - Copyright (c) 2025 Aaron Stannard <https://aaronstannard.com/>

See [LICENSE](LICENSE) for full details.
