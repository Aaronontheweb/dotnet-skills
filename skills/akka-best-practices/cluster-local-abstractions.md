# Cluster/Local Mode Abstractions

For applications that need to run both in clustered production environments and local/test environments without cluster infrastructure, use abstraction patterns to toggle between implementations.

## Contents

- [AkkaExecutionMode Enum](#akkaexecutionmode-enum)
- [GenericChildPerEntityParent - Local Sharding Alternative](#genericchildperentityparent---local-sharding-alternative)
- [IPubSubMediator - Abstracting DistributedPubSub](#ipubsubmediator---abstracting-distributedpubsub)
- [LocalPubSubMediator - In-Memory Implementation](#localpubsubmediator---in-memory-implementation)
- [ClusterPubSubMediator - Production Implementation](#clusterpubsubmediator---production-implementation)
- [Wiring It All Together](#wiring-it-all-together)
- [Usage in Application Code](#usage-in-application-code)
- [Benefits and When to Use Each Mode](#benefits-and-when-to-use-each-mode)

## AkkaExecutionMode Enum

Define an execution mode that controls which implementations are used:

```csharp
/// <summary>
/// Determines how Akka.NET infrastructure features are configured.
/// </summary>
public enum AkkaExecutionMode
{
    /// <summary>
    /// Local test mode - no cluster infrastructure.
    /// Uses in-memory implementations for pub/sub and local parent actors
    /// instead of cluster sharding.
    /// </summary>
    LocalTest,

    /// <summary>
    /// Full cluster mode with sharding, singletons, and distributed pub/sub.
    /// </summary>
    Clustered
}
```

## GenericChildPerEntityParent - Local Sharding Alternative

When testing locally, you can't use Cluster Sharding. This actor mimics sharding behavior by creating child actors per entity ID using the same `IMessageExtractor` interface:

```csharp
/// <summary>
/// A local parent actor that mimics Cluster Sharding behavior.
/// Creates and manages child actors per entity ID using the same IMessageExtractor
/// that would be used with real sharding, enabling seamless switching between modes.
/// </summary>
public sealed class GenericChildPerEntityParent : ReceiveActor
{
    private readonly IMessageExtractor _extractor;
    private readonly Func<string, Props> _propsFactory;
    private readonly Dictionary<string, IActorRef> _children = new();
    private readonly ILoggingAdapter _log = Context.GetLogger();

    public GenericChildPerEntityParent(
        IMessageExtractor extractor,
        Func<string, Props> propsFactory)
    {
        _extractor = extractor;
        _propsFactory = propsFactory;

        ReceiveAny(msg =>
        {
            var entityId = _extractor.EntityId(msg);
            if (string.IsNullOrEmpty(entityId))
            {
                _log.Warning("Could not extract entity ID from message {0}", msg.GetType().Name);
                Unhandled(msg);
                return;
            }

            var child = GetOrCreateChild(entityId);

            // Unwrap the message if it's a ShardingEnvelope
            var unwrapped = _extractor.EntityMessage(msg);
            child.Forward(unwrapped);
        });
    }

    private IActorRef GetOrCreateChild(string entityId)
    {
        if (_children.TryGetValue(entityId, out var existing))
            return existing;

        var props = _propsFactory(entityId);
        var child = Context.ActorOf(props, entityId);
        Context.Watch(child);
        _children[entityId] = child;

        _log.Debug("Created child actor for entity {0}", entityId);
        return child;
    }

    protected override void PreRestart(Exception reason, object message)
    {
        // Don't stop children on restart
    }

    public static Props CreateProps(
        IMessageExtractor extractor,
        Func<string, Props> propsFactory)
    {
        return Props.Create(() => new GenericChildPerEntityParent(extractor, propsFactory));
    }
}
```

## IPubSubMediator - Abstracting DistributedPubSub

Create an interface to abstract over pub/sub so tests can use a local implementation:

```csharp
/// <summary>
/// Abstraction over pub/sub messaging that allows swapping between
/// DistributedPubSub (clustered) and local implementations (testing).
/// </summary>
public interface IPubSubMediator
{
    /// <summary>
    /// Subscribe an actor to a topic.
    /// </summary>
    void Subscribe(string topic, IActorRef subscriber);

    /// <summary>
    /// Unsubscribe an actor from a topic.
    /// </summary>
    void Unsubscribe(string topic, IActorRef subscriber);

    /// <summary>
    /// Publish a message to all subscribers of a topic.
    /// </summary>
    void Publish(string topic, object message);

    /// <summary>
    /// Send a message to one subscriber of a topic (load balanced).
    /// </summary>
    void Send(string topic, object message);
}
```

## LocalPubSubMediator - In-Memory Implementation

```csharp
/// <summary>
/// In-memory pub/sub implementation for local testing without cluster.
/// Uses the EventStream internally for simplicity.
/// </summary>
public sealed class LocalPubSubMediator : IPubSubMediator
{
    private readonly ActorSystem _system;
    private readonly ConcurrentDictionary<string, HashSet<IActorRef>> _subscriptions = new();
    private readonly object _lock = new();

    public LocalPubSubMediator(ActorSystem system)
    {
        _system = system;
    }

    public void Subscribe(string topic, IActorRef subscriber)
    {
        lock (_lock)
        {
            var subs = _subscriptions.GetOrAdd(topic, _ => new HashSet<IActorRef>());
            subs.Add(subscriber);
        }

        // Send acknowledgement like real DistributedPubSub does
        subscriber.Tell(new SubscribeAck(new Subscribe(topic, subscriber)));
    }

    public void Unsubscribe(string topic, IActorRef subscriber)
    {
        lock (_lock)
        {
            if (_subscriptions.TryGetValue(topic, out var subs))
            {
                subs.Remove(subscriber);
            }
        }

        subscriber.Tell(new UnsubscribeAck(new Unsubscribe(topic, subscriber)));
    }

    public void Publish(string topic, object message)
    {
        HashSet<IActorRef> subscribers;
        lock (_lock)
        {
            if (!_subscriptions.TryGetValue(topic, out var subs))
                return;
            subscribers = new HashSet<IActorRef>(subs);
        }

        foreach (var subscriber in subscribers)
        {
            subscriber.Tell(message);
        }
    }

    public void Send(string topic, object message)
    {
        IActorRef? target = null;
        lock (_lock)
        {
            if (_subscriptions.TryGetValue(topic, out var subs) && subs.Count > 0)
            {
                // Simple round-robin - pick first available
                target = subs.FirstOrDefault();
            }
        }

        target?.Tell(message);
    }
}
```

## ClusterPubSubMediator - Production Implementation

```csharp
/// <summary>
/// Production implementation wrapping Akka.Cluster.Tools.PublishSubscribe.
/// </summary>
public sealed class ClusterPubSubMediator : IPubSubMediator
{
    private readonly IActorRef _mediator;

    public ClusterPubSubMediator(ActorSystem system)
    {
        _mediator = DistributedPubSub.Get(system).Mediator;
    }

    public void Subscribe(string topic, IActorRef subscriber)
    {
        _mediator.Tell(new Subscribe(topic, subscriber));
    }

    public void Unsubscribe(string topic, IActorRef subscriber)
    {
        _mediator.Tell(new Unsubscribe(topic, subscriber));
    }

    public void Publish(string topic, object message)
    {
        _mediator.Tell(new Publish(topic, message));
    }

    public void Send(string topic, object message)
    {
        _mediator.Tell(new Send(topic, message, localAffinity: true));
    }
}
```

## Wiring It All Together

Configure your ActorSystem based on execution mode:

```csharp
public static class AkkaHostingExtensions
{
    public static AkkaConfigurationBuilder ConfigureActorSystem(
        this AkkaConfigurationBuilder builder,
        AkkaExecutionMode mode,
        IServiceCollection services)
    {
        if (mode == AkkaExecutionMode.Clustered)
        {
            builder
                .WithClustering()
                .WithShardRegion<MyEntity>(
                    "my-entity",
                    (system, registry, resolver) => entityId =>
                        resolver.Props<MyEntityActor>(entityId),
                    new MyEntityMessageExtractor(),
                    new ShardOptions())
                .WithDistributedPubSub();

            // Register cluster pub/sub mediator
            services.AddSingleton<IPubSubMediator>(sp =>
            {
                var system = sp.GetRequiredService<ActorSystem>();
                return new ClusterPubSubMediator(system);
            });
        }
        else // LocalTest mode
        {
            // Register local pub/sub mediator
            services.AddSingleton<IPubSubMediator>(sp =>
            {
                var system = sp.GetRequiredService<ActorSystem>();
                return new LocalPubSubMediator(system);
            });

            // Use GenericChildPerEntityParent instead of sharding
            builder.WithActors((system, registry, resolver) =>
            {
                var parent = system.ActorOf(
                    GenericChildPerEntityParent.CreateProps(
                        new MyEntityMessageExtractor(),
                        entityId => resolver.Props<MyEntityActor>(entityId)),
                    "my-entity");

                registry.Register<MyEntityParent>(parent);
            });
        }

        return builder;
    }
}
```

## Usage in Application Code

Application code uses the abstractions and doesn't need to know which mode is active:

```csharp
public class MyService
{
    private readonly IPubSubMediator _pubSub;
    private readonly IRequiredActor<MyEntityParent> _entityParent;

    public MyService(
        IPubSubMediator pubSub,
        IRequiredActor<MyEntityParent> entityParent)
    {
        _pubSub = pubSub;
        _entityParent = entityParent;
    }

    public async Task ProcessAsync(string entityId, MyCommand command)
    {
        // Works identically in both modes
        var parent = await _entityParent.GetAsync();
        parent.Tell(new ShardingEnvelope(entityId, command));

        // Publish event - works with both local and distributed pub/sub
        _pubSub.Publish($"entity:{entityId}", new EntityUpdated(entityId));
    }
}
```

## Benefits and When to Use Each Mode

| Benefit | Description |
|---------|-------------|
| **Fast unit tests** | No cluster startup overhead, tests run in milliseconds |
| **Identical message flow** | Same `IMessageExtractor`, same message types |
| **Easy debugging** | Local mode is simpler to step through |
| **Integration test flexibility** | Choose mode per test scenario |
| **Production confidence** | Abstractions are thin wrappers over real implementations |

| Scenario | Recommended Mode |
|----------|------------------|
| Unit tests | LocalTest |
| Integration tests (single node) | LocalTest |
| Integration tests (multi-node) | Clustered |
| Local development | LocalTest or Clustered (your choice) |
| Production | Clustered |
