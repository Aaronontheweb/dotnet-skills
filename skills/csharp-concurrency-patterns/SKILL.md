---
name: csharp-concurrency-patterns
description: Choosing the right concurrency abstraction in .NET - from async/await for I/O to Channels for producer/consumer to Akka.NET for stateful entity management. Avoid locks and manual synchronization unless absolutely necessary.
invocable: false
---

# .NET Concurrency: Choosing the Right Tool

## When to Use This Skill

Use this skill when:
- Deciding how to handle concurrent operations in .NET
- Evaluating whether to use async/await, Channels, Akka.NET, or other abstractions
- Tempted to use locks, semaphores, or other synchronization primitives
- Need to process streams of data with backpressure, batching, or debouncing
- Managing state across multiple concurrent entities

## Reference Files

- [advanced-concurrency.md](advanced-concurrency.md): Akka.NET Streams, Reactive Extensions, Akka.NET Actors (entity-per-actor, state machines, cluster sharding), and async local function patterns

## The Philosophy

**Start simple, escalate only when needed.**

Most concurrency problems can be solved with `async/await`. Only reach for more sophisticated tools when you have a specific need that async/await can't address cleanly.

**Try to avoid shared mutable state.** The best way to handle concurrency is to design it away. Immutable data, message passing, and isolated state (like actors) eliminate entire categories of bugs.

**Locks should be the exception, not the rule.** When you can't avoid shared mutable state:
1. **First choice:** Redesign to avoid it (immutability, message passing, actor isolation)
2. **Second choice:** Use `System.Collections.Concurrent` (ConcurrentDictionary, etc.)
3. **Third choice:** Use `Channel<T>` to serialize access through message passing
4. **Last resort:** Use `lock` for simple, short-lived critical sections

---

## Decision Tree

```
What are you trying to do?
│
├─► Wait for I/O (HTTP, database, file)?
│   └─► Use async/await
│
├─► Process a collection in parallel (CPU-bound)?
│   └─► Use Parallel.ForEachAsync
│
├─► Producer/consumer pattern (work queue)?
│   └─► Use System.Threading.Channels
│
├─► UI event handling (debounce, throttle, combine)?
│   └─► Use Reactive Extensions (Rx)
│
├─► Server-side stream processing (backpressure, batching)?
│   └─► Use Akka.NET Streams
│
├─► State machines with complex transitions?
│   └─► Use Akka.NET Actors (Become pattern)
│
├─► Manage state for many independent entities?
│   └─► Use Akka.NET Actors (entity-per-actor)
│
├─► Coordinate multiple async operations?
│   └─► Use Task.WhenAll / Task.WhenAny
│
└─► None of the above fits?
    └─► Ask yourself: "Do I really need shared mutable state?"
        ├─► Yes → Consider redesigning to avoid it
        └─► Truly unavoidable → Use Channels or Actors to serialize access
```

---

## Level 1: async/await (Default Choice)

**Use for:** I/O-bound operations, non-blocking waits, most everyday concurrency.

```csharp
// Simple async I/O
public async Task<Order> GetOrderAsync(string orderId, CancellationToken ct)
{
    var order = await _database.GetAsync(orderId, ct);
    var customer = await _customerService.GetAsync(order.CustomerId, ct);
    return order with { Customer = customer };
}

// Parallel async operations (when independent)
public async Task<Dashboard> LoadDashboardAsync(string userId, CancellationToken ct)
{
    var ordersTask = _orderService.GetRecentOrdersAsync(userId, ct);
    var notificationsTask = _notificationService.GetUnreadAsync(userId, ct);
    var statsTask = _statsService.GetUserStatsAsync(userId, ct);

    await Task.WhenAll(ordersTask, notificationsTask, statsTask);

    return new Dashboard(
        Orders: await ordersTask,
        Notifications: await notificationsTask,
        Stats: await statsTask);
}
```

**Key principles:** Always accept `CancellationToken`. Use `ConfigureAwait(false)` in library code. Don't block on async code.

---

## Level 2: Parallel.ForEachAsync (CPU-Bound Parallelism)

**Use for:** Processing collections in parallel when work is CPU-bound or you need controlled concurrency.

```csharp
public async Task ProcessOrdersAsync(
    IEnumerable<Order> orders,
    CancellationToken ct)
{
    await Parallel.ForEachAsync(
        orders,
        new ParallelOptions
        {
            MaxDegreeOfParallelism = Environment.ProcessorCount,
            CancellationToken = ct
        },
        async (order, token) =>
        {
            await ProcessOrderAsync(order, token);
        });
}
```

**When NOT to use:** Pure I/O operations, when order matters, when you need backpressure.

---

## Level 3: System.Threading.Channels (Producer/Consumer)

**Use for:** Work queues, producer/consumer patterns, decoupling producers from consumers.

```csharp
public class OrderProcessor
{
    private readonly Channel<Order> _channel;

    public OrderProcessor()
    {
        _channel = Channel.CreateBounded<Order>(new BoundedChannelOptions(100)
        {
            FullMode = BoundedChannelFullMode.Wait
        });
    }

    // Producer
    public async Task EnqueueOrderAsync(Order order, CancellationToken ct)
    {
        await _channel.Writer.WriteAsync(order, ct);
    }

    // Consumer (run as background task)
    public async Task ProcessOrdersAsync(CancellationToken ct)
    {
        await foreach (var order in _channel.Reader.ReadAllAsync(ct))
        {
            await ProcessOrderAsync(order, ct);
        }
    }

    public void Complete() => _channel.Writer.Complete();
}
```

**Channels are good for:** Decoupling speed, buffering with backpressure, fan-out to workers, background queues.

**Channels are NOT good for:** Complex stream operations (batching, windowing), stateful per-entity processing, sophisticated supervision.

---

## Level 4+: Akka.NET Streams, Reactive Extensions, Actors

For advanced scenarios requiring stream processing, UI event composition, or stateful entity management, see [advanced-concurrency.md](advanced-concurrency.md).

**Akka.NET Streams** excel at server-side batching, throttling, and backpressure. **Reactive Extensions** are ideal for UI event composition. **Akka.NET Actors** handle entity-per-actor patterns, state machines with `Become()`, and distributed systems via Cluster Sharding.

---

## Anti-Patterns: What to Avoid

### Locks for Business Logic

```csharp
// BAD: Using locks to protect shared state
private readonly object _lock = new();
private Dictionary<string, Order> _orders = new();

public void UpdateOrder(string id, Action<Order> update)
{
    lock (_lock) { if (_orders.TryGetValue(id, out var order)) update(order); }
}

// GOOD: Use an actor or Channel to serialize access
```

### Manual Thread Management

```csharp
// BAD: Creating threads manually
var thread = new Thread(() => ProcessOrders());
thread.Start();

// GOOD: Use Task.Run or better abstractions
_ = Task.Run(() => ProcessOrdersAsync(cancellationToken));
```

### Blocking in Async Code

```csharp
// BAD: Blocking on async - deadlock risk!
var result = GetDataAsync().Result;

// GOOD: Async all the way
var result = await GetDataAsync();
```

### Shared Mutable State Without Protection

```csharp
// BAD: Multiple tasks mutating shared state
var results = new List<Result>();
await Parallel.ForEachAsync(items, async (item, ct) =>
{
    var result = await ProcessAsync(item, ct);
    results.Add(result); // Race condition!
});

// GOOD: Use ConcurrentBag
var results = new ConcurrentBag<Result>();
```

---

## Quick Reference: Which Tool When?

| Need | Tool | Example |
|------|------|---------|
| Wait for I/O | `async/await` | HTTP calls, database queries |
| Parallel CPU work | `Parallel.ForEachAsync` | Image processing, calculations |
| Work queue | `Channel<T>` | Background job processing |
| UI events with debounce/throttle | Reactive Extensions | Search-as-you-type, auto-save |
| Server-side batching/throttling | Akka.NET Streams | Event aggregation, rate limiting |
| State machines | Akka.NET Actors | Payment flows, order lifecycles |
| Entity state management | Akka.NET Actors | Order management, user sessions |
| Fire multiple async ops | `Task.WhenAll` | Loading dashboard data |
| Race multiple async ops | `Task.WhenAny` | Timeout with fallback |
| Periodic work | `PeriodicTimer` | Health checks, polling |

---

## The Escalation Path

```
async/await (start here)
    │
    ├─► Need parallelism? → Parallel.ForEachAsync
    │
    ├─► Need producer/consumer? → Channel<T>
    │
    ├─► Need UI event composition? → Reactive Extensions
    │
    ├─► Need server-side stream processing? → Akka.NET Streams
    │
    └─► Need state machines or entity management? → Akka.NET Actors
```

**Only escalate when you have a concrete need.** Don't reach for actors or streams "just in case".
