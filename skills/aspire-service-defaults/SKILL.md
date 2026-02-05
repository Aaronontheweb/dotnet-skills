---
name: aspire-service-defaults
description: Create a shared ServiceDefaults project for Aspire applications. Centralizes OpenTelemetry, health checks, resilience, and service discovery configuration across all services.
invocable: false
---

# Aspire Service Defaults

## When to Use This Skill

Use this skill when:
- Building Aspire-based distributed applications
- Need consistent observability (logging, tracing, metrics) across services
- Want shared health check configuration
- Configuring HttpClient resilience and service discovery

---

## What is ServiceDefaults?

ServiceDefaults is a shared project that provides common configuration for all services in an Aspire application:

- **OpenTelemetry** - Logging, tracing, and metrics
- **Health Checks** - Readiness and liveness endpoints
- **Service Discovery** - Automatic service resolution
- **HTTP Resilience** - Retry and circuit breaker policies

Every service references this project and calls `AddServiceDefaults()`.

---

## Project Structure

```
src/
  MyApp.ServiceDefaults/
    Extensions.cs
    MyApp.ServiceDefaults.csproj
  MyApp.Api/
    Program.cs  # Calls AddServiceDefaults()
  MyApp.Worker/
    Program.cs  # Calls AddServiceDefaults()
  MyApp.AppHost/
    Program.cs
```

---

## ServiceDefaults Project

### Project File

```xml
<Project Sdk="Microsoft.NET.Sdk">
  <PropertyGroup>
    <TargetFramework>net9.0</TargetFramework>
    <IsAspireSharedProject>true</IsAspireSharedProject>
  </PropertyGroup>

  <ItemGroup>
    <FrameworkReference Include="Microsoft.AspNetCore.App" />
    <PackageReference Include="Microsoft.Extensions.Http.Resilience" />
    <PackageReference Include="Microsoft.Extensions.ServiceDiscovery" />
    <PackageReference Include="OpenTelemetry.Exporter.OpenTelemetryProtocol" />
    <PackageReference Include="OpenTelemetry.Extensions.Hosting" />
    <PackageReference Include="OpenTelemetry.Instrumentation.AspNetCore" />
    <PackageReference Include="OpenTelemetry.Instrumentation.Http" />
    <PackageReference Include="OpenTelemetry.Instrumentation.Runtime" />
  </ItemGroup>
</Project>
```

### Extensions.cs

```csharp
using Microsoft.AspNetCore.Builder;
using Microsoft.AspNetCore.Diagnostics.HealthChecks;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.Diagnostics.HealthChecks;
using Microsoft.Extensions.Logging;
using OpenTelemetry;
using OpenTelemetry.Metrics;
using OpenTelemetry.Trace;

namespace Microsoft.Extensions.Hosting;

public static class Extensions
{
    private const string HealthEndpointPath = "/health";
    private const string AlivenessEndpointPath = "/alive";

    /// <summary>
    /// Adds common Aspire services: OpenTelemetry, health checks,
    /// service discovery, and HTTP resilience.
    /// </summary>
    public static TBuilder AddServiceDefaults<TBuilder>(this TBuilder builder)
        where TBuilder : IHostApplicationBuilder
    {
        builder.ConfigureOpenTelemetry();
        builder.AddDefaultHealthChecks();

        builder.Services.AddServiceDiscovery();

        builder.Services.ConfigureHttpClientDefaults(http =>
        {
            // Resilience: retries, circuit breaker, timeouts
            http.AddStandardResilienceHandler();

            // Service discovery: resolve service names to addresses
            http.AddServiceDiscovery();
        });

        return builder;
    }

    public static TBuilder ConfigureOpenTelemetry<TBuilder>(this TBuilder builder)
        where TBuilder : IHostApplicationBuilder
    {
        // Logging
        builder.Logging.AddOpenTelemetry(logging =>
        {
            logging.IncludeFormattedMessage = true;
            logging.IncludeScopes = true;
        });

        builder.Services.AddOpenTelemetry()
            // Metrics
            .WithMetrics(metrics =>
            {
                metrics
                    .AddAspNetCoreInstrumentation()
                    .AddHttpClientInstrumentation()
                    .AddRuntimeInstrumentation();
            })
            // Tracing
            .WithTracing(tracing =>
            {
                tracing
                    .AddSource(builder.Environment.ApplicationName)
                    .AddAspNetCoreInstrumentation(options =>
                        // Exclude health checks from traces
                        options.Filter = context =>
                            !context.Request.Path.StartsWithSegments(HealthEndpointPath) &&
                            !context.Request.Path.StartsWithSegments(AlivenessEndpointPath))
                    .AddHttpClientInstrumentation();
            });

        builder.AddOpenTelemetryExporters();

        return builder;
    }

    private static TBuilder AddOpenTelemetryExporters<TBuilder>(this TBuilder builder)
        where TBuilder : IHostApplicationBuilder
    {
        // Use OTLP exporter if endpoint is configured (Aspire Dashboard, Jaeger, etc.)
        var useOtlp = !string.IsNullOrWhiteSpace(
            builder.Configuration["OTEL_EXPORTER_OTLP_ENDPOINT"]);

        if (useOtlp)
        {
            builder.Services.AddOpenTelemetry().UseOtlpExporter();
        }

        return builder;
    }

    public static TBuilder AddDefaultHealthChecks<TBuilder>(this TBuilder builder)
        where TBuilder : IHostApplicationBuilder
    {
        builder.Services.AddHealthChecks()
            .AddCheck("self", () => HealthCheckResult.Healthy(), ["live"]);

        return builder;
    }

    /// <summary>
    /// Maps health check endpoints. Call after UseRouting().
    /// </summary>
    public static WebApplication MapDefaultEndpoints(this WebApplication app)
    {
        // Only expose in development - see security note below
        if (app.Environment.IsDevelopment())
        {
            // Readiness: all health checks must pass
            app.MapHealthChecks(HealthEndpointPath);

            // Liveness: only "live" tagged checks
            app.MapHealthChecks(AlivenessEndpointPath, new HealthCheckOptions
            {
                Predicate = r => r.Tags.Contains("live")
            });
        }

        return app;
    }
}
```

---

## Usage in Services

### API Service

```csharp
var builder = WebApplication.CreateBuilder(args);

// Add all service defaults
builder.AddServiceDefaults();

// Add your services
builder.Services.AddControllers();

var app = builder.Build();

// Map health endpoints
app.MapDefaultEndpoints();

app.MapControllers();
app.Run();
```

### Worker Service

```csharp
var builder = Host.CreateApplicationBuilder(args);

// Works for non-web hosts too
builder.AddServiceDefaults();

builder.Services.AddHostedService<MyWorker>();

var host = builder.Build();
host.Run();
```

---

## Adding Custom Health Checks

```csharp
public static TBuilder AddDefaultHealthChecks<TBuilder>(this TBuilder builder)
    where TBuilder : IHostApplicationBuilder
{
    builder.Services.AddHealthChecks()
        // Basic liveness
        .AddCheck("self", () => HealthCheckResult.Healthy(), ["live"])

        // Database readiness
        .AddNpgSql(
            builder.Configuration.GetConnectionString("postgres")!,
            name: "postgres",
            tags: ["ready"])

        // Redis readiness
        .AddRedis(
            builder.Configuration.GetConnectionString("redis")!,
            name: "redis",
            tags: ["ready"])

        // Custom check
        .AddCheck<MyCustomHealthCheck>("custom", tags: ["ready"]);

    return builder;
}
```

---

## Adding Custom Trace Sources

For Akka.NET or custom ActivitySources:

```csharp
public static TBuilder ConfigureOpenTelemetry<TBuilder>(this TBuilder builder)
    where TBuilder : IHostApplicationBuilder
{
    builder.Services.AddOpenTelemetry()
        .WithTracing(tracing =>
        {
            tracing
                .AddSource(builder.Environment.ApplicationName)
                // Akka.NET tracing
                .AddSource("Akka.NET")
                // Custom sources
                .AddSource("MyApp.Orders")
                .AddSource("MyApp.Payments")
                .AddAspNetCoreInstrumentation()
                .AddHttpClientInstrumentation();
        });

    return builder;
}
```

---

## Production Health Checks

For production, protect health endpoints or use different paths:

```csharp
public static WebApplication MapDefaultEndpoints(this WebApplication app)
{
    // Always map for Kubernetes probes, but consider:
    // - Using internal-only ports
    // - Adding authorization
    // - Rate limiting

    app.MapHealthChecks("/health", new HealthCheckOptions
    {
        // Only return status, not details
        ResponseWriter = (context, report) =>
        {
            context.Response.ContentType = "text/plain";
            return context.Response.WriteAsync(report.Status.ToString());
        }
    });

    app.MapHealthChecks("/alive", new HealthCheckOptions
    {
        Predicate = r => r.Tags.Contains("live"),
        ResponseWriter = (context, report) =>
        {
            context.Response.ContentType = "text/plain";
            return context.Response.WriteAsync(report.Status.ToString());
        }
    });

    return app;
}
```

---

## Integration with AppHost

The AppHost automatically configures OTLP endpoints:

```csharp
// AppHost/Program.cs
var builder = DistributedApplication.CreateBuilder(args);

var postgres = builder.AddPostgres("postgres");
var redis = builder.AddRedis("redis");

var api = builder.AddProject<Projects.MyApp_Api>("api")
    .WithReference(postgres)
    .WithReference(redis);

builder.Build().Run();
```

Services receive `OTEL_EXPORTER_OTLP_ENDPOINT` automatically, sending telemetry to the Aspire Dashboard.

---

## Best Practices

| Practice | Reason |
|----------|--------|
| **One ServiceDefaults project** | Consistent config across all services |
| **Filter health checks from traces** | Reduces noise in observability data |
| **Tag health checks** | Separate liveness from readiness |
| **Use StandardResilienceHandler** | Built-in retry, circuit breaker, timeout |
| **Add custom trace sources** | Capture domain-specific spans |

---

## Resources

- **Aspire Service Defaults**: https://learn.microsoft.com/en-us/dotnet/aspire/fundamentals/service-defaults
- **OpenTelemetry .NET**: https://opentelemetry.io/docs/languages/net/
- **Health Checks**: https://learn.microsoft.com/en-us/aspnet/core/host-and-deploy/health-checks
