# Metrics and Instruments Reference

Detailed reference for all metric instrument types in .NET, including observable instrument callback patterns, dimensions management, exemplars, aggregation, and units guidance.

This is a companion to [SKILL.md](SKILL.md). See it for core principles, the "System.Diagnostics-first" architecture, metrics naming conventions, and metric recording method naming.

## Table of Contents

- [Instrument Type Overview](#instrument-type-overview)
- [Counter](#counter)
- [UpDownCounter](#updowncounter)
- [Histogram](#histogram)
- [Gauge (.NET 9+)](#gauge-net-9)
- [ObservableCounter](#observablecounter)
- [ObservableGauge](#observablegauge)
- [ObservableUpDownCounter](#observableupdowncounter)
- [Batching Observable Measurements](#batching-observable-measurements)
- [Dimensions Deep Dive](#dimensions-deep-dive)
- [Exemplars](#exemplars)
- [Aggregation Defaults](#aggregation-defaults)
- [Units Guidance](#units-guidance)
- [References](#references)

---

## Instrument Type Overview

.NET provides 7 metric instrument types (the 6 defined by the OTel specification plus a synchronous `Gauge` added in .NET 9). All are available via `System.Diagnostics.Metrics.Meter`. They fall into two categories:

### Synchronous Instruments (called when an event occurs)

| Instrument | .NET API | Monotonic | Typical Use |
|-----------|---------|-----------|-------------|
| **Counter** | `CreateCounter<T>` | Yes (increasing only) | Request counts, error counts, bytes sent |
| **UpDownCounter** | `CreateUpDownCounter<T>` | No (up or down) | Queue size, active connections, memory in use |
| **Histogram** | `CreateHistogram<T>` | N/A (distribution) | Request durations, response sizes, latency percentiles |
| **Gauge** | `CreateGauge<T>` (.NET 9+) | No (instant value) | Current temperature, voltage, non-cumulative measurement |

### Asynchronous/Observable Instruments (called on collection interval)

| Instrument | .NET API | Monotonic | Typical Use |
|-----------|---------|-----------|-------------|
| **ObservableCounter** | `CreateObservableCounter<T>` | Yes | Total CPU time, total bytes read since startup |
| **ObservableGauge** | `CreateObservableGauge<T>` | No | Current CPU usage %, current memory, queue depth |
| **ObservableUpDownCounter** | `CreateObservableUpDownCounter<T>` | No | Active tasks by priority, current connections by type |

### Choosing an Instrument

```
Is the value a cumulative total that only goes up?
  → YES: Can you increment it on every event?
           → YES: Counter (synchronous)
           → NO (polled periodically):  ObservableCounter (async)
  → NO:  Is it a distribution/percentile you need?
           → YES: Histogram
  → NO:  Can the value go both up AND down?
           → YES: Can you update it on every event?
                    → YES: UpDownCounter (synchronous)
                    → NO (polled periodically): ObservableUpDownCounter (async)
           → NO (instantaneous snapshot): Can you record it on every event?
                    → YES: Gauge (synchronous, .NET 9+)
                    → NO (polled periodically): ObservableGauge (async)
```

---

## Counter

A Counter records a monotonically increasing value. You can only add non-negative values. Use for counting events: requests, errors, and bytes transferred.

### Creating a Counter

```csharp
var meter = new Meter("MyCompany.MyProduct", "1.0.0");

var requestCounter = meter.CreateCounter<long>(
    "myapp.request_count",
    unit: "{request}",
    description: "Number of requests received");
```

### Recording Measurements

```csharp
// Increment by 1
requestCounter.Add(1);

// Increment with attributes (tags/dimensions)
requestCounter.Add(1,
    new KeyValuePair<string, object?>("http.request.method", "GET"),
    new KeyValuePair<string, object?>("http.route", "/api/users"));

// Increment by larger amount
bytesSentCounter.Add(1024,
    new KeyValuePair<string, object?>("myapp.endpoint", "/download"));
```

### Rules

- Values MUST be non-negative (adding a negative value throws at runtime)
- Use `long` or `int` for counts, `double` for fractional measurements
- The SDK aggregates by summing all recorded values per unique attribute set
- Aggregation: **Sum** (monotonic)

---

## UpDownCounter

An UpDownCounter records a value that can both increase and decrease. Use for tracking current values: queue sizes, active connections, resource pool usage.

### Creating an UpDownCounter

```csharp
var activeConnections = meter.CreateUpDownCounter<int>(
    "myapp.active_connections",
    unit: "{connection}",
    description: "Number of active connections");
```

### Recording Measurements

```csharp
// Connection opened → +1
activeConnections.Add(1,
    new KeyValuePair<string, object?>("myapp.protocol", "https"));

// Connection closed → -1
activeConnections.Add(-1,
    new KeyValuePair<string, object?>("myapp.protocol", "https"));
```

### Rules

- Values can be positive or negative
- The SDK tracks the net sum per unique attribute set
- Aggregation: **Sum** (non-monotonic)
- Use when you need to track a value that changes over time but don't need
  a distribution/percentile view (use Histogram for that)

---

## Histogram

A Histogram records the distribution of values — capturing count, sum, min, max, and configurable bucket boundaries for percentile estimation. Use for measuring durations, response sizes, and any value where you need percentiles (p50, p95, p99).

### Creating a Histogram

```csharp
var requestDuration = meter.CreateHistogram<double>(
    "myapp.request.duration",
    unit: "ms",
    description: "Request duration in milliseconds");
```

### Recording Measurements

```csharp
var startTime = Stopwatch.GetTimestamp();
try
{
    await ProcessRequestAsync();
}
finally
{
    var duration = Stopwatch.GetElapsedTime(startTime);
    requestDuration.Record(duration.TotalMilliseconds,
        new KeyValuePair<string, object?>("http.route", "/api/orders"),
        new KeyValuePair<string, object?>("http.request.method", "POST"));
}
```

### Custom Bucket Boundaries

The OTel SDK allows configuring explicit bucket boundaries via views:

```csharp
// Application setup: configure histogram buckets
builder.Services.AddOpenTelemetry()
    .WithMetrics(metrics => metrics
        .AddMeter("MyCompany.MyProduct")
        .AddView("myapp.request.duration", new ExplicitBucketHistogramConfiguration
        {
            Boundaries = new double[] { 0, 5, 10, 25, 50, 75, 100, 250, 500, 1000 }
        }));
```

### Rules

- Records individual measurements (not sums)
- The SDK aggregates into: count, sum, min, max, bucket counts
- Default boundaries vary by SDK version; configure explicitly for your use case
- Aggregation: **Explicit Bucket Histogram** by default

---

## Gauge (.NET 9+)

A Gauge records the current value of a measurement at a specific point in time. This is a synchronous instrument — you call it when the event occurs. Use for non-cumulative instantaneous measurements.

### Creating a Gauge

```csharp
// .NET 9+ only
var temperatureGauge = meter.CreateGauge<double>(
    "myapp.sensor.temperature",
    unit: "Cel",
    description: "Current temperature reading");
```

### Recording Measurements

```csharp
temperatureGauge.Record(23.5,
    new KeyValuePair<string, object?>("myapp.sensor_id", "sensor-01"));
```

### Rules

- Available in .NET 9 and later
- Records the latest value (not a sum)
- Use when you have the value at call time and don't need polling
- For polled values (e.g., CPU usage read from OS), use `ObservableGauge` instead
- Aggregation: **Last Value** (Gauge)

---

## ObservableCounter

An ObservableCounter is an asynchronous instrument that reports a monotonically increasing value via a callback. The SDK calls the callback at collection intervals. Use for values that are maintained externally and only read periodically.

### Creating an ObservableCounter

```csharp
var totalBytesRead = meter.CreateObservableCounter<long>(
    "myapp.io.bytes_read",
    () => GetTotalBytesRead(),  // callback returning current value
    unit: "By",
    description: "Total bytes read since startup");
```

### With Tags

```csharp
meter.CreateObservableCounter<long>(
    "myapp.io.bytes_read",
    () => new[]
    {
        new Measurement<long>(GetBytesRead("disk"), new KeyValuePair<string, object?>("myapp.device", "disk")),
        new Measurement<long>(GetBytesRead("network"), new KeyValuePair<string, object?>("myapp.device", "network"))
    },
    unit: "By",
    description: "Total bytes read since startup");
```

### Rules

- Callback is invoked by the SDK at collection intervals (not on every event)
- Callback returns `Measurement<T>` or `IEnumerable<Measurement<T>>`
- Values must be non-negative (monotonic)
- No `Add()` or `Record()` method — values come from the callback
- Aggregation: **Sum** (monotonic)

---

## ObservableGauge

An ObservableGauge is an asynchronous instrument that reports the current measurement value via a callback. Use for values read from the system at collection intervals: CPU usage, memory, temperature, and queue depth.

### Creating an ObservableGauge

```csharp
var cpuUsageGauge = meter.CreateObservableGauge<double>(
    "myapp.cpu.usage",
    () => new Measurement<double>(GetCurrentCpuUsage()),
    unit: "%",
    description: "Current CPU usage percentage");
```

### With Tags

```csharp
meter.CreateObservableGauge<double>(
    "myapp.cpu.usage",
    () => new[]
    {
        new Measurement<double>(GetCpuUsage("core0"), new KeyValuePair<string, object?>("myapp.core", "0")),
        new Measurement<double>(GetCpuUsage("core1"), new KeyValuePair<string, object?>("myapp.core", "1"))
    },
    unit: "%",
    description: "Current CPU usage percentage per core");
```

### Rules

- Callback invoked at collection intervals
- Values can go up or down (non-monotonic)
- Reports the last observed value
- Aggregation: **Last Value** (Gauge)

---

## ObservableUpDownCounter

An ObservableUpDownCounter is an asynchronous instrument that reports a value that can increase or decrease, via a callback. Use for tracking current counts that are maintained externally.

### Creating an ObservableUpDownCounter

```csharp
meter.CreateObservableUpDownCounter<int>(
    "myapp.active_tasks",
    () => new[]
    {
        new Measurement<int>(GetHighPriorityTaskCount(), new KeyValuePair<string, object?>("myapp.priority", "high")),
        new Measurement<int>(GetLowPriorityTaskCount(), new KeyValuePair<string, object?>("myapp.priority", "low"))
    },
    unit: "{task}",
    description: "Current number of active tasks by priority");
```

### Rules

- Callback invoked at collection intervals
- Values can go up or down
- Aggregation: **Sum** (non-monotonic)

---

## Batching Observable Measurements

For multiple observable instruments that share collection logic, define a single method that returns measurements. Each instrument registers independently with its own callback delegate that calls the shared logic:

```csharp
// Shared data-gathering method
static IEnumerable<Measurement<long>> CollectProcessed() =>
    new[] { new Measurement<long>(GetProcessedCount(),
        new KeyValuePair<string, object?>("myapp.queue", "default")) };

// Each instrument registers with its own callback
var observableCounter = meter.CreateObservableCounter<long>(
    "myapp.items_processed", () => CollectProcessed(), unit: "{item}");
```

For instruments of different numeric types, use separate callbacks. The key pattern is to share the underlying data-gathering logic, not to batch the SDK callback itself.

---

## Dimensions Deep Dive

### Cardinality Management

Each unique combination of attribute key-value pairs creates a separate time series. High-cardinality dimensions (e.g., user IDs, request IDs, exception messages) cause **cardinality explosion** — each unique value creates a new time series row, leading to excessive memory and storage usage.

```csharp
// ✅ CORRECT: Low-cardinality dimensions — finite, small set of values
counter.Add(1,
    new KeyValuePair<string, object?>("myapp.operation", "checkout"),
    new KeyValuePair<string, object?>("myapp.region", "us-east-1"),
    new KeyValuePair<string, object?>("outcome", "success"));

// ❌ WRONG: High-cardinality — unbounded values
counter.Add(1,
    new KeyValuePair<string, object?>("order_id", orderId),          // thousands of unique values
    new KeyValuePair<string, object?>("user_email", userEmail),       // thousands of unique values
    new KeyValuePair<string, object?>("exception_message", exMsg);   // unpredictable values
```

### Cardinality Limits in the OTel SDK

The OTel .NET SDK has a configurable cardinality limit (default: 2000 attribute combinations per instrument). When exceeded, new combinations are dropped. This is a safety valve, not a design target — you should design for low cardinality.

Configure via the `OTEL_DOTNET_EXPERIMENTAL_METRICS_CARDINALITY_LIMIT` environment variable or in code.

### High-Cardinality Opt-In Pattern

```csharp
public sealed class OrderProcessingMetrics : IDisposable
{
    private readonly Meter _meter;
    private readonly Histogram<double> _processingDuration;
    private readonly bool _enableHighCardinalityDimensions;

    public OrderProcessingMetrics(IConfiguration config)
    {
        _meter = new Meter("MyApp.OrderProcessing", "1.0.0");
        _enableHighCardinalityDimensions = config.GetValue("Metrics:EnableHighCardinality", false);

        _processingDuration = _meter.CreateHistogram<double>(
            "myapp.order.processing.duration", unit: "s");
    }

    public void OrderProcessingSucceeded(string orderType, TimeSpan duration, string? orderId = null)
    {
        var tags = new TagList
        {
            { "myapp.order_type", orderType },
            { "outcome", "success" }
        };

        // High-cardinality dimension only when explicitly opted in
        if (_enableHighCardinalityDimensions && orderId != null)
        {
            tags.Add("myapp.order_id", orderId);
        }

        _processingDuration.Record(duration.TotalSeconds, tags);
    }

    public void Dispose() => _meter.Dispose();
}
```

---

## Exemplars

[Exemplars](https://opentelemetry.io/docs/specs/otel/metrics/sdk/#exemplar) are metric measurements that carry an associated trace context (TraceId/SpanId). They enable correlating metric data points with specific traces, allowing jumping from a metric spike on a dashboard to the exact trace that contributed to that measurement.

### Enabling Exemplars in .NET

Exemplars are enabled via configuration in the OTel .NET SDK:

```csharp
builder.Services.AddOpenTelemetry()
    .WithMetrics(metrics => metrics
        .AddMeter("MyApp.OrderProcessing")
        .AddOtlpExporter(options =>
        {
            // Exemplars are supported in the OTLP exporter
        }));
```

Or via environment variable:

```
OTEL_DOTNET_EXPERIMENTAL_METRICS_EXEMPLAR_FILTER=always_on
# or: trace_based (only for sampled traces)
```

### How Exemplars Work

1. When a metric is recorded within an active trace, the SDK may store the
   current `TraceId`/`SpanId` alongside the measurement (exemplar)
2. The exemplar reservoir decides which measurements to keep (sampling)
3. Exporters that support exemplars (OTLP) include them in the exported data
4. Visualization tools (Grafana, Jaeger) can link from the metric data point
   to the trace

### Exemplar Reservoirs

The SDK provides default reservoirs:

| Reservoir | Behavior |
|-----------|----------|
| `AlignedHistogramBucketExemplarReservoir` | One exemplar per histogram bucket (default for histograms) |
| `SimpleFixedSizeExemplarReservoir` | Fixed-size pool, randomly samples |

You typically don't configure these directly — the SDK selects appropriate defaults based on instrument type.

See [OTel .NET: Using Exemplars](https://opentelemetry.io/docs/languages/dotnet/metrics/exemplars/).

---

## Aggregation Defaults

The SDK applies default aggregations based on instrument type. You can override these via **Views**:

| Instrument | Default Aggregation |
|------------|---------------------|
| Counter | Sum (monotonic) |
| UpDownCounter | Sum (non-monotonic) |
| Histogram | Explicit Bucket Histogram |
| Gauge | Last Value |
| ObservableCounter | Sum (monotonic) |
| ObservableGauge | Last Value |
| ObservableUpDownCounter | Sum (non-monotonic) |

### Overriding Aggregation with Views

```csharp
builder.Services.AddOpenTelemetry()
    .WithMetrics(metrics => metrics
        .AddMeter("MyCompany.MyProduct")
        // Change a histogram to use custom bucket boundaries
        .AddView("myapp.request.duration", new ExplicitBucketHistogramConfiguration
        {
            Boundaries = new double[] { 0, 5, 10, 25, 50, 75, 100, 250, 500, 1000 }
        })
        // Drop an instrument entirely
        .AddView("myapp.internal.debug_metric", MetricStreamConfiguration.Drop)
        // Rename an instrument for export
        .AddView(instrumentName: "myapp.old_name", name: "myapp.new_name"));
```

---

## Units Guidance

Follow the [OTel semantic conventions for units](https://opentelemetry.io/docs/specs/semconv/general/metrics/):

### UCUM Notation

OTel uses [UCUM (Unified Code for Units of Measure)](https://ucum.org/) notation:

| Unit | Notation | Example |
|------|----------|---------|
| seconds | `s` | `"s"` |
| milliseconds | `ms` | `"ms"` |
| bytes | `By` | `"By"` |
| bits | `bit` | `"bit"` |
| percent | `%` | `"%"` |
| count (annotated) | `{request}` | `"{request}"` |
| count (annotated) | `{order}` | `"{order}"` |
| count (annotated) | `{connection}` | `"{connection}"` |

### Annotated Units

Use curly braces for "annotated" units — units that represent a count of something specific: `{request}`, `{order}`, `{connection}`, `{message}`. This distinguishes them from plain integers and enables backends to interpret them more semantically.

### Rules

- Always specify a unit (even if it's `1` for dimensionless)
- Use UCUM notation, not arbitrary strings (`"ms"` not `"milliseconds"`)
- For counts, use annotated units: `"{order}"` not `"count"` or `"orders"`
- The SDK does NOT validate units (per spec) — be consistent within your codebase

---

## References

- [OTel Metrics API Specification](https://opentelemetry.io/docs/specs/otel/metrics/api/)
- [OTel Metrics SDK Specification](https://opentelemetry.io/docs/specs/otel/metrics/sdk/)
- [OTel .NET: Metric Instruments](https://opentelemetry.io/docs/languages/dotnet/metrics/instruments/)
- [OTel .NET: Using Exemplars](https://opentelemetry.io/docs/languages/dotnet/metrics/exemplars/)
- [OTel .NET: Metrics Best Practices](https://opentelemetry.io/docs/languages/dotnet/metrics/best-practices/)
- [OTel Semantic Conventions: General Metrics](https://opentelemetry.io/docs/specs/semconv/general/metrics/)
- [OTel Exemplar Specification](https://opentelemetry.io/docs/specs/otel/metrics/sdk/#exemplar)
- [OTel Aggregation Specification](https://opentelemetry.io/docs/specs/otel/metrics/sdk/#aggregation)
- [OTel Cardinality Limits (.NET)](https://github.com/open-telemetry/opentelemetry-dotnet/blob/main/docs/metrics/README.md#cardinality-limits)
- [UCUM Units of Measure](https://ucum.org/)