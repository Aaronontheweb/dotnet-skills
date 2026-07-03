# Traces and Context Propagation Reference

Detailed reference for OpenTelemetry tracing patterns in .NET, covering SpanKind
selection, span links, context propagation, baggage, and exception recording.

This is a companion to [SKILL.md](SKILL.md). See it for core principles and the
"System.Diagnostics first" architecture.

## Table of Contents

- [SpanKind Deep Dive](#spankind-deep-dive)
- [Span Links](#span-links)
- [Context Propagation](#context-propagation)
- [Baggage](#baggage)
- [Nested Spans](#nested-spans)
- [Full Exception Recording Pattern](#full-exception-recording-pattern)
- [References](#references)

---

## SpanKind Deep Dive

`ActivityKind` (called `SpanKind` in the OTel spec) clarifies a span's relationship
to other spans. It describes two independent properties:

1. Whether a span represents an **outgoing call** (`Client`/`Producer`) or
   **incoming request processing** (`Server`/`Consumer`)
2. Whether a span is a **request/response** (`Client`/`Server`) or
   **deferred execution** (`Producer`/`Consumer`)

A single span SHOULD NOT serve more than one purpose. If you need to describe both
an incoming request and an outgoing call, create separate spans.

### Internal (Default)

In-process operations that do not cross a remote boundary.

```csharp
// ActivityKind.Internal is the default — both calls are equivalent
using var activity = ActivitySource.StartActivity("ProcessItem", ActivityKind.Internal);
// or simply: ActivitySource.StartActivity("ProcessItem");
```

**Use when**: the work happens entirely within the current process — business logic,
data transformation, internal computation.

### Server

Processing an incoming remote request.

```csharp
// HTTP server handler
using var activity = ActivitySource.StartActivity("HandleRequest", ActivityKind.Server);
activity?.SetTag("http.request.method", "GET");
activity?.SetTag("url.full", requestUrl);
activity?.SetTag("server.address", "myapp.example.com");
activity?.SetTag("server.port", 8080);
```

**Use when**: your code is the server side of a request/response interaction —
HTTP handler, gRPC service, RPC server, or custom protocol handler that sends a response.

**Key**: the OTel SDK's ASP.NET Core instrumentation automatically creates `Server`
spans for incoming HTTP requests. Only create your own `Server` span if you have a
custom transport (e.g., raw TCP listener, custom protocol).

### Client

Making an outgoing remote request.

```csharp
// Outgoing HTTP call
using var activity = ActivitySource.StartActivity("CallExternalApi", ActivityKind.Client);
activity?.SetTag("http.request.method", "POST");
activity?.SetTag("url.full", "https://api.example.com/orders");
activity?.SetTag("server.address", "api.example.com");
```

**Use when**: your code is the client side of a client/server interaction —
HTTP client call, database query, RPC invocation.

**Key**: the OTel SDK's HttpClient instrumentation automatically creates `Client`
spans for outgoing HTTP calls. Only create your own `Client` span for custom
transports not covered by built-in instrumentation.

**Guideline**: create the `Client` span **before** injecting its `SpanContext`
into the outgoing request headers. If you inject first, `Activity.Current` still
points to the parent span, so the parent's context propagates instead of the
`Client` span's context. The `Client` span then ends up dangling — it exists in
the trace but has no connection to the downstream call.

### Producer

Sending a deferred/asynchronous message to a remote destination.

```csharp
// Publishing to a message queue
using var activity = ActivitySource.StartActivity("PublishOrderEvent", ActivityKind.Producer);
activity?.SetTag("messaging.system", "rabbitmq");
activity?.SetTag("messaging.destination.name", "order.events");
activity?.SetTag("messaging.operation.name", "publish");
```

**Use when**: your code enqueues or publishes deferred work that will be processed
asynchronously later — message queue publish, event bus emit, job enqueue.

The key difference from `Client`: a `Client` span expects a response (request/response),
while a `Producer` span represents handing work to another component for later processing.
The context is propagated so the downstream `Consumer` span can link back.

### Consumer

Receiving and processing a deferred/asynchronous message.

```csharp
// Consuming from a message queue
using var activity = ActivitySource.StartActivity("ProcessOrderEvent", ActivityKind.Consumer);
activity?.SetTag("messaging.system", "rabbitmq");
activity?.SetTag("messaging.destination.name", "order.events");
activity?.SetTag("messaging.operation.name", "receive");
```

**Use when**: your code dequeues, receives, or processes deferred work that was
previously produced by a `Producer` span — message queue consume, background job
processing, event handler, job dequeue.

The `Consumer` span's parent is typically the `Producer` span (propagated via context),
creating a causal link across the asynchronous boundary.

### SpanKind Decision Flowchart

```
Is the work entirely in-process?
  → YES: ActivityKind.Internal
  → NO:  Is this processing an incoming request?
           → YES: Is it request/response (HTTP, gRPC, RPC)?
                    → YES: ActivityKind.Server
                    → NO (deferred/async): ActivityKind.Consumer
           → NO (outgoing): Is it request/response?
                    → YES: ActivityKind.Client
                    → NO (deferred/async): ActivityKind.Producer
```

---

## Span Links

[Span links](https://opentelemetry.io/docs/specs/otel/overview/#links-between-spans)
connect a span to other spans that are causally related but not in a direct
parent-child relationship. Links can point to spans in the same trace or across
different traces.

### When to Use Links

- **Batch processing**: a single span processes items from multiple upstream spans
- **Scatter/gather (fork/join)**: a root span fans out to multiple operations, then
  an aggregation span links back to all of them
- **Trace boundary crossing**: when a new trace is created at a trust boundary,
  link back to the originating trace
- **Fan-in**: multiple incoming messages trigger a single processing span

### Creating Links

```csharp
// ✅ CORRECT: Pass links at activity creation time
// (samplers can only consider links present during span creation)
var links = new List<ActivityLink>
{
    new(activityContext1),
    new(activityContext2),
    new(activityContext3)
};

var activity = MyActivitySource.StartActivity(
    ActivityKind.Internal,
    name: "batch-process",
    links: links);
```

### Batch Processing Example

```csharp
// Each incoming item has its own trace context
// The batch span links to all of them
public async Task ProcessBatchAsync(List<ActivityContext> itemContexts)
{
    var links = itemContexts.Select(ctx => new ActivityLink(ctx)).ToList();

    using var batchActivity = ActivitySource.StartActivity(
        ActivityKind.Internal,
        name: "ProcessBatch",
        links: links);

    if (batchActivity?.IsAllDataRequested == true)
    {
        batchActivity.SetTag("batch.item_count", itemContexts.Count);
    }

    foreach (var itemContext in itemContexts)
    {
        await ProcessItemAsync(itemContext);
    }
}
```

### Scatter/Gather Example

```csharp
// Fan out to multiple workers, then aggregate results
public async Task<AggregatedResult> ScatterGatherAsync(List<Input> inputs)
{
    // Capture each worker's ActivityContext during execution
    var results = await Task.WhenAll(inputs.Select(async input =>
    {
        using var workerActivity = ActivitySource.StartActivity("ProcessWorker", ActivityKind.Internal);
        await ProcessWorkerAsync(input);
        return (input, workerActivity?.Context);
    }));

    // The aggregation span links back to all worker spans
    var links = results
        .Where(r => r.Context != default)
        .Select(r => new ActivityLink(r.Context))
        .ToList();

    using var aggregateActivity = ActivitySource.StartActivity(
        ActivityKind.Internal,
        name: "AggregateResults",
        links: links);

    return Aggregate(results.Select(r => r.input));
}
```

### Trace Boundary Crossing

When a service creates a new trace rather than trusting the incoming context
(e.g., at a security/trust boundary), link back to the originating trace.
To create a true root span, you must clear `Activity.Current` first — otherwise
`StartActivity` will use the current activity as the parent:

```csharp
public async Task HandleUntrustedRequest(ActivityContext incomingContext)
{
    // Link to the incoming context
    var links = new List<ActivityLink> { new(incomingContext) };

    // Clear Activity.Current to force a root span (new trace)
    var previousActivity = Activity.Current;
    Activity.Current = null;
    try
    {
        using var activity = ActivitySource.StartActivity(
            ActivityKind.Server, name: "HandleRequest", links: links);

        // This is now a root span linked to the incoming trace
        await ProcessRequestAsync();
    }
    finally
    {
        Activity.Current = previousActivity; // restore context
    }
}
```

### Link Best Practices

1. **Add links at creation time** — samplers can only consider links present during
   span creation. Adding links later is possible but won't affect sampling.
2. **Use links, not parent, for multi-origin spans** — the parent field represents a
   single parent; links represent multiple causal relationships.
3. **Don't set a parent for scatter/gather aggregation** — the aggregation span is
   linked to many spans, not a child of any single one.
4. **Use sparingly** — links add overhead; only use them when there is a genuine
   causal relationship that parent/child doesn't capture.

See [OTel .NET: Creating links between traces](https://opentelemetry.io/docs/languages/dotnet/traces/links-creation/).

---

## Context Propagation

[Distributed tracing](https://opentelemetry.io/docs/specs/otel/context/) requires
propagating trace context across process boundaries. In .NET, this is handled by
`DistributedContextPropagator`, which serializes/deserializes the `SpanContext`
(SpanContext portion) and `Baggage` into and out of carrier objects (HTTP headers,
message metadata, etc.).

### W3C TraceContext

The default and recommended propagation format is [W3C TraceContext](https://www.w3.org/TR/trace-context/),
which uses the `traceparent` and `tracestate` HTTP headers:

```
traceparent: 00-0af7651916cd43dd8448eb211c80319c-b7ad6b7169203331-01
             version-traceid-spanid-flags
```

The OTel .NET SDK configures W3C TraceContext propagation by default. .NET 7+ also
defaults to W3C format for `Activity` ID format.

### Automatic Propagation

For standard transports (HttpClient, ASP.NET Core), propagation is automatic when
using the OTel instrumentation libraries:

```csharp
// Application setup (NOT library code)
builder.Services.AddOpenTelemetry()
    .WithTracing(tracing => tracing
        .AddAspNetCoreInstrumentation()  // auto-extracts incoming context
        .AddHttpClientInstrumentation()   // auto-injects outgoing context
        .AddOtlpExporter());
```

With these, you do NOT need to manually propagate context for HTTP calls.

### Manual Propagation (Custom Transports)

For non-standard transports (raw TCP, custom protocols, message systems without
built-in instrumentation), use the OTel SDK's `TextMapPropagator` (from
`OpenTelemetry.Context.Propagation`, requires an OTel NuGet package at the
application root) to manually inject/extract context:

```csharp
using OpenTelemetry.Context.Propagation;

// ✅ Manual inject for outgoing call
using var activity = ActivitySource.StartActivity("SendMessage", ActivityKind.Client);

if (activity != null)
{
    var headers = new Dictionary<string, string>();
    var propagator = Propagators.DefaultTextMapPropagator;
    propagator.Inject(new PropagationContext(activity.Context, Baggage.Current),
        headers,
        static (carrier, name, value) => ((Dictionary<string, string>)carrier!)[name] = value!);

    await SendMessageAsync(payload, headers);
}
```

```csharp
// ✅ Manual extract for incoming request
var propagator = Propagators.DefaultTextMapPropagator;
var extracted = propagator.Extract(default, incomingHeaders,
    static (carrier, name) =>
    {
        if (((Dictionary<string, string>)carrier!).TryGetValue(name, out var value))
            return new[] { value };
        return null;
    });

// Create a server span with the extracted parent context
using var activity = ActivitySource.StartActivity(
    ActivityKind.Server,
    name: "ReceiveMessage",
    parentId: extracted.ActivityContext.TraceId != default
        ? extracted.ActivityContext
        : default);
```

For library code (no OTel packages), use the built-in `DistributedContextPropagator`
APIs: `DistributedContextPropagator.Current.Inject(activity, carrier, setter)` for
injection, and `DistributedContextPropagator.Current.ExtractTraceIdAndState(...)`
for extraction. These use the same `traceparent` header format.

### Custom Propagators

You can configure which propagators are active. For example, to support both
W3C TraceContext and Baggage propagation (the OTel default composite):

```csharp
// Application setup
Sdk.SetDefaultTextMapPropagator(new CompositeTextMapPropagator(
    new TextMapPropagator[]
    {
        new TraceContextPropagator(),   // W3C traceparent
        new BaggagePropagator()         // W3C baggage
    }));
```

### B3 Propagator (Legacy Compatibility)

If you need to interoperate with systems using the [B3 propagation format](https://github.com/openzipkin/b3-propagation)
(Zipkin-style), install `OpenTelemetry.Extensions.Propagators` and configure:

```csharp
Sdk.SetDefaultTextMapPropagator(new CompositeTextMapPropagator(
    new TextMapPropagator[]
    {
        new TraceContextPropagator(),
        new BaggagePropagator(),
        new B3Propagator()  // legacy B3 multi-header format
    }));
```

---

## Baggage

[Baggage](https://opentelemetry.io/docs/specs/otel/baggage/) is a mechanism for
propagating name/value pairs across service boundaries within a distributed trace.
It is intended for **observability correlation** — not for general-purpose
application data transport.

### When to Use Baggage

- A web service needs to know what upstream service sent the request
- A SaaS provider needs to include the API user/token responsible for a request
- Correlating a failure to a specific browser version across services

### When NOT to Use Baggage

- Application business logic data (use your own headers/protocol)
- Large payloads (baggage has size limits)
- Security-sensitive data (baggage is not encrypted)

### .NET Baggage API

**Library code** (no OTel packages): use `Activity.Current?.SetBaggage()` —
this is built into `System.Diagnostics.Activity`:

```csharp
// ✅ Set baggage in library code (no OTel package needed)
Activity.Current?.SetBaggage("tenant.id", tenantId);
Activity.Current?.SetBaggage("request.source", "mobile-app");
```

**Application code** (with OTel SDK): use `Baggage.Current` from
`OpenTelemetry.Context.Baggage` — this provides a process-wide baggage API
independent of the current Activity:

```csharp
using OpenTelemetry.Context.Baggage;

// ✅ Read baggage in application code
var tenantId = Baggage.Current.GetBaggage("tenant.id");
var requestSource = Baggage.Current.GetBaggage("request.source");

// Use baggage values as span attributes
activity?.SetTag("tenant.id", tenantId);
activity?.SetTag("request.source", requestSource);
```

Propagation happens automatically via the `BaggagePropagator` (configured as part
of the default composite propagator).

### Baggage Rules

- Baggage keys and values are strings
- Keys must match the pattern: `[a-z0-9][-a-z0-9._*]*[a-z0-9]` (lowercase)
- The total baggage size SHOULD be limited (typically 180 characters per entry,
  max 64 entries per the [W3C baggage spec](https://www.w3.org/TR/baggage/))
- Baggage is propagated alongside trace context via the same HTTP headers mechanism
- Do NOT use baggage for high-cardinality or sensitive data

---

## Nested Spans

Nested spans track work that is hierarchical in nature. The parent/child relationship
is established automatically via `AsyncLocal<Activity>` flow. Use explicit `using`
blocks to control when each span ends — `Activity.Current` is restored to the
parent when the inner `using` block disposes:

```csharp
public async Task ProcessOrderAsync(Order order)
{
    using (var parentActivity = ActivitySource.StartActivity("ProcessOrder", ActivityKind.Internal))
    {
        // Child span — parented to ProcessOrder via AsyncLocal
        using (var childActivity = ActivitySource.StartActivity("ValidateOrder", ActivityKind.Internal))
        {
            await ValidateAsync(order);
        } // childActivity disposed → Activity.Current restored to parentActivity

        // Sibling span — also parented to ProcessOrder (not to ValidateOrder)
        using (var dbActivity = ActivitySource.StartActivity("SaveOrder", ActivityKind.Internal))
        {
            await SaveAsync(order);
        }
    }
}
```

**Rules**:
- Parent/child is automatic — do not set `parentId` manually for in-process nesting
- Use explicit `using` blocks (not `using var`) when you need the parent restored
  before starting a sibling span
- The child span's `ParentId` will be the parent's `SpanId`
- Never start activities in fire-and-forget tasks where the `using` scope ends before
  the work completes (the `AsyncLocal` context is lost when the task detaches)

---

## Full Exception Recording Pattern

The modern .NET approach uses `Activity.SetStatus()` as the primary mechanism.
The OTel SDK translates `ActivityStatusCode` into the proper OTel span status.

### Basic Pattern

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
        // Set error status with description
        activity.SetStatus(ActivityStatusCode.Error, ex.Message);

        // Record exception as an event per OTel semantic conventions
        activity.AddEvent(new ActivityEvent(
            "exception",
            tags: new ActivityTagsCollection
            {
                ["exception.type"] = ex.GetType().FullName,
                ["exception.message"] = ex.Message,
                // exception.stacktrace is Recommended by the span-event convention.
                // Include it unless size, sensitivity, or volume policy says otherwise.
                // For high-volume handled exceptions, prefer ILogger with trace correlation.
                // ["exception.stacktrace"] = ex.ToString()
            }
        ));
    }
    throw;
}
```

### With Status Code Attributes

For HTTP and other protocol handlers, also set the response status as a tag:

```csharp
catch (HttpRequestException ex) when (ex.StatusCode != null)
{
    if (activity != null)
    {
        activity.SetStatus(ActivityStatusCode.Error, ex.Message);
        activity.SetTag("http.response.status_code", (int)ex.StatusCode);
        activity.AddEvent(new ActivityEvent("exception", tags: new ActivityTagsCollection
        {
            ["exception.type"] = ex.GetType().FullName,
            ["exception.message"] = ex.Message,
            // Include exception.stacktrace unless size, sensitivity, or volume policy says otherwise
        }));
    }
    throw;
}
```

### Legacy Compatibility

The manual `otel.status_code` and `otel.status_description` **tags** were required
in early OTel .NET versions before `Activity.SetStatus()` was available:

```csharp
// ❌ LEGACY — no longer needed, prefer SetStatus
activity.SetTag("otel.status_code", "error");
activity.SetTag("otel.status_description", ex.Message);
```

Do NOT use these tags in new code. `Activity.SetStatus()` is the modern API and the
OTel SDK handles translation to the OTel span status fields automatically.

### Exception Event Attribute Reference

Per the [OTel exception span conventions](https://opentelemetry.io/docs/specs/semconv/exceptions/exceptions-spans/):

| Attribute | Required | Description |
|-----------|----------|-------------|
| `exception.type` | Yes (if available) | Fully qualified exception type name |
| `exception.message` | Yes (if available) | The exception message |
| `exception.stacktrace` | Recommended | String representation of the stack trace |
| `exception.escaped` | Optional | `true` if the exception escaped the span boundary |

---

## References

- [OTel SpanKind Specification](https://opentelemetry.io/docs/specs/otel/trace/api/#spankind)
- [OTel Links Between Spans](https://opentelemetry.io/docs/specs/otel/overview/#links-between-spans)
- [OTel Link API](https://opentelemetry.io/docs/specs/otel/trace/api/#link)
- [OTel Context Specification](https://opentelemetry.io/docs/specs/otel/context/)
- [OTel Baggage Specification](https://opentelemetry.io/docs/specs/otel/baggage/)
- [W3C Trace Context](https://www.w3.org/TR/trace-context/)
- [W3C Baggage](https://www.w3.org/TR/baggage/)
- [OTel .NET: Creating Links Between Traces](https://opentelemetry.io/docs/languages/dotnet/traces/links-creation/)
- [OTel .NET: Reporting Exceptions](https://opentelemetry.io/docs/languages/dotnet/traces/reporting-exceptions/)
- [OTel Exception Span Conventions](https://opentelemetry.io/docs/specs/semconv/exceptions/exceptions-spans/)
- [.NET Distributed Tracing Documentation](https://learn.microsoft.com/en-us/dotnet/core/diagnostics/distributed-tracing)