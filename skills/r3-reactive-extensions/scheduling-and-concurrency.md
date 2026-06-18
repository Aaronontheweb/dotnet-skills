# R3 Scheduling & Concurrency

How R3 handles concurrent updates, thread marshaling, and time — plus deterministic testing.
All behavior verified against **R3 1.3.1**. Reference:
[R3 README](https://github.com/Cysharp/R3/blob/main/README.md).

## Contents
- The concurrency contract (concurrent updates)
- Making concurrent producers safe (`Synchronize`, `ObserveOn`)
- Thread-safe state: `SynchronizedReactiveProperty`
- Re-entrancy
- `TimeProvider` (wall-clock scheduling)
- `FrameProvider` (frame-clock scheduling) — and when it's necessary
- Deterministic testing with fake providers

---

## The concurrency contract (concurrent updates)

**R3 does not serialize concurrent producers.** It inherits the Rx grammar: a source must not
call `OnNext` concurrently or re-entrantly across threads. Operators such as `Where`, `Select`,
and `Subject<T>` are **not internally locked** — they assume notifications arrive one at a time.

This is a deliberate performance choice, and it bites if you ignore it. Pushing `OnNext` from
many threads into a stateful downstream corrupts state. Verified: 20,000 concurrent `OnNext`
calls through a `Where`/`Select` chain into a `List<T>` subscriber, run three times:

```csharp
var subject = new Subject<int>();
var list = new List<int>();
int count = 0;
subject.Where(x => x % 2 == 0).Select(x => x).Subscribe(x => { list.Add(x); Interlocked.Increment(ref count); });
Parallel.For(0, 20000, i => subject.OnNext(i));     // concurrent producers
```
```text
trial 1: Interlocked count=9999,  list.Count=9013   (expected 10000)
trial 2: Interlocked count=10000, list.Count=4104   (expected 10000)
trial 3: Interlocked count=10000, list.Count=7896   (expected 10000)
# plus: ArgumentOutOfRangeException thrown inside List.AddWithResize, surfaced via
# R3's GLOBAL unhandled-exception handler (not the Parallel.For caller)
```

The `List<T>` is torn (lost items), and the exception from the corrupted add did **not** reach
the caller — it went to R3's unhandled-exception handler. The lesson: R3 will not protect you
from a multi-threaded producer.

## Making concurrent producers safe

Put the serialization boundary in the pipeline explicitly.

**`Synchronize()`** wraps delivery in a gate lock so the downstream sees single-threaded
notifications. Same test, with `Synchronize()` after the source (verified safe across trials):

```csharp
subject.Synchronize()              // optional: Synchronize(gate) to share a lock object
       .Where(x => x % 2 == 0)
       .Subscribe(list.Add);
Parallel.For(0, 20000, i => subject.OnNext(i));
```
```text
trial 1: list.Count=10000   trial 2: list.Count=10000   trial 3: list.Count=10000
```

**`ObserveOn*`** also serializes, because it hands every notification to a single target context
or queue:

```csharp
source.ObserveOnThreadPool().Subscribe(Handle);                 // deliver on the thread pool
source.ObserveOnCurrentSynchronizationContext().Subscribe(...); // deliver on the captured ctx (UI)
```

Verified that `ObserveOnThreadPool()` moves the callback off the producer thread (producer
thread `5` → observer thread `7`). Platform packages add `ObserveOnDispatcher` (WPF/Avalonia),
`ObserveOnMainThread` (Unity), etc.

**Rule:** if more than one thread can publish into a stream, add `Synchronize()` (or an
`ObserveOn*`) immediately after the source. `Subscribe` / `Dispose` happening concurrently *with*
delivery is handled by R3 (disposal is interlocked); it's concurrent **`OnNext`** that you own.

## Thread-safe state: `SynchronizedReactiveProperty`

`ReactiveProperty<T>` is not safe for concurrent writes. Use `SynchronizedReactiveProperty<T>`
when many threads assign `.Value`. Verified under 50,000 concurrent writes:

```csharp
var plain = new ReactiveProperty<int>(0);
Parallel.For(0, 50000, i => plain.Value = i);
// no crash, but notification count and final value are racy/non-deterministic

var safe = new SynchronizedReactiveProperty<int>(0);
Parallel.For(0, 50000, i => safe.Value = i);
// no exception; internal state stays consistent (final value is still last-writer-wins)
```

`SynchronizedReactiveProperty` protects the property's internal state; it does not make
"read-modify-write" sequences atomic — the final value is whichever thread wrote last.

## Re-entrancy

Emitting from inside an observer's own handler is handled gracefully (verified — no stack
overflow, no reordering surprise for the simple case):

```csharp
subject.Subscribe(x =>
{
    order.Add(x);
    if (x == 1) subject.OnNext(2);   // re-entrant emit
});
subject.OnNext(1);                   // delivery order: [1, 2]
```

## `TimeProvider` (wall-clock scheduling)

Time-based operators take a `TimeProvider` (the .NET 8 BCL abstraction), defaulting to
`TimeProvider.System`. Pass an explicit one so the pipeline is testable:

```csharp
source.Debounce(TimeSpan.FromMilliseconds(300), timeProvider);
source.Delay(TimeSpan.FromSeconds(1), timeProvider);
Observable.Interval(TimeSpan.FromSeconds(5), timeProvider);
Observable.Timer(TimeSpan.FromSeconds(5), timeProvider);
source.Timeout(TimeSpan.FromSeconds(30), timeProvider);
```

Use `TimeProvider` for essentially all server/business scheduling — anything measured in elapsed
real time.

## `FrameProvider` (frame-clock scheduling)

`FrameProvider` is R3's second clock: it counts **frames** (update/render ticks) instead of
time. Frame operators mirror the time ones — `EveryUpdate`, `DelayFrame(n)`, `IntervalFrame(n)`,
`DebounceFrame(n)`, `NextFrame`, `TimerFrame`, etc.

```csharp
Observable.EveryUpdate(frameProvider).Subscribe(_ => Tick());   // once per frame
source.DelayFrame(2, frameProvider).Subscribe(...);             // shift by 2 frames
Observable.IntervalFrame(2, frameProvider).Subscribe(...);      // every 2 frames
```

**When is a `FrameProvider` necessary?** When "progress" is a render/update tick, not elapsed
time:
- **Game engines** (Unity, Godot, Stride, MonoGame): ticking on the engine update loop keeps
  logic in lockstep with rendering and respects pause / time-scale (a wall-clock timer keeps
  running while the game is paused; a frame clock does not).
- **UI render loops** (WPF/Avalonia/WinUI composition frames): react per frame for animation or
  per-frame recomputation.
- **Deterministic frame-stepping in tests** (below).

Plain server/business code does **not** need a `FrameProvider` — use `TimeProvider`. Each host
supplies its own provider (`UnityFrameProvider`, `WpfRenderingFrameProvider`, …); R3 sets the
default via the platform package's initializer.

## Deterministic testing with fake providers

Both clocks have fakes, so time- and frame-dependent pipelines test instantly with zero real
waiting.

**`FakeTimeProvider`** (from `Microsoft.Extensions.TimeProvider.Testing`) + `ToLiveList()`
(verified — a 5-second timer fires only after advancing a full 5 seconds of virtual time):

```csharp
var fake = new FakeTimeProvider();
using var live = Observable.Timer(TimeSpan.FromSeconds(5), fake).ToLiveList();

fake.Advance(TimeSpan.FromSeconds(4));
Assert.False(live.IsCompleted);          // not yet

fake.Advance(TimeSpan.FromSeconds(1));    // total 5s
Assert.True(live.IsCompleted);            // fired; no real time elapsed
```

**`FakeFrameProvider`** (ships in R3) — drive frames by hand (verified):

```csharp
var frame = new FakeFrameProvider();
using var live = Observable.EveryUpdate(frame)
    .Select(_ => frame.GetFrameCount())
    .ToLiveList();

frame.Advance();    // 1 frame
frame.Advance(3);   // 3 more frames
// live now contains one entry per advanced frame
```

`ToLiveList()` is R3's test sink: it captures emissions into a list you can assert on, and
exposes `IsCompleted`. Combined with fake providers it makes Rx pipelines — historically painful
to test because of real timers — fully deterministic.
