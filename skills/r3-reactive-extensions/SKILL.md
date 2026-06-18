---
name: r3-reactive-extensions
description: Build reactive/event-driven C# with R3 (Cysharp's modern reimplementation of Reactive Extensions). Covers the Observable<T>/Observer<T> model, the OnErrorResume error contract, async dispatch with AwaitOperation, Task/IAsyncEnumerable integration, TimeProvider/FrameProvider scheduling, the concurrency contract, and how R3 differs from System.Reactive (Rx.NET).
invocable: false
---

# R3: Modern Reactive Extensions for .NET

R3 is [Cysharp's](https://github.com/Cysharp/R3) ground-up reimplementation of Reactive
Extensions — "the new future of dotnet/reactive and UniRx." It keeps the LINQ-over-events
programming model but rebuilds the core types, error contract, and scheduler to fix
long-standing problems in `System.Reactive` (Rx.NET). Use this skill when composing event
streams, UI input, timers, or push-based pipelines in C#.

**Canonical sources** (link to these from code and docs):
- Repository: https://github.com/Cysharp/R3
- README (full operator reference): https://github.com/Cysharp/R3/blob/main/README.md
- Author's design rationale: https://neuecc.medium.com/r3-a-new-modern-reimplementation-of-reactive-extensions-for-c-cf29abcc5826

## When to Use This Skill

Use this skill when:
- Composing **events** over time — UI input, sensor/feed updates, websocket messages, domain events
- You need operators like debounce, throttle, merge, combine-latest, distinct-until-changed
- Building **MVVM** state with `ReactiveProperty` / `BindableReactiveProperty`
- Bridging push-based streams with `Task` / `async` and `IAsyncEnumerable`
- Migrating from `System.Reactive`, UniRx, or `IObservable<T>` code
- You hit Rx pain points: subscriptions dying on exceptions, scheduler overhead, or leak hunting

**Not the right tool for:** request/response I/O (use `async/await`), bounded producer/consumer
with **backpressure** (use `System.Threading.Channels`), or server-side stream processing with
batching/backpressure (use Akka.NET Streams). R3, like all Rx, is **push-based with no
backpressure**. See the `csharp-concurrency-patterns` skill for choosing between these.

## Reference Files

- [rx-net-differences.md](rx-net-differences.md): Every meaningful difference vs System.Reactive (Rx.NET) — the new core types, the error model, operator renames, dropped APIs, the scheduler swap, and a migration checklist.
- [async-and-integration-patterns.md](async-and-integration-patterns.md): Common patterns — async dispatch with `AwaitOperation`, `Task` integration, `IAsyncEnumerable` round-tripping, `ReactiveProperty`/MVVM, subjects, and subscription lifecycle.
- [scheduling-and-concurrency.md](scheduling-and-concurrency.md): How R3 handles **concurrent updates** (the threading contract, `Synchronize`, `ObserveOn`), `TimeProvider` vs `FrameProvider`, when each is necessary, and deterministic testing with fake providers.

> Everything in this skill was validated empirically against **R3 1.3.1**. Captured output
> appears in the reference files as evidence.

---

## Why R3 Exists (the "why use it")

The author ([neuecc](https://neuecc.medium.com/r3-a-new-modern-reimplementation-of-reactive-extensions-for-c-cf29abcc5826))
built R3 to fix concrete defects in `System.Reactive`:

1. **Exceptions silently kill subscriptions.** In Rx, one exception in the pipeline calls
   `OnError` and *unsubscribes forever* — "a billion-dollar mistake" for long-lived event
   streams (a single bad UI event tears down the whole subscription). R3 routes errors to
   `OnErrorResume` and **keeps the subscription alive by default**.
2. **`IScheduler` is heavy and confusing.** `ImmediateScheduler`/`Merge` were measured causing
   real server memory/CPU bloat. R3 deletes `IScheduler` and uses .NET 8's `TimeProvider`
   (wall-clock) plus a new `FrameProvider` (frame-clock).
3. **Subscription leaks are hard to find.** R3 makes every `Observable<T>` an abstract class so
   all subscriptions funnel through one place, enabling `ObservableTracker` to list every live
   subscription with stack traces.
4. **Rx and async were awkwardly fused.** R3 treats Rx as **event-first** and adds explicit
   bridges (`AwaitOperation`, `FromAsync`, `ToAsyncEnumerable`) instead of pretending events
   are pull-based sequences.
5. **One library, every UI.** A platform-neutral core plus thin provider packages for Unity,
   Godot, WPF, WinForms, Avalonia, WinUI3, MAUI, Stride, MonoGame, and Blazor.

---

## Install

```bash
dotnet add package R3
# Platform glue (pick what applies): R3.WPF, R3.Avalonia, R3.WinForms, R3.Unity (UPM),
# R3.Godot, ObservableCollections.R3, etc. See the repo README for the full list.
```

```csharp
using R3;
```

---

## The Mental Model

R3 replaces Rx's **interfaces** with **abstract classes**, and replaces Rx's two-method error
contract with a single completion that carries a result.

```csharp
public abstract class Observable<T>
{
    public IDisposable Subscribe(Observer<T> observer);     // tracked centrally
    protected abstract IDisposable SubscribeCore(Observer<T> observer);
}

public abstract class Observer<T> : IDisposable               // the observer IS the subscription
{
    public void OnNext(T value);
    public void OnErrorResume(Exception error);               // error WITHOUT unsubscribing
    public void OnCompleted(Result result);                   // success OR failure terminates
}
```

The grammar is `(OnNext | OnErrorResume)* OnCompleted(Result)?`. Note the difference from Rx's
`OnNext* (OnError | OnCompleted)?`: **errors and termination are decoupled**. An error is just a
notification; only `OnCompleted` ends the stream, and it carries a `Result` that is either
`Result.Success` or `Result.Failure(exception)`.

### Quick start

```csharp
using R3;

var subscription = Observable
    .EveryValueChanged(model, m => m.SearchText)   // emits when the property changes
    .Debounce(TimeSpan.FromMilliseconds(300))      // Rx called this "Throttle" (see differences)
    .DistinctUntilChanged()
    .SubscribeAwait(async (text, ct) =>
    {
        var results = await _api.SearchAsync(text, ct);
        Render(results);
    }, AwaitOperation.Switch);                      // cancel the in-flight search on a new keystroke

// Dispose to unsubscribe; or route into a DisposableBag / AddTo(token).
subscription.Dispose();
```

---

## Core Behavior, Verified

### Errors do not terminate by default

```csharp
var subject = new Subject<int>();
subject.Select(x => 100 / x).Subscribe(
    onNext:        x => Console.WriteLine($"next {x}"),
    onErrorResume: e => Console.WriteLine($"errorResume {e.GetType().Name}"),
    onCompleted:   (Result r) => Console.WriteLine($"completed IsSuccess={r.IsSuccess}"));

subject.OnNext(2);   // next 50
subject.OnNext(0);   // errorResume DivideByZeroException   <-- NOT terminated
subject.OnNext(5);   // next 20                             <-- subscription is still alive!
subject.OnCompleted(); // completed IsSuccess=True
```

This is the single biggest behavioral change from Rx. To opt back into classic "an error
terminates the sequence" behavior, insert `.OnErrorResumeAsFailure()` — the error then flows to
`OnCompleted(Result.Failure(e))` and downstream `OnNext`s stop. Recover with `Catch`. Full
captured runs and the (deliberately absent) `Retry` story are in
[rx-net-differences.md](rx-net-differences.md).

### Async dispatch is explicit

R3's async operators (`SubscribeAwait`, `SelectAwait`, `WhereAwait`, …) take an `AwaitOperation`
that decides what happens when values arrive faster than the async work completes:

| `AwaitOperation` | Overlap behavior | Typical use |
|------------------|------------------|-------------|
| `Sequential` (default) | Queue values, run one at a time | Ordered processing |
| `Drop` | Ignore new values while one is running | Debounced submit / cooldown |
| `Switch` | Cancel the running one, start the new | Search-as-you-type, latest-wins |
| `Parallel` | Run all concurrently | Independent fan-out |
| `SequentialParallel` | Run concurrently, emit results in order | Parallel map, ordered output |
| `ThrottleFirstLast` | Run first + last of a burst | Leading/trailing sampling |

These were verified to behave exactly as described (including `Switch` cancelling the superseded
operation's `CancellationToken`). See [async-and-integration-patterns.md](async-and-integration-patterns.md).

### Task and IAsyncEnumerable bridges

```csharp
// Task -> Observable
await Observable.FromAsync(async ct => await LoadAsync(ct)).FirstAsync();

// Observable -> Task (terminal operators return Task<T>)
List<int> all = await source.ToListAsync();
int last      = await source.LastAsync();

// IAsyncEnumerable -> Observable, and back
await asyncEnumerable.ToObservable().ForEachAsync(Handle);
await foreach (var x in source.ToAsyncEnumerable()) { /* ... */ }
```

All verified working. Details and the full terminal-operator list are in
[async-and-integration-patterns.md](async-and-integration-patterns.md).

---

## How R3 Handles Concurrent Updates

**R3 does not serialize concurrent producers.** Like Rx, it assumes the Rx grammar: `OnNext`
must not be called concurrently or re-entrantly from multiple threads. Operators (`Where`,
`Select`, `Subject`, …) are **not internally locked**. Pushing `OnNext` from many threads at once
into a stateful downstream **corrupts state** — in testing, 20,000 concurrent `OnNext` calls into
a `List<T>` subscriber lost ~half the items and threw inside the operator chain.

The fix is to make the boundary explicit:

```csharp
// Multiple producer threads -> one serialized consumer
subject.Synchronize()                  // lock-based gate; delivery becomes single-threaded
       .Where(x => x.IsValid)
       .Subscribe(Handle);             // verified: 10000/10000 items, no corruption

// Or marshal onto a context/threadpool, which also serializes delivery:
source.ObserveOnThreadPool().Subscribe(Handle);

// For shared MVVM state written from many threads:
var counter = new SynchronizedReactiveProperty<int>(0);   // thread-safe writes
```

**Practical rule:** if more than one thread can publish into a stream, put `Synchronize()` (or an
`ObserveOn*`) immediately after the source, or use `SynchronizedReactiveProperty`. Full race
reproductions and outputs are in [scheduling-and-concurrency.md](scheduling-and-concurrency.md).

---

## Time vs Frames: TimeProvider and FrameProvider

R3 has **two** notions of "when," and both are abstractions you can fake in tests:

- **`TimeProvider`** (the .NET 8 BCL type) = wall-clock time. Used by `Delay`, `Debounce`,
  `Interval`, `Timer`, `Timeout`. This is what server/business code uses.
- **`FrameProvider`** (R3-specific) = a *frame clock*. Used by `EveryUpdate`, `DelayFrame(n)`,
  `IntervalFrame(n)`, etc.

**When is a FrameProvider necessary?** Whenever "progress" is measured in render/update ticks
instead of elapsed time:
- **Game engines** (Unity, Godot, Stride, MonoGame) — logic ticks with the engine's update loop,
  so it respects pause and time-scale and stays in lockstep with rendering.
- **UI render loops** (WPF/Avalonia/WinUI composition frames) — react per frame.
- **Deterministic tests** — `FakeFrameProvider.Advance(n)` drives frames with zero real time,
  exactly as `FakeTimeProvider.Advance(timeSpan)` drives the clock.

Plain server/business code virtually never needs `FrameProvider` — that's `TimeProvider`
territory. Both fakes make time-dependent pipelines fully deterministic; examples in
[scheduling-and-concurrency.md](scheduling-and-concurrency.md).

---

## Best Practices Summary

### DO
- Treat `OnErrorResume` as the default: design streams that survive individual bad events.
- Add `.OnErrorResumeAsFailure()` when you genuinely want an error to terminate the stream.
- Choose an `AwaitOperation` deliberately for every async operator (`Switch` for latest-wins,
  `Sequential` for ordering, `Drop` for cooldowns).
- Put `Synchronize()` / `ObserveOn*` after any source that multiple threads publish into.
- Pass a `TimeProvider` to time operators and a `FrameProvider` to frame operators so tests can
  use `FakeTimeProvider` / `FakeFrameProvider`.
- Manage lifetime: route subscriptions into a `DisposableBag`, `CompositeDisposable`, or
  `.AddTo(cancellationToken)`; turn on `ObservableTracker` in dev to catch leaks.
- Use `ReactiveProperty` for de-duplicated observable state; `BindableReactiveProperty` for
  XAML-bound state.

### DON'T
- Don't assume an exception ends the stream (that's Rx, not R3).
- Don't reach for Rx names that R3 renamed: it's `Debounce` (not `Throttle`), `ThrottleLast`
  (not `Sample`), `Chunk` (not `Buffer`). `Retry`, `GroupBy`, `Finally`, and plain `Buffer` are
  **absent** in 1.3.1 — see the differences file for replacements.
- Don't call `OnNext` concurrently/re-entrantly from multiple threads without `Synchronize()`.
- Don't use R3 for backpressured throughput pipelines — use Channels or Akka.NET Streams.
- Don't block on terminal operators (`.Result`/`.Wait()`); they return `Task<T>` — `await` them.

---

## Additional Resources

- **R3 repository:** https://github.com/Cysharp/R3
- **Full README / operator reference:** https://github.com/Cysharp/R3/blob/main/README.md
- **Design rationale (neuecc):** https://neuecc.medium.com/r3-a-new-modern-reimplementation-of-reactive-extensions-for-c-cf29abcc5826
- **NuGet:** https://www.nuget.org/packages/R3
- **`TimeProvider` (BCL):** https://learn.microsoft.com/en-us/dotnet/api/system.timeprovider
- **`FakeTimeProvider`:** https://www.nuget.org/packages/Microsoft.Extensions.TimeProvider.Testing
- **Related skill:** `csharp-concurrency-patterns` (choosing R3 vs async/await vs Channels vs Akka.NET)
