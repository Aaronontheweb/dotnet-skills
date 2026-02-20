# Advanced Concurrency Patterns

Akka.NET Streams, Reactive Extensions, Akka.NET Actors, and async local function patterns for advanced concurrency scenarios.

## Contents

- [Akka.NET Streams (Complex Stream Processing)](#akkanet-streams-complex-stream-processing)
- [Reactive Extensions (UI and Event Composition)](#reactive-extensions-ui-and-event-composition)
- [Akka.NET Actors (Stateful Concurrency)](#akkanet-actors-stateful-concurrency)
- [Prefer Async Local Functions](#prefer-async-local-functions)

## Akka.NET Streams (Complex Stream Processing)

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

## Reactive Extensions (UI and Event Composition)

**Use for:** UI event handling, composing event streams, time-based operations in client applications.

Rx shines in UI scenarios where you need to react to user events with debouncing, throttling, or combining multiple event sources.

```csharp
using System.Reactive.Linq;

// Search-as-you-type with debouncing
public class SearchViewModel
{
    public SearchViewModel(ISearchService searchService)
    {
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
| UI events | Best choice | Overkill |
| Client-side composition | Best choice | Overkill |
| Server-side pipelines | Works but limited | Better backpressure |
| Distributed processing | Not designed for | Built for this |
| Hot observables | Native support | Requires more setup |

**Rule of thumb:** Rx for UI/client, Akka.NET Streams for server-side pipelines.

## Akka.NET Actors (Stateful Concurrency)

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
        Pending();
    }

    private void Pending()
    {
        Receive<AuthorizePayment>(msg =>
        {
            _payment = _payment with { Amount = msg.Amount };
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
builder.WithShardRegion<OrderActor>(
    typeName: "orders",
    entityPropsFactory: (_, _, resolver) =>
        orderId => Props.Create(() => new OrderActor(orderId)),
    messageExtractor: new OrderMessageExtractor(),
    shardOptions: new ShardOptions());

var orderRegion = registry.Get<OrderActor>();
orderRegion.Tell(new ShardingEnvelope("order-123", new AddItem(item)));
```

### When to Use Akka.NET

**Use Akka.NET Actors when you have:**

| Scenario | Why Actors? |
|----------|-------------|
| Many entities with independent state | Each entity gets its own actor - no locks |
| State machines | `Become()` elegantly models state transitions |
| Push-based/reactive updates | Actors naturally support tell-don't-ask |
| Supervision requirements | Parent actors supervise children, auto restart |
| Distributed systems | Cluster Sharding distributes across nodes |
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
| CRUD operations | Standard async services |

### The Actor Mindset

Think of actors when your problem looks like:
- "I have **thousands** of [orders/users/devices] that need independent state"
- "Each entity goes through a **lifecycle** with different behaviors at each stage"
- "I need to **push updates** to interested parties when something changes"
- "If processing fails, I want to **restart** just that entity"
- "This needs to work across **multiple servers**"

## Prefer Async Local Functions

Use async local functions instead of `Task.Run(async () => ...)` or `ContinueWith()`:

### Don't: Anonymous Async Lambda

```csharp
private void HandleCommand(MyCommand cmd)
{
    var self = Self;

    _ = Task.Run(async () =>
    {
        var result = await DoWorkAsync();
        return new WorkCompleted(result);
    }).PipeTo(self);
}
```

### Do: Async Local Function

```csharp
private void HandleCommand(MyCommand cmd)
{
    async Task<WorkCompleted> ExecuteAsync()
    {
        var result = await DoWorkAsync();
        return new WorkCompleted(result);
    }

    ExecuteAsync().PipeTo(Self);
}
```

### Avoid ContinueWith for Sequencing

**Don't:**
```csharp
someTask
    .ContinueWith(t => ProcessResult(t.Result))
    .ContinueWith(t => SendNotification(t.Result));
```

**Do:**
```csharp
async Task ProcessAndNotifyAsync()
{
    var result = await someTask;
    var processed = await ProcessResult(result);
    await SendNotification(processed);
}

ProcessAndNotifyAsync();
```

### Akka.NET Example

When using `PipeTo` in actors, async local functions keep the pattern clean:

```csharp
private void HandleSync(StartSync cmd)
{
    async Task<SyncResult> PerformSyncAsync()
    {
        await using var scope = _scopeFactory.CreateAsyncScope();
        var service = scope.ServiceProvider.GetRequiredService<ISyncService>();

        var count = await service.SyncAsync(cmd.EntityId);
        return new SyncResult(cmd.EntityId, count);
    }

    PerformSyncAsync().PipeTo(Self);
}
```

| Benefit | Description |
|---------|-------------|
| **Readability** | Named functions are self-documenting |
| **Debugging** | Stack traces show meaningful function names |
| **Exception handling** | Cleaner try/catch without `AggregateException` |
| **Scope clarity** | Local functions make captured variables explicit |
| **Testability** | Easier to extract and unit test the async logic |
