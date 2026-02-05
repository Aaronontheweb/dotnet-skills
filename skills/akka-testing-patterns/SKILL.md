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

## Choosing Your Testing Approach

### ✅ Use Akka.Hosting.TestKit (Recommended for 95% of Use Cases)

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
- Better integration with .NET ecosystem
- Type-safe actor registry for retrieving actors
- Supports both local and clustered testing modes

**This guide focuses primarily on Akka.Hosting.TestKit patterns.**

### ⚠️ Use Traditional Akka.TestKit

**When:**
- Contributing to Akka.NET core library development
- Working in environments without `Microsoft.Extensions` (console apps, legacy systems)
- Legacy codebases using manual `Props` creation without DI
- Need direct control over low-level ActorSystem configuration
- Working with Akka.NET projects pre-v1.5

**Note:** If starting a new project in 2025+, strongly prefer Akka.Hosting.TestKit unless you have specific constraints.

Traditional TestKit patterns are covered briefly at the end of this document.

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

## Pattern 1: Basic Actor Test with Akka.Hosting.TestKit

```csharp
using Akka.Actor;
using Akka.Hosting;
using Akka.Hosting.TestKit;
using Akka.Persistence.Hosting;
using FluentAssertions;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.Hosting;
using Xunit;
using Xunit.Abstractions;

namespace MyApp.Tests;

/// <summary>
/// Tests for OrderActor demonstrating modern Akka.Hosting.TestKit patterns.
/// </summary>
public class OrderActorTests : TestKit
{
    private readonly FakeOrderRepository _fakeRepository;
    private readonly FakeEmailService _fakeEmailService;

    public OrderActorTests(ITestOutputHelper output) : base(output: output)
    {
        // Create fake services as fields (composition, not inheritance)
        _fakeRepository = new FakeOrderRepository();
        _fakeEmailService = new FakeEmailService();
    }

    /// <summary>
    /// Override ConfigureServices to inject fake services.
    /// This runs BEFORE ConfigureAkka, so services are available to actors.
    /// </summary>
    protected override void ConfigureServices(HostBuilderContext context, IServiceCollection services)
    {
        // Register fakes as singletons (same instance used across all actors)
        services.AddSingleton<IOrderRepository>(_fakeRepository);
        services.AddSingleton<IEmailService>(_fakeEmailService);
        services.AddLogging();
    }

    /// <summary>
    /// Override ConfigureAkka to configure actor system for testing.
    /// This is where you register actors using the same extension methods as production.
    /// </summary>
    protected override void ConfigureAkka(AkkaConfigurationBuilder builder, IServiceProvider provider)
    {
        // Use TestScheduler for time control
        builder.AddHocon("akka.scheduler.implementation = \"Akka.TestKit.TestScheduler, Akka.TestKit\"",
            HoconAddMode.Prepend);

        // In-memory persistence (no database needed)
        builder.WithInMemoryJournal()
            .WithInMemorySnapshotStore();

        // Register actors using the same extension methods as production
        builder.WithActors((system, registry, resolver) =>
        {
            // Create actor with dependency injection
            var props = resolver.Props<OrderActor>();
            var actor = system.ActorOf(props, "order-actor");

            // Register in ActorRegistry for type-safe retrieval
            registry.Register<OrderActor>(actor);
        });
    }

    [Fact]
    public async Task CreateOrder_Success_SavesToRepository()
    {
        // Arrange
        var orderActor = ActorRegistry.Get<OrderActor>();
        var command = new CreateOrder(OrderId: "ORDER-123", CustomerId: "CUST-456", Amount: 99.99m);

        // Act
        var response = await orderActor.Ask<OrderCommandResult>(command, RemainingOrDefault);

        // Assert
        response.Status.Should().Be(CommandStatus.Success);

        // Verify fake repository was called
        _fakeRepository.SaveCallCount.Should().Be(1);
        _fakeRepository.LastSavedOrderId.Should().Be("ORDER-123");
    }

    [Fact]
    public async Task CreateOrder_RepositoryFails_ReturnsError()
    {
        // Arrange
        _fakeRepository.FailNextSave = true;
        var orderActor = ActorRegistry.Get<OrderActor>();
        var command = new CreateOrder(OrderId: "ORDER-789", CustomerId: "CUST-456", Amount: 99.99m);

        // Act
        var response = await orderActor.Ask<OrderCommandResult>(command, RemainingOrDefault);

        // Assert
        response.Status.Should().Be(CommandStatus.Failed);
        response.ErrorMessage.Should().NotBeNullOrEmpty();
    }
}

// ============================================================================
// FAKE SERVICE IMPLEMENTATIONS (Composition, not inheritance)
// ============================================================================

public sealed class FakeOrderRepository : IOrderRepository
{
    public int SaveCallCount { get; private set; }
    public string? LastSavedOrderId { get; private set; }
    public bool FailNextSave { get; set; }

    public Task SaveOrderAsync(string orderId, decimal amount)
    {
        SaveCallCount++;
        LastSavedOrderId = orderId;

        if (FailNextSave)
        {
            FailNextSave = false;
            throw new InvalidOperationException("Simulated repository failure");
        }

        return Task.CompletedTask;
    }
}

public sealed class FakeEmailService : IEmailService
{
    public int SendCallCount { get; private set; }
    public string? LastEmailRecipient { get; private set; }

    public Task SendEmailAsync(string recipient, string subject, string body)
    {
        SendCallCount++;
        LastEmailRecipient = recipient;
        return Task.CompletedTask;
    }
}
```

**Key Takeaways:**
- `TestKit` is a **framework base class**, not a user-defined one
- Fake services are **fields** (composition), not inherited
- `ConfigureServices()` overrides DI registrations
- `ConfigureAkka()` uses same extension methods as production
- `ActorRegistry.Get<T>()` provides type-safe actor retrieval

---

## Pattern 2: Testing Actor Interactions with TestProbes

Use `TestProbe` to verify that your actor sends messages to other actors without needing the full implementation.

```csharp
public class InvoiceActorTests : TestKit
{
    private readonly FakeInvoiceService _fakeInvoiceService;
    private TestProbe? _paymentProbe;

    public InvoiceActorTests(ITestOutputHelper output) : base(output: output)
    {
        _fakeInvoiceService = new FakeInvoiceService();
    }

    /// <summary>
    /// Property that creates TestProbe on first access (lazy initialization).
    /// </summary>
    private TestProbe PaymentProbe => _paymentProbe ??= CreateTestProbe("payment-probe");

    protected override void ConfigureServices(HostBuilderContext context, IServiceCollection services)
    {
        services.AddSingleton<IInvoiceService>(_fakeInvoiceService);
    }

    protected override void ConfigureAkka(AkkaConfigurationBuilder builder, IServiceProvider provider)
    {
        builder.WithInMemoryJournal().WithInMemorySnapshotStore();

        builder.WithActors((system, registry, resolver) =>
        {
            // Register TestProbe as PaymentActor for verification
            _paymentProbe = CreateTestProbe("payment-probe");
            registry.Register<PaymentActor>(_paymentProbe);

            // Register InvoiceActor (actor under test)
            var invoiceProps = resolver.Props<InvoiceActor>();
            var invoiceActor = system.ActorOf(invoiceProps, "invoice-actor");
            registry.Register<InvoiceActor>(invoiceActor);
        });
    }

    [Fact]
    public async Task CreateInvoice_Success_SendsPaymentRequest()
    {
        // Arrange
        var invoiceActor = ActorRegistry.Get<InvoiceActor>();
        var command = new CreateInvoice(InvoiceId: "INV-001", Amount: 100.00m);

        // Act
        var response = await invoiceActor.Ask<InvoiceCommandResult>(command, RemainingOrDefault);

        // Assert - Command succeeded
        response.Status.Should().Be(CommandStatus.Success);

        // Assert - Payment request was sent to PaymentActor
        var paymentRequest = await PaymentProbe.ExpectMsgAsync<InitiatePayment>(TimeSpan.FromSeconds(3));
        paymentRequest.InvoiceId.Should().Be("INV-001");
        paymentRequest.Amount.Should().Be(100.00m);
    }

    [Fact]
    public async Task PaymentCompleted_UpdatesInvoiceState()
    {
        // Arrange
        var invoiceActor = ActorRegistry.Get<InvoiceActor>();

        // Create invoice first
        await invoiceActor.Ask<InvoiceCommandResult>(
            new CreateInvoice(InvoiceId: "INV-002", Amount: 50.00m),
            RemainingOrDefault);

        // Drain the InitiatePayment message
        await PaymentProbe.ExpectMsgAsync<InitiatePayment>();

        // Act - Notify invoice that payment completed
        var notification = new PaymentCompleted(InvoiceId: "INV-002", Amount: 50.00m);
        invoiceActor.Tell(notification);

        // Assert - Query state to verify update
        var stateQuery = await invoiceActor.Ask<InvoiceState>(
            new GetInvoiceState("INV-002"),
            RemainingOrDefault);

        stateQuery.Status.Should().Be(InvoiceStatus.Paid);
        stateQuery.AmountPaid.Should().Be(50.00m);
    }
}
```

**Key Patterns:**
- **TestProbe as lazy property** - Created on first access
- **Register TestProbe in ActorRegistry** - Acts as a fake actor
- **ExpectMsgAsync<T>()** - Verifies message was sent
- **Drain messages** - Use `ExpectMsgAsync()` to clear expected messages before proceeding

---

## Pattern 3: Auto-Responding TestProbe (Avoiding Ask Timeouts)

When an actor uses `Ask` to talk to another actor, the sender expects a response. Use an auto-responder to prevent timeouts.

```csharp
/// <summary>
/// Auto-responding actor that forwards all messages to a TestProbe while automatically
/// replying to specific message types to avoid Ask timeouts.
/// </summary>
internal sealed class PaymentAutoResponder : ReceiveActor
{
    private readonly IActorRef _probe;

    public PaymentAutoResponder(IActorRef probe)
    {
        _probe = probe;

        // Auto-respond to InitiatePayment with PaymentStarted
        Receive<InitiatePayment>(msg =>
        {
            _probe.Tell(msg, Sender); // Forward to probe for verification

            var response = new PaymentStarted(
                PaymentId: msg.PaymentId,
                InvoiceId: msg.InvoiceId);

            Sender.Tell(response, Self); // Auto-reply to avoid timeout
        });

        // Forward all other messages without auto-responding
        ReceiveAny(msg => _probe.Tell(msg, Sender));
    }
}

// Usage in ConfigureAkka:
protected override void ConfigureAkka(AkkaConfigurationBuilder builder, IServiceProvider provider)
{
    builder.WithActors((system, registry, resolver) =>
    {
        _paymentProbe = CreateTestProbe("payment-probe");

        // Create auto-responder that forwards to probe
        var autoResponder = system.ActorOf(
            Props.Create(() => new PaymentAutoResponder(_paymentProbe)),
            "payment-auto-responder");

        registry.Register<PaymentActor>(autoResponder);

        // Register actor under test
        var invoiceActor = system.ActorOf(resolver.Props<InvoiceActor>(), "invoice-actor");
        registry.Register<InvoiceActor>(invoiceActor);
    });
}
```

**When to Use:**
- Actor under test uses `Ask` to communicate with dependencies
- You want to verify the message was sent (probe) AND avoid timeout
- Complex interaction patterns with multiple round-trips

---

## Pattern 4: Testing Persistent Actors with Event Sourcing

```csharp
public class OrderPersistentActorTests : TestKit
{
    public OrderPersistentActorTests(ITestOutputHelper output) : base(output: output)
    {
    }

    protected override void ConfigureAkka(AkkaConfigurationBuilder builder, IServiceProvider provider)
    {
        // Configure TestScheduler
        builder.AddHocon("akka.scheduler.implementation = \"Akka.TestKit.TestScheduler, Akka.TestKit\"",
            HoconAddMode.Prepend);

        // In-memory persistence (events stored in memory, cleared after test)
        builder.WithInMemoryJournal()
            .WithInMemorySnapshotStore();

        builder.WithActors((system, registry, resolver) =>
        {
            var props = resolver.Props<OrderPersistentActor>("order-123");
            var actor = system.ActorOf(props, "order-persistent-actor");
            registry.Register<OrderPersistentActor>(actor);
        });
    }

    [Fact]
    public async Task CreateOrder_PersistsEvent()
    {
        // Arrange
        var actor = ActorRegistry.Get<OrderPersistentActor>();
        var command = new CreateOrder(OrderId: "ORDER-123", Amount: 100.00m);

        // Act
        var response = await actor.Ask<OrderCommandResult>(command, RemainingOrDefault);

        // Assert
        response.Status.Should().Be(CommandStatus.Success);

        // Query state to verify event was applied
        var state = await actor.Ask<OrderState>(new GetOrderState("ORDER-123"), RemainingOrDefault);
        state.OrderId.Should().Be("ORDER-123");
        state.Amount.Should().Be(100.00m);
        state.Status.Should().Be(OrderStatus.Created);
    }

    [Fact]
    public async Task ActorRecovery_AfterPassivation_RestoresState()
    {
        // Arrange - Create order and persist events
        var actor = ActorRegistry.Get<OrderPersistentActor>();
        await actor.Ask<OrderCommandResult>(
            new CreateOrder(OrderId: "ORDER-456", Amount: 200.00m),
            RemainingOrDefault);

        // Get reference to the actual actor (not the registry wrapper)
        var childActorPath = actor.Path / "order-456";
        var childActor = await Sys.ActorSelection(childActorPath).ResolveOne(TimeSpan.FromSeconds(3));

        // Act - Kill the actor to simulate passivation
        await WatchAsync(childActor);
        childActor.Tell(PoisonPill.Instance);
        await ExpectTerminatedAsync(childActor);

        // Send a query which forces the actor to recover from journal
        var state = await actor.Ask<OrderState>(
            new GetOrderState("ORDER-456"),
            RemainingOrDefault);

        // Assert - Verify state was recovered correctly
        state.Should().NotBeNull();
        state.OrderId.Should().Be("ORDER-456");
        state.Amount.Should().Be(200.00m);
        state.Status.Should().Be(OrderStatus.Created);
    }
}
```

**Key Patterns:**
- **In-memory journal** - No database needed, fast tests
- **Recovery testing** - Use `PoisonPill` to kill actor, then query to force recovery
- **WatchAsync/ExpectTerminatedAsync** - Verify actor actually terminated before proceeding

---

## Pattern 5: Reuse Production Configuration Extension Methods

When your production code uses custom `AkkaConfigurationBuilder` extension methods (for serializers, actors, persistence), your tests should use those same extension methods rather than duplicating HOCON configuration.

### Anti-Pattern: Duplicated Configuration

```csharp
// BAD: Duplicating HOCON config that already exists in an extension method
public class DraftSerializerTests : Akka.TestKit.Xunit2.TestKit
{
    public DraftSerializerTests() : base(ConfigurationFactory.ParseString(@"
        akka.actor {
            serializers {
                proto = ""MyApp.Serialization.DraftSerializer, MyApp""
            }
            serialization-bindings {
                ""MyApp.Messages.IDraftEvent, MyApp"" = proto
                ""MyApp.Actors.DraftState, MyApp"" = proto
            }
        }
    "))
    { }
}
```

**Problems with duplicated config:**
- Two places to update when bindings change
- Tests can pass while production fails (or vice versa)
- Easy to forget to add new bindings to tests
- Doesn't actually test the extension method itself

### Correct Pattern: Reuse Extension Methods

```csharp
// Production extension method (in your main project)
public static class AkkaSerializerExtensions
{
    public static AkkaConfigurationBuilder AddDraftSerializer(
        this AkkaConfigurationBuilder builder)
    {
        return builder.WithCustomSerializer(
            serializerIdentifier: "draft-proto",
            boundTypes: [typeof(IDraftEvent), typeof(DraftState)],
            serializerFactory: system => new DraftSerializer(system));
    }
}

// GOOD: Test reuses the same extension method
public class DraftSerializerTests : Akka.Hosting.TestKit.TestKit
{
    public DraftSerializerTests(ITestOutputHelper output) : base(output: output) { }

    protected override void ConfigureAkka(AkkaConfigurationBuilder builder, IServiceProvider provider)
    {
        // Use the SAME extension method as production
        builder.AddDraftSerializer();

        // Add test-specific config (in-memory persistence, etc.)
        builder.WithInMemoryJournal()
            .WithInMemorySnapshotStore();
    }

    [Fact]
    public async Task DraftSerializer_RoundTrips_DraftCreatedEvent()
    {
        // Arrange
        var original = new DraftCreated(DraftId.New(), "Test Draft", DateTime.UtcNow);

        // Act - serialize and deserialize through the actor system
        var serializer = Sys.Serialization.FindSerializerFor(original);
        var bytes = serializer.ToBinary(original);
        var deserialized = serializer.FromBinary(bytes, typeof(DraftCreated));

        // Assert
        deserialized.Should().BeEquivalentTo(original);
    }
}
```

### Benefits

| Benefit | Explanation |
|---------|-------------|
| **DRY** | Single source of truth for configuration |
| **No Drift** | Tests always use the exact same config as production |
| **Easier Maintenance** | Add a new binding in one place, tests automatically pick it up |
| **Better Coverage** | Actually tests the extension method itself |
| **Catches Real Bugs** | If the extension method is broken, tests fail |

### Applying to Other Configurations

This pattern applies to any `AkkaConfigurationBuilder` extension method:

```csharp
protected override void ConfigureAkka(AkkaConfigurationBuilder builder, IServiceProvider provider)
{
    // Reuse production extension methods
    builder
        .AddDraftSerializer()           // Custom serializer
        .AddOrderDomainActors(AkkaExecutionMode.LocalTest)  // Domain actors
        .AddCustomPersistence()         // Persistence config
        .AddReminders();                // Reminder system

    // Override only what's test-specific
    builder
        .WithInMemoryJournal()          // Replace real DB with in-memory
        .WithInMemorySnapshotStore();
}
```

---

## Pattern 6: Testing Cluster Sharding Locally

Use `AkkaExecutionMode.LocalTest` to test cluster sharding behavior without an actual cluster.

```csharp
// In your production code (AkkaHostingExtensions.cs):
public static AkkaConfigurationBuilder WithOrderActor(
    this AkkaConfigurationBuilder builder,
    AkkaExecutionMode executionMode = AkkaExecutionMode.Clustered)
{
    if (executionMode == AkkaExecutionMode.LocalTest)
    {
        // Non-clustered mode: Use GenericChildPerEntityParent
        builder.WithActors((system, registry, resolver) =>
        {
            var parent = system.ActorOf(
                GenericChildPerEntityParent.CreateProps(
                    new OrderMessageExtractor(),
                    entityId => resolver.Props<OrderActor>(entityId)),
                "orders");

            registry.Register<OrderActor>(parent);
        });
    }
    else
    {
        // Clustered mode: Use ShardRegion
        builder.WithShardRegion<OrderActor>(
            "orders",
            (system, registry, resolver) => entityId => resolver.Props<OrderActor>(entityId),
            new OrderMessageExtractor(),
            new ShardOptions
            {
                StateStoreMode = StateStoreMode.DData,
                Role = "order-service"
            });
    }

    return builder;
}

// In your tests:
public class OrderShardingTests : TestKit
{
    protected override void ConfigureAkka(AkkaConfigurationBuilder builder, IServiceProvider provider)
    {
        builder.WithInMemoryJournal().WithInMemorySnapshotStore();

        // Use the same extension method as production, but with LocalTest mode
        builder.WithOrderActor(AkkaExecutionMode.LocalTest);
    }

    [Fact]
    public async Task ShardedActor_RoutesMessagesByEntityId()
    {
        // Arrange
        var orderRegion = ActorRegistry.Get<OrderActor>();

        // Act - Send commands for two different entity IDs
        var response1 = await orderRegion.Ask<OrderCommandResult>(
            new CreateOrder(OrderId: "ORDER-001", Amount: 100m),
            RemainingOrDefault);

        var response2 = await orderRegion.Ask<OrderCommandResult>(
            new CreateOrder(OrderId: "ORDER-002", Amount: 200m),
            RemainingOrDefault);

        // Assert
        response1.Status.Should().Be(CommandStatus.Success);
        response2.Status.Should().Be(CommandStatus.Success);

        // Query state to verify routing worked correctly
        var state1 = await orderRegion.Ask<OrderState>(
            new GetOrderState("ORDER-001"),
            RemainingOrDefault);
        var state2 = await orderRegion.Ask<OrderState>(
            new GetOrderState("ORDER-002"),
            RemainingOrDefault);

        state1.Amount.Should().Be(100m);
        state2.Amount.Should().Be(200m);
    }
}
```

**Key Patterns:**
- **Same extension methods** for production and tests
- **`AkkaExecutionMode` parameter** switches between clustered and local
- **`GenericChildPerEntityParent`** simulates sharding behavior locally
- **No actual cluster** needed for tests

---

## Pattern 6: Testing Asynchronous Actor Behavior with AwaitAssertAsync

Use `AwaitAssertAsync` when actors perform async operations (like calling external services).

```csharp
[Fact]
public async Task CreateInvoice_CallsReadModelSync()
{
    // Arrange
    var invoiceActor = ActorRegistry.Get<InvoiceActor>();
    var command = new CreateInvoice(InvoiceId: "INV-003", Amount: 75.00m);

    // Act
    var response = await invoiceActor.Ask<InvoiceCommandResult>(command, RemainingOrDefault);

    // Assert - Command succeeded
    response.Status.Should().Be(CommandStatus.Success);

    // Assert - Read model sync was called (async operation, need to wait)
    await AwaitAssertAsync(() =>
    {
        _fakeReadModelService.SyncCallCount.Should().BeGreaterOrEqualTo(1);
        _fakeReadModelService.LastSyncedInvoiceId.Should().Be("INV-003");
    }, TimeSpan.FromSeconds(3));
}

[Fact]
public async Task PaymentRetry_SchedulesReminder()
{
    // Arrange
    var invoiceActor = ActorRegistry.Get<InvoiceActor>();
    await CreateAndFailPayment(invoiceActor, "INV-004");

    // Act - Trigger payment failure (which schedules retry reminder)
    var failure = new PaymentFailed(InvoiceId: "INV-004", Reason: "Card declined");
    invoiceActor.Tell(failure);

    // Assert - Verify reminder was scheduled (async operation)
    var reminderClient = Sys.ReminderClient().CreateClient(
        new ReminderEntity("invoicing", "INV-004"));

    await AwaitAssertAsync(async () =>
    {
        var reminders = await reminderClient.ListRemindersAsync();
        reminders.Reminders.Should().HaveCount(1);
        reminders.Reminders.First().Key.Name.Should().Be("payment-retry");
    }, TimeSpan.FromSeconds(3));
}
```

**Key Patterns:**
- **AwaitAssertAsync** - Retries assertion until it passes or times out
- **Useful for async operations** - Read model syncs, reminder scheduling, external API calls
- **Prevents flaky tests** - Gives async operations time to complete

---

## Pattern 7: Scenario-Based Integration Tests

Test complete business workflows end-to-end with multiple actors and state transitions.

```csharp
public class SubscriptionScenarioTests : TestKit
{
    private readonly FakeSubscriptionService _fakeService;

    public SubscriptionScenarioTests(ITestOutputHelper output)
        : base(output: output, logLevel: LogLevel.Debug)
    {
        _fakeService = new FakeSubscriptionService();
    }

    protected override void ConfigureServices(HostBuilderContext context, IServiceCollection services)
    {
        services.AddSingleton<ISubscriptionService>(_fakeService);
        services.AddSingleton<IInvoiceService, FakeInvoiceService>();
        services.AddSingleton<IPaymentService, FakePaymentService>();
    }

    protected override void ConfigureAkka(AkkaConfigurationBuilder builder, IServiceProvider provider)
    {
        builder.AddHocon("akka.scheduler.implementation = \"Akka.TestKit.TestScheduler, Akka.TestKit\"",
            HoconAddMode.Prepend);

        builder.WithInMemoryJournal().WithInMemorySnapshotStore();

        // Register all domain actors (subscription, invoice, payment)
        builder.WithSubscriptionDomainActors(AkkaExecutionMode.LocalTest);
    }

    [Fact]
    public async Task Scenario_FirstTimePurchase_SuccessfulPayment()
    {
        // Arrange
        var subscriptionId = "SUB-001";
        var subscriptionActor = ActorRegistry.Get<SubscriptionActor>();

        // Step 1: Create subscription
        var createResult = await subscriptionActor.Ask<SubscriptionCommandResult>(
            new CreateSubscription(subscriptionId, "CUST-123", 99.99m),
            RemainingOrDefault);
        createResult.Status.Should().Be(CommandStatus.Success);

        // Step 2: Verify invoice was generated
        await AwaitAssertAsync(async () =>
        {
            var state = await subscriptionActor.Ask<SubscriptionState>(
                new GetSubscriptionState(subscriptionId),
                RemainingOrDefault);
            state.CurrentInvoiceId.Should().NotBeNullOrEmpty();
        });

        // Step 3: Simulate payment success
        var state = await subscriptionActor.Ask<SubscriptionState>(
            new GetSubscriptionState(subscriptionId),
            RemainingOrDefault);

        var paymentNotification = new PaymentCompleted(
            InvoiceId: state.CurrentInvoiceId!,
            Amount: 99.99m);
        subscriptionActor.Tell(paymentNotification);

        // Step 4: Verify subscription is now active
        await AwaitAssertAsync(async () =>
        {
            var finalState = await subscriptionActor.Ask<SubscriptionState>(
                new GetSubscriptionState(subscriptionId),
                RemainingOrDefault);
            finalState.Status.Should().Be(SubscriptionStatus.Active);
            finalState.BenefitsProvisioned.Should().BeTrue();
        });

        // Step 5: Verify service was provisioned
        _fakeService.ProvisionCallCount.Should().BeGreaterOrEqualTo(1);
        _fakeService.LastProvisionedSubscriptionId.Should().Be(subscriptionId);
    }

    [Fact]
    public async Task Scenario_PaymentFailure_RetryAndGracePeriod()
    {
        // Arrange
        var subscriptionId = "SUB-002";
        var subscriptionActor = ActorRegistry.Get<SubscriptionActor>();

        // Step 1: Create subscription and generate invoice
        await subscriptionActor.Ask<SubscriptionCommandResult>(
            new CreateSubscription(subscriptionId, "CUST-456", 199.99m),
            RemainingOrDefault);

        var state = await subscriptionActor.Ask<SubscriptionState>(
            new GetSubscriptionState(subscriptionId),
            RemainingOrDefault);
        var invoiceId = state.CurrentInvoiceId!;

        // Step 2: Simulate 3 payment failures
        for (int attempt = 1; attempt <= 3; attempt++)
        {
            var failure = new PaymentFailed(
                InvoiceId: invoiceId,
                Reason: "Insufficient funds",
                CanRetry: true,
                AttemptNumber: attempt);

            subscriptionActor.Tell(failure);

            if (attempt < 3)
            {
                // Verify soft dunning notification for attempts 1-2
                await AwaitAssertAsync(async () =>
                {
                    var currentState = await subscriptionActor.Ask<SubscriptionState>(
                        new GetSubscriptionState(subscriptionId),
                        RemainingOrDefault);
                    currentState.PaymentRetryCount.Should().Be(attempt);
                });
            }
        }

        // Step 3: Verify hard dunning after 3 failures
        await AwaitAssertAsync(async () =>
        {
            var finalState = await subscriptionActor.Ask<SubscriptionState>(
                new GetSubscriptionState(subscriptionId),
                RemainingOrDefault);
            finalState.Status.Should().Be(SubscriptionStatus.PaymentFailed);
            finalState.GracePeriodExpiresAt.Should().NotBeNull();
        });

        // Step 4: Verify grace period reminder scheduled
        var reminderClient = Sys.ReminderClient().CreateClient(
            new ReminderEntity("subscription", subscriptionId));

        await AwaitAssertAsync(async () =>
        {
            var reminders = await reminderClient.ListRemindersAsync();
            reminders.Reminders.Should().ContainSingle(r =>
                r.Key.Name == "grace-period-expiration");
        });
    }
}
```

**Key Patterns:**
- **Multi-step workflows** - Test complete business scenarios, not just single operations
- **State verification at each step** - Use `AwaitAssertAsync` to verify state transitions
- **Multiple actors** - Register all domain actors, test their interactions
- **Business-focused naming** - `Scenario_FirstTimePurchase_SuccessfulPayment`

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

## Anti-Patterns to Avoid

### ❌ DON'T: Create Custom Test Base Classes

```csharp
// BAD: Custom base class for "DRY" setup
public abstract class BaseAkkaTest : TestKit
{
    protected IActorRef OrderActor { get; private set; }
    protected FakeOrderRepository FakeRepository { get; private set; }

    protected override void ConfigureAkka(...)
    {
        // Setup shared across all tests
    }
}

public class OrderActorTests : BaseAkkaTest
{
    // Now coupled to BaseAkkaTest setup
}
```

**Why it's bad:**
- Tight coupling between tests
- Hidden dependencies (what services are registered?)
- Difficult to customize per-test
- Violates principle of test isolation

**✅ DO: Use Method Overrides**

Each test class overrides `ConfigureServices()` and `ConfigureAkka()` with exactly what it needs.

### ❌ DON'T: Share State Between Tests

```csharp
// BAD: Reusing same actor instance across tests
public class OrderActorTests : TestKit
{
    private readonly IActorRef _orderActor;

    public OrderActorTests()
    {
        _orderActor = /* create once */;
    }

    [Fact] public void Test1() { /* uses _orderActor */ }
    [Fact] public void Test2() { /* uses _orderActor */ }
}
```

**Why it's bad:**
- Test1 and Test2 share state
- Test execution order matters
- Flaky tests due to side effects

**✅ DO: Use xUnit Class Fixtures or Get Fresh Actors**

```csharp
// GOOD: Each test gets clean ActorSystem
public class OrderActorTests : TestKit
{
    [Fact]
    public async Task Test1()
    {
        var actor = ActorRegistry.Get<OrderActor>(); // Fresh system
        // Test
    }

    [Fact]
    public async Task Test2()
    {
        var actor = ActorRegistry.Get<OrderActor>(); // Fresh system
        // Test
    }
}
```

### ❌ DON'T: Use Real External Dependencies

```csharp
// BAD: Using real database in tests
protected override void ConfigureServices(...)
{
    services.AddDbContext<OrderDbContext>(options =>
        options.UseSqlServer(connectionString)); // Real DB!
}
```

**✅ DO: Use Fakes or In-Memory Alternatives**

```csharp
// GOOD: Fake repository
protected override void ConfigureServices(...)
{
    services.AddSingleton<IOrderRepository>(_fakeRepository);
}
```

---

## Testing with Akka.Reminders

If your actors use Akka.Reminders for scheduling, configure local reminders in tests:

```csharp
protected override void ConfigureAkka(AkkaConfigurationBuilder builder, IServiceProvider provider)
{
    builder.AddHocon("akka.scheduler.implementation = \"Akka.TestKit.TestScheduler, Akka.TestKit\"",
        HoconAddMode.Prepend);

    builder.WithInMemoryJournal().WithInMemorySnapshotStore();

    // Configure local reminders for testing
    var shardResolver = new TestShardRegionResolver();

    builder.WithLocalReminders(reminders => reminders
        .WithInMemoryStorage()
        .WithResolver(shardResolver)
        .WithSettings(new ReminderSettings
        {
            MaxDeliveryAttempts = 5,
            RetryBackoffBase = TimeSpan.FromSeconds(1),
            MaxSlippage = TimeSpan.FromSeconds(60)
        }));

    builder.WithInvoicingActor(AkkaExecutionMode.LocalTest);

    // Register shard region with reminder resolver after startup
    builder.AddStartup(async (system, registry) =>
    {
        var invoicingRegion = await registry.GetAsync<InvoicingActor>();
        shardResolver.RegisterShardRegion("invoicing", invoicingRegion);
    });
}

[Fact]
public async Task PaymentFailure_SchedulesRetryReminder()
{
    // Arrange
    var invoiceId = "INV-001";
    var actor = ActorRegistry.Get<InvoicingActor>();

    // Act - Trigger payment failure
    var failure = new PaymentFailed(invoiceId, "Card declined");
    actor.Tell(failure);

    // Assert - Verify reminder was scheduled
    var reminderClient = Sys.ReminderClient().CreateClient(
        new ReminderEntity("invoicing", invoiceId));

    await AwaitAssertAsync(async () =>
    {
        var reminders = await reminderClient.ListRemindersAsync();
        reminders.Reminders.Should().HaveCount(1);
        reminders.Reminders.First().Key.Name.Should().Be("payment-retry");
    }, TimeSpan.FromSeconds(3));
}
```

---

## Traditional Akka.TestKit (Legacy/Core Development)

For completeness, here's the traditional TestKit approach (use only when you can't use Microsoft.Extensions):

```csharp
using Akka.Actor;
using Akka.TestKit.Xunit2;
using Xunit;

public class OrderActorTests_Traditional : TestKit
{
    public OrderActorTests_Traditional()
        : base(@"akka.loglevel = DEBUG")
    {
    }

    [Fact]
    public void CreateOrder_SendsConfirmation()
    {
        // Arrange - Create actor manually with Props
        var orderActor = Sys.ActorOf(Props.Create<OrderActor>(), "order-actor");

        // Act
        orderActor.Tell(new CreateOrder("ORDER-001", 100m));

        // Assert
        var confirmation = ExpectMsg<OrderCreated>();
        Assert.Equal("ORDER-001", confirmation.OrderId);
    }

    [Fact]
    public void OrderActor_RespondsToQuery()
    {
        // Arrange
        var orderActor = Sys.ActorOf(Props.Create<OrderActor>());

        // Act
        orderActor.Tell(new CreateOrder("ORDER-002", 200m));
        ExpectMsg<OrderCreated>(); // Drain creation message

        // Query
        orderActor.Tell(new GetOrderState("ORDER-002"));

        // Assert
        var state = ExpectMsg<OrderState>();
        Assert.Equal("ORDER-002", state.OrderId);
        Assert.Equal(200m, state.Amount);
    }
}
```

**Key Differences:**
- Manual `Props.Create<T>()` instead of DI
- No service injection (actors must create dependencies internally or use `Context`)
- `ExpectMsg<T>()` instead of `Ask` patterns
- Constructor takes HOCON config string

**When to use:**
- Contributing to Akka.NET core
- Legacy projects without Microsoft.Extensions
- Console applications that don't use DI

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

// Check what messages TestProbe received
[Fact]
public void DebugTest()
{
    // ... test code ...

    // Inspect all messages sent to probe
    _paymentProbe.Messages.Should().NotBeEmpty();
    foreach (var msg in _paymentProbe.Messages)
    {
        Output?.WriteLine($"Received: {msg}");
    }
}
```

---

## CI/CD Integration

### GitHub Actions Example

```yaml
name: Akka.NET Tests

on:
  push:
    branches: [ main ]
  pull_request:
    branches: [ main ]

jobs:
  test:
    runs-on: ubuntu-latest

    steps:
    - uses: actions/checkout@v3

    - name: Setup .NET
      uses: actions/setup-dotnet@v3
      with:
        dotnet-version: 9.0.x

    - name: Restore dependencies
      run: dotnet restore

    - name: Build
      run: dotnet build --no-restore -c Release

    - name: Run Akka.NET tests
      run: |
        dotnet test tests/MyApp.Domain.Tests \
          --no-build \
          -c Release \
          --logger trx \
          --collect:"XPlat Code Coverage"

    - name: Publish test results
      uses: actions/upload-artifact@v3
      if: always()
      with:
        name: test-results
        path: "**/TestResults/*.trx"
```

---

## Additional Resources

- **Akka.NET Documentation**: https://getakka.net/
- **Akka.Hosting Documentation**: https://github.com/akkadotnet/Akka.Hosting
- **Petabridge Bootcamp**: https://petabridge.com/bootcamp/ (comprehensive Akka.NET training)
- **Akka.TestKit Guide**: https://getakka.net/articles/testing/testing-actor-systems.html
