---
name: akka-hosting-actor-patterns
description: Patterns for building entity actors with Akka.Hosting - GenericChildPerEntityParent, message extractors, cluster sharding abstraction, akka-reminders, and ITimeProvider. Supports both local testing and clustered production modes.
invocable: false
---

# Akka.Hosting Actor Patterns

## When to Use This Skill

Use this skill when:
- Building entity actors that represent domain objects (users, orders, invoices, etc.)
- Need actors that work in both unit tests (no clustering) and production (cluster sharding)
- Setting up scheduled tasks with akka-reminders
- Registering actors with Akka.Hosting extension methods
- Creating reusable actor configuration patterns

## Core Principles

1. **Execution Mode Abstraction** - Same actor code runs locally (tests) or clustered (production)
2. **GenericChildPerEntityParent for Local** - Mimics sharding semantics without cluster overhead
3. **Message Extractors for Routing** - Reuse Akka.Cluster.Sharding's IMessageExtractor interface
4. **Akka.Hosting Extension Methods** - Fluent configuration that composes well
5. **ITimeProvider for Testability** - Use ActorSystem.Scheduler instead of DateTime.Now

## Execution Modes

Define an enum to control actor behavior:

```csharp
/// <summary>
/// Determines how Akka.NET should be configured
/// </summary>
public enum AkkaExecutionMode
{
    /// <summary>
    /// Pure local actor system - no remoting, no clustering.
    /// Use GenericChildPerEntityParent instead of ShardRegion.
    /// Ideal for unit tests and simple scenarios.
    /// </summary>
    LocalTest,

    /// <summary>
    /// Full clustering with ShardRegion.
    /// Use for integration testing and production.
    /// </summary>
    Clustered
}
```

## GenericChildPerEntityParent

A lightweight parent actor that routes messages to child entities, mimicking cluster sharding semantics without requiring a cluster:

```csharp
using Akka.Actor;
using Akka.Cluster.Sharding;

/// <summary>
/// A generic "child per entity" parent actor.
/// </summary>
/// <remarks>
/// Reuses Akka.Cluster.Sharding's IMessageExtractor for consistent routing.
/// Ideal for unit tests where clustering overhead is unnecessary.
/// </remarks>
public sealed class GenericChildPerEntityParent : ReceiveActor
{
    public static Props CreateProps(
        IMessageExtractor extractor,
        Func<string, Props> propsFactory)
    {
        return Props.Create(() =>
            new GenericChildPerEntityParent(extractor, propsFactory));
    }

    private readonly IMessageExtractor _extractor;
    private readonly Func<string, Props> _propsFactory;

    public GenericChildPerEntityParent(
        IMessageExtractor extractor,
        Func<string, Props> propsFactory)
    {
        _extractor = extractor;
        _propsFactory = propsFactory;

        ReceiveAny(message =>
        {
            var entityId = _extractor.EntityId(message);
            if (entityId is null) return;

            // Get existing child or create new one
            Context.Child(entityId)
                .GetOrElse(() => Context.ActorOf(_propsFactory(entityId), entityId))
                .Forward(_extractor.EntityMessage(message));
        });
    }
}
```

## Message Extractors

Create extractors that implement `IMessageExtractor` from Akka.Cluster.Sharding:

```csharp
using Akka.Cluster.Sharding;

/// <summary>
/// Routes messages to entity actors based on a strongly-typed ID.
/// </summary>
public sealed class OrderMessageExtractor : HashCodeMessageExtractor
{
    public const int DefaultShardCount = 40;

    public OrderMessageExtractor(int maxNumberOfShards = DefaultShardCount)
        : base(maxNumberOfShards)
    {
    }

    public override string? EntityId(object message)
    {
        return message switch
        {
            IWithOrderId msg => msg.OrderId.Value.ToString(),
            _ => null
        };
    }
}

// Define an interface for messages that target a specific entity
public interface IWithOrderId
{
    OrderId OrderId { get; }
}

// Use strongly-typed IDs
public readonly record struct OrderId(Guid Value)
{
    public static OrderId New() => new(Guid.NewGuid());
    public override string ToString() => Value.ToString();
}
```

## Akka.Hosting Extension Methods

Create extension methods that abstract the execution mode:

```csharp
using Akka.Cluster.Hosting;
using Akka.Cluster.Sharding;
using Akka.Hosting;

public static class OrderActorHostingExtensions
{
    /// <summary>
    /// Adds OrderActor with support for both local and clustered modes.
    /// </summary>
    public static AkkaConfigurationBuilder WithOrderActor(
        this AkkaConfigurationBuilder builder,
        AkkaExecutionMode executionMode = AkkaExecutionMode.Clustered,
        string? clusterRole = null)
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
                (system, registry, resolver) =>
                    entityId => resolver.Props<OrderActor>(entityId),
                new OrderMessageExtractor(),
                new ShardOptions
                {
                    StateStoreMode = StateStoreMode.DData,
                    Role = clusterRole
                });
        }

        return builder;
    }
}
```

## Composing Multiple Actors

Create a convenience method that registers all domain actors:

```csharp
public static class DomainActorHostingExtensions
{
    /// <summary>
    /// Adds all order domain actors with sharding support.
    /// </summary>
    public static AkkaConfigurationBuilder WithOrderDomainActors(
        this AkkaConfigurationBuilder builder,
        AkkaExecutionMode executionMode = AkkaExecutionMode.Clustered,
        string? clusterRole = null)
    {
        return builder
            .WithOrderActor(executionMode, clusterRole)
            .WithPaymentActor(executionMode, clusterRole)
            .WithShipmentActor(executionMode, clusterRole)
            .WithNotificationActor(); // Singleton, no sharding needed
    }
}
```

## Using ITimeProvider for Scheduling

Register the ActorSystem's Scheduler as an `ITimeProvider` for testable time-based logic:

```csharp
public static class SharedAkkaHostingExtensions
{
    public static IServiceCollection AddAkkaWithTimeProvider(
        this IServiceCollection services,
        Action<AkkaConfigurationBuilder, IServiceProvider> configure)
    {
        // Register ITimeProvider using the ActorSystem's Scheduler
        services.AddSingleton<ITimeProvider>(sp =>
            sp.GetRequiredService<ActorSystem>().Scheduler);

        return services.ConfigureAkka((builder, sp) =>
        {
            configure(builder, sp);
        });
    }
}

// In your actor, inject ITimeProvider
public class SubscriptionActor : ReceiveActor
{
    private readonly ITimeProvider _timeProvider;

    public SubscriptionActor(ITimeProvider timeProvider)
    {
        _timeProvider = timeProvider;

        // Use _timeProvider.GetUtcNow() instead of DateTime.UtcNow
        // This allows tests to control time
    }
}
```

## Akka.Reminders Integration

For durable scheduled tasks that survive restarts, use akka-reminders:

```csharp
using Akka.Reminders;
using Akka.Reminders.Sql;
using Akka.Reminders.Sql.Configuration;
using Akka.Reminders.Storage;

public static class ReminderHostingExtensions
{
    /// <summary>
    /// Configures akka-reminders with PostgreSQL storage.
    /// </summary>
    public static AkkaConfigurationBuilder WithPostgresReminders(
        this AkkaConfigurationBuilder builder,
        string connectionString,
        string schemaName = "reminders",
        string tableName = "scheduled_reminders",
        bool autoInitialize = true)
    {
        return builder.WithLocalReminders(reminders => reminders
            .WithResolver(sys => new GenericChildPerEntityResolver(sys))
            .WithStorage(system =>
            {
                var settings = SqlReminderStorageSettings.CreatePostgreSql(
                    connectionString,
                    schemaName,
                    tableName,
                    autoInitialize);
                return new SqlReminderStorage(settings, system);
            })
            .WithSettings(new ReminderSettings
            {
                MaxSlippage = TimeSpan.FromSeconds(30),
                MaxDeliveryAttempts = 3,
                RetryBackoffBase = TimeSpan.FromSeconds(10)
            }));
    }

    /// <summary>
    /// Configures akka-reminders with in-memory storage for testing.
    /// </summary>
    public static AkkaConfigurationBuilder WithInMemoryReminders(
        this AkkaConfigurationBuilder builder)
    {
        return builder.WithLocalReminders(reminders => reminders
            .WithResolver(sys => new GenericChildPerEntityResolver(sys))
            .WithStorage(system => new InMemoryReminderStorage())
            .WithSettings(new ReminderSettings
            {
                MaxSlippage = TimeSpan.FromSeconds(1),
                MaxDeliveryAttempts = 3,
                RetryBackoffBase = TimeSpan.FromMilliseconds(100)
            }));
    }
}
```

### Custom Reminder Resolver for Child-Per-Entity

Route reminder callbacks to GenericChildPerEntityParent actors:

```csharp
using Akka.Actor;
using Akka.Hosting;
using Akka.Reminders;

/// <summary>
/// Resolves reminder targets to GenericChildPerEntityParent actors.
/// </summary>
public sealed class GenericChildPerEntityResolver : IReminderActorResolver
{
    private readonly ActorSystem _system;

    public GenericChildPerEntityResolver(ActorSystem system)
    {
        _system = system;
    }

    public IActorRef ResolveActorRef(ReminderEntry entry)
    {
        var registry = ActorRegistry.For(_system);

        return entry.Key switch
        {
            var k when k.StartsWith("order-") =>
                registry.Get<OrderActor>(),
            var k when k.StartsWith("subscription-") =>
                registry.Get<SubscriptionActor>(),
            _ => throw new InvalidOperationException(
                $"Unknown reminder key format: {entry.Key}")
        };
    }
}
```

## Singleton Actors (Not Sharded)

For actors that should only have one instance:

```csharp
public static AkkaConfigurationBuilder WithEmailSenderActor(
    this AkkaConfigurationBuilder builder)
{
    return builder.WithActors((system, registry, resolver) =>
    {
        var actor = system.ActorOf(
            resolver.Props<EmailSenderActor>(),
            "email-sender");
        registry.Register<EmailSenderActor>(actor);
    });
}
```

## Marker Types for Registry

When you need to reference actors that are registered as parents:

```csharp
/// <summary>
/// Marker type for ActorRegistry to retrieve the order manager
/// (GenericChildPerEntityParent for OrderActors).
/// </summary>
public sealed class OrderManagerActor;

// Usage in extension method
registry.Register<OrderManagerActor>(parent);

// Usage in controller/service
public class OrderService
{
    private readonly IActorRef _orderManager;

    public OrderService(IRequiredActor<OrderManagerActor> orderManager)
    {
        _orderManager = orderManager.ActorRef;
    }

    public async Task<OrderResponse> CreateOrder(CreateOrderCommand cmd)
    {
        return await _orderManager.Ask<OrderResponse>(cmd);
    }
}
```

## DI Scope Management in Actors

**Actors don't have automatic DI scopes.** Unlike ASP.NET controllers (where each HTTP request creates a scope), actors are long-lived. If you need scoped services (like `DbContext`), inject `IServiceProvider` and create scopes manually.

### Pattern: Scope Per Message

```csharp
public sealed class OrderProcessingActor : ReceiveActor
{
    private readonly IServiceProvider _serviceProvider;
    private readonly IActorRef _notificationActor;

    public OrderProcessingActor(
        IServiceProvider serviceProvider,
        IRequiredActor<NotificationActor> notificationActor)
    {
        _serviceProvider = serviceProvider;
        _notificationActor = notificationActor.ActorRef;

        ReceiveAsync<ProcessOrder>(HandleProcessOrder);
    }

    private async Task HandleProcessOrder(ProcessOrder msg)
    {
        // Create scope for this message - disposed after processing
        using var scope = _serviceProvider.CreateScope();

        // Resolve scoped services within the scope
        var orderRepository = scope.ServiceProvider.GetRequiredService<IOrderRepository>();
        var paymentService = scope.ServiceProvider.GetRequiredService<IPaymentService>();
        var emailComposer = scope.ServiceProvider.GetRequiredService<IOrderEmailComposer>();

        // Do work with scoped services
        var order = await orderRepository.GetByIdAsync(msg.OrderId);
        var payment = await paymentService.ProcessAsync(order);

        // DbContext changes committed when scope disposes
    }
}
```

### Why This Pattern

| Benefit | Explanation |
|---------|-------------|
| **Fresh DbContext per message** | No stale entity tracking between messages |
| **Proper disposal** | Database connections released after each message |
| **Isolation** | One message's errors don't corrupt another's state |
| **Testable** | Can inject mock IServiceProvider in tests |

### Singleton Services - Direct Injection

For stateless, thread-safe services, inject directly (no scope needed):

```csharp
public sealed class NotificationActor : ReceiveActor
{
    private readonly IEmailLinkGenerator _linkGenerator;  // Singleton - OK!
    private readonly IMjmlTemplateRenderer _renderer;     // Singleton - OK!

    public NotificationActor(
        IEmailLinkGenerator linkGenerator,
        IMjmlTemplateRenderer renderer)
    {
        _linkGenerator = linkGenerator;
        _renderer = renderer;

        Receive<SendWelcomeEmail>(Handle);
    }
}
```

### Common Mistake: Injecting Scoped Services Directly

```csharp
// BAD: Scoped service injected into long-lived actor
public sealed class BadActor : ReceiveActor
{
    private readonly IOrderRepository _repo;  // Scoped! DbContext lives forever!

    public BadActor(IOrderRepository repo)  // Captured at actor creation
    {
        _repo = repo;  // This DbContext will become stale
    }
}

// GOOD: Inject IServiceProvider, create scope per message
public sealed class GoodActor : ReceiveActor
{
    private readonly IServiceProvider _sp;

    public GoodActor(IServiceProvider sp)
    {
        _sp = sp;
        ReceiveAsync<ProcessOrder>(async msg =>
        {
            using var scope = _sp.CreateScope();
            var repo = scope.ServiceProvider.GetRequiredService<IOrderRepository>();
            // Fresh DbContext for this message
        });
    }
}
```

For more on DI lifetimes and scope management, see `microsoft-extensions/dependency-injection` skill.

---

## Cluster Sharding Configuration

### RememberEntities: Almost Always False

`RememberEntities` controls whether the shard region remembers and automatically restarts all entities that were ever created. **This should almost always be `false`.**

```csharp
builder.WithShardRegion<OrderActor>(
    "orders",
    (system, registry, resolver) => entityId => resolver.Props<OrderActor>(entityId),
    new OrderMessageExtractor(),
    new ShardOptions
    {
        StateStoreMode = StateStoreMode.DData,
        RememberEntities = false,  // DEFAULT - almost always correct
        Role = clusterRole
    });
```

**When `RememberEntities = true` causes problems:**

| Problem | Explanation |
|---------|-------------|
| **Unbounded memory growth** | Every entity ever created gets remembered and restarted forever |
| **Slow cluster startup** | Cluster must restart thousands/millions of entities on boot |
| **Stale entity resurrection** | Expired sessions, sent emails, old orders all get restarted |
| **No passivation** | Idle entities consume memory indefinitely (passivation is disabled) |

### When to Use Each Setting

| Entity Type | RememberEntities | Reason |
|-------------|------------------|--------|
| `UserSessionActor` | **false** | Sessions expire, created on login |
| `DraftActor` | **false** | Drafts are sent/discarded, ephemeral |
| `EmailSenderActor` | **false** | Fire-and-forget operations |
| `OrderActor` | **false** | Orders complete, new ones created constantly |
| `ShoppingCartActor` | **false** | Carts expire, abandoned carts common |
| `TenantActor` | *maybe true* | Fixed set of tenants, always needed |
| `AccountActor` | *maybe true* | Bounded set of accounts, long-lived |

**Rule of thumb:** Use `RememberEntities = true` only for:
1. **Bounded** entity sets (known upper limit)
2. **Long-lived** domain entities that should always be available
3. Entities where the **cost of remembering < cost of lazy creation**

### Marker Types with WithShardRegion<T>

When using `WithShardRegion<T>`, the generic parameter `T` serves as a marker type for the `ActorRegistry`. Use a dedicated marker type (not the actor class itself) for consistent registry access:

```csharp
/// <summary>
/// Marker type for ActorRegistry. Use this to retrieve the OrderActor shard region.
/// </summary>
public sealed class OrderActorRegion;

// Registration - use marker type as generic parameter
builder.WithShardRegion<OrderActorRegion>(
    "orders",
    (system, registry, resolver) => entityId => resolver.Props<OrderActor>(entityId),
    new OrderMessageExtractor(),
    new ShardOptions { StateStoreMode = StateStoreMode.DData });

// Retrieval - same marker type
var orderRegion = ActorRegistry.Get<OrderActorRegion>();
orderRegion.Tell(new CreateOrder(orderId, amount));
```

**Why marker types?**
- `WithShardRegion<T>` auto-registers the shard region under type `T`
- Using the actor class directly can cause confusion (registry returns region, not actor)
- Marker types make the intent explicit and work consistently in both LocalTest and Clustered modes

### Avoiding Redundant Registry Calls

`WithShardRegion<T>` automatically registers the shard region in the `ActorRegistry`. Don't call `registry.Register<T>()` again:

```csharp
// BAD - redundant registration
builder.WithShardRegion<OrderActorRegion>("orders", ...)
    .WithActors((system, registry, resolver) =>
    {
        var region = registry.Get<OrderActorRegion>();
        registry.Register<OrderActorRegion>(region);  // UNNECESSARY!
    });

// GOOD - WithShardRegion already registers
builder.WithShardRegion<OrderActorRegion>("orders", ...);
// That's it - OrderActorRegion is now in the registry
```

---

## Best Practices

1. **Always support both execution modes** - Makes testing easy without code changes
2. **Use strongly-typed IDs** - `OrderId` instead of `string` or `Guid`
3. **Interface-based message routing** - `IWithOrderId` for type-safe extraction
4. **Register parent, not children** - For child-per-entity, register the parent in ActorRegistry
5. **Marker types for clarity** - Use empty marker classes for registry lookups
6. **Composition over inheritance** - Chain extension methods, don't create deep hierarchies
7. **ITimeProvider for scheduling** - Never use `DateTime.Now` directly in actors
8. **akka-reminders for durability** - Use for scheduled tasks that must survive restarts
9. **RememberEntities = false by default** - Only set to true for bounded, long-lived entities
