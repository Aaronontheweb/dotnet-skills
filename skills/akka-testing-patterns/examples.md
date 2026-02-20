# Testing Pattern Examples

Complete code samples for each Akka.Hosting.TestKit testing pattern.

## Contents

- [Pattern 1: Basic Actor Test](#pattern-1-basic-actor-test-with-akkahosting-testkit)
- [Pattern 2: Testing Actor Interactions with TestProbes](#pattern-2-testing-actor-interactions-with-testprobes)
- [Pattern 3: Auto-Responding TestProbe](#pattern-3-auto-responding-testprobe-avoiding-ask-timeouts)
- [Pattern 4: Testing Persistent Actors](#pattern-4-testing-persistent-actors-with-event-sourcing)
- [Pattern 5: Reuse Production Configuration](#pattern-5-reuse-production-configuration-extension-methods)
- [Pattern 6: Testing Cluster Sharding Locally](#pattern-6-testing-cluster-sharding-locally)
- [Pattern 7: Testing Async Behavior with AwaitAssertAsync](#pattern-7-testing-asynchronous-actor-behavior-with-awaitassertasync)
- [Pattern 8: Scenario-Based Integration Tests](#pattern-8-scenario-based-integration-tests)
- [Testing with Akka.Reminders](#testing-with-akkareminders)

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

## Pattern 5: Reuse Production Configuration Extension Methods

When your production code uses custom `AkkaConfigurationBuilder` extension methods, your tests should use those same extension methods rather than duplicating HOCON configuration.

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

## Pattern 7: Testing Asynchronous Actor Behavior with AwaitAssertAsync

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

## Pattern 8: Scenario-Based Integration Tests

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
