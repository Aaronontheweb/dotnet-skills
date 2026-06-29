# SDK Setup, Resources, Sampling, and Logs Reference

Detailed reference for OpenTelemetry SDK initialization, resource configuration,
exporters, instrumentation libraries, sampling, logs integration, and environment
variable configuration in .NET.

This is a companion to [SKILL.md](SKILL.md). See it for core principles and the
"System.Diagnostics first" architecture.

**Key principle**: SDK setup, resources, exporters, and sampling are **application
concerns** — they are configured at the application composition root, NOT in libraries.
Library authors use only `System.Diagnostics.*` and `ILogger`; the consuming application
wires up the OTel SDK.

## Table of Contents

- [SDK Initialization](#sdk-initialization)
- [Resources](#resources)
- [Exporters](#exporters)
- [Instrumentation Libraries](#instrumentation-libraries)
- [Sampling](#sampling)
- [Logs](#logs)
- [Environment Variable Configuration](#environment-variable-configuration)
- [Zero-Code Instrumentation](#zero-code-instrumentation)
- [References](#references)

---

## SDK Initialization

### ASP.NET Core / Generic Host

Use the `OpenTelemetry.Extensions.Hosting` package and the `AddOpenTelemetry()` builder:

```csharp
// Program.cs — Application code (NOT library code)
using OpenTelemetry.Logs;
using OpenTelemetry.Metrics;
using OpenTelemetry.Resources;
using OpenTelemetry.Trace;

var builder = WebApplication.CreateBuilder(args);

builder.Services.AddOpenTelemetry()
    .ConfigureResource(resource => resource
        .AddService(serviceName: "myapp", serviceVersion: "1.0.0"))
    .WithTracing(tracing => tracing
        .AddSource("MyApp.MyComponent")           // your ActivitySource
        .AddAspNetCoreInstrumentation()           // auto-trace HTTP requests
        .AddHttpClientInstrumentation()           // auto-trace HTTP client calls
        .AddOtlpExporter())                       // export via OTLP
    .WithMetrics(metrics => metrics
        .AddMeter("MyApp.OrderProcessing")        // your Meter
        .AddAspNetCoreInstrumentation()           // auto-collect ASP.NET Core metrics
        .AddRuntimeInstrumentation()              // .NET runtime metrics
        .AddOtlpExporter());

// Logs: configure on the logging builder
builder.Logging.AddOpenTelemetry(options => options
    .SetResourceBuilder(
        ResourceBuilder.CreateDefault().AddService("myapp", serviceVersion: "1.0.0"))
    .AddOtlpExporter());

var app = builder.Build();
app.Run();
```

**NuGet packages needed** (application only):

```bash
dotnet add package OpenTelemetry.Extensions.Hosting
dotnet add package OpenTelemetry.Exporter.OpenTelemetryProtocol
dotnet add package OpenTelemetry.Instrumentation.AspNetCore
dotnet add package OpenTelemetry.Instrumentation.Http
dotnet add package OpenTelemetry.Instrumentation.Runtime
```

### Console Application (No DI)

For console apps without the generic host, use the SDK directly:

```csharp
using OpenTelemetry;
using OpenTelemetry.Resources;
using OpenTelemetry.Trace;
using OpenTelemetry.Metrics;

var serviceName = "myapp";
var serviceVersion = "1.0.0";

// Traces
using var tracerProvider = Sdk.CreateTracerProviderBuilder()
    .AddSource(serviceName)
    .ConfigureResource(resource => resource
        .AddService(serviceName: serviceName, serviceVersion: serviceVersion))
    .AddConsoleExporter()
    .Build();

// Metrics
using var meterProvider = Sdk.CreateMeterProviderBuilder()
    .AddMeter(serviceName)
    .ConfigureResource(resource => resource
        .AddService(serviceName: serviceName, serviceVersion: serviceVersion))
    .AddConsoleExporter()
    .Build();

// Run your application...
```

### Logs (Console Application)

```csharp
using var loggerFactory = LoggerFactory.Create(builder => builder
    .AddOpenTelemetry(options =>
    {
        options.SetResourceBuilder(
            ResourceBuilder.CreateDefault().AddService("myapp"));
        options.AddOtlpExporter();
    }));

var logger = loggerFactory.CreateLogger<Program>();
logger.LogInformation("Application started");
```

### Important: Dispose Providers

Always dispose `TracerProvider` and `MeterProvider` (use `using` or call `.Dispose()`)
to flush buffered data to exporters on shutdown:

```csharp
// ✅ CORRECT: using ensures flush on exit
using var tracerProvider = Sdk.CreateTracerProviderBuilder()
    // ...
    .Build();

// ❌ WRONG: data may be lost on exit — no flush
var tracerProvider = Sdk.CreateTracerProviderBuilder()
    // ...
    .Build();
```

---

## Resources

[Resources](https://opentelemetry.io/docs/specs/otel/resource/) capture information
about the entity producing telemetry — "what" produced the signal. Every telemetry
signal (trace, metric, log) should carry a Resource so you can identify its origin.

### ResourceBuilder API

```csharp
// ✅ CORRECT: Use the fluent builder
var resourceBuilder = ResourceBuilder
    .CreateDefault()                    // auto-detects: service.name, service.instance.id, process info
    .AddService(                         // explicitly set service identity
        serviceName: "myapp",
        serviceVersion: "1.0.0")
    .AddAttributes(new Dictionary<string, object>
    {
        ["deployment.environment.name"] = "production",
        ["team.name"] = "backend",
        ["host.name"] = Environment.MachineName
    });
```

### What CreateDefault Detects

`ResourceBuilder.CreateDefault()` automatically populates:

| Attribute | Source |
|-----------|--------|
| `service.name` | From `OTEL_SERVICE_NAME` env var, or `unknown_service` if not set |
| `service.instance.id` | Auto-generated unique ID per process |
| `process.pid` | Current process ID |
| `process.runtime.name` | e.g., `.NET` |
| `process.runtime.version` | e.g., `8.0.0` |
| `host.name` | Machine name |

### Adding Custom Resources via ConfigureResource

When using `AddOpenTelemetry()`, configure resources for all signals at once:

```csharp
builder.Services.AddOpenTelemetry()
    .ConfigureResource(resource => resource
        .AddService("myapp", serviceVersion: "1.0.0")
        .AddAttributes(new Dictionary<string, object>
        {
            ["deployment.environment.name"] = builder.Configuration["Environment"],
            ["team.name"] = "payments-team"
        }));
```

### Custom Resource Detectors

Implement `IResourceDetector` for custom resource detection (e.g., reading from
cloud metadata endpoints, Kubernetes downward API):

```csharp
public class KubernetesResourceDetector : IResourceDetector
{
    public Resource Detect()
    {
        var attributes = new Dictionary<string, object>();

        // Read from Kubernetes downward API or environment
        var podName = Environment.GetEnvironmentVariable("POD_NAME");
        if (!string.IsNullOrEmpty(podName))
        {
            attributes["k8s.pod.name"] = podName;
        }

        var namespaceName = Environment.GetEnvironmentVariable("POD_NAMESPACE");
        if (!string.IsNullOrEmpty(namespaceName))
        {
            attributes["k8s.namespace.name"] = namespaceName;
        }

        return new Resource(attributes);
    }
}

// Register the detector
builder.Services.AddOpenTelemetry()
    .ConfigureResource(resource => resource
        .AddService("myapp")
        .AddDetector(new KubernetesResourceDetector()));
```

### Resource via Environment Variables

Set resources without code changes:

```bash
# Single attribute
export OTEL_SERVICE_NAME=myapp

# Multiple attributes (comma-separated)
export OTEL_RESOURCE_ATTRIBUTES="service.name=myapp,service.version=1.0.0,deployment.environment.name=production"
```

### Key Resource Semantic Conventions

| Attribute | Description | Source |
|-----------|-------------|--------|
| `service.name` | **Required** — logical service name | `AddService()` or env var |
| `service.version` | Service version | `AddService()` |
| `service.instance.id` | Unique instance ID (auto) | `CreateDefault()` |
| `deployment.environment.name` | Environment (staging, production) | `AddAttributes()` |
| `host.name` | Host machine name | `CreateDefault()` or manual |
| `process.pid` | Process ID | `CreateDefault()` |
| `process.runtime.name` | Runtime name | `CreateDefault()` |
| `process.runtime.version` | Runtime version | `CreateDefault()` |
| `k8s.pod.name` | Kubernetes pod name | Custom detector |
| `k8s.namespace.name` | Kubernetes namespace | Custom detector |
| `cloud.provider` | Cloud provider (aws, azure, gcp) | Custom detector |

See the [full resource semantic conventions](https://opentelemetry.io/docs/specs/semconv/resource/).

---

## Exporters

Exporters send telemetry data to observability backends. Configure them at the
application composition root.

### OTLP (Recommended for Production)

The [OTLP exporter](https://opentelemetry.io/docs/specs/otel/protocol/) sends data
to an OTLP-compatible collector or backend (Jaeger, Tempo, Honeycomb, Datadog, etc.):

```csharp
builder.Services.AddOpenTelemetry()
    .WithTracing(tracing => tracing
        .AddSource("MyApp.MyComponent")
        .AddOtlpExporter(options =>
        {
            options.Endpoint = new Uri("http://otel-collector:4317");
            options.Protocol = OtlpExportProtocol.Grpc;
        }))
    .WithMetrics(metrics => metrics
        .AddMeter("MyApp.OrderProcessing")
        .AddOtlpExporter(options =>
        {
            options.Endpoint = new Uri("http://otel-collector:4317");
            options.Protocol = OtlpExportProtocol.Grpc;
        }));
```

```bash
dotnet add package OpenTelemetry.Exporter.OpenTelemetryProtocol
```

Default endpoint: `http://localhost:4317` (gRPC) or `http://localhost:4318` (HTTP/protobuf).

Configure via environment variables:
```bash
export OTEL_EXPORTER_OTLP_ENDPOINT=http://otel-collector:4317
export OTEL_EXPORTER_OTLP_PROTOCOL=grpc
```

### Console (Development/Debug)

```csharp
.WithTracing(tracing => tracing
    .AddSource("MyApp.MyComponent")
    .AddConsoleExporter())
.WithMetrics(metrics => metrics
    .AddMeter("MyApp.OrderProcessing")
    .AddConsoleExporter())
```

```bash
dotnet add package OpenTelemetry.Exporter.Console
```

### Prometheus (Metrics Scrape Endpoint)

Exposes a `/metrics` endpoint for Prometheus scraping:

```csharp
builder.Services.AddOpenTelemetry()
    .WithMetrics(metrics => metrics
        .AddMeter("MyApp.OrderProcessing")
        .AddPrometheusExporter());

// Add the scrape endpoint middleware
app.UseOpenTelemetryPrometheusScrapingEndpoint();
```

```bash
dotnet add package OpenTelemetry.Exporter.Prometheus.AspNetCore
```

### Jaeger (Traces, Legacy)

> Note: Jaeger now supports OTLP natively. Prefer the OTLP exporter for new setups.

```csharp
.WithTracing(tracing => tracing
    .AddSource("MyApp.MyComponent")
    .AddJaegerExporter(options =>
    {
        options.AgentHost = "localhost";
        options.AgentPort = 6831;
    }));
```

```bash
dotnet add package OpenTelemetry.Exporter.Jaeger
```

### Zipkin (Traces)

```csharp
.WithTracing(tracing => tracing
    .AddSource("MyApp.MyComponent")
    .AddZipkinExporter(options =>
    {
        options.Endpoint = new Uri("http://zipkin:9411/api/v2/spans");
    }));
```

```bash
dotnet add package OpenTelemetry.Exporter.Zipkin
```

---

## Instrumentation Libraries

Instrumentation libraries automatically instrument common .NET libraries without
modifying application code. Add them at the application composition root:

| Library | Package | What it instruments |
|---------|---------|-------------------|
| ASP.NET Core | `OpenTelemetry.Instrumentation.AspNetCore` | Incoming HTTP requests (Server spans) |
| HttpClient | `OpenTelemetry.Instrumentation.Http` | Outgoing HTTP calls (Client spans) |
| SqlClient | `OpenTelemetry.Instrumentation.SqlClient` | SQL Server database calls (Client spans) |
| .NET Runtime | `OpenTelemetry.Instrumentation.Runtime` | GC, thread pool, JIT, exception metrics |
| Entity Framework Core | `OpenTelemetry.Instrumentation.EntityFrameworkCore` | EF Core database calls |
| gRPC | `OpenTelemetry.Instrumentation.GrpcNetClient` | gRPC client calls |
| StackExchange.Redis | `OpenTelemetry.Instrumentation.StackExchangeRedis` | Redis calls |
| PostgreSQL (Npgsql) | `Npgsql.OpenTelemetry` | PostgreSQL database calls |

### Example: Full Application Setup

```csharp
builder.Services.AddOpenTelemetry()
    .ConfigureResource(resource => resource
        .AddService("myapp", serviceVersion: "1.0.0"))
    .WithTracing(tracing => tracing
        // Your custom ActivitySources
        .AddSource("MyApp.OrderProcessing")
        // Auto-instrumentation
        .AddAspNetCoreInstrumentation()
        .AddHttpClientInstrumentation()
        .AddSqlClientInstrumentation()
        .AddEntityFrameworkCoreInstrumentation()
        // Export
        .AddOtlpExporter())
    .WithMetrics(metrics => metrics
        // Your custom Meters
        .AddMeter("MyApp.OrderProcessing")
        // Auto-instrumentation
        .AddAspNetCoreInstrumentation()
        .AddRuntimeInstrumentation()
        // Export
        .AddOtlpExporter());
```

### Filtering Instrumentation

Filter out noisy spans (e.g., health checks):

```csharp
.WithTracing(tracing => tracing
    .AddAspNetCoreInstrumentation(options =>
    {
        options.Filter = httpContext =>
        {
            // Don't trace health check endpoints
            return !httpContext.Request.Path.StartsWithSegments("/health");
        };
    }))
```

---

## Sampling

[Sampling](https://opentelemetry.io/docs/specs/otel/trace/sdk/#sampling) controls
which traces are recorded and exported. It reduces overhead and telemetry volume.
Sampling decisions are typically made at trace start (head-based sampling) and
propagated downstream via context.

### How Sampling Affects Instrumentation Authors

- Your spans may be sampled out — the `Activity` may be `null` even when
  `HasListeners()` returns true (the SDK decides based on the sampler)
- Always null-check `Activity` after `StartActivity`
- Samplers can consider attributes set at span creation time — set key attributes
  early if you want them to influence sampling decisions

### Built-in Samplers (.NET SDK)

The OTel .NET SDK defaults to `ParentBased(AlwaysOn)` — effectively always on,
but respecting parent sampling decisions for child spans.

| Sampler | Description |
|---------|-------------|
| `AlwaysOnSampler` | Records and samples every span |
| `AlwaysOffSampler` | Drops every span |
| `TraceIdRatioBasedSampler(ratio)` | Samples a fixed fraction of traces (0.0–1.0) |
| `ParentBasedSampler(root)` | Follows parent's sampling decision (recommended production default) |

### Configuring a Sampler in Code

```csharp
using var tracerProvider = Sdk.CreateTracerProviderBuilder()
    .AddSource("MyApp.MyComponent")
    // Use ParentBased with TraceIdRatioBased for root spans
    .SetSampler(new ParentBasedSampler(
        new TraceIdRatioBasedSampler(0.1)))  // 10% of root spans
    .AddOtlpExporter()
    .Build();
```

### With AddOpenTelemetry()

```csharp
builder.Services.AddOpenTelemetry()
    .WithTracing(tracing => tracing
        .AddSource("MyApp.MyComponent")
        .SetSampler(new ParentBasedSampler(
            new TraceIdRatioBasedSampler(0.1)))
        .AddOtlpExporter());
```

### Configuring via Environment Variables

```bash
# Always sample (default)
export OTEL_TRACES_SAMPLER=always_on

# Never sample
export OTEL_TRACES_SAMPLER=always_off

# Ratio-based sampling (10%)
export OTEL_TRACES_SAMPLER=traceidratio
export OTEL_TRACES_SAMPLER_ARG=0.1

# Parent-based with ratio for roots
export OTEL_TRACES_SAMPLER=parentbased_traceidratio
export OTEL_TRACES_SAMPLER_ARG=0.1
```

### ParentBased Explained

`ParentBased` is the recommended production sampler. It delegates to sub-samplers
based on the parent context:

| Parent State | Sampler Invoked | Default |
|-------------|-----------------|---------|
| No parent (root span) | `root` | You configure this |
| Remote parent, sampled | `remoteParentSampled` | AlwaysOn |
| Remote parent, not sampled | `remoteParentNotSampled` | AlwaysOff |
| Local parent, sampled | `localParentSampled` | AlwaysOn |
| Local parent, not sampled | `localParentNotSampled` | AlwaysOff |

This ensures child spans follow their parent's sampling decision, maintaining
trace completeness. Only root spans are subject to the ratio-based decision.

### Custom Sampler

Implement a custom sampler by extending `Sampler`:

```csharp
public class HealthCheckExcludingSampler : Sampler
{
    private readonly TraceIdRatioBasedSampler _fallback;

    public HealthCheckExcludingSampler(double ratio)
    {
        _fallback = new TraceIdRatioBasedSampler(ratio);
    }

    public override SamplingResult ShouldSample(in SamplingParameters parameters)
    {
        // Drop health check spans entirely
        if (parameters.Name != null && parameters.Name.Contains("health"))
        {
            return new SamplingResult(SamplingDecision.Drop);
        }

        // Delegate to ratio-based for everything else
        return _fallback.ShouldSample(parameters);
    }
}
```

```csharp
.SetSampler(new ParentBasedSampler(new HealthCheckExcludingSampler(0.1)))
```

### Head-Based vs. Tail-Based Sampling

**Head-based sampling** (default in OTel): the sampling decision is made when the
trace starts, at the root span. All child spans inherit the decision. Simple,
low-overhead, but you can't sample based on downstream information (e.g., "keep
all traces that had an error").

**Tail-based sampling**: the decision is made after the trace completes, based on
the full trace data. This allows sampling rules like "keep 100% of error traces,
10% of successful traces." Tail-based sampling is typically implemented in the
[OTel Collector](https://opentelemetry.io/docs/collector/), not in the SDK.

For .NET-specific tail-based sampling patterns, see
[OTel .NET: Tail-Based Sampling](https://opentelemetry.io/docs/languages/dotnet/traces/tail-based-sampling/).

---

## Logs

OpenTelemetry logs integrate with the built-in `Microsoft.Extensions.Logging.ILogger`
API. The OTel SDK provides `AddOpenTelemetry()` on the logging builder to collect,
process, and export log data.

### How .NET Logs Work with OTel

Per the [MS Learn documentation](https://learn.microsoft.com/en-us/dotnet/core/diagnostics/observability-with-otel),
.NET provides logging APIs in the framework. OTel collects from these APIs and
exports them:

```
ILogger.Log() → OpenTelemetry LoggerProvider → Processors → Exporters → Backend
```

### ASP.NET Core Setup

```csharp
builder.Logging.AddOpenTelemetry(options =>
{
    options.SetResourceBuilder(
        ResourceBuilder.CreateDefault().AddService("myapp", serviceVersion: "1.0.0"));
    options.AddOtlpExporter();
    // Optional: include formatted log state as a field
    options.IncludeFormattedMessage = true;
    options.ParseStateValues = true;
});
```

When using `AddOpenTelemetry()` on `builder.Services`, logs are configured separately
on `builder.Logging`.

### Log Correlation with Traces

Logs are automatically correlated with traces. When a log is emitted within an active
span, the OTel SDK includes the current `TraceId` and `SpanId` in the log record:

```csharp
// This log will automatically carry TraceId/SpanId from the current Activity
logger.LogInformation("Processing order {OrderId} for customer {CustomerId}",
    orderId, customerId);
```

The log record's `TraceId`/`SpanId` can be used in observability backends to filter
logs by trace, jump from a trace to its logs, or correlate across services.

### Structured Logging

Use `ILogger` structured logging (template with named placeholders):

```csharp
// ✅ CORRECT: Structured logging with named placeholders
logger.LogInformation("Order {OrderId} processed in {DurationMs}ms",
    orderId, duration.TotalMilliseconds);

// ❌ WRONG: String interpolation loses structure
logger.LogInformation($"Order {orderId} processed in {duration.TotalMilliseconds}ms");
```

Structured logging preserves the semantic meaning of each parameter — backends can
index, filter, and query by `OrderId` as a structured field, not just as text.

### Log Redaction

For sensitive data, implement a custom processor or use the logging pipeline:

```csharp
public class RedactingLogProcessor : BaseProcessor<LogRecord>
{
    private static readonly Regex EmailRegex = new(@"\b[\w.-]+@[\w.-]+\.\w+\b",
        RegexOptions.Compiled);

    public override void OnEnd(LogRecord record)
    {
        if (record.FormattedMessage != null)
        {
            // Redact email addresses
            // Note: modify the record or drop it based on your needs
        }
    }
}

builder.Logging.AddOpenTelemetry(options =>
{
    options.AddProcessor(new RedactingLogProcessor());
    options.AddOtlpExporter();
});
```

See [OTel .NET: Log Redaction](https://opentelemetry.io/docs/languages/dotnet/logs/redaction/).

### Severity and Filtering

The OTel logs SDK supports severity-based filtering:

```csharp
builder.Logging.AddOpenTelemetry(options =>
{
    // Only export logs at Warning or above
    options.AddOtlpExporter();
});
```

Standard ASP.NET Core log level filtering applies:

```csharp
builder.Logging.AddFilter<OpenTelemetryLoggerProvider>("Microsoft", LogLevel.Warning);
```

The OTel spec also defines `LoggerConfig` with:
- `enabled`: whether the logger is active (default: `true`)
- `minimum_severity`: minimum severity number for processing
- `trace_based`: drop logs associated with unsampled traces (default: `false`)

### Dedicated Logging Pipeline

You can route specific logs to a dedicated pipeline (e.g., audit logs to a separate
backend):

```csharp
// Route audit logs to a separate OTLP destination
builder.Logging.AddFilter("MyApp.Audit", logLevel => true)
    .AddOpenTelemetry(options =>
    {
        options.AddOtlpExporter(o =>
            o.Endpoint = new Uri("http://audit-collector:4317"));
    });
```

See [OTel .NET: Dedicated Logging Pipeline](https://opentelemetry.io/docs/languages/dotnet/logs/dedicated-pipeline/).

### Logging Complex Objects

```csharp
// Objects are serialized as structured fields
logger.LogInformation("Order processed: {Order}", order);

// For complex objects, use a custom converter or log individual fields
logger.LogInformation("Order {OrderId} total: {Total:C} items: {ItemCount}",
    order.Id, order.Total, order.Items.Count);
```

See [OTel .NET: Logging Complex Objects](https://opentelemetry.io/docs/languages/dotnet/logs/complex-objects/).

---

## Environment Variable Configuration

The OTel SDK reads configuration from environment variables with the `OTEL_` prefix.
These are useful for deployment without code changes.

### General SDK Configuration

| Variable | Description | Example |
|----------|-------------|---------|
| `OTEL_SERVICE_NAME` | Service name | `myapp` |
| `OTEL_RESOURCE_ATTRIBUTES` | Resource attributes (comma-separated) | `service.version=1.0.0,deployment.environment.name=prod` |
| `OTEL_LOG_LEVEL` | SDK log level | `info` |

### Traces

| Variable | Description | Example |
|----------|-------------|---------|
| `OTEL_TRACES_SAMPLER` | Sampler to use | `parentbased_traceidratio` |
| `OTEL_TRACES_SAMPLER_ARG` | Sampler argument | `0.1` |
| `OTEL_TRACES_EXPORTER` | Trace exporter | `otlp` |
| `OTEL_BSP_SCHEDULE_DELAY` | Batch processor delay | `5000` |

### Metrics

| Variable | Description | Example |
|----------|-------------|---------|
| `OTEL_METRICS_EXPORTER` | Metrics exporter | `otlp` |
| `OTEL_METRICS_EXPORT_INTERVAL` | Export interval (ms) | `60000` |
| `OTEL_DOTNET_EXPERIMENTAL_METRICS_CARDINALITY_LIMIT` | Max attribute combinations | `2000` |

### Exporter (OTLP)

| Variable | Description | Example |
|----------|-------------|---------|
| `OTEL_EXPORTER_OTLP_ENDPOINT` | OTLP endpoint | `http://collector:4317` |
| `OTEL_EXPORTER_OTLP_PROTOCOL` | Protocol | `grpc` or `http/protobuf` |
| `OTEL_EXPORTER_OTLP_HEADERS` | Headers (comma-separated) | `key1=val1,key2=val2` |

See the [full environment variable reference](https://opentelemetry.io/docs/specs/otel/configuration/sdk-environment-variables/).

---

## Zero-Code Instrumentation

For applications where you cannot modify source code, use the
[OpenTelemetry .NET Automatic Instrumentation](https://opentelemetry.io/docs/zero-code/net/).
This injects instrumentation at runtime without code changes:

```bash
# Install
curl -sSfL https://github.com/open-telemetry/opentelemetry-dotnet-instrumentation/releases/latest/download/otel-dotnet-auto-install.sh -O
sh ./otel-dotnet-auto-install.sh

# Enable
. $HOME/.otel-dotnet-auto/instrument.sh

# Run with instrumentation
OTEL_SERVICE_NAME=myapp OTEL_EXPORTER_OTLP_ENDPOINT=http://collector:4317 ./MyApp
```

This is an alternative to manual SDK setup — useful for existing applications,
brownfield deployments, and when source changes are not possible.

---

## References

- [OTel .NET: Manual Instrumentation](https://opentelemetry.io/docs/languages/dotnet/instrumentation/)
- [OTel .NET: Resources](https://opentelemetry.io/docs/languages/dotnet/resources/)
- [OTel .NET: Sampling](https://opentelemetry.io/docs/languages/dotnet/sampling/)
- [OTel .NET: Logs](https://opentelemetry.io/docs/languages/dotnet/logs/)
- [OTel .NET: Exporters](https://opentelemetry.io/docs/languages/dotnet/exporters/)
- [OTel Resource Specification](https://opentelemetry.io/docs/specs/otel/resource/)
- [OTel Logs Specification](https://opentelemetry.io/docs/specs/otel/logs/)
- [OTel Logs SDK Specification](https://opentelemetry.io/docs/specs/otel/logs/sdk/)
- [OTel Tracing SDK: Sampling](https://opentelemetry.io/docs/specs/otel/trace/sdk/#sampling)
- [OTel Configuration: SDK Environment Variables](https://opentelemetry.io/docs/specs/otel/configuration/sdk-environment-variables/)
- [OTel .NET: Zero-Code Instrumentation](https://opentelemetry.io/docs/zero-code/net/)
- [OTel .NET: Tail-Based Sampling](https://opentelemetry.io/docs/languages/dotnet/traces/tail-based-sampling/)
- [OTel .NET: Stratified Sampling](https://opentelemetry.io/docs/languages/dotnet/traces/stratified-sampling/)
- [OTel .NET: Log Redaction](https://opentelemetry.io/docs/languages/dotnet/logs/redaction/)
- [OTel .NET: Dedicated Logging Pipeline](https://opentelemetry.io/docs/languages/dotnet/logs/dedicated-pipeline/)
- [OTel .NET: Log Correlation](https://opentelemetry.io/docs/languages/dotnet/logs/correlation/)
- [OTel .NET: Logging Complex Objects](https://opentelemetry.io/docs/languages/dotnet/logs/complex-objects/)
- [OTel .NET: Export to Jaeger](https://opentelemetry.io/docs/languages/dotnet/traces/jaeger/)
- [OTel .NET: Export to Prometheus](https://opentelemetry.io/docs/languages/dotnet/metrics/getting-started-prometheus-grafana/)
- [OTel Semantic Conventions: Resource](https://opentelemetry.io/docs/specs/semconv/resource/)
- [.NET Observability with OpenTelemetry (Microsoft Learn)](https://learn.microsoft.com/en-us/dotnet/core/diagnostics/observability-with-otel)