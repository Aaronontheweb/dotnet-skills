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

## The Philosophy

**Start simple, escalate only when needed.**

Most concurrency problems can be solved with `async/await`. Only reach for more sophisticated tools when you have a specific need that async/await can't address cleanly.

**Try to avoid shared mutable state.** The best way to handle concurrency is to design it away. Immutable data, message passing, and isolated state (like actors) eliminate entire categories of bugs.

**Locks should be the exception, not the rule.** When you can't avoid shared mutable state, using a lock occasionally isn't the end of the world. But if you find yourself reaching for `lock`, `SemaphoreSlim`, or other synchronization primitives regularly, step back and reconsider your design.

When you truly need shared mutable state:
1. **First choice:** Redesign to avoid it (immutability, message passing, actor isolation)
2. **Second choice:** Use `System.Collections.Concurrent` (ConcurrentDictionary, ConcurrentQueue, etc.)
3. **Third choice:** Use `Channel<T>` to serialize access through message passing
4. **Last resort:** Use `lock` for simple, short-lived critical sections

Locks are appropriate when building low-level infrastructure or concurrent data structures. But for business logic, there's almost always a better abstraction.

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

**Key principles:**
- Always accept `CancellationToken`
- Use `ConfigureAwait(false)` in library code
- Don't block on async code (no `.Result` or `.Wait()`)

---

## Level 2: Parallel.ForEachAsync (CPU-Bound Parallelism)

**Use for:** Processing collections in parallel when work is CPU-bound or you need controlled concurrency.

```csharp
// Process items with controlled parallelism
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

// CPU-bound work with I/O
public async Task<IReadOnlyList<ProcessedImage>> ProcessImagesAsync(
    IEnumerable<string> imagePaths,
    CancellationToken ct)
{
    var results = new ConcurrentBag<ProcessedImage>();

    await Parallel.ForEachAsync(
        imagePaths,
        new ParallelOptions { MaxDegreeOfParallelism = 4, CancellationToken = ct },
        async (path, token) =>
        {
            var image = await File.ReadAllBytesAsync(path, token);
            var processed = ProcessImage(image); // CPU-bound
            results.Add(processed);
        });

    return results.ToList();
}
```

**When NOT to use:**
- Pure I/O operations (async/await is sufficient)
- When order matters (Parallel doesn't preserve order)
- When you need backpressure or flow control

---

## Level 3: System.Threading.Channels (Producer/Consumer)

**Use for:** Work queues, producer/consumer patterns, decoupling producers from consumers, simple stream-like processing.

```csharp
// Basic producer/consumer
public class OrderProcessor
{
    private readonly Channel<Order> _channel;

    public OrderProcessor()
    {
        // Bounded channel provides backpressure
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

    // Signal no more items
    public void Complete() => _channel.Writer.Complete();
}
```

```csharp
// Multiple consumers (work-stealing pattern)
public class WorkerPool
{
    private readonly Channel<WorkItem> _channel;
    private readonly List<Task> _workers = new();

    public WorkerPool(int workerCount)
    {
        _channel = Channel.CreateUnbounded<WorkItem>();

        // Start multiple consumers
        for (int i = 0; i < workerCount; i++)
        {
            _workers.Add(Task.Run(() => ConsumeAsync()));
        }
    }

    private async Task ConsumeAsync()
    {
        await foreach (var item in _channel.Reader.ReadAllAsync())
        {
            await ProcessAsync(item);
        }
    }

    public ValueTask EnqueueAsync(WorkItem item)
        => _channel.Writer.WriteAsync(item);
}
```

**Channels are good for:**
- Decoupling producer speed from consumer speed
- Buffering work with backpressure
- Simple fan-out to multiple workers
- Background processing queues

**Channels are NOT good for:**
- Complex stream operations (batching, windowing, merging)
- Stateful processing per entity
- When you need sophisticated error handling/supervision

---

## Level 4: Akka.NET Streams (Complex Stream Processing)

**Use for:** Backpressure, batching, debouncing, throttling, merging streams, complex transformations.

```csharp
using Akka.Streams;
using Akka.Streams.Dsl;

// Batching with timeout
public Source<IReadOnlyList<Event>, NotUsed> BatchEvents(
    Source<Event, NotUsed> events)
{
    return events
        .GroupedWithin(100, TimeSpan.FromSeconds(1)) // Batch up to 100 or 1 second
        .Select(batch => batch.ToList() as IReadOnlyList<Event>);
}

// Throttling
public Source<Request, NotUsed> ThrottleRequests(
    Source<Request, NotUsed> requests)
{
    return requests
        .Throttle(10, TimeSpan.FromSeconds(1), 5, ThrottleMode.Shaping);
}

// Parallel processing with ordered results
public Source<ProcessedItem, NotUsed> ProcessWithParallelism(
    Source<Item, NotUsed> items)
{
    return items
        .SelectAsync(4, async item => await ProcessAsync(item)); // 4 parallel
}

// Complex pipeline
public IRunnableGraph<Task<Done>> CreatePipeline(
    Source<RawEvent, NotUsed> events,
    Sink<ProcessedEvent, Task<Done>> sink)
{
    return events
        .Where(e => e.IsValid)
        .GroupedWithin(50, TimeSpan.FromMilliseconds(500))
        .SelectAsync(4, batch => ProcessBatchAsync(batch))
        .SelectMany(results => results)
        .ToMaterialized(sink, Keep.Right);
}
```

**Akka.NET Streams excel at:**
- Batching with size AND time limits
- Throttling and rate limiting
- Backpressure that propagates through the entire pipeline
- Merging/splitting streams
- Parallel processing with ordering guarantees
- Error handling with supervision

---

## Level 4b: Reactive Extensions (UI and Event Composition)

**Use for:** UI event handling, composing event streams, time-based operations in client applications.

Rx shines in UI scenarios where you need to react to user events with debouncing, throttling, or combining multiple event sources.

```csharp
using System.Reactive.Linq;

// Search-as-you-type with debouncing
public class SearchViewModel
{
    public SearchViewModel(ISearchService searchService)
    {
        // React to text changes with debouncing
        SearchResults = SearchText
            .Throttle(TimeSpan.FromMilliseconds(300))  // Wait for typing to pause
            .DistinctUntilChanged()                     // Ignore if same text
            .Where(text => text.Length >= 3)           // Minimum length
            .SelectMany(text => searchService.SearchAsync(text).ToObservable())
            .ObserveOn(RxApp.MainThreadScheduler);     // Back to UI thread
    }

    public IObservable<string> SearchText { get; }
    public IObservable<IList<SearchResult>> SearchResults { get; }
}

// Combining multiple UI events
public IObservable<bool> CanSubmit =>
    Observable.CombineLatest(
        UsernameValid,
        PasswordValid,
        EmailValid,
        (user, pass, email) => user && pass && email);

// Double-click detection
public IObservable<Point> DoubleClicks =>
    MouseClicks
        .Buffer(TimeSpan.FromMilliseconds(300))
        .Where(clicks => clicks.Count >= 2)
        .Select(clicks => clicks.Last());

// Auto-save with debouncing
public IDisposable AutoSave =>
    DocumentChanges
        .Throttle(TimeSpan.FromSeconds(2))
        .Subscribe(async doc => await SaveAsync(doc));
```

**Rx is ideal for:**
- UI event composition (WPF, WinForms, MAUI, Blazor)
- Search-as-you-type with debouncing
- Combining multiple event sources
- Time-windowed operations in UI
- Drag-and-drop gesture detection
- Real-time data visualization

**Rx vs Akka.NET Streams:**

| Scenario | Rx | Akka.NET Streams |
|----------|----|--------------------|
| UI events | ✅ Best choice | Overkill |
| Client-side composition | ✅ Best choice | Overkill |
| Server-side pipelines | Works but limited | ✅ Better backpressure |
| Distributed processing | ❌ Not designed for | ✅ Built for this |
| Hot observables | ✅ Native support | Requires more setup |

**Rule of thumb:** Rx for UI/client, Akka.NET Streams for server-side pipelines.

---

## Level 5: Akka.NET Actors (Stateful Concurrency)

**Use for:** Managing state for multiple entities, state machines, push-based updates, complex coordination, supervision and fault tolerance.

### Entity-Per-Actor Pattern

```csharp
// Actor per entity - each order has isolated state
public class OrderActor : ReceiveActor
{
    private OrderState _state;

    public OrderActor(string orderId)
    {
        _state = new OrderState(orderId);

        Receive<AddItem>(msg =>
        {
            _state = _state.AddItem(msg.Item);
            Sender.Tell(new ItemAdded(msg.Item));
        });

        Receive<Checkout>(msg =>
        {
            if (_state.CanCheckout)
            {
                _state = _state.Checkout();
                Sender.Tell(new CheckoutSucceeded(_state.Total));
            }
            else
            {
                Sender.Tell(new CheckoutFailed("Cart is empty"));
            }
        });

        Receive<GetState>(_ => Sender.Tell(_state));
    }
}
```

### State Machines with Become

Actors excel at implementing state machines using `Become()` to switch message handlers:

```csharp
public class PaymentActor : ReceiveActor
{
    private PaymentData _payment;

    public PaymentActor(string paymentId)
    {
        _payment = new PaymentData(paymentId);

        // Start in Pending state
        Pending();
    }

    private void Pending()
    {
        Receive<AuthorizePayment>(msg =>
        {
            _payment = _payment with { Amount = msg.Amount };
            // Transition to Authorizing state
            Become(Authorizing);
            Self.Tell(new ProcessAuthorization());
        });

        Receive<CancelPayment>(_ =>
        {
            Become(Cancelled);
            Sender.Tell(new PaymentCancelled(_payment.Id));
        });
    }

    private void Authorizing()
    {
        Receive<ProcessAuthorization>(async _ =>
        {
            var result = await _gateway.AuthorizeAsync(_payment);
            if (result.Success)
            {
                _payment = _payment with { AuthCode = result.AuthCode };
                Become(Authorized);
            }
            else
            {
                Become(Failed);
            }
        });

        // Can't cancel while authorizing - stash for later or reject
        Receive<CancelPayment>(_ =>
        {
            Sender.Tell(new PaymentError("Cannot cancel during authorization"));
        });
    }

    private void Authorized()
    {
        Receive<CapturePayment>(_ =>
        {
            Become(Capturing);
            Self.Tell(new ProcessCapture());
        });

        Receive<VoidPayment>(_ =>
        {
            Become(Voiding);
            Self.Tell(new ProcessVoid());
        });
    }

    private void Capturing() { /* ... */ }
    private void Voiding() { /* ... */ }
    private void Cancelled() { /* Only responds to GetState */ }
    private void Failed() { /* Only responds to GetState, Retry */ }
}
```

### Distributed Entities with Cluster Sharding

```csharp
// Using Cluster Sharding for distributed entities
builder.WithShardRegion<OrderActor>(
    typeName: "orders",
    entityPropsFactory: (_, _, resolver) =>
        orderId => Props.Create(() => new OrderActor(orderId)),
    messageExtractor: new OrderMessageExtractor(),
    shardOptions: new ShardOptions());

// Send message to any order - sharding routes to correct node
var orderRegion = registry.Get<OrderActor>();
orderRegion.Tell(new ShardingEnvelope("order-123", new AddItem(item)));
```

### When to Use Akka.NET

**Use Akka.NET Actors when you have:**

| Scenario | Why Actors? |
|----------|-------------|
| Many entities with independent state | Each entity gets its own actor - no locks, natural isolation |
| State machines | `Become()` elegantly models state transitions |
| Push-based/reactive updates | Actors naturally support tell-don't-ask |
| Supervision requirements | Parent actors supervise children, automatic restart on failure |
| Distributed systems | Cluster Sharding distributes entities across nodes |
| Long-running workflows | Actors + persistence = durable workflows |
| Real-time systems | Message-driven, non-blocking by design |
| IoT / device management | Each device = one actor, scales to millions |

**Don't use Akka.NET when:**

| Scenario | Better Alternative |
|----------|-------------------|
| Simple work queue | `Channel<T>` |
| Request/response API | `async/await` |
| Batch processing | `Parallel.ForEachAsync` or Akka.NET Streams |
| UI event handling | Reactive Extensions |
| Shared state (single instance) | Service with `Channel` for serialization |
| CRUD operations | Standard async services |

### The Actor Mindset

Think of actors when your problem looks like:
- "I have **thousands** of [orders/users/devices/sessions] that need independent state"
- "Each [entity] goes through a **lifecycle** with different behaviors at each stage"
- "I need to **push updates** to interested parties when something changes"
- "If processing fails, I want to **restart** just that entity, not the whole system"
- "This needs to work across **multiple servers**"

If none of these apply, you probably don't need actors.

---

## Anti-Patterns: What to Avoid

### ❌ Locks for Business Logic

```csharp
// BAD: Using locks to protect shared state
private readonly object _lock = new();
private Dictionary<string, Order> _orders = new();

public void UpdateOrder(string id, Action<Order> update)
{
    lock (_lock)
    {
        if (_orders.TryGetValue(id, out var order))
        {
            update(order);
        }
    }
}

// GOOD: Use an actor or Channel to serialize access
// Each order gets its own actor - no locks needed
```

### ❌ Manual Thread Management

```csharp
// BAD: Creating threads manually
var thread = new Thread(() => ProcessOrders());
thread.Start();

// GOOD: Use Task.Run or better abstractions
_ = Task.Run(() => ProcessOrdersAsync(cancellationToken));
```

### ❌ Blocking in Async Code

```csharp
// BAD: Blocking on async
var result = GetDataAsync().Result; // Deadlock risk!
GetDataAsync().Wait();              // Also bad

// GOOD: Async all the way
var result = await GetDataAsync();
```

### ❌ Shared Mutable State Without Protection

```csharp
// BAD: Multiple tasks mutating shared state
var results = new List<Result>();
await Parallel.ForEachAsync(items, async (item, ct) =>
{
    var result = await ProcessAsync(item, ct);
    results.Add(result); // Race condition!
});

// GOOD: Use ConcurrentBag or collect results differently
var results = new ConcurrentBag<Result>();
// Or better: return from the lambda and collect
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

**Only escalate when you have a concrete need.** Don't reach for actors or streams "just in case" - start with async/await and move up only when the simpler approach doesn't fit.
