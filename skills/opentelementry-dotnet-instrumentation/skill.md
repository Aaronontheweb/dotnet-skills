---
name: OpenTelemetry-NET-Instrumentation
description: Provides guidance for implementing OpenTelemetry instrumentation in .NET codebases, covering tracing (Activities/Spans), metrics, naming conventions, error handling, performance, and API design best practices.
version: 1.0.0
tags:
  - opentelemetry
  - dotnet
  - observability
  - tracing
  - metrics
  - performance
---

# OpenTelemetry .NET Instrumentation Skill

## Description
Provides guidance for implementing OpenTelemetry instrumentation in .NET codebases, covering tracing (Activities/Spans), metrics, naming conventions, error handling, performance, and API design best practices.

## When to Use
- Adding OpenTelemetry instrumentation to .NET code
- Creating or modifying ActivitySources and metrics
- Reviewing telemetry implementations for compliance
- Optimizing instrumentation performance
- Designing telemetry APIs that become part of the public surface

## Prerequisites
- .NET application with OpenTelemetry SDK
- Understanding of System.Diagnostics.Metrics and ActivitySource APIs
- Access to observability backend (e.g., Jaeger, Prometheus, Grafana)

## Core Principles

### Resiliency First
**CRITICAL**: Exceptions in diagnostic/tracing/metrics logic MUST NEVER impact application processing.
- Always protect against null Activity references except in Activity extension methods (use `activity?.ExtensionMethod()`)
- Assume Activity instances can be null (only created when listeners subscribe)
- Guard all instrumentation code with appropriate null checks

### API Surface Awareness
- Any telemetry emitted becomes part of the public API surface
- Changes are subject to breaking changes guidelines
- Telemetry should be emitted by default (users opt-in to collection via OpenTelemetry extensions)
- Exception: High-cardinality metric dimensions may require explicit opt-in

### Standards Compliance
- Follow Microsoft best practices for [distributed tracing instrumentation](https://docs.microsoft.com/en-us/dotnet/core/diagnostics/distributed-tracing-instrumentation-walkthroughs)
- Follow [OpenTelemetry semantic conventions](https://opentelemetry.io/docs/concepts/semantic-conventions/)
- All attributes must be non-null, non-empty strings

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
- Create separate ActivitySources for specialized/opt-in scenarios

### Creating Activities

```csharp
// ✅ CORRECT: Check HasListeners before creating
if (ActivitySource.HasListeners())
{
    using var activity = ActivitySource.StartActivity("ProcessItem", ActivityKind.Internal);

    if (activity != null)
    {
        activity.DisplayName = "Processing order #12345";

        // Only compute expensive tags if requested
        if (activity.IsAllDataRequested)
        {
            activity.SetTag("app.item_id", itemId);
            activity.SetTag("app.item_type", itemType);
        }
    }
}

// ❌ WRONG: Don't start activities in async helper methods (breaks AsyncLocal)
async Task HelperAsync()
{
    using var activity = ActivitySource.StartActivity("Helper"); // ❌ BAD
    await DoWorkAsync();
}
```

**Rules**:
- Check `ActivitySource.HasListeners()` before creating (zero-allocation fast path)
- Always check if activity is null after creation
- Never start activities in asynchronous helper methods (`Activity.Current` uses `AsyncLocal`)
- Use `activity.IsAllDataRequested` before expensive computations
- Always use W3C ID format (enforce format change if parent uses hierarchical)

### Activity Naming

```csharp
// ✅ CORRECT: Unique operation name, friendly display name
using var activity = ActivitySource.StartActivity(
    name: "ProcessItem",              // Unique, identifies class of spans
    kind: ActivityKind.Internal
);
activity.DisplayName = "Processing order #12345"; // User-friendly, can be specific

// ❌ WRONG: Don't include runtime data in operation name
using var activity = ActivitySource.StartActivity($"Process_{itemId}"); // ❌ BAD
```

**Rules**:
- Each span type has unique `OperationName` (identifies statistically interesting class of spans)
- Operation name should NOT contain runtime data (only compile/config-time info)
- Use human-readable `DisplayName` for specifics
- Follow [OpenTelemetry span naming conventions](https://opentelemetry.io/docs/specs/otel/trace/api/#span)

### Span Attributes (Tags)

```csharp
// ✅ CORRECT: Namespace, lowercase, underscore-delimited
activity?.SetTag("myapp.order_id", orderId);
activity?.SetTag("myapp.order_type", orderType);
activity?.SetTag("myapp.db.table_name", tableName);

// Standard semantic conventions where applicable
activity?.SetTag("db.system", "postgresql");
activity?.SetTag("http.method", "GET");

// ❌ WRONG: Various naming violations
activity?.SetTag("MyApp.OrderId", orderId);         // ❌ Wrong case
activity?.SetTag("myapp.order-id", orderId);        // ❌ Wrong delimiter
activity?.SetTag("myapp.orders", count);            // ❌ Plural
activity?.SetTag("unrelated.ip_address", ip);       // ❌ Not characteristic
```

**Naming Conventions**:
- Use a namespace prefix matching your component: `myapp.*`, `myapp.db.*`
- All lowercase letters
- Underscore (`_`) delimiters for multi-word attributes
- Singular form
- Only set tags directly relevant to this activity
- Prefer standard [OpenTelemetry semantic conventions](https://opentelemetry.io/docs/specs/semconv/) over custom attributes where they exist
- Only use standard semantic conventions if certain no downstream library will set them

### Activity Status and Errors

```csharp
// ✅ CORRECT: Set status and record exceptions
try
{
    await ProcessItemAsync();
    activity?.SetStatus(ActivityStatusCode.Ok);
}
catch (Exception ex)
{
    if (activity != null)
    {
        activity.SetStatus(ActivityStatusCode.Error);
        activity.SetTag("otel.status_code", "error");
        activity.SetTag("otel.status_description", ex.Message);

        // Record exception event per OTel spec
        activity.AddEvent(new ActivityEvent(
            "exception",
            tags: new ActivityTagsCollection
            {
                ["exception.type"] = ex.GetType().FullName,
                ["exception.message"] = ex.Message,
                ["exception.stacktrace"] = ex.ToString()
            }
        ));
    }
    throw;
}
```

**Rules**:
- Set `ActivityStatusCode.Ok` on success
- Set `ActivityStatusCode.Error` on exception
- Always add `otel.status_code` and `otel.status_description` tags
- Record exception events following [OTel exception conventions](https://opentelemetry.io/docs/reference/specification/trace/semantic_conventions/exceptions/)

### Activity Events

```csharp
// ✅ CORRECT: Use events for additional context (sparingly)
activity?.AddEvent(new ActivityEvent("ItemRetried", tags: new ActivityTagsCollection
{
    ["retry_attempt"] = retryCount,
    ["next_retry_delay"] = delayMs
}));

// ❌ WRONG: Don't use events for verbose logging
activity?.AddEvent(new ActivityEvent($"Step {i} completed")); // ❌ Use logging instead
```

**Rules**:
- Events stored in-memory until transmission (use sparingly)
- Only for additional context; consider nested spans for multiple events
- Use logging for verbose information

### Accessing Activities

```csharp
// ❌ WRONG: Don't rely on Activity.Current when you need a specific span
public async Task HandleAsync(Context context)
{
    var activity = Activity.Current; // ❌ Might be a user-created span, not yours
    activity?.SetTag("custom", "value");
}

// ✅ CORRECT: Pass Activity explicitly or store it in a dedicated context object
public async Task HandleAsync(Context context)
{
    if (context.TryGetActivity(out var activity))
    {
        activity?.SetTag("custom", "value");
    }
}
```

## Metrics

### Meter and Metrics Class Setup

```csharp
// ✅ CORRECT: Group metrics by feature/component
public sealed class OrderProcessingMetrics : IDisposable
{
    private readonly Meter meter;
    private readonly Histogram<double> processingDuration;
    private readonly Counter<long> itemsProcessed;

    public OrderProcessingMetrics()
    {
        meter = new Meter("MyApp.OrderProcessing", "1.0.0");

        // Singular names, appropriate units, nested hierarchy
        processingDuration = meter.CreateHistogram<double>(
            "myapp.order.processing.duration",
            unit: "s",
            description: "Duration of order processing"
        );

        itemsProcessed = meter.CreateCounter<long>(
            "myapp.order.processing.count",
            unit: "{order}",
            description: "Number of orders processed"
        );
    }

    public void Dispose() => meter.Dispose();
}
```

**Naming Conventions** (follow [OTel semantic conventions](https://opentelemetry.io/docs/specs/semconv/general/metrics/)):
- Singular names (use `_count` suffix instead of pluralization)
- Nested hierarchy: `myapp.order.processing.duration`
- Define units (s, ms, {item}, {connection})
- Avoid technical suffixes (`_counter`, `_histogram`)
- Start with pre-1.0.0 version until adoption proven

### Metric Recording Method Naming

```csharp
// ✅ CORRECT: Action/outcome-based naming, separate methods per outcome
public sealed class OrderProcessingMetrics
{
    // Event happened: describe what occurred
    public void OrderProcessingSucceeded(string orderType, TimeSpan duration)
    {
        processingDuration.Record(duration.TotalSeconds,
            new KeyValuePair<string, object?>("myapp.order_type", orderType),
            new KeyValuePair<string, object?>("outcome", "success")
        );
    }

    public void OrderProcessingFailed(string orderType, Exception exception, TimeSpan duration)
    {
        processingDuration.Record(duration.TotalSeconds,
            new KeyValuePair<string, object?>("myapp.order_type", orderType),
            new KeyValuePair<string, object?>("outcome", "failure"),
            new KeyValuePair<string, object?>("exception.type", exception.GetType().Name)
        );
    }

    public void ConnectionOpened() => connectionsOpen.Add(1);
    public void ConnectionClosed() => connectionsOpen.Add(-1);
}

// ❌ WRONG: Various naming anti-patterns
public void RecordOrderProcessingDuration(...) { } // ❌ Don't name after metric
public void RecordError(bool succeeded, Exception? ex) { } // ❌ Confusing signature
```

**Rules** (inspired by ASP.NET Core patterns):
- Name after action/outcome: `OrderProcessingSucceeded`, `RetryAttempted`, `ConnectionFailed`
- NOT after metric name: avoid `RecordXxx`, `IncrementXxx`
- Separate methods for different outcomes (avoid boolean flags + optional exceptions)
- Event-based naming for state changes: `ConnectionOpened()`, `ItemQueued()`

### Metric Dimensions

```csharp
// ✅ CORRECT: Low-cardinality, predefined dimensions
public void OrderProcessingSucceeded(string orderType, TimeSpan duration)
{
    processingDuration.Record(duration.TotalSeconds,
        new KeyValuePair<string, object?>("myapp.order_type", orderType),
        new KeyValuePair<string, object?>("myapp.region", region),
        new KeyValuePair<string, object?>("outcome", "success")
    );
}

// ❌ WRONG: High-cardinality dimensions (unbounded values cause cardinality explosion)
public void OrderFailed(string orderId, string exceptionMessage)
{
    failureCount.Add(1,
        new KeyValuePair<string, object?>("order_id", orderId),               // ❌ Unbounded
        new KeyValuePair<string, object?>("exception_message", exceptionMessage) // ❌ Unbounded
    );
}
```

**Rules**:
- Dimensions MUST be predefined at instrument creation
- Avoid dynamic/unbounded values (causes cardinality explosion: each unique value creates a new time series row)
- High-cardinality dimensions MUST be opt-in configuration
- Use low-cardinality identifiers: item type, queue name, outcome
- Consistent dimension names across components: `myapp.region` means same thing everywhere
- Avoid sensitive data
- Consider [metric enrichment alternatives](https://github.com/open-telemetry/opentelemetry-dotnet/tree/main/docs/metrics#metrics-enrichment)
- Users can enable [metric exemplars](https://github.com/open-telemetry/opentelemetry-dotnet/tree/main/docs/metrics#metrics-correlation) for correlation (not through dimensions)

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
// ✅ CORRECT: Timestamp math (no allocation)
var startTime = Stopwatch.GetTimestamp();
try
{
    await ProcessAsync();
}
finally
{
    var duration = Stopwatch.GetElapsedTime(startTime);
    metrics.OrderProcessingSucceeded(orderType, duration);
}

// ❌ WRONG: Allocates Stopwatch object
var stopwatch = Stopwatch.StartNew(); // ❌ Allocates

// ❌ WRONG: IDisposable timing class (allocates per use)
using (new MetricScope(metrics, "ProcessOrder")) // ❌ BAD
{
    ProcessOrder();
}
```

### Avoid Hidden Allocations

```csharp
// ❌ WRONG: String interpolation allocates
activity?.SetTag("item", $"Processing {itemId}"); // ❌ Allocates

// ✅ CORRECT: Check IsAllDataRequested first
if (activity?.IsAllDataRequested == true)
{
    activity.SetTag("item", $"Processing {itemId}");
}

// ❌ WRONG: LINQ allocates enumerators
activity?.SetTag("handlers", handlers.Select(h => h.Name).ToArray()); // ❌ Bad

// ✅ CORRECT: Manual construction or check first
if (activity?.IsAllDataRequested == true)
{
    activity.SetTag("handlers", string.Join(",", handlers.Select(h => h.Name)));
}
```

**Rules**:
- No `Stopwatch.StartNew()` (use timestamp math)
- No timing `IDisposable` wrappers as classes
- Prefer `TagList` (struct) over arrays/dictionaries
- No hidden work: avoid LINQ, string interpolation, async state machines in hot paths

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

## References

- [OpenTelemetry .NET Trace Documentation](https://github.com/open-telemetry/opentelemetry-dotnet/tree/main/docs/trace)
- [OpenTelemetry .NET Metrics Documentation](https://github.com/open-telemetry/opentelemetry-dotnet/tree/main/docs/metrics)
- [OpenTelemetry Semantic Conventions](https://opentelemetry.io/docs/concepts/semantic-conventions/)
- [Microsoft Distributed Tracing Instrumentation](https://docs.microsoft.com/en-us/dotnet/core/diagnostics/distributed-tracing-instrumentation-walkthroughs)
- [ASP.NET Core Metrics Examples](https://github.com/search?q=repo%3Adotnet%2Faspnetcore+Metrics&type=code)
- [OpenTelemetry Trace API Span Definition](https://opentelemetry.io/docs/specs/otel/trace/api/#span)
- [OpenTelemetry Exception Conventions](https://opentelemetry.io/docs/reference/specification/trace/semantic_conventions/exceptions/)
- [OpenTelemetry Attribute Specification](https://github.com/open-telemetry/opentelemetry-specification/tree/main/specification/common#attribute)
- [OpenTelemetry Cardinality Limits](https://github.com/open-telemetry/opentelemetry-dotnet/blob/main/docs/metrics/README.md#cardinality-limits)
