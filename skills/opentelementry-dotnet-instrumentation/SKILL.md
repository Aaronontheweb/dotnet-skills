---
name: opentelemetry-net-instrumentation
description: Provides guidance for implementing OpenTelemetry instrumentation in .NET codebases, covering tracing (Activities/Spans), metrics, logs, naming conventions, error handling, performance, SDK setup, resources, context propagation, and API design best practices.
version: 2.0.0
tags:
  - opentelemetry
  - dotnet
  - observability
  - tracing
  - metrics
  - logs
  - performance
---

# OpenTelemetry .NET Instrumentation Skill

## When to Use

- Adding OpenTelemetry instrumentation to .NET code (traces, metrics, logs)
- Creating or modifying ActivitySources, Meters, or ILogger usage
- Setting up the OpenTelemetry SDK, resources, exporters, or sampling
- Reviewing telemetry implementations for spec compliance
- Optimizing instrumentation performance
- Designing telemetry APIs that become part of the public surface
- Implementing context propagation across service boundaries

## Architecture: .NET Is Different

**CRITICAL**: The .NET OpenTelemetry implementation is fundamentally different from other platforms. .NET provides tracing, metrics, and logging APIs **in the framework itself**.
That means **OTel does not provide a separate instrumentation API** — it uses the built-in .NET APIs and acts as the collection/export layer.

### The Three Built-in .NET APIs (Primary — Zero Dependencies)

| Signal | .NET Framework API | Namespace |
|--------|-------------------|-----------|
| **Tracing** | `ActivitySource` / `Activity` | `System.Diagnostics` |
| **Metrics** | `Meter` / `Counter<T>` / `Histogram<T>` / etc. | `System.Diagnostics.Metrics` |
| **Logging** | `ILogger<T>` | `Microsoft.Extensions.Logging` |

These are **the primary and only APIs** library authors should use for instrumentation.
They ship with the .NET runtime — **no NuGet packages required**.

### The OTel Collection/Export Layer (Secondary — Application Root Only)

OTel NuGet packages are the **collection and export layer**, added only at the application
composition root (not in libraries):

| Package | Purpose | When to add |
|---------|---------|-------------|
| `OpenTelemetry.Extensions.Hosting` | DI integration for ASP.NET Core / generic host | Application only |
| `OpenTelemetry.Exporter.Console` | Console exporter (dev/testing) | Application only |
| `OpenTelemetry.Exporter.OpenTelemetryProtocol` | OTLP exporter (production) | Application only |
| `OpenTelemetry.Exporter.Prometheus*` | Prometheus metrics endpoint | Application only |
| `OpenTelemetry.Instrumentation.AspNetCore` | Auto-instrument ASP.NET Core requests | Application only |
| `OpenTelemetry.Instrumentation.Http` | Auto-instrument HttpClient calls | Application only |
| `OpenTelemetry.Instrumentation.SqlClient` | Auto-instrument SQL calls | Application only |

### Package Decision Guide

**Before adding ANY OpenTelemetry NuGet package, discuss the trade-off with the user:**

> "You're about to add an OTel NuGet package. Is this an application where you need to
> export telemetry to an observability backend (Jaeger, Prometheus, OTLP collector)?
> If you're writing a library, you likely need **zero** OTel packages — just use
> `System.Diagnostics.ActivitySource` / `System.Diagnostics.Metrics.Meter` and let the
> consuming application configure the export pipeline. Do you want to proceed?"

**Library authors**: Add **nothing**. Use only `System.Diagnostics.*` and `ILogger`.
The consuming application wires up the SDK and exporters.

**Application authors**: Add `OpenTelemetry.Extensions.Hosting` + the exporters and instrumentation libraries you need. See [sdk-resources-and-logs-reference.md](sdk-resources-and-logs-reference.md) for full setup patterns.

**Never add** `OpenTelemetry.Api` to a library — `System.Diagnostics.*` IS the API.

For SDK setup, resource configuration, exporters, sampling, and logs integration, see [sdk-resources-and-logs-reference.md](sdk-resources-and-logs-reference.md).

## Core Principles

### Resiliency First
**CRITICAL**: Exceptions in diagnostic/tracing/metrics logic MUST NEVER impact application processing.
- Assume Activity instances can be null. Always protect against null Activity references except in Activity extension methods (use `activity?.ExtensionMethod()`)
- Guard all instrumentation code with appropriate null checks

### API Surface Awareness
- Any telemetry emitted becomes part of the public API surface
- Changes are subject to breaking changes guidelines
- Telemetry should be emitted by default (users opt-in to collection via OpenTelemetry extensions)
- Exception: High-cardinality metric dimensions may require explicit opt-in

### Standards Compliance
- Follow Microsoft best practices for [distributed tracing instrumentation](https://learn.microsoft.com/en-us/dotnet/core/diagnostics/distributed-tracing-instrumentation-walkthroughs)
- Follow [OpenTelemetry semantic conventions](https://opentelemetry.io/docs/specs/semconv/)
- Attribute values support: **string, boolean, double (IEEE 754), int64, byte arrays, and homogeneous arrays** of these primitive types. Null/empty values are valid and meaningful per the [OTel AnyValue spec](https://opentelemetry.io/docs/specs/otel/common/#anyvalue) — they MUST be stored and passed to exporters.
- Attribute **keys** must be non-null, non-empty strings

## Traces / Spans (Activities)

### ActivitySource Setup

```csharp
// ✅ CORRECT: Use ActivitySource, not DiagnosticSource
public class MyFeature
{
    // Primary ActivitySource - name typically matches the component or NuGet package name
    private static readonly ActivitySource ActivitySource = new("MyApp.MyComponent", "1.0.0");

    // Specialized ActivitySource for opt-in scenarios
    private static readonly ActivitySource DetailedActivitySource = new("MyApp.MyComponent.Detailed", "1.0.0");
}
```

**Rules**:
- Every component defines a primary `ActivitySource` for mainstream activities
- Name typically matches the component or NuGet package (e.g., `"MyCompany.MyLibrary"`)
- Version the ActivitySource using SemVer
- Create separate `ActivitySource`s for specialized or opt-in scenarios. Use hierarchical source names, e.g. `MyCompany.MyLibrary` and `MyCompany.MyLibrary.Detailed`, so consuming applications can subscribe only to the sources they want via `AddSource(...)` and backends can filter by instrumentation scope.

### Creating Activities

```csharp
// ✅ Check HasListeners, null-check, then guard expensive work behind IsAllDataRequested
if (ActivitySource.HasListeners())
{
    using var activity = ActivitySource.StartActivity("ProcessItem", ActivityKind.Internal);
    if (activity != null && activity.IsAllDataRequested)
    {
        activity.DisplayName = "Processing order #12345";
        activity.SetTag("app.item_id", itemId);
        activity.SetTag("app.item_type", itemType);
    }
}

// ❌ WRONG: Don't start activities in fire-and-forget tasks where the
// using scope ends before the async work completes (AsyncLocal context is lost)
async Task HelperAsync()
{
    using var activity = ActivitySource.StartActivity("Helper");
    _ = Task.Run(() => DoWorkAsync()); // ❌ activity disposed before task completes
}
```

**Rules**:
- Check `ActivitySource.HasListeners()` before creating (zero-allocation fast path)
- Always null-check Activity after creation (listener may filter or sample it out)
- Never start activities in async helper methods (`Activity.Current` uses `AsyncLocal`)
- Guard expensive tag computation behind `activity.IsAllDataRequested`
- Use W3C TraceContext. .NET Core 3.0+ / .NET 5+ uses it by default; older TFMs or .NET Framework apps may set `Activity.DefaultIdFormat = ActivityIdFormat.W3C` at startup and use `Activity.ForceDefaultIdFormat = true` to override hierarchical parents.

### Activity Naming

```csharp
// ✅ Unique operation name, friendly display name (null-check before accessing)
using var activity = ActivitySource.StartActivity(
    name: "ProcessItem",              // Unique, identifies class of spans
    kind: ActivityKind.Internal
);
if (activity != null)
    activity.DisplayName = "Processing order #12345"; // User-friendly, can be specific

// ❌ WRONG: Don't include runtime data in operation name
using var badActivity = ActivitySource.StartActivity($"Process_{itemId}"); // ❌
```

**Rules**:
- Each span type has unique `OperationName` (identifies statistically interesting class of spans)
- Operation name should NOT contain runtime data (only compile/config-time info)
- Use human-readable `DisplayName` for specifics
- Follow [OpenTelemetry span naming conventions](https://opentelemetry.io/docs/specs/otel/trace/api/#span)

### SpanKind Selection

Choose the correct `ActivityKind` to clarify the span's role in distributed tracing:

| `ActivityKind` | OTel SpanKind | When to use |
|----------------|---------------|-------------|
| `Internal` | `INTERNAL` | Default — in-process operations not crossing a remote boundary |
| `Server` | `SERVER` | Processing an incoming request/response call (HTTP server, gRPC server, RPC server) |
| `Client` | `CLIENT` | Making an outgoing request/response call (HTTP client, database client, RPC call) |
| `Producer` | `PRODUCER` | Enqueuing/publishing deferred work (message queue publish, event emit, job enqueue) |
| `Consumer` | `CONSUMER` | Dequeuing/processing deferred work (message queue receive, event handle, job dequeue) |

**Rules**:
- A single span SHOULD NOT serve more than one purpose
- Create the outgoing span **before** injecting its `SpanContext` into the request. If you inject first, the parent's context propagates instead and the outgoing span ends up dangling (no connection to the downstream call).
- See [traces-and-propagation-reference.md](traces-and-propagation-reference.md) for detailed SpanKind guidance with examples

### Span Attributes (Tags)

```csharp
// ✅ Application code: use your own namespace
activity?.SetTag("myapp.order_id", orderId);
activity?.SetTag("myapp.payment.status", "confirmed");

// ✅ Manual infrastructure instrumentation: use semantic conventions
// activity?.SetTag("db.system.name", "postgresql"); // custom database client
// activity?.SetTag("http.request.method", "GET"); // custom HTTP transport

// Values can be strings, numbers, booleans, or homogeneous arrays
activity?.SetTag("app.item_count", 42);
activity?.SetTag("app.related_ids", new int[] { 1, 2, 3 });

// ❌ WRONG: PascalCase, hyphen delimiter, plural, or unrelated namespace
activity?.SetTag("MyApp.OrderId", orderId);     // ❌ Wrong case
activity?.SetTag("myapp.order-id", orderId);    // ❌ Wrong delimiter
```

**Rules**:
- Namespace prefix matching your component: `myapp.*`, `myapp.db.*`
- All lowercase, underscore (`_`) delimiters, singular form
- Attribute values: string, boolean, double, int64, byte arrays, homogeneous arrays (null/empty valid per [AnyValue spec](https://opentelemetry.io/docs/specs/otel/common/#anyvalue))
- **Business/domain attributes**: use your own namespace (`myapp.*`).
- **HTTP, database, messaging, or RPC concepts you manually instrument**: use [semantic conventions](https://opentelemetry.io/docs/specs/semconv/). Do not duplicate attributes already emitted by auto-instrumentation. Do not use OTel namespaces as prefixes for custom attributes.

### Activity Status and Errors

```csharp
try
{
    await ProcessItemAsync();
    activity?.SetStatus(ActivityStatusCode.Ok);
}
catch (Exception ex)
{
    if (activity != null)
    {
        activity.SetStatus(ActivityStatusCode.Error, ex.Message); // modern API
        activity.AddEvent(new ActivityEvent("exception", tags: new ActivityTagsCollection
        {
            ["exception.type"] = ex.GetType().FullName,
            ["exception.message"] = ex.Message,
            // Include unless size/sensitivity/volume policy says otherwise.
            // ["exception.stacktrace"] = ex.ToString() // Recommended
        }));
    }
    throw;
}
```

**Rules**:
- Set `ActivityStatusCode.Ok` on success, `ActivityStatusCode.Error` on exception
- Use `SetStatus` (the SDK translates it to OTel span status) — legacy `otel.status_code`/`otel.status_description` tags are no longer needed
- Record exception events per [OTel exception span conventions](https://opentelemetry.io/docs/specs/semconv/exceptions/exceptions-spans/)
- `exception.stacktrace` is **Recommended** for exception span events. Include it unless size, sensitivity, or volume policy says otherwise. For high-volume handled exceptions, prefer `ILogger` with trace correlation or the semconv logs opt-in (`OTEL_SEMCONV_EXCEPTION_SIGNAL_OPT_IN`).

### Activity Events

```csharp
// ✅ Use events sparingly — stored in-memory until export
activity?.AddEvent(new ActivityEvent("ItemRetried", tags: new ActivityTagsCollection
{
    ["retry_attempt"] = retryCount
}));
// ❌ Don't use events for verbose logging — use ILogger instead
```

### Accessing Activities

```csharp
var current = Activity.Current; // ❌ may be a user-created ambient span
using var ownedActivity = ActivitySource.StartActivity("MyOperation"); // ✅ captured reference
ownedActivity?.SetTag("myapp.key", value);
```
**Rules**: Do not rely on `Activity.Current` for spans you own; user code can replace it via `AsyncLocal`. Pass/store captured `Activity` only while alive. Store `ActivityContext` for propagation identity.

### Span Links

Links connect a span to other spans that are causally related but not in a direct parent-child relationship — batch processing, scatter/gather, trace boundary crossings.

```csharp
var links = new List<ActivityLink>
{
    new(activityContext1),
    new(activityContext2),
};

var activity = ActivitySource.StartActivity(
    ActivityKind.Internal, name: "batch-process", links: links);
```

See [traces-and-propagation-reference.md](traces-and-propagation-reference.md) for full link patterns including batch processing, scatter/gather, and trace boundary crossing.

### Context Propagation

Distributed tracing requires propagating trace context across process boundaries (HTTP calls, message queues, etc.) using W3C `traceparent` headers. In .NET, this is handled by `DistributedContextPropagator`. The OTel SDK configures W3C TraceContext propagation by default.

See [traces-and-propagation-reference.md](traces-and-propagation-reference.md) for propagation patterns, custom propagators, and manual inject/extract for non-standard transports.

## Metrics

### Meter and Metrics Class Setup

```csharp
public sealed class OrderProcessingMetrics : IDisposable
{
    private readonly Meter meter = new("MyApp.OrderProcessing", "1.0.0");
    private readonly Histogram<double> processingDuration =
        meter.CreateHistogram<double>("myapp.order.processing.duration", unit: "s");
    private readonly Counter<long> itemsProcessed =
        meter.CreateCounter<long>("myapp.order.processing.count", unit: "{order}");

    public void Dispose() => meter.Dispose();
}
```

**Naming Conventions** (follow [OTel semantic conventions](https://opentelemetry.io/docs/specs/semconv/general/metrics/)):
- Singular names, nested hierarchy: `myapp.order.processing.duration`
- Define units (s, ms, {item}, {connection}); avoid technical suffixes (`_counter`, `_histogram`)
- Start with pre-1.0.0 version until adoption proven

### Instrument Type Overview

.NET provides 7 metric instrument types. Choose the right one for your measurement:

| Instrument | .NET API | Behavior | Typical Use |
|------------|---------|----------|-------------|
| **Counter** | `CreateCounter<T>` | Monotonically increasing | Request counts, error counts |
| **UpDownCounter** | `CreateUpDownCounter<T>` | Increases or decreases | Queue size, active connections |
| **Histogram** | `CreateHistogram<T>` | Distribution of values | Durations, response sizes |
| **Gauge** | `CreateGauge<T>` (.NET 9+) | Synchronous instant value | Current measurement recording |
| **ObservableCounter** | `CreateObservableCounter<T>` | Async callback, monotonic | Periodically polled totals |
| **ObservableGauge** | `CreateObservableGauge<T>` | Async callback, non-monotonic | CPU/memory usage |
| **ObservableUpDownCounter** | `CreateObservableUpDownCounter<T>` | Async callback, bi-directional | Active tasks by priority |

See [metrics-and-instruments-reference.md](metrics-and-instruments-reference.md) for full creation/recording examples and observable callback patterns.

### Metric Recording Method Naming

```csharp
// ✅ Action/outcome-based naming, separate methods per outcome
public void OrderProcessingSucceeded(string orderType, TimeSpan duration) { /* Record */ }
public void OrderProcessingFailed(string orderType, Exception ex, TimeSpan duration) { /* Record */ }
public void ConnectionOpened() => connectionsOpen.Add(1);
public void ConnectionClosed() => connectionsOpen.Add(-1);

// ❌ WRONG: Name after metric, confusing signature
public void RecordOrderProcessingDuration(...) { } // ❌ don't name after metric
public void RecordError(bool succeeded, Exception? ex) { } // ❌ confusing signature
```

**Rules**:
- Name after action/outcome (`OrderProcessingSucceeded`), NOT after metric (`RecordXxx`)
- Separate methods per outcome (avoid boolean flags + optional exceptions)
- Event-based naming for state changes: `ConnectionOpened()`, `ItemQueued()`

### Metric Dimensions

```csharp
// ✅ Low-cardinality, predefined dimensions
processingDuration.Record(duration.TotalSeconds,
    new KeyValuePair<string, object?>("myapp.order_type", orderType),  // bounded set
    new KeyValuePair<string, object?>("outcome", "success"));         // bounded set

// ❌ High-cardinality: unbounded values cause cardinality explosion
failureCount.Add(1, new KeyValuePair<string, object?>("order_id", orderId)); // ❌ unbounded
```

**Rules**:
- Dimensions MUST be predefined and low-cardinality (item type, queue name, outcome)
- Avoid unbounded values (each unique value = new time series row → cardinality explosion)
- High-cardinality dimensions MUST be opt-in configuration
- Consistent names across components: `myapp.region` means the same everywhere
- Users can enable [exemplars](https://opentelemetry.io/docs/languages/dotnet/metrics/exemplars/) for trace correlation (not via dimensions)

## Performance Requirements

Instrumentation MUST be cheap by default. Follow these rules to minimize overhead:

### Zero-Allocation Fast Path

```csharp
// ✅ CORRECT: Guard with cheap checks
if (ActivitySource.HasListeners())
{
    using var activity = ActivitySource.StartActivity("Operation");
    // ... expensive work
}

// ✅ CORRECT: Use TagList (struct) for metrics
var tags = new TagList
{
    { "myapp.order_type", orderType },
    { "outcome", "success" }
};
counter.Add(1, tags);
```

### Timing

```csharp
// ✅ Timestamp math (no allocation)
var startTime = Stopwatch.GetTimestamp();
try { await ProcessAsync(); }
finally { var duration = Stopwatch.GetElapsedTime(startTime); metrics.OrderProcessingSucceeded(orderType, duration); }

// ❌ Allocates: Stopwatch.StartNew() or IDisposable timing wrappers
```

### Avoid Hidden Allocations

```csharp
// ❌ Allocates: string interpolation without IsAllDataRequested guard
activity?.SetTag("item", $"Processing {itemId}"); // ❌

// ✅ Guard expensive work behind IsAllDataRequested
if (activity?.IsAllDataRequested == true)
    activity.SetTag("item", $"Processing {itemId}");
```

**Rules**:
- No `Stopwatch.StartNew()` (use `Stopwatch.GetTimestamp()`/`GetElapsedTime`)
- Prefer `TagList` (struct) over arrays/dictionaries
- No LINQ, string interpolation, or async state machines in hot paths without guards

## Testing Requirements

### Span Tests

```csharp
[Test]
public async Task Should_create_processing_span_with_correct_parent()
{
    // Arrange
    using var parent = new Activity("Parent").Start();

    // Act
    await handler.Handle(item);

    // Assert
    var processingSpan = recordedActivities.Single(a => a.OperationName == "ProcessItem");
    Assert.AreEqual(parent.Id, processingSpan.ParentId);
    Assert.AreEqual("myapp.item_type", processingSpan.Tags.First().Key);
}

[Test]
public void Should_not_introduce_breaking_changes_to_span_names()
{
    // Ensures string values in span names are under test
    Assert.AreEqual("ProcessItem", MyFeature.SpanName);
}
```

**Rules**:
- Test which spans activities connect to
- Test string values (span names, tag names) to prevent breaking changes
- Remember: telemetry is part of public API

## Versioning

- Telemetry versioning decoupled from package version
- Use SemVer semantics
- Traces and Metrics use separate versions (evolve independently)
- Start with pre-1.0.0 version until adoption/usefulness proven

```csharp
private static readonly ActivitySource ActivitySource = new("MyApp.MyComponent", "0.9.0");
private readonly Meter meter = new("MyApp.MyComponent", "0.8.0");
```

## Logs

.NET logs integrate with OpenTelemetry through the built-in `ILogger` API. The OTel SDK provides `AddOpenTelemetry()` on the logging builder to collect, process, and export logs. Log records are automatically correlated with traces via `TraceId`/`SpanId`.

See [sdk-resources-and-logs-reference.md](sdk-resources-and-logs-reference.md) for full logs integration patterns including correlation, redaction, structured logging, and severity filtering.

## Reference Files

- [traces-and-propagation-reference.md](traces-and-propagation-reference.md): SpanKind deep dive with examples, Span Links (batch, scatter/gather, trace boundary), Context Propagation (W3C traceparent, DistributedContextPropagator, custom propagators), Baggage, and the full modern exception recording pattern.
- [metrics-and-instruments-reference.md](metrics-and-instruments-reference.md): All 7 metric instrument types with creation/recording code and when-to-use guidance, observable instrument callback patterns, dimensions deep dive, exemplars, aggregation defaults, and units.
- [sdk-resources-and-logs-reference.md](sdk-resources-and-logs-reference.md): SDK initialization (ASP.NET Core + Console), Resource configuration (ResourceBuilder, AddService, AddDetector, custom detectors), Exporters (OTLP, Console, Jaeger, Zipkin, Prometheus), Instrumentation Libraries, Sampling (built-in, custom, env vars, head/tail-based), Logs integration (ILogger, correlation, redaction, structured logging), and environment variable configuration.

## References

- [OTel Specification Overview](https://opentelemetry.io/docs/specs/otel/overview/)
- [OTel Semantic Conventions](https://opentelemetry.io/docs/specs/semconv/)
- [OTel Common Spec (AnyValue)](https://opentelemetry.io/docs/specs/otel/common/)
- [OTel Tracing SDK Spec](https://opentelemetry.io/docs/specs/otel/trace/sdk/)
- [OTel Metrics SDK Spec](https://opentelemetry.io/docs/specs/otel/metrics/sdk/)
- [OTel Logs Spec](https://opentelemetry.io/docs/specs/otel/logs/)
- [OTel Resource Spec](https://opentelemetry.io/docs/specs/otel/resource/)
- [OTel Context Spec](https://opentelemetry.io/docs/specs/otel/context/)
- [.NET Observability with OpenTelemetry (MS Learn)](https://learn.microsoft.com/en-us/dotnet/core/diagnostics/observability-with-otel)
- [OTel .NET Manual Instrumentation](https://opentelemetry.io/docs/languages/dotnet/instrumentation/)
- [OTel .NET Metric Instruments](https://opentelemetry.io/docs/languages/dotnet/metrics/instruments/)
- [OTel .NET Sampling](https://opentelemetry.io/docs/languages/dotnet/sampling/)
- [OTel .NET Zero-Code Instrumentation](https://opentelemetry.io/docs/zero-code/net/)