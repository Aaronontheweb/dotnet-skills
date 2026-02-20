# Managing Async Operations with CancellationToken

When actors launch async operations via `PipeTo`, those operations can outlive the actor if not properly managed. Use `CancellationToken` tied to the actor lifecycle.

## Contents

- [Actor-Scoped CancellationTokenSource](#actor-scoped-cancellationtokensource)
- [Linked CTS for Per-Operation Timeouts](#linked-cts-for-per-operation-timeouts)
- [Graceful Timeout vs Shutdown Handling](#graceful-timeout-vs-shutdown-handling)
- [Key Points](#key-points)
- [When to Use](#when-to-use)

## Actor-Scoped CancellationTokenSource

Cancel in-flight async work when the actor stops:

```csharp
public class DataSyncActor : ReceiveActor
{
    private CancellationTokenSource? _operationCts;

    public DataSyncActor()
    {
        ReceiveAsync<StartSync>(HandleStartSyncAsync);
    }

    protected override void PostStop()
    {
        // Cancel any in-flight async work when actor stops
        _operationCts?.Cancel();
        _operationCts?.Dispose();
        _operationCts = null;
        base.PostStop();
    }

    private Task HandleStartSyncAsync(StartSync cmd)
    {
        // Cancel any previous operation, create new CTS
        _operationCts?.Cancel();
        _operationCts?.Dispose();
        _operationCts = new CancellationTokenSource();
        var ct = _operationCts.Token;

        async Task<SyncResult> PerformSyncAsync()
        {
            try
            {
                ct.ThrowIfCancellationRequested();

                // Pass token to all async operations
                var data = await _repository.GetDataAsync(ct);
                await _service.ProcessAsync(data, ct);

                return new SyncResult(Success: true);
            }
            catch (OperationCanceledException) when (ct.IsCancellationRequested)
            {
                // Actor is stopping - graceful exit
                return new SyncResult(Success: false, "Cancelled");
            }
        }

        PerformSyncAsync().PipeTo(Self);
        return Task.CompletedTask;
    }
}
```

## Linked CTS for Per-Operation Timeouts

For external API calls that might hang, use linked CTS with short timeouts:

```csharp
private static readonly TimeSpan ApiTimeout = TimeSpan.FromSeconds(30);

async Task<SyncResult> PerformSyncAsync()
{
    // Check actor-level cancellation
    ct.ThrowIfCancellationRequested();

    // Per-operation timeout linked to actor's CTS
    SomeResult result;
    using (var opCts = CancellationTokenSource.CreateLinkedTokenSource(ct))
    {
        opCts.CancelAfter(ApiTimeout);
        result = await _externalApi.FetchDataAsync(opCts.Token);
    }

    // Process result...
}
```

**How linked CTS works:**
- Inherits cancellation from parent (actor stop -> cancels immediately)
- Adds its own timeout via `CancelAfter` (hung API -> cancels after timeout)
- Whichever fires first wins
- Disposed after each operation (short-lived)

## Graceful Timeout vs Shutdown Handling

Distinguish between actor shutdown and operation timeout:

```csharp
try
{
    using var opCts = CancellationTokenSource.CreateLinkedTokenSource(ct);
    opCts.CancelAfter(ApiTimeout);
    await _api.CallAsync(opCts.Token);
}
catch (OperationCanceledException) when (!ct.IsCancellationRequested)
{
    // Timeout (not actor death) - can retry or handle gracefully
    _log.Warning("API call timed out, skipping item");
}
// If ct.IsCancellationRequested is true, let it propagate up
```

## Key Points

| Practice | Description |
|----------|-------------|
| **Actor CTS in PostStop** | Always cancel and dispose in `PostStop()` |
| **New CTS per operation** | Cancel previous before starting new work |
| **Pass token everywhere** | EF Core queries, HTTP calls, etc. all accept `CancellationToken` |
| **Linked CTS for timeouts** | External calls get short timeouts to prevent hanging |
| **Check in loops** | Call `ct.ThrowIfCancellationRequested()` between iterations |
| **Graceful handling** | Distinguish timeout vs shutdown in catch blocks |

## When to Use

- Any actor that launches async work via `PipeTo`
- Long-running operations (sync jobs, batch processing)
- External API calls that might hang
- Database operations in loops
