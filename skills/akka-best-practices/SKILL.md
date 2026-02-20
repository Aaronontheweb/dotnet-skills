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

## Reference Files

- [work-distribution-patterns.md](work-distribution-patterns.md): Database queues, Akka.Streams throttling, outbox pattern
- [cluster-local-abstractions.md](cluster-local-abstractions.md): GenericChildPerEntityParent, IPubSubMediator, execution mode wiring
- [async-cancellation-patterns.md](async-cancellation-patterns.md): Actor-scoped CancellationToken, linked CTS, timeout handling

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
- Actor throws exceptions indicating irrecoverable state corruption -> Restart
- Actor throws exceptions that should NOT cause restart (expected failures) -> Resume
- Child failures should affect siblings -> Use `AllForOneStrategy`
- Need different retry limits than the default

**Bad reasons:**
- "Just to be safe" - the default is already safe
- Don't understand what the actor does - understand it first

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
                    TimeSpan.FromMinutes(5), Self, msg, Self);
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

### Anti-Pattern: Swallowing Unknown Exceptions

```csharp
// BAD: Swallowing exceptions hides problems
catch (Exception ex)
{
    _log.Error(ex, "Error processing work");
    // Actor continues with potentially corrupt state
}

// GOOD: Handle known exceptions, let unknown ones propagate
catch (HttpRequestException ex)
{
    // Known, expected failure - handle gracefully
    _log.Warning("HTTP request failed: {Error}", ex.Message);
    Sender.Tell(new WorkResult.TransientFailure());
}
// Unknown exceptions propagate to supervision
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
```

### When to Use DependencyResolver

**Use `resolver.Props<T>()` when:**
- Actor needs `IServiceProvider` to create scoped services
- Actor uses `IRequiredActor<T>` to get references to other actors
- Actor has many dependencies that are already in DI container

```csharp
// Registration with DI
builder.WithActors((system, registry, resolver) =>
{
    var actor = system.ActorOf(resolver.Props<OrderProcessorActor>(), "order-processor");
    registry.Register<OrderProcessorActor>(actor);
});
```

### Remote Deployment Considerations

**You almost never need remote deployment.** If you're not doing remote deployment (and you probably aren't):
- `Props.Create(() => new Actor(...))` with closures is fine
- The "serialization issue" warning doesn't apply

For most applications, use **cluster sharding** instead of remote deployment - it handles distribution automatically.

---

## 5. Work Distribution Patterns

When you have many background jobs (RSS feeds, email sending, etc.), don't process them all at once - this causes thundering herd problems.

**Three patterns to solve this:**
1. **Database-Driven Work Queue** - Use `FOR UPDATE SKIP LOCKED` for natural cross-node distribution
2. **Akka.Streams Rate Limiting** - Throttle processing within a single node
3. **Durable Queue (Outbox Pattern)** - Database-backed outbox for reliable processing

See [work-distribution-patterns.md](work-distribution-patterns.md) for full code samples.

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
├── Same process only? -> EventStream is fine
├── Across cluster nodes?
│   ├── Point-to-point? -> Use ActorSelection or known IActorRef
│   └── Pub/sub? -> Use DistributedPubSub
└── Fire-and-forget to external system? -> Consider outbox pattern
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

For applications that need to run both in clustered production and local/test environments, use abstraction patterns to toggle between implementations:

- **`AkkaExecutionMode` enum** - Controls which implementations are used (LocalTest vs Clustered)
- **`GenericChildPerEntityParent`** - Mimics sharding behavior locally using the same `IMessageExtractor`
- **`IPubSubMediator`** - Abstracts DistributedPubSub for swappable local/cluster implementations

See [cluster-local-abstractions.md](cluster-local-abstractions.md) for complete implementation code.

---

## 9. Actor Logging

### Use ILoggingAdapter, Not ILogger<T>

In actors, use `ILoggingAdapter` from `Context.GetLogger()` instead of DI-injected `ILogger<T>`:

```csharp
public class MyActor : ReceiveActor
{
    private readonly ILoggingAdapter _log = Context.GetLogger();

    public MyActor()
    {
        Receive<MyMessage>(msg =>
        {
            _log.Info("Processing message for user {UserId}", msg.UserId);
            _log.Error(ex, "Failed to process {MessageType}", msg.GetType().Name);
        });
    }
}
```

**Why ILoggingAdapter:**
- Integrates with Akka's logging pipeline and supervision
- Supports semantic/structured logging as of v1.5.57
- Method names: `Info()`, `Debug()`, `Warning()`, `Error()` (not `Log*` variants)
- No DI required - obtained directly from actor context

**Don't inject ILogger<T> into actors** - it bypasses Akka's logging infrastructure.

### Semantic Logging (v1.5.57+)

```csharp
// Named placeholders for better log aggregation and querying
_log.Info("Order {OrderId} processed for customer {CustomerId}", order.Id, order.CustomerId);

// Prefer named placeholders over positional
// Good: {OrderId}, {CustomerId}
// Avoid: {0}, {1}
```

---

## 10. Managing Async Operations with CancellationToken

When actors launch async operations via `PipeTo`, those operations can outlive the actor if not properly managed. Key practices:

- **Actor CTS in PostStop** - Always cancel and dispose in `PostStop()`
- **New CTS per operation** - Cancel previous before starting new work
- **Pass token everywhere** - EF Core queries, HTTP calls, etc.
- **Linked CTS for timeouts** - External calls get short timeouts to prevent hanging
- **Graceful handling** - Distinguish timeout vs shutdown in catch blocks

See [async-cancellation-patterns.md](async-cancellation-patterns.md) for complete implementation code.
