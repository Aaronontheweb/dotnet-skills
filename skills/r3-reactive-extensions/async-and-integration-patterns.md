# R3 Common Patterns: Async, Task, IAsyncEnumerable, MVVM

Day-to-day patterns for R3, with emphasis on async dispatch and bridging to `Task` /
`IAsyncEnumerable`. Verified against **R3 1.3.1**. Operator reference:
[R3 README](https://github.com/Cysharp/R3/blob/main/README.md).

## Contents
- Async dispatch with `AwaitOperation`
- The async operators (`SubscribeAwait`, `SelectAwait`, `WhereAwait`)
- Task integration (in and out)
- IAsyncEnumerable round-tripping
- Creating observables (events, properties, factories)
- ReactiveProperty and MVVM
- Subjects: which one to use
- Subscription lifecycle and disposal

---

## Async dispatch with `AwaitOperation`

The defining feature of R3's async story: async operators take an `AwaitOperation` enum that
controls what happens when values arrive faster than the async handler completes. The full
enum (verified): `Sequential, Drop, Switch, Parallel, SequentialParallel, ThrottleFirstLast`.

The POC below emits `1, 2, 3` back-to-back; each handler sleeps 100 ms. Captured output per mode
makes the semantics concrete:

```csharp
subject.SubscribeAwait(async (x, ct) =>
{
    Log($"start {x}");
    await Task.Delay(100, ct);
    Log($"end {x}");
}, awaitOperation);   // <-- the mode
```

```text
--- Sequential: queue, one at a time ---
[  13ms] start 1   [ 118ms] end 1   [ 118ms] start 2   [ 218ms] end 2   [ 218ms] start 3   [ 318ms] end 3

--- Drop: ignore arrivals while busy ---
[   0ms] start 1   [ 100ms] end 1            (2 and 3 dropped)

--- Switch: cancel running, start newest ---
[   0ms] start 1   [   1ms] start 2   [   1ms] start 3
[   9ms] CANCELLED 1   [   9ms] CANCELLED 2   [ 101ms] end 3

--- Parallel: all at once ---
[   0ms] start 1   [   1ms] start 2   [   1ms] start 3   [ ~100ms] end 3 / end 2 / end 1
```

Choosing a mode:

| Mode | Use it for |
|---|---|
| `Sequential` (default) | Order matters; never overlap (e.g. apply writes in order) |
| `Drop` | Cooldown / debounced submit — ignore clicks while one is in flight |
| `Switch` | Latest-wins — search-as-you-type, autocomplete, live preview |
| `Parallel` | Independent fan-out where order doesn't matter |
| `SequentialParallel` | Run concurrently but emit results in source order |
| `ThrottleFirstLast` | Sample the leading and trailing item of a burst |

`Switch` cancels the superseded operation's `CancellationToken` (note the `CANCELLED 1/2`
above) — so a handler that honors `ct` stops wasted work immediately.

## The async operators

All async operators share the shape `Func<T, CancellationToken, ValueTask<...>>` plus the
`AwaitOperation` and a few knobs (`configureAwait`, `cancelOnCompleted`, `maxConcurrent`):

```csharp
// Subscribe with async handler
source.SubscribeAwait(
    async (x, ct) => await HandleAsync(x, ct),
    AwaitOperation.Sequential,
    configureAwait: true,
    cancelOnCompleted: true,
    maxConcurrent: -1);

// Project asynchronously -> Observable<TResult>
source.SelectAwait(async (x, ct) => await LoadAsync(x, ct), AwaitOperation.Switch);

// Filter asynchronously
source.WhereAwait(async (x, ct) => await IsAllowedAsync(x, ct), AwaitOperation.Sequential);
```

`maxConcurrent` bounds `Parallel`/`SequentialParallel` concurrency. `cancelOnCompleted` cancels
the in-flight `ct` when the source completes.

## Task integration (in and out)

**Task → Observable.** Lift an async operation into a one-shot stream:

```csharp
var value = await Observable
    .FromAsync(async ct => { await Task.Delay(10, ct); return 42; })
    .FirstAsync();                       // -> 42  (verified)
```

**Observable → Task.** Every "collapse to one result" operator is a `*Async` returning `Task<T>`
— `await` them (verified):

```csharp
List<int> all  = await source.ToListAsync();
int[]     arr  = await source.ToArrayAsync();
int       first= await source.FirstAsync();
int       last = await source.LastAsync();
int       count= await source.CountAsync();
```

Other terminals include `SingleAsync`, `ElementAtAsync`, `SumAsync`, `MinAsync`, `MaxAsync`,
`AggregateAsync`, `ToDictionaryAsync`, `ToHashSetAsync`, `ContainsAsync`, `AnyAsync`, `AllAsync`,
`IsEmptyAsync`. `ForEachAsync(Func<T, ValueTask>)` awaits the whole stream with a per-item async
action; `WaitAsync(timeout)` adds a timeout.

## IAsyncEnumerable round-tripping

R3 bridges both directions (verified):

```csharp
// IAsyncEnumerable<T> -> Observable<T>
static async IAsyncEnumerable<int> Gen()
{
    for (int i = 1; i <= 3; i++) { await Task.Delay(5); yield return i * 10; }
}
await Gen().ToObservable().ForEachAsync(x => received.Add(x));   // received: [10, 20, 30]

// Observable<T> -> IAsyncEnumerable<T>
await foreach (var x in Observable.Range(1, 3).ToAsyncEnumerable())   // 1, 2, 3
    Process(x);
```

Rule of thumb from the author: use `IAsyncEnumerable` for **pull**-based / network sequences and
R3 for **push**-based events; the bridges let you cross over at the seams.

## Creating observables (events, properties, factories)

```csharp
// From a .NET event
Observable.FromEvent<EventHandler, EventArgs>(
    h => (s, e) => h(e),
    h => button.Click += h,
    h => button.Click -= h);

// From INotifyPropertyChanged property changes
viewModel.ObservePropertyChanged(vm => vm.Name);

// Poll-free property watching (frame-based; great for game/UI state)
Observable.EveryValueChanged(model, m => m.Health);

// Custom producer
Observable.Create<int>(observer =>
{
    observer.OnNext(1);
    observer.OnCompleted();
    return Disposable.Empty;
});

// Timers / ranges / single values
Observable.Range(1, 10);
Observable.Return(42);
Observable.Interval(TimeSpan.FromSeconds(1), timeProvider);
```

## ReactiveProperty and MVVM

`ReactiveProperty<T>` is the workhorse for observable state: it holds a current `.Value`, replays
it to new subscribers, and suppresses consecutive duplicates by default (verified):

```csharp
var health = new ReactiveProperty<int>(100);
health.Subscribe(v => Console.WriteLine($"health = {v}"));  // immediately prints 100
health.Value = 100;   // suppressed (duplicate)
health.Value = 80;    // health = 80

// Derive read-only state from any observable:
ReadOnlyReactiveProperty<bool> isLow =
    health.Select(v => v < 25).ToReadOnlyReactiveProperty(false);
Console.WriteLine(isLow.CurrentValue);   // current snapshot without subscribing
```

For XAML/data-binding hosts (WPF, Avalonia, WinUI, MAUI), use `BindableReactiveProperty<T>`
(implements `INotifyPropertyChanged`) and `ReactiveCommand` for bound commands:

```csharp
public BindableReactiveProperty<string> Name { get; } = new("");
public ReactiveCommand<Unit> Save { get; }

Save = Name.Select(n => !string.IsNullOrEmpty(n)).ToReactiveCommand();   // enabled when name set
Save.SubscribeAwait(async (_, ct) => await SaveAsync(ct), AwaitOperation.Drop);
```

## Subjects: which one to use

| Type | Replays to new subscribers | De-duplicates | Use for |
|---|---|---|---|
| `Subject<T>` | no | no | plain multicast hub |
| `BehaviorSubject<T>` | current value | no | "last value + future" without de-dup |
| `ReactiveProperty<T>` | current value | **yes** (distinct-until-changed) | observable state / MVVM |
| `ReplaySubject<T>` | buffered history | no | late subscribers need past values |
| `SynchronizedReactiveProperty<T>` | current value | yes | state written from multiple threads |

Verified: `ReplaySubject` replays its buffer to a subscriber that attaches *after* emissions; a
late subscriber to `new ReplaySubject<int>()` that already saw `1,2,3` receives `[1, 2, 3]`.

## Subscription lifecycle and disposal

Every `Subscribe` returns an `IDisposable`. Manage many at once with R3's disposal helpers
(roughly fastest → most flexible):

```csharp
// Struct builder — zero-alloc, fixed at build time
var builder = Disposable.CreateBuilder();
source1.Subscribe(...).AddTo(ref builder);
source2.Subscribe(...).AddTo(ref builder);
IDisposable all = builder.Build();

// DisposableBag — struct field, add-only, dispose together
DisposableBag bag = default;
source.Subscribe(...).AddTo(ref bag);
// bag.Dispose();

// CompositeDisposable — class, thread-safe, supports Remove
var disposables = new CompositeDisposable();
source.Subscribe(...).AddTo(disposables);

// Tie a subscription to a CancellationToken (auto-dispose on cancel)
source.Subscribe(...).AddTo(cancellationToken);
```

In development, turn on `ObservableTracker.EnableTracking = true` (and `EnableStackTrace = true`)
and call `ObservableTracker.ForEachActiveTask(...)` to find subscriptions you forgot to dispose.
