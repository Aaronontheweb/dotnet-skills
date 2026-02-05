---
name: akka-net-best-practices
description: Critical Akka.NET best practices including EventStream vs DistributedPubSub, supervision strategies, error handling, Props vs DependencyResolver, work distribution patterns, and cluster/local mode abstractions for testability.
invocable: false
---

# Akka.NET Best Practices

## When to Use This Skill

Use this skill when:
- Designing actor communication patterns
- Deciding between EventStream and DistributedPubSub
- Implementing error handling in actors
- Understanding supervision strategies
- Choosing between Props patterns and DependencyResolver
- Designing work distribution across nodes
- Creating testable actor systems that can run with or without cluster infrastructure
- Abstracting over Cluster Sharding for local testing scenarios

---

## 1. EventStream vs DistributedPubSub

### Critical: EventStream is LOCAL ONLY

`Context.System.EventStream` is **local to a single ActorSystem process**. It does NOT work across cluster nodes.

```csharp
// BAD: This only works on a single server
// When you add a second server, subscribers on server 2 won't receive events from server 1
Context.System.EventStream.Subscribe(Self, typeof(PostCreated));
Context.System.EventStream.Publish(new PostCreated(postId, authorId));
```

**When EventStream is appropriate:**
- Logging and diagnostics within a single process
- Local event bus for truly single-process applications
- Development/testing scenarios

### Use DistributedPubSub for Multi-Node

For events that must reach actors across multiple cluster nodes, use `Akka.Cluster.Tools.PublishSubscribe`:

```csharp
using Akka.Cluster.Tools.PublishSubscribe;

public class TimelineUpdatePublisher : ReceiveActor
{
    private readonly IActorRef _mediator;

    public TimelineUpdatePublisher()
    {
        // Get the DistributedPubSub mediator
        _mediator = DistributedPubSub.Get(Context.System).Mediator;

        Receive<PublishTimelineUpdate>(msg =>
        {
            // Publish to a topic - reaches all subscribers across all nodes
            _mediator.Tell(new Publish($"timeline:{msg.UserId}", msg.Update));
        });
    }
}

public class TimelineSubscriber : ReceiveActor
{
    public TimelineSubscriber(UserId userId)
    {
        var mediator = DistributedPubSub.Get(Context.System).Mediator;

        // Subscribe to user-specific topic
        mediator.Tell(new Subscribe($"timeline:{userId}", Self));

        Receive<TimelineUpdate>(update =>
        {
            // Handle the update - this works across cluster nodes
        });

        Receive<SubscribeAck>(ack =>
        {
            // Subscription confirmed
        });
    }
}
```

### Akka.Hosting Configuration for DistributedPubSub

```csharp
builder.WithDistributedPubSub(role: null); // Available on all roles, or specify a role
```

### Topic Design Patterns

| Pattern | Topic Format | Use Case |
|---------|--------------|----------|
| Per-user | `timeline:{userId}` | Timeline updates, notifications |
| Per-entity | `post:{postId}` | Post engagement updates |
| Broadcast | `system:announcements` | System-wide notifications |
| Role-based | `workers:rss-poller` | Work distribution |

---

## 2. Supervision Strategies

### Key Clarification: Supervision is for CHILDREN

A supervision strategy defined on an actor dictates **how that actor supervises its children**, NOT how the actor itself is supervised.

```csharp
public class ParentActor : ReceiveActor
{
    // This strategy applies to children of ParentActor, NOT to ParentActor itself
    protected override SupervisorStrategy SupervisorStrategy()
    {
        return new OneForOneStrategy(
            maxNrOfRetries: 10,
            withinTimeRange: TimeSpan.FromSeconds(30),
            decider: ex => ex switch
            {
                ArithmeticException => Directive.Resume,
                NullReferenceException => Directive.Restart,
                ArgumentException => Directive.Stop,
                _ => Directive.Escalate
            });
    }
}
```

### Default Supervision Strategy

The default `OneForOneStrategy` already includes rate limiting:
- **10 restarts within 1 second** = actor is permanently stopped
- This prevents infinite restart loops

**You rarely need a custom strategy** unless you have specific requirements.

### When to Define Custom Supervision

**Good reasons:**
- Actor throws exceptions indicating irrecoverable state corruption → Restart
- Actor throws exceptions that should NOT cause restart (expected failures) → Resume
- Child failures should affect siblings → Use `AllForOneStrategy`
- Need different retry limits than the default

**Bad reasons:**
- "Just to be safe" - the default is already safe
- Don't understand what the actor does - understand it first

### Example: When Custom Supervision Makes Sense

```csharp
public class RssFeedCoordinator : ReceiveActor
{
    protected override SupervisorStrategy SupervisorStrategy()
    {
        return new OneForOneStrategy(
            maxNrOfRetries: -1, // Unlimited retries
            withinTimeRange: TimeSpan.FromMinutes(1),
            decider: ex => ex switch
            {
                // HTTP timeout - transient, resume and let the actor retry via its own timer
                HttpRequestException => Directive.Resume,

                // Feed URL permanently invalid - stop this child, don't restart forever
                InvalidFeedUrlException => Directive.Stop,

                // Unknown error - restart to clear potentially corrupt state
                _ => Directive.Restart
            });
    }
}
```

---

## 3. Error Handling: Supervision vs Try-Catch

### When to Use Try-Catch (Most Cases)

**Use try-catch when:**
- The failure is **expected** (network timeout, invalid input, external service down)
- You know **exactly why** the exception occurred
- You can handle it **gracefully** (retry, return error response, log and continue)
- Restarting would **not help** (same error would occur again)

```csharp
public class RssFeedPollerActor : ReceiveActor
{
    public RssFeedPollerActor()
    {
        ReceiveAsync<PollFeed>(async msg =>
        {
            try
            {
                var feed = await _httpClient.GetStringAsync(msg.FeedUrl);
                var items = ParseFeed(feed);
                // Process items...
            }
            catch (HttpRequestException ex)
            {
                // Expected failure - log and schedule retry
                _log.Warning("Feed {Url} unavailable: {Error}", msg.FeedUrl, ex.Message);
                Context.System.Scheduler.ScheduleTellOnce(
                    TimeSpan.FromMinutes(5),
                    Self,
                    msg,
                    Self);
            }
            catch (XmlException ex)
            {
                // Invalid feed format - log and mark as bad
                _log.Error("Feed {Url} has invalid format: {Error}", msg.FeedUrl, ex.Message);
                Sender.Tell(new FeedPollResult.InvalidFormat(msg.FeedUrl));
            }
        });
    }
}
```

### When to Let Supervision Handle It

**Let exceptions propagate (trigger supervision) when:**
- You have **no idea** why the exception occurred
- The actor's **state might be corrupt**
- A **restart would help** (fresh state, reconnect resources)
- It's a **programming error** (NullReferenceException, InvalidOperationException from bad logic)

```csharp
public class OrderActor : ReceiveActor
{
    private OrderState _state;

    public OrderActor()
    {
        Receive<ProcessPayment>(msg =>
        {
            // If this throws, we have no idea why - let supervision restart us
            // A restart will reload state from persistence and might fix the issue
            var result = _state.ApplyPayment(msg.Amount);
            Persist(new PaymentApplied(msg.Amount), evt =>
            {
                _state = _state.With(evt);
            });
        });
    }
}
```

### Anti-Pattern: Swallowing Unknown Exceptions

```csharp
// BAD: Swallowing exceptions hides problems
public class BadActor : ReceiveActor
{
    public BadActor()
    {
        ReceiveAsync<DoWork>(async msg =>
        {
            try
            {
                await ProcessWork(msg);
            }
            catch (Exception ex)
            {
                // This hides all errors - you'll never know something is broken
                _log.Error(ex, "Error processing work");
                // Actor continues with potentially corrupt state
            }
        });
    }
}

// GOOD: Handle known exceptions, let unknown ones propagate
public class GoodActor : ReceiveActor
{
    public GoodActor()
    {
        ReceiveAsync<DoWork>(async msg =>
        {
            try
            {
                await ProcessWork(msg);
            }
            catch (HttpRequestException ex)
            {
                // Known, expected failure - handle gracefully
                _log.Warning("HTTP request failed: {Error}", ex.Message);
                Sender.Tell(new WorkResult.TransientFailure());
            }
            // Unknown exceptions propagate to supervision
        });
    }
}
```

---

## 4. Props vs DependencyResolver

### When to Use Plain Props

**Use `Props.Create()` when:**
- Actor doesn't need `IServiceProvider` or `IRequiredActor<T>`
- All dependencies can be passed via constructor
- Actor is simple and self-contained

```csharp
// Simple actor with no DI needs
public static Props Props(PostId postId, IPostWriteStore store)
    => Akka.Actor.Props.Create(() => new PostEngagementActor(postId, store));

// Usage
var actor = Context.ActorOf(PostEngagementActor.Props(postId, store), postId.ToString());
```

### When to Use DependencyResolver

**Use `resolver.Props<T>()` when:**
- Actor needs `IServiceProvider` to create scoped services
- Actor uses `IRequiredActor<T>` to get references to other actors
- Actor has many dependencies that are already in DI container

```csharp
// Actor that needs scoped database connections
public class OrderProcessorActor : ReceiveActor
{
    public OrderProcessorActor(IServiceProvider serviceProvider)
    {
        ReceiveAsync<ProcessOrder>(async msg =>
        {
            // Create a scope for this operation
            using var scope = serviceProvider.CreateScope();
            var dbContext = scope.ServiceProvider.GetRequiredService<OrderDbContext>();
            // Process order...
        });
    }
}

// Registration with DI
builder.WithActors((system, registry, resolver) =>
{
    var actor = system.ActorOf(resolver.Props<OrderProcessorActor>(), "order-processor");
    registry.Register<OrderProcessorActor>(actor);
});
```

### Remote Deployment Considerations

**You almost never need remote deployment.** Remote deployment means deploying an actor to run on a different node than the one creating it.

If you're not doing remote deployment (and you probably aren't):
- `Props.Create(() => new Actor(...))` with closures is fine
- The "serialization issue" warning doesn't apply

**When you would use remote deployment:**
- Distributing compute-intensive work to specific nodes
- Running actors on nodes with specific hardware (GPU, etc.)

For most applications, use **cluster sharding** instead of remote deployment - it handles distribution automatically.

---

## 5. Work Distribution Patterns

### Problem: Thundering Herd

When you have many background jobs (RSS feeds, email sending, etc.), don't process them all at once:

```csharp
// BAD: Polls all feeds simultaneously on startup
public class BadRssCoordinator : ReceiveActor
{
    public BadRssCoordinator(IRssFeedRepository repo)
    {
        ReceiveAsync<StartPolling>(async _ =>
        {
            var feeds = await repo.GetAllFeedsAsync();
            foreach (var feed in feeds) // 2000 feeds = 2000 simultaneous HTTP requests
            {
                Context.ActorOf(RssFeedPollerActor.Props(feed.Url));
            }
        });
    }
}
```

### Pattern 1: Database-Driven Work Queue

Use the database as a work queue with `FOR UPDATE SKIP LOCKED`:

```csharp
public class RssPollerWorker : ReceiveActor
{
    public RssPollerWorker(IRssFeedRepository repo)
    {
        ReceiveAsync<PollBatch>(async _ =>
        {
            // Each worker claims a batch - naturally distributes across nodes
            var feeds = await repo.ClaimFeedsForPollingAsync(
                batchSize: 10,
                staleAfter: TimeSpan.FromMinutes(10));

            foreach (var feed in feeds)
            {
                try
                {
                    await PollFeed(feed);
                    await repo.MarkPolledAsync(feed.Id, success: true);
                }
                catch (Exception ex)
                {
                    await repo.MarkPolledAsync(feed.Id, success: false, error: ex.Message);
                }
            }

            // Schedule next batch
            Context.System.Scheduler.ScheduleTellOnce(
                TimeSpan.FromSeconds(5),
                Self,
                PollBatch.Instance,
                Self);
        });
    }
}
```

```sql
-- ClaimFeedsForPollingAsync implementation
UPDATE rss_feeds
SET status = 'processing',
    processing_started_at = NOW()
WHERE id IN (
    SELECT id FROM rss_feeds
    WHERE status = 'pending'
      AND (next_poll_at IS NULL OR next_poll_at <= NOW())
    ORDER BY next_poll_at NULLS FIRST
    LIMIT @batchSize
    FOR UPDATE SKIP LOCKED
)
RETURNING *;
```

**Benefits:**
- Naturally distributes work across multiple server nodes
- No coordination needed - database handles locking
- Easy to monitor (query the table)
- Survives server restarts

### Pattern 2: Akka.Streams for Rate Limiting

Use Akka.Streams to throttle processing within a single node:

```csharp
public class ThrottledRssProcessor : ReceiveActor
{
    public ThrottledRssProcessor(IRssFeedRepository repo)
    {
        var materializer = Context.System.Materializer();

        ReceiveAsync<StartProcessing>(async _ =>
        {
            await Source.From(await repo.GetPendingFeedsAsync())
                .Throttle(10, TimeSpan.FromSeconds(1)) // Max 10 per second
                .SelectAsync(4, async feed => // Max 4 concurrent
                {
                    await PollFeed(feed);
                    return feed;
                })
                .RunWith(Sink.Ignore<RssFeed>(), materializer);
        });
    }
}
```

### Pattern 3: Durable Queue (Email Outbox Pattern)

For work that must be reliably processed, use a database-backed outbox:

```csharp
// Enqueue work transactionally with business operation
public async Task CreatePostAsync(Post post)
{
    await using var transaction = await _db.BeginTransactionAsync();

    await _postStore.CreateAsync(post);

    // Enqueue notification emails in same transaction
    foreach (var follower in await _followStore.GetFollowersAsync(post.AuthorId))
    {
        await _emailOutbox.EnqueueAsync(new EmailJob
        {
            To = follower.Email,
            Template = "new-post",
            Data = JsonSerializer.Serialize(new { PostId = post.Id })
        });
    }

    await transaction.CommitAsync();
}

// Worker processes outbox
public class EmailOutboxWorker : ReceiveActor
{
    public EmailOutboxWorker(IEmailOutboxStore outbox, IEmailSender sender)
    {
        ReceiveAsync<ProcessBatch>(async _ =>
        {
            var batch = await outbox.ClaimBatchAsync(10);
            foreach (var job in batch)
            {
                try
                {
                    await sender.SendAsync(job);
                    await outbox.MarkSentAsync(job.Id);
                }
                catch (Exception ex)
                {
                    await outbox.MarkFailedAsync(job.Id, ex.Message);
                }
            }
        });
    }
}
```

---

## 6. Common Mistakes Summary

| Mistake | Why It's Wrong | Fix |
|---------|----------------|-----|
| Using EventStream for cross-node pub/sub | EventStream is local only | Use DistributedPubSub |
| Defining supervision to "protect" an actor | Supervision protects children | Understand the hierarchy |
| Catching all exceptions | Hides bugs, corrupts state | Only catch expected errors |
| Always using DependencyResolver | Adds unnecessary complexity | Use plain Props when possible |
| Processing all background jobs at once | Thundering herd, resource exhaustion | Use database queue + rate limiting |
| Throwing exceptions for expected failures | Triggers unnecessary restarts | Return result types, use messaging |

---

## 7. Quick Reference

### Communication Pattern Decision Tree

```
Need to communicate between actors?
├── Same process only? → EventStream is fine
├── Across cluster nodes?
│   ├── Point-to-point? → Use ActorSelection or known IActorRef
│   └── Pub/sub? → Use DistributedPubSub
└── Fire-and-forget to external system? → Consider outbox pattern
```

### Error Handling Decision Tree

```
Exception occurred in actor?
├── Expected failure (HTTP timeout, invalid input)?
│   └── Try-catch, handle gracefully, continue
├── State might be corrupt?
│   └── Let supervision restart
├── Unknown cause?
│   └── Let supervision restart
└── Programming error (null ref, bad logic)?
    └── Let supervision restart, fix the bug
```

### Props Decision Tree

```
Creating actor Props?
├── Actor needs IServiceProvider?
│   └── Use resolver.Props<T>()
├── Actor needs IRequiredActor<T>?
│   └── Use resolver.Props<T>()
├── Simple actor with constructor params?
│   └── Use Props.Create(() => new Actor(...))
└── Remote deployment needed?
    └── Probably not - use cluster sharding instead
```

---

## 8. Cluster/Local Mode Abstractions

For applications that need to run both in clustered production environments and local/test environments without cluster infrastructure, use abstraction patterns to toggle between implementations.

### AkkaExecutionMode Enum

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

### GenericChildPerEntityParent - Local Sharding Alternative

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

### IPubSubMediator - Abstracting DistributedPubSub

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

### LocalPubSubMediator - In-Memory Implementation

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

### ClusterPubSubMediator - Production Implementation

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

### Wiring It All Together

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

### Usage in Application Code

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

### Benefits of This Pattern

| Benefit | Description |
|---------|-------------|
| **Fast unit tests** | No cluster startup overhead, tests run in milliseconds |
| **Identical message flow** | Same `IMessageExtractor`, same message types |
| **Easy debugging** | Local mode is simpler to step through |
| **Integration test flexibility** | Choose mode per test scenario |
| **Production confidence** | Abstractions are thin wrappers over real implementations |

### When to Use Each Mode

| Scenario | Recommended Mode |
|----------|------------------|
| Unit tests | LocalTest |
| Integration tests (single node) | LocalTest |
| Integration tests (multi-node) | Clustered |
| Local development | LocalTest or Clustered (your choice) |
| Production | Clustered |
