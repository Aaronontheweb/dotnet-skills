---
name: akka-hosting-actor-patterns
description: Patterns for building entity actors with Akka.Hosting - GenericChildPerEntityParent, message extractors, cluster sharding abstraction, akka-reminders, and ITimeProvider. Supports both local testing and clustered production modes.
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

## Best Practices

1. **Always support both execution modes** - Makes testing easy without code changes
2. **Use strongly-typed IDs** - `OrderId` instead of `string` or `Guid`
3. **Interface-based message routing** - `IWithOrderId` for type-safe extraction
4. **Register parent, not children** - For child-per-entity, register the parent in ActorRegistry
5. **Marker types for clarity** - Use empty marker classes for registry lookups
6. **Composition over inheritance** - Chain extension methods, don't create deep hierarchies
7. **ITimeProvider for scheduling** - Never use `DateTime.Now` directly in actors
8. **akka-reminders for durability** - Use for scheduled tasks that must survive restarts
