---
name: akka-net-testing-patterns
description: Write unit and integration tests for Akka.NET actors using modern Akka.Hosting.TestKit patterns. Covers dependency injection, TestProbes, persistence testing, and actor interaction verification. Includes guidance on when to use traditional TestKit.
invocable: false
---

# Akka.NET Testing Patterns

## When to Use This Skill

Use this skill when:
- Writing unit tests for Akka.NET actors
- Testing persistent actors with event sourcing
- Verifying actor interactions and message flows
- Testing actor supervision and lifecycle
- Mocking external dependencies in actor tests
- Testing cluster sharding behavior locally
- Verifying actor state recovery and persistence

## Reference Files

- [examples.md](examples.md): Complete code samples for all testing patterns (Patterns 1-8 plus Reminders)
- [anti-patterns-and-reference.md](anti-patterns-and-reference.md): Anti-patterns, traditional TestKit, CI/CD integration

## Choosing Your Testing Approach

### Use Akka.Hosting.TestKit (Recommended for 95% of Use Cases)

**When:**
- Building modern .NET applications with `Microsoft.Extensions.DependencyInjection`
- Using Akka.Hosting for actor configuration in production
- Need to inject services into actors (`IOptions`, `DbContext`, `ILogger`, HTTP clients, etc.)
- Testing applications that use ASP.NET Core, Worker Services, or .NET Aspire
- Working with modern Akka.NET projects (Akka.NET v1.5+)

**Advantages:**
- Native dependency injection support - override services with fakes in tests
- Configuration parity with production (same extension methods work in tests)
- Clean separation between actor logic and infrastructure
- Type-safe actor registry for retrieving actors

### Use Traditional Akka.TestKit

**When:**
- Contributing to Akka.NET core library development
- Working in environments without `Microsoft.Extensions` (console apps, legacy systems)
- Legacy codebases using manual `Props` creation without DI

See [anti-patterns-and-reference.md](anti-patterns-and-reference.md) for traditional TestKit patterns.

---

## Core Principles (Akka.Hosting.TestKit)

1. **Inherit from `Akka.Hosting.TestKit.TestKit`** - This is a framework base class, not a user-defined one
2. **Override `ConfigureServices()`** - Replace real services with fakes/mocks
3. **Override `ConfigureAkka()`** - Configure actors using the same extension methods as production
4. **Use `ActorRegistry`** - Type-safe retrieval of actor references
5. **Composition over Inheritance** - Fake services as fields, not base classes
6. **No Custom Base Classes** - Use method overrides, not inheritance hierarchies
7. **Test One Actor at a Time** - Use TestProbes for dependencies
8. **Match Production Patterns** - Same extension methods, different `AkkaExecutionMode`

---

## Required NuGet Packages

```xml
<ItemGroup>
  <!-- Core testing framework -->
  <PackageReference Include="Akka.Hosting.TestKit" Version="*" />

  <!-- xUnit (or your preferred test framework) -->
  <PackageReference Include="xunit" Version="*" />
  <PackageReference Include="xunit.runner.visualstudio" Version="*" />
  <PackageReference Include="Microsoft.NET.Test.Sdk" Version="*" />

  <!-- Assertions (recommended) -->
  <PackageReference Include="FluentAssertions" Version="*" />

  <!-- In-memory persistence for testing -->
  <PackageReference Include="Akka.Persistence.Hosting" Version="*" />

  <!-- If testing cluster sharding -->
  <PackageReference Include="Akka.Cluster.Hosting" Version="*" />
</ItemGroup>
```

---

## CRITICAL: File Watcher Fix for Test Projects

Akka.Hosting.TestKit spins up real `IHost` instances, which by default enable file watchers for configuration reload. When running many tests, this exhausts file descriptor limits on Linux (inotify watch limit).

**Add this to your test project - it runs before any tests execute:**

```csharp
// TestEnvironmentInitializer.cs
using System.Runtime.CompilerServices;

namespace YourApp.Tests;

internal static class TestEnvironmentInitializer
{
    [ModuleInitializer]
    internal static void Initialize()
    {
        // Disable config file watching in test hosts
        // Prevents file descriptor exhaustion (inotify watch limit) on Linux
        Environment.SetEnvironmentVariable("DOTNET_HOSTBUILDER__RELOADCONFIGONCHANGE", "false");
    }
}
```

**Why this matters:**
- `[ModuleInitializer]` runs automatically before any test code
- Sets the environment variable globally for all `IHost` instances
- Prevents cryptic `inotify` errors when running 100+ tests
- Also applies to Aspire integration tests that use `IHost`

---

## Testing Patterns Overview

Each pattern below has a condensed description. See [examples.md](examples.md) for complete code samples.

### Pattern 1: Basic Actor Test

The foundation pattern. Override `ConfigureServices()` to inject fakes, override `ConfigureAkka()` to register actors with the same extension methods as production.

```csharp
public class OrderActorTests : TestKit
{
    private readonly FakeOrderRepository _fakeRepository = new();

    protected override void ConfigureServices(HostBuilderContext context, IServiceCollection services)
    {
        services.AddSingleton<IOrderRepository>(_fakeRepository);
    }

    protected override void ConfigureAkka(AkkaConfigurationBuilder builder, IServiceProvider provider)
    {
        builder.WithInMemoryJournal().WithInMemorySnapshotStore();
        builder.WithActors((system, registry, resolver) =>
        {
            registry.Register<OrderActor>(system.ActorOf(resolver.Props<OrderActor>(), "order-actor"));
        });
    }

    [Fact]
    public async Task CreateOrder_Success_SavesToRepository()
    {
        var orderActor = ActorRegistry.Get<OrderActor>();
        var response = await orderActor.Ask<OrderCommandResult>(
            new CreateOrder("ORDER-123", "CUST-456", 99.99m), RemainingOrDefault);
        response.Status.Should().Be(CommandStatus.Success);
        _fakeRepository.SaveCallCount.Should().Be(1);
    }
}
```

### Pattern 2: TestProbe for Actor Interactions

Register a `TestProbe` in the `ActorRegistry` as a stand-in for a dependency actor. Use `ExpectMsgAsync<T>()` to verify messages were sent.

### Pattern 3: Auto-Responding TestProbe

When the actor under test uses `Ask` to communicate with dependencies, create an auto-responder actor that forwards messages to a probe AND replies to avoid timeouts.

### Pattern 4: Testing Persistent Actors

Use `WithInMemoryJournal()` and `WithInMemorySnapshotStore()`. Test recovery by killing the actor with `PoisonPill` and querying to force recovery from journal.

### Pattern 5: Reuse Production Configuration

**Always reuse production extension methods** in tests instead of duplicating HOCON config. This ensures tests use the exact same configuration as production.

```csharp
protected override void ConfigureAkka(AkkaConfigurationBuilder builder, IServiceProvider provider)
{
    builder
        .AddDraftSerializer()                                    // Same as production
        .AddOrderDomainActors(AkkaExecutionMode.LocalTest)      // Same, but local mode
        .WithInMemoryJournal().WithInMemorySnapshotStore();      // Test-specific overrides
}
```

### Pattern 6: Cluster Sharding Locally

Use `AkkaExecutionMode.LocalTest` with `GenericChildPerEntityParent` to test sharding behavior without an actual cluster. Same extension methods, different mode.

### Pattern 7: AwaitAssertAsync for Async Operations

Use `AwaitAssertAsync` when actors perform async operations. It retries assertions until they pass or timeout, preventing flaky tests.

```csharp
await AwaitAssertAsync(() =>
{
    _fakeReadModelService.SyncCallCount.Should().BeGreaterOrEqualTo(1);
}, TimeSpan.FromSeconds(3));
```

### Pattern 8: Scenario-Based Integration Tests

Test complete business workflows end-to-end with multiple actors and state transitions. Register all domain actors, verify state at each step.

---

## Common Patterns Summary

| Pattern | Use Case |
|---------|----------|
| Basic Actor Test | Single actor with injected services |
| TestProbe | Verify actor sends messages to dependencies |
| Auto-Responder | Avoid `Ask` timeouts when testing |
| Persistent Actor | Test event sourcing and recovery |
| Cluster Sharding | Test sharding behavior locally |
| AwaitAssertAsync | Handle async operations in actors |
| Scenario Tests | End-to-end business workflows |

---

## Best Practices

1. **One test class per actor** - Keep tests focused
2. **Override ConfigureServices/ConfigureAkka** - Don't create base classes
3. **Use fakes, not mocks** - Simpler, more maintainable
4. **Test one actor at a time** - Use TestProbes for dependencies
5. **Match production patterns** - Same extension methods, different `AkkaExecutionMode`
6. **Use AwaitAssertAsync for async** - Prevents flaky tests
7. **Test recovery** - Kill and restart actors to verify persistence
8. **Scenario tests for workflows** - Test complete business flows end-to-end
9. **Keep tests fast** - In-memory persistence, no real databases
10. **Use meaningful names** - `Scenario_FirstTimePurchase_SuccessfulPayment`

---

## Debugging Tips

1. **Enable debug logging** - Pass `LogLevel.Debug` to TestKit constructor
2. **Use ITestOutputHelper** - See actor system logs in test output
3. **Inspect TestProbe** - Check `probe.Messages` to see what was sent
4. **Query actor state** - Add state query messages for debugging
5. **Use AwaitAssertAsync with logging** - See why assertions fail
6. **Check ActorRegistry** - Verify actors are registered correctly

```csharp
// Constructor with debug logging
public OrderActorTests(ITestOutputHelper output)
    : base(output: output, logLevel: LogLevel.Debug)
{
}
```
