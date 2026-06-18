# R3 vs System.Reactive (Rx.NET): Differences

How R3 differs from `System.Reactive` (Rx.NET) and UniRx, with the reasoning behind each change.
All API facts below were verified by reflection and runtime POCs against **R3 1.3.1**. The
authoritative reference is the [R3 README](https://github.com/Cysharp/R3/blob/main/README.md);
the rationale is in the [author's article](https://neuecc.medium.com/r3-a-new-modern-reimplementation-of-reactive-extensions-for-c-cf29abcc5826).

## Contents
- The big picture
- Difference 1: Abstract classes, not interfaces
- Difference 2: The error model (`OnErrorResume` + `Result`)
- Difference 3: No `IScheduler` — `TimeProvider` + `FrameProvider`
- Difference 4: Operator renames
- Difference 5: Dropped / `*Async`-only operators
- Difference 6: Subjects and single-value sequences
- Difference 7: Built-in subscription-leak tracking
- Difference 8: Interop with System.Reactive
- Difference 9: Performance posture
- Migration checklist

---

## The big picture

| Concern | System.Reactive (Rx.NET) | R3 |
|---|---|---|
| Core abstraction | `IObservable<T>` / `IObserver<T>` interfaces | `Observable<T>` / `Observer<T>` **abstract classes** |
| Observer methods | `OnNext`, `OnError`, `OnCompleted` | `OnNext`, `OnErrorResume`, `OnCompleted(Result)` |
| Exception default | Terminates + unsubscribes | **Continues** (error is a notification) |
| Scheduling | `IScheduler` (+ sub-interfaces) | `TimeProvider` (wall-clock) + `FrameProvider` (frame-clock) |
| Subscription handle | separate `IDisposable` | the `Observer<T>` **is** the `IDisposable` |
| Leak diagnostics | none built in | `ObservableTracker` lists live subscriptions |
| Async bridge | `ToTask`, ad-hoc | `AwaitOperation` operators, `FromAsync`, `ToAsyncEnumerable` |
| Reach | .NET (+ UI libs) | .NET core + Unity, Godot, WPF, WinForms, Avalonia, WinUI3, MAUI, Stride, MonoGame, Blazor |

---

## Difference 1: Abstract classes, not interfaces

R3 makes `Observable<T>` and `Observer<T>` abstract classes. The author's stated reason: *"to
centralize management of all subscriptions. All Subscribes must go through the base class's
Subscribe implementation, enabling tracking of subscriptions."*

```csharp
public abstract class Observable<T>
{
    public IDisposable Subscribe(Observer<T> observer);          // sealed entry point; tracks then calls:
    protected abstract IDisposable SubscribeCore(Observer<T> observer);
}

public abstract class Observer<T> : IDisposable                  // observer doubles as the subscription
{
    public void OnNext(T value);
    public void OnErrorResume(Exception error);
    public void OnCompleted(Result result);
    protected abstract void OnNextCore(T value);
    protected abstract void OnErrorResumeCore(Exception error);
    protected abstract void OnCompletedCore(Result result);
}
```

Consequences:
- You can no longer declare `IObservable<T>` and get Rx for free; you derive from
  `Observable<T>` or (almost always) use factory methods and operators.
- The observer being its own `IDisposable` removes a per-subscription allocation.
- Custom operators override the `*Core` methods, and disposal is centralized and thread-safe
  (single-execution via `Interlocked`).

## Difference 2: The error model (`OnErrorResume` + `Result`)

This is the most important behavioral difference. In Rx, `OnError` is terminal — a single
exception anywhere in the pipeline unsubscribes everything. The author calls automatic
unsubscription-on-exception *"a billion-dollar mistake in Rx"*: real event sources (UI, sensors,
sockets) should not die because one event threw.

In R3:
- Exceptions flow to **`OnErrorResume`** and the **subscription stays alive**.
- Termination is a separate event, `OnCompleted(Result)`, where `Result` is a readonly struct:
  `Result.Success` (a property) or `Result.Failure(Exception)` (a static method), exposing
  `IsSuccess`, `IsFailure`, `Exception`, and `TryThrow()`.

Verified against R3 1.3.1:

```csharp
var subject = new Subject<int>();
subject.Select(x => 100 / x).Subscribe(
    onNext:        x => Console.WriteLine($"next {x}"),
    onErrorResume: e => Console.WriteLine($"errorResume {e.GetType().Name}"),
    onCompleted:   (Result r) => Console.WriteLine($"completed IsSuccess={r.IsSuccess} IsFailure={r.IsFailure}"));

subject.OnNext(2);   subject.OnNext(0);   subject.OnNext(5);   subject.OnCompleted();
```
```text
next 50
errorResume DivideByZeroException
next 20                                  <-- still alive after the error
completed IsSuccess=True
```

To get classic Rx "an error ends the stream" semantics, insert `OnErrorResumeAsFailure()`. The
exception is then delivered as `OnCompleted(Result.Failure(e))` and later values are dropped:

```csharp
subject.Select(x => 100 / x)
       .OnErrorResumeAsFailure()
       .Subscribe(onNext: x => ..., onCompleted: r => Console.WriteLine($"IsFailure={r.IsFailure} {r.Exception?.GetType().Name}"));
// next 50
// completed IsFailure=True DivideByZeroException     (a subsequent OnNext(5) never arrives)
```

Recovery uses `Catch` (verified). A burst of substitution:

```csharp
source.Select(x => 100 / x)
      .OnErrorResumeAsFailure()
      .Catch((DivideByZeroException _) => Observable.Return(-1))
      .Subscribe(...);   // emits 25, then -1 in place of the divide-by-zero, then completes Success
```

**Watch out:** an exception thrown inside the *terminal* `Subscribe` callback (not an operator)
has no downstream `OnErrorResume` to catch it, so it goes to R3's **global unhandled-exception
handler** (`ObservableSystem.RegisterUnhandledExceptionHandler(...)`), not to the caller.

## Difference 3: No `IScheduler` — `TimeProvider` + `FrameProvider`

R3 deletes `IScheduler` and its tangle of sub-interfaces (`ISchedulerLongRunning`,
`ISchedulerPeriodic`, `IStopwatchProvider`). Time-based operators take a **`TimeProvider`** (the
.NET 8 BCL abstraction). Frame-based operators take a **`FrameProvider`** (new in R3).

```csharp
// Rx:  Observable.Timer(dueTime, scheduler)
// R3:  pass a TimeProvider (defaults to TimeProvider.System)
Observable.Timer(TimeSpan.FromSeconds(1), timeProvider);
Observable.Interval(TimeSpan.FromSeconds(1), timeProvider);
source.Debounce(TimeSpan.FromMilliseconds(300), timeProvider);

// Frame clock (game/UI loops) has no Rx equivalent:
Observable.EveryUpdate(frameProvider);
source.DelayFrame(2, frameProvider);
```

Why: `TimeProvider.CreateTimer()`/`GetTimestamp()` are cheaper than Rx's recursive
`Schedule` calls, and the BCL type is testable out of the box with `FakeTimeProvider`. See
`scheduling-and-concurrency.md` (sibling) for the testing patterns and the frame-vs-time decision.

## Difference 4: Operator renames

R3 fixes Rx's most confusing operator names. Verified by reflecting the operator surface — the
**old names do not exist** in R3 1.3.1:

| Rx.NET name | R3 name | Notes |
|---|---|---|
| `Throttle` | **`Debounce`** | "wait for quiet" — R3 uses the name everyone actually means |
| `Sample` | **`ThrottleLast`** | emit the last value per interval |
| *(n/a)* | **`ThrottleFirst`** | emit the first value per interval (new) |
| *(n/a)* | **`ThrottleFirstLast`** | first + last of a window (new) |
| `Buffer` | **`Chunk`** | matches LINQ's `Chunk`; also `ChunkFrame`, `ChunkUntil` |

Every time operator also has a `*Frame` sibling (`DebounceFrame`, `ThrottleLastFrame`,
`IntervalFrame`, `DelayFrame`, `TimeoutFrame`, …) for the frame clock.

## Difference 5: Dropped / `*Async`-only operators

Some Rx operators are intentionally gone or reshaped in 1.3.1 (verified absent by reflection).
Don't reach for these out of Rx muscle memory:

| Rx.NET | Status in R3 1.3.1 | Replacement |
|---|---|---|
| `Retry` | **absent** | `OnErrorResumeAsFailure()` then `Catch`/`Repeat`; or re-subscribe explicitly |
| `GroupBy` | **absent** | partition manually / use `ObservableCollections` groupings |
| `Finally` | **absent** | `Do(onCompleted/onDispose)` or dispose-side handling |
| `Buffer` | **absent** (renamed) | `Chunk` |
| `Aggregate` | only `AggregateAsync` | `await source.AggregateAsync(...)` |
| `SequenceEqual` | only `SequenceEqualAsync` | `await source.SequenceEqualAsync(...)` |
| `First`/`Last`/`Single`/`Count`/`Sum`/`ToList`/`ToArray` | `*Async`, return `Task<T>` | `await source.FirstAsync()` etc. |

The pattern: anything that collapses a stream to **one value** is a `*Async` method returning
`Task<T>` — because in R3, "give me the single result" is a pull/await operation, not a one-shot
observable. `FlatMap` is named `SelectMany` (LINQ-consistent).

## Difference 6: Subjects and single-value sequences

R3 ships a focused set of subjects (verified present): `Subject<T>`, `BehaviorSubject<T>`,
`ReplaySubject<T>`, `ReplayFrameSubject<T>`, plus the property-style hubs `ReactiveProperty<T>`,
`ReadOnlyReactiveProperty<T>`, `BindableReactiveProperty<T>`, and `SynchronizedReactiveProperty<T>`.

The notable change from Rx is **`ReactiveProperty<T>`**, the modern `BehaviorSubject`
replacement. Both replay the current value to new subscribers, but they differ in de-duplication
(verified):

```csharp
// ReactiveProperty: distinct-until-changed by DEFAULT
var rp = new ReactiveProperty<int>(1);
rp.Subscribe(received.Add);
rp.Value = 1; rp.Value = 1; rp.Value = 2; rp.Value = 2; rp.Value = 3;
// received: [1, 2, 3]          <-- consecutive duplicates suppressed

// BehaviorSubject: replays, but does NOT de-duplicate
var bs = new BehaviorSubject<int>(100);
bs.Subscribe(received.Add);
bs.OnNext(100); bs.OnNext(100); bs.OnNext(200);
// received: [100, 100, 100, 200]
```

`AsyncSubject` (Rx's "remember the last value at completion") is gone — that role is served by
awaiting `LastAsync()`.

## Difference 7: Built-in subscription-leak tracking

R3 ships `ObservableTracker`, enabled by setting public static fields:

```csharp
ObservableTracker.EnableTracking = true;
ObservableTracker.EnableStackTrace = true;     // capture where each subscription was created
ObservableTracker.ForEachActiveTask(state => Console.WriteLine(state));
```

This is the payoff of Difference 1 (centralized `Subscribe`). Unity gets an editor window; other
hosts can dump active subscriptions on demand. Rx has no equivalent.

## Difference 8: Interop with System.Reactive

R3 is a separate type system, so it provides explicit bridges (present in the operator surface):
- `AsSystemObservable()` — expose an R3 `Observable<T>` as an `IObservable<T>` for code that
  expects Rx.NET.
- `ToObservable()` — adapt an `IObservable<T>` (and `IEnumerable<T>`, `IAsyncEnumerable<T>`,
  `Task<T>`) into an R3 `Observable<T>`.

This lets you adopt R3 incrementally at the edges of an existing Rx.NET codebase.

## Difference 9: Performance posture

R3's design choices are largely performance-driven (per the author's article):
- `TimeProvider.CreateTimer` instead of allocating a new timer per `Schedule`.
- The observer-is-the-subscription design removes a wrapper allocation per `Subscribe`.
- Raw timestamps (`GetTimestamp`) instead of `DateTimeOffset` math.
- Struct-based disposable containers (`DisposableBag`, `Disposable.CreateBuilder`) to avoid
  per-subscription `CompositeDisposable` overhead.

The author specifically cites Rx's `ImmediateScheduler`/`Merge` causing measurable server memory
and CPU bloat as a motivating case. (Treat exact numbers as version-dependent; benchmark your own
hot paths.)

## Migration checklist

When porting Rx.NET / UniRx code to R3:

1. Replace `using System.Reactive.Linq;` with `using R3;`.
2. Replace `IObservable<T>`/`IObserver<T>` declarations with `Observable<T>`/`Observer<T>`.
3. Split `OnError` handling: decide per stream whether errors should **resume** (default,
   handle in `onErrorResume`) or **terminate** (add `OnErrorResumeAsFailure()`).
4. Change `onCompleted: () => ...` to `onCompleted: (Result r) => ...`.
5. Rename operators: `Throttle`→`Debounce`, `Sample`→`ThrottleLast`, `Buffer`→`Chunk`.
6. Convert single-value operators to `await ...Async()` (`First`→`FirstAsync`, etc.).
7. Replace `IScheduler` arguments with a `TimeProvider` (or `FrameProvider` for frame loops).
8. Replace `BehaviorSubject` with `ReactiveProperty` where you want de-duplicated state.
9. Replace `Retry`/`GroupBy`/`Finally` usages with the alternatives above.
10. Add lifetime management (`DisposableBag`/`AddTo`) and turn on `ObservableTracker` in dev.
