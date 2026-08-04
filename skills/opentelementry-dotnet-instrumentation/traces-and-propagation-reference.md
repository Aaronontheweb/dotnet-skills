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
2. Whether the communication is **synchronous** — the caller awaits a response
   (`Client`/`Server`, request/response) — or **asynchronous** — the initiator
   hands off work and does not wait for the outcome (`Producer`/`Consumer`,
   deferred execution)

| ActivityKind | Call direction | Communication style              |
|--------------|----------------|----------------------------------|
| `Client`     | outgoing       | synchronous (request/response)   |
| `Server`     | incoming       | synchronous (request/response)   |
| `Producer`   | outgoing       | asynchronous (deferred execution)|
| `Consumer`   | incoming       | asynchronous (deferred execution)|
| `Internal`   | — (in-process) | —                                |

A single span SHOULD NOT serve more than one purpose. If you need to describe both
an incoming request and an outgoing call, create separate spans — e.g., a `Server`
span handling a request SHOULD NOT also describe an outgoing call it makes; that
call is its own `Client` (or `Producer`) child span.

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
activity?.SetTag("url.path", "/orders");
activity?.SetTag("url.scheme", "https");
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

**Use when**: your code makes any **synchronous** outgoing remote call — one where
it awaits the response — HTTP client call, database query, cache lookup, RPC
invocation. `Client` is not limited to RPC: a SQL query or Redis `GET` is a
`Client` span because the caller blocks for the result.

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

The key difference from `Client`: a `Client` span awaits a response (request/response),
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

The `Consumer` span's parent is typically the `Producer` span (the propagated
message creation context), creating a causal link across the asynchronous boundary.
Note that per the
[messaging semantic conventions](https://opentelemetry.io/docs/specs/semconv/messaging/messaging-spans/),
only the `process` operation is kind `Consumer` — a pull-based `receive` is kind
`Client`, because pulling from the broker is a synchronous request/response with
the broker. The semconv also supports parenting the `process` span under the local
ambient context with a span link back to the producer — see
[Messaging Consumer Parenting Example](#messaging-consumer-parenting-example).

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
- **Trust boundary crossing**: when a new trace is created at a trust boundary,
  link back to the originating trace
- **Fan-in**: multiple incoming messages trigger a single processing span
- **Messaging consumer parenting**: a `process` span parented under the local
  ambient context links back to the message's creation context (see below)

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

### Trust Boundary Crossing

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

### Messaging Consumer Parenting Example

The [messaging semantic conventions](https://opentelemetry.io/docs/specs/semconv/messaging/messaging-spans/) allow — and default to — parenting the `process` span under the local ambient context instead of the producer, with a **span link** to the producer's message creation context. In a pull-based consumer that ambient parent is the `receive` span, which the semconv assigns kind `Client` (pulling from the broker is a synchronous request/response with the broker; only the `process` span is `Consumer`):

```
Producer service                     Consumer service (pull-based)
────────────────                     ─────────────────────────────
send order.events (PRODUCER) ──┐     poll loop (INTERNAL)
                               │       └─ receive (CLIENT)  ← sync call to broker
     creation context          │            └─ process (CONSUMER)
     travels in the message    └──────────────── link ──────┘
```

Here the `Consumer` span's direct parent is a `Client` span; the producer relationship is expressed as a link, not parenthood. If you instead parent the `process` span directly under the producer's creation context, the semconv says the ambient context SHOULD be added as a link on the `process` span to preserve that correlation.

```csharp
// process span: parented under the ambient context (the Client receive span),
// linked to the message's creation context extracted from the message headers
var creationContext = ExtractContext(message.Headers); // via Propagator, see below

using var processActivity = ActivitySource.StartActivity(
    ActivityKind.Consumer,
    name: "ProcessOrderEvent",
    links: [new ActivityLink(creationContext)]);
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
built-in instrumentation), the default choice is the built-in `System.Diagnostics.DistributedContextPropagator` — it ships with the runtime (`System.Diagnostics.DiagnosticSource`, .NET 6+), so a library or custom transport needs **zero** OTel packages to propagate context. This follows the same "System.Diagnostics first" rule as `ActivitySource` vs `OpenTelemetry.Api`: the propagation API is already in the framework.

This is also exactly what the platform itself does: `HttpClient` (SocketsHttpHandler) and ASP.NET Core inject/extract `traceparent`/`tracestate`/ baggage through `DistributedContextPropagator.Current`. A custom transport that uses the same mechanism behaves identically to the built-in ones, and the
application root keeps control of propagation policy by setting `DistributedContextPropagator.Current` — see [Configuring the BCL Propagator](#configuring-the-bcl-propagator-application-root).

```csharp
// ✅ Manual inject for outgoing call — library code, no OTel packages
using var activity = ActivitySource.StartActivity("SendMessage", ActivityKind.Client);

if (activity != null)
{
    var headers = new Dictionary<string, string>();
    DistributedContextPropagator.Current.Inject(activity, headers,
        static (carrier, name, value) => ((Dictionary<string, string>)carrier!)[name] = value);

    await SendMessageAsync(payload, headers);
}
```

```csharp
// ✅ Manual extract for incoming request — library code, no OTel packages
DistributedContextPropagator.Current.ExtractTraceIdAndState(incomingHeaders,
    static (object? carrier, string name, out string? value, out IEnumerable<string>? values) =>
    {
        values = null;
        ((Dictionary<string, string>)carrier!).TryGetValue(name, out value);
    },
    out var traceParent, out var traceState);

// Create a server span with the extracted parent context
using var activity = ActivitySource.StartActivity(
    "ReceiveMessage", ActivityKind.Server, parentId: traceParent);

if (activity != null && traceState != null)
{
    activity.TraceStateString = traceState;
}
```

Baggage can be extracted with
`DistributedContextPropagator.Current.ExtractBaggage(carrier, getter)`.

#### Application-level alternative: OTel `TextMapPropagator`

Use the OTel SDK's `TextMapPropagator` (from `OpenTelemetry.Context.Propagation`) **only when the built-in propagator cannot do the job, and only at the application root** — never in libraries. The legitimate cases are needing OTel `Baggage.Current` or a non-W3C wire format such as B3 (see below):

```csharp
using OpenTelemetry.Context.Propagation;

// Manual inject for outgoing call (application code)
var headers = new Dictionary<string, string>();
var propagator = Propagators.DefaultTextMapPropagator;
propagator.Inject(new PropagationContext(activity.Context, Baggage.Current),
    headers,
    static (carrier, name, value) => ((Dictionary<string, string>)carrier!)[name] = value!);
```

Note that `Sdk.SetDefaultTextMapPropagator` (OTel) and `DistributedContextPropagator.Current` (BCL) are separate registries that do not know about each other. An application that configures a non-default OTel propagator may therefore also need to **bridge** it into `DistributedContextPropagator.Current` (a small `DistributedContextPropagator` subclass wrapping the `TextMapPropagator`), otherwise `HttpClient`, ASP.NET Core, and BCL-propagating libraries will still emit/parse W3C headers. Libraries stay on `DistributedContextPropagator` regardless — bridging is an application-root concern.

### Configuring the BCL Propagator (Application Root)

`DistributedContextPropagator.Current` is a process-wide, settable static. Whatever the application root assigns here is what `HttpClient`, ASP.NET Core, and any library using the BCL pattern above will use:

```csharp
// Application setup — affects HttpClient, ASP.NET Core, and all BCL-propagating code
DistributedContextPropagator.Current = DistributedContextPropagator.CreateW3CPropagator();
```

Built-in factories:

| Factory | Behavior |
|---------|----------|
| `CreateDefaultPropagator()` | What `Current` is initialized with. Up to .NET 9: the legacy propagator (lenient encoding, baggage in the non-standard `Correlation-Context` header). **From .NET 10: the W3C propagator** ([breaking change](https://learn.microsoft.com/en-us/dotnet/core/compatibility/core-libraries/10.0/default-trace-context-propagator)) |
| `CreateW3CPropagator()` (.NET 10+) | Strict [W3C TraceContext](https://www.w3.org/TR/trace-context/) + [W3C Baggage](https://www.w3.org/TR/baggage/) — baggage in the `baggage` header, W3C-compliant encoding |
| `CreatePreW3CPropagator()` (.NET 10+) | The legacy behavior, for backward compatibility after the .NET 10 default change |
| `CreateNoOutputPropagator()` | Suppresses all outbound propagation — useful at trust boundaries (e.g., calls to third-party APIs that should not see your trace context) |
| `CreatePassThroughPropagator()` | Forwards the headers received on the inbound request unchanged, using the root `Activity` and ignoring intermediate spans — useful for proxies/gateways |

For a custom wire format, subclass `DistributedContextPropagator` and override its four abstract members:

```csharp
public sealed class CustomHeaderPropagator : DistributedContextPropagator
{
    public override IReadOnlyCollection<string> Fields { get; } = ["x-my-trace"];

    public override void Inject(Activity? activity, object? carrier, PropagatorSetterCallback? setter)
    {
        if (activity is null || setter is null) return;
        setter(carrier, "x-my-trace", activity.Id ?? string.Empty);
    }

    public override void ExtractTraceIdAndState(object? carrier, PropagatorGetterCallback? getter,
        out string? traceId, out string? traceState)
    {
        traceId = null;
        traceState = null;
        if (getter is null) return;
        getter(carrier, "x-my-trace", out traceId, out _);
    }

    public override IEnumerable<KeyValuePair<string, string?>>? ExtractBaggage(
        object? carrier, PropagatorGetterCallback? getter) => null; // no baggage support
}

// Application setup — HttpClient and ASP.NET Core now speak this format too
DistributedContextPropagator.Current = new CustomHeaderPropagator();
```

### Custom Propagators (OTel SDK)

Configure OTel propagators **only at the application root, and only when you need to deviate from the W3C defaults** — the SDK already ships with the composite of `TraceContextPropagator` + `BaggagePropagator`, so restating that buys nothing. The example below shows the shape of the call; in practice you would add or replace entries (e.g., B3, see below):

```csharp
// Application setup — only needed when deviating from the W3C defaults
Sdk.SetDefaultTextMapPropagator(new CompositeTextMapPropagator(
    new TextMapPropagator[]
    {
        new TraceContextPropagator(),   // W3C traceparent
        new BaggagePropagator()         // W3C baggage
    }));
```

### B3 Propagator (Legacy Compatibility)

If you need to interoperate with systems using the [B3 propagation format](https://github.com/openzipkin/b3-propagation)
(Zipkin-style), install `OpenTelemetry.Extensions.Propagators` at the application root and configure:

```csharp
Sdk.SetDefaultTextMapPropagator(new CompositeTextMapPropagator(
    new TextMapPropagator[]
    {
        new TraceContextPropagator(),
        new BaggagePropagator(),
        new B3Propagator()  // legacy B3 multi-header format
    }));
```

This changes only the OTel registry — `HttpClient`, ASP.NET Core, and libraries using  DistributedContextPropagator` still speak W3C. If B3 must apply to those too, bridge the composite into `DistributedContextPropagator.Current` as described above.

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

`Activity.SetStatus()` plus the `error.type` tag, governed by [Recording Errors](https://opentelemetry.io/docs/specs/semconv/general/recording-errors/), is the current, non-deprecated way to mark a span as failed. `Activity.AddEvent(new ActivityEvent("exception", ...))`, governed by [`exceptions-spans.md`](https://opentelemetry.io/docs/specs/semconv/exceptions/exceptions-spans/), is **Deprecated** in favor of recording exception details as a log record per [`exceptions-logs.md`](https://opentelemetry.io/docs/specs/semconv/exceptions/exceptions-logs/) — and the same shift applies to non-exception span events, since the spec now models any discrete named occurrence as an Event backed by a `LogRecord`, not a span event, per the [general Events conventions](https://opentelemetry.io/docs/specs/semconv/general/events/). Treat `Activity.AddEvent` as legacy: do not add new callers, whether for exceptions or anything else.

### Span Status and `error.type` (Current)

```csharp
try
{
    await ProcessItemAsync(); // success: leave status Unset, do not call SetStatus(Ok) — see below
}
catch (Exception ex)
{
    if (activity != null)
    {
        activity.SetStatus(ActivityStatusCode.Error, ex.Message);
        activity.SetTag("error.type", ex.GetType().FullName);
    }
    throw;
}
```

Per `recording-errors.md`: span status **MUST** be left unset if the operation ended without error. On failure, instrumentation **SHOULD** set the status code to `Error`, **SHOULD** set `error.type`, and **SHOULD** set the status description — when failing with an exception, the description **SHOULD** be the exception message. Errors that were retried or handled, letting the operation complete gracefully, **SHOULD NOT** be recorded on spans or metrics — the spec's own worked example is a `createIfNotExists` call that catches `ResourceAlreadyExistsException` internally and returns `false`: that path does not set `Error` status or `error.type`, because from the caller's point of view the operation succeeded.

`Ok` is a separate, narrower case governed by the [Set Status API spec](https://opentelemetry.io/docs/specs/otel/trace/api/#set-status), not by `recording-errors.md`: "Instrumentation Libraries SHOULD NOT set the status code to `Ok`, unless explicitly configured to do so... Application developers and Operators may set the status code to `Ok`." So library/instrumentation code should leave status `Unset` on success and never call `SetStatus(Ok)`; `Ok` exists for application-level code that wants to make a final call — most commonly overriding a library-reported `Error` it has decided isn't a real failure, such as suppressing noisy 404s. Once set, `Ok` is final and further status changes are ignored.

### Recording Exception Details as Logs (Current Spec)

Exception details — type, message, stacktrace — belong on a log record correlated to the active span, not on a span event. In .NET, passing the exception instance to `ILogger` gets you both halves of that for free: the OTel .NET Logs SDK reads `Activity.Current` when the `LogRecord` is constructed and stamps `trace_id`/`span_id` from it automatically, and the OTLP log exporter derives `exception.type`, `exception.message`, and `exception.stacktrace` from the exception instance — none of that needs to be set by hand.

```csharp
catch (Exception ex)
{
    activity?.SetStatus(ActivityStatusCode.Error, ex.Message);
    activity?.SetTag("error.type", ex.GetType().FullName);
    logger.LogError(ex, "Item processing failed"); // must be logged while `activity` is still Activity.Current — see below
    throw;
}
```

Severity, per `exceptions-logs.md`, reflects expected impact, not just presence: `FATAL` for exceptions that cause application shutdown, `ERROR` for unhandled exceptions (semantic conventions defining `SERVER`/`CONSUMER` spans should recommend this), `WARN` for exceptions expected to be handled by the caller (`CLIENT`/`PRODUCER` spans should recommend this — e.g. a connection timeout, a retry-exhausted client call), `DEBUG` for exceptions that don't indicate an actual issue (the spec's own example: a request cancelled client-side and detected server-side), `INFO`/`TRACE` are available to application developers but semantic conventions should not prescribe them.

The spec's correlation requirement is a MUST, not a SHOULD: "exception events emitted by instrumentations that also record spans for the same operation MUST be associated with the corresponding span context." In .NET that means the log call has to happen before the enclosing `using activity = source.StartActivity(...)` scope ends. This is a real failure mode, not a theoretical one — a nested `try`/`catch` where the outer method's activity scope closes before an inner exception-reporting callback fires will find `Activity.Current` already reverted to the parent (or null) by the time the callback runs, so the exception log silently attaches to the wrong span. Always trace the call path from `catch` to the log call and confirm it stays inside the `using` block.

### Migrating Off Exception Span Events

Existing instrumentation that already emits `AddEvent(new ActivityEvent("exception", ...))` should not drop it in a patch release. The spec's transition guidance: introduce an `OTEL_SEMCONV_EXCEPTION_SIGNAL_OPT_IN` environment variable supporting `logs` (emit exceptions as logs only), `logs/dup` (emit both span events and logs, for a phased rollout), with the default — absent either value — continuing to emit span events for backward compatibility; maintain that existing major version, with security patches at a minimum, for at least six months after dual-emission starts; then drop the environment variable and the span events in the next major version. As of `OpenTelemetry.Api` 1.17.0, no OpenTelemetry .NET package implements this opt-in yet, and `OpenTelemetry.Instrumentation.AspNetCore` 1.17.0 still records exceptions via `Activity.AddException` (span events) — that's a gap in the .NET ecosystem's catch-up to the spec, not a reason to add new span-event exception recording; new code should go straight to logs as shown above.

### Example: Exception Callback With No Logging Dependency

A library's core often shouldn't take a hard dependency on `Microsoft.Extensions.Logging.Abstractions` or any other logging package — it keeps the core lean, testable, and free to be used by consumers who bring their own logging story. But its exception details still need to reach the Logs API while the right `Activity` is current, and only code outside the core knows where "current" means for that consumer. The fix is the same pattern used for context propagation hooks in messaging clients: a settable delegate that the core invokes synchronously, in place, right where the exception is caught.

```csharp
// Core library — references only System.Diagnostics.DiagnosticSource. No Microsoft.Extensions.Logging.Abstractions, no OpenTelemetry package.
public static class MyLibraryDiagnostics
{
    public static Action<Exception, string>? ExceptionCallback { get; set; } // an OTel integration package (or the application itself) sets this
}

internal sealed class Consumer
{
    private static readonly ActivitySource Source = new("MyLibrary");

    public async Task DeliverAsync(Message message)
    {
        using var activity = Source.StartActivity("deliver", ActivityKind.Consumer);
        try
        {
            await ProcessAsync(message); // success: leave status Unset — this is library code, so no SetStatus(Ok)
        }
        catch (Exception ex)
        {
            activity?.SetStatus(ActivityStatusCode.Error, ex.Message);
            activity?.SetTag("error.type", ex.GetType().FullName);
            MyLibraryDiagnostics.ExceptionCallback?.Invoke(ex, "deliver"); // synchronous, inline, still inside the `using` scope — Activity.Current is this "deliver" span right now; deferring this call (Task.Run, a queue drained later) would let Activity.Current revert before it runs
            throw;
        }
    }
}
```

```csharp
// MyLibrary.OpenTelemetry — the only assembly in the stack that references Microsoft.Extensions.Logging.Abstractions.
public static void AddMyLibraryInstrumentation(this IServiceCollection services)
{
    services.AddSingleton<IStartupFilter>(_ =>
    {
        var logger = services.BuildServiceProvider().GetRequiredService<ILoggerFactory>().CreateLogger("MyLibrary");
        MyLibraryDiagnostics.ExceptionCallback = (exception, operationName) =>
        {
            logger.LogError(exception, "{Operation} failed", operationName); // Activity.Current is still the "deliver" span the core had open when it invoked us — the OTel Logs SDK reads it here to stamp trace_id/span_id, satisfying the exceptions-logs.md MUST
        };
        return new NoopStartupFilter();
    });
}
```

### Legacy Compatibility

The manual `otel.status_code` and `otel.status_description` **tags** were required in early OTel .NET versions before `Activity.SetStatus()` was available:

```csharp
// ❌ LEGACY — no longer needed, prefer SetStatus
activity.SetTag("otel.status_code", "error");
activity.SetTag("otel.status_description", ex.Message);
```

Do NOT use these tags in new code. `Activity.SetStatus()` is the modern API and the OTel SDK handles translation to the OTel span status fields automatically.

### Exception Attribute Reference

`exceptions-spans.md` is **Deprecated**; `exceptions-logs.md` is the current document, and both share the same first three attributes. `exception.escaped` is deprecated outright, not just deprioritized — "it's no longer recommended to record exceptions that are handled and do not escape the scope of a span" — and has no equivalent in the logs convention.

| Attribute | Stability | Requirement | Description |
|-----------|-----------|-------------|-------------|
| `exception.type` | Stable | Conditionally Required (if `exception.message` not set) | Fully qualified exception type name |
| `exception.message` | Stable | Conditionally Required (if `exception.type` not set) | The exception message |
| `exception.stacktrace` | Stable | Recommended | String representation of the stack trace |
| `exception.escaped` | **Deprecated** | Span events only, not recommended | Whether the exception escaped the span boundary — don't set this |

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
- [OTel Recording Errors](https://opentelemetry.io/docs/specs/semconv/general/recording-errors/)
- [OTel Exception Span Conventions (Deprecated)](https://opentelemetry.io/docs/specs/semconv/exceptions/exceptions-spans/)
- [OTel Exception Logs Conventions](https://opentelemetry.io/docs/specs/semconv/exceptions/exceptions-logs/)
- [OTel General Events Conventions](https://opentelemetry.io/docs/specs/semconv/general/events/)
- [.NET Distributed Tracing Documentation](https://learn.microsoft.com/en-us/dotnet/core/diagnostics/distributed-tracing)