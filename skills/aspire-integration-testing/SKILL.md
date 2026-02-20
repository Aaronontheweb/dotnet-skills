---
name: aspire-integration-testing
description: Write integration tests using .NET Aspire's testing facilities with xUnit. Covers test fixtures, distributed application setup, endpoint discovery, and patterns for testing ASP.NET Core apps with real dependencies.
invocable: false
---

# Integration Testing with .NET Aspire + xUnit

## When to Use This Skill

Use this skill when:
- Writing integration tests for .NET Aspire applications
- Testing ASP.NET Core apps with real database connections
- Verifying service-to-service communication in distributed applications
- Testing with actual infrastructure (SQL Server, Redis, message queues) in containers
- Combining Playwright UI tests with Aspire-orchestrated services
- Testing microservices with proper service discovery and networking

## Reference Files

- [advanced-patterns.md](advanced-patterns.md): Endpoint discovery, database testing, Playwright, conditional config, Respawn, service communication, message queues
- [ci-and-tooling.md](ci-and-tooling.md): CI/CD integration, custom resource waiters, Aspire CLI with MCP

## Core Principles

1. **Real Dependencies** - Use actual infrastructure (databases, caches) via Aspire, not mocks
2. **Dynamic Port Binding** - Let Aspire assign ports dynamically (`127.0.0.1:0`) to avoid conflicts
3. **Fixture Lifecycle** - Use `IAsyncLifetime` for proper test fixture setup and teardown
4. **Endpoint Discovery** - Never hard-code URLs; discover endpoints from Aspire at runtime
5. **Parallel Isolation** - Use xUnit collections to control test parallelization
6. **Health Checks** - Always wait for services to be healthy before running tests

## High-Level Testing Architecture

```
┌─────────────────┐                    ┌──────────────────────┐
│ xUnit test file │──uses────────────►│  AspireFixture       │
└─────────────────┘                    │  (IAsyncLifetime)    │
                                       └──────────────────────┘
                                               │
                                               │ starts
                                               ▼
                                    ┌───────────────────────────┐
                                    │  DistributedApplication   │
                                    │  (from AppHost)           │
                                    └───────────────────────────┘
                                               │ exposes
                                               ▼
                                  ┌──────────────────────────────┐
                                  │   Dynamic HTTP Endpoints     │
                                  └──────────────────────────────┘
                                               │ consumed by
                                               ▼
                                   ┌─────────────────────────┐
                                   │  HttpClient / Playwright│
                                   └─────────────────────────┘
```

## Required NuGet Packages

```xml
<ItemGroup>
  <PackageReference Include="Aspire.Hosting.Testing" Version="$(AspireVersion)" />
  <PackageReference Include="xunit" Version="*" />
  <PackageReference Include="xunit.runner.visualstudio" Version="*" />
  <PackageReference Include="Microsoft.NET.Test.Sdk" Version="*" />
</ItemGroup>
```

## CRITICAL: File Watcher Fix for Integration Tests

When running many integration tests that each start an IHost, the default .NET host builder enables file watchers for configuration reload. This exhausts file descriptor limits on Linux.

**Add this to your test project before any tests run:**

```csharp
// TestEnvironmentInitializer.cs
using System.Runtime.CompilerServices;

namespace YourApp.Tests;

internal static class TestEnvironmentInitializer
{
    [ModuleInitializer]
    internal static void Initialize()
    {
        // Disable config file watching in test hosts
        // Prevents file descriptor exhaustion (inotify watch limit) on Linux
        Environment.SetEnvironmentVariable("DOTNET_HOSTBUILDER__RELOADCONFIGONCHANGE", "false");
    }
}
```

## Pattern 1: Basic Aspire Test Fixture (Modern API)

```csharp
using Aspire.Hosting;
using Aspire.Hosting.Testing;

public sealed class AspireAppFixture : IAsyncLifetime
{
    private DistributedApplication? _app;

    public DistributedApplication App => _app
        ?? throw new InvalidOperationException("App not initialized");

    public async Task InitializeAsync()
    {
        var builder = await DistributedApplicationTestingBuilder
            .CreateAsync<Projects.YourApp_AppHost>([
                "YourApp:UseVolumes=false",
                "YourApp:Environment=IntegrationTest",
                "YourApp:Replicas=1"
            ]);

        _app = await builder.BuildAsync();

        using var startupCts = new CancellationTokenSource(TimeSpan.FromMinutes(10));
        await _app.StartAsync(startupCts.Token);

        using var healthCts = new CancellationTokenSource(TimeSpan.FromMinutes(5));
        await _app.ResourceNotifications.WaitForResourceHealthyAsync("api", healthCts.Token);
    }

    public Uri GetEndpoint(string resourceName, string scheme = "https")
    {
        return _app?.GetEndpoint(resourceName, scheme)
            ?? throw new InvalidOperationException($"Endpoint for '{resourceName}' not found");
    }

    public async Task DisposeAsync()
    {
        if (_app is not null)
        {
            await _app.DisposeAsync();
        }
    }
}
```

## Pattern 2: Using the Fixture in Tests

```csharp
[CollectionDefinition("Aspire collection")]
public class AspireCollection : ICollectionFixture<AspireAppFixture> { }

[Collection("Aspire collection")]
public class IntegrationTests
{
    private readonly AspireAppFixture _fixture;

    public IntegrationTests(AspireAppFixture fixture)
    {
        _fixture = fixture;
    }

    [Fact]
    public async Task Application_ShouldStart()
    {
        var httpClient = _fixture.App.CreateHttpClient("yourapp");
        var response = await httpClient.GetAsync("/");
        Assert.Equal(HttpStatusCode.OK, response.StatusCode);
    }
}
```

See [advanced-patterns.md](advanced-patterns.md) for Endpoint Discovery, Database Testing, Playwright UI Tests, Conditional Resource Configuration, Respawn database reset, Service-to-Service Communication, and Message Queue testing patterns.

## Common Patterns Summary

| Pattern | Use Case |
|---------|----------|
| Basic Fixture | Simple HTTP endpoint testing |
| Endpoint Discovery | Avoid hard-coded URLs |
| Database Testing | Verify data access layer |
| Playwright Integration | Full UI testing with real backend |
| Configuration Override | Test-specific settings |
| Health Checks | Ensure services are ready |
| Service Communication | Test distributed system interactions |
| Message Queue Testing | Verify async messaging |

## Tricky / Non-Obvious Tips

| Problem | Solution |
|---------|----------|
| Tests timeout immediately | Call `await _app.StartAsync()` and wait for services to be healthy |
| Port conflicts between tests | Use xUnit `CollectionDefinition` to share fixtures |
| Flaky tests due to timing | Implement proper health check polling instead of `Task.Delay()` |
| Can't connect to SQL Server | Retrieve connection string dynamically via `GetConnectionStringAsync()` |
| Parallel tests interfere | Use `[Collection]` attribute to run related tests sequentially |
| Aspire dashboard conflicts | Only one dashboard can run at a time; tests reuse the same instance |

## Best Practices

1. **Use `IAsyncLifetime`** - Ensures proper async initialization and cleanup
2. **Share fixtures via collections** - Reduces test execution time by reusing app instances
3. **Discover endpoints dynamically** - Never hard-code localhost:5000 or similar
4. **Wait for health checks** - Don't assume services are immediately ready
5. **Test with real dependencies** - Aspire makes it easy to use real SQL, Redis, etc.
6. **Clean up resources** - Always implement `DisposeAsync` properly
7. **Use meaningful test data** - Seed databases with realistic test data
8. **Test failure scenarios** - Verify error handling and resilience
9. **Keep tests isolated** - Each test should be independent and order-agnostic
10. **Monitor test execution time** - If tests are slow, consider parallelization

See [ci-and-tooling.md](ci-and-tooling.md) for GitHub Actions setup, custom resource waiters, and Aspire CLI/MCP integration.

---

## Debugging Tips

1. **Run Aspire Dashboard** - When tests fail, check the dashboard at `http://localhost:15888`
2. **Use Aspire CLI with MCP** - Let AI assistants query real application state
3. **Enable detailed logging** - Set `ASPIRE_ALLOW_UNSECURED_TRANSPORT=true` for more verbose output
4. **Check container logs** - Use `docker logs` to inspect container output
5. **Use breakpoints in fixtures** - Debug fixture initialization to catch startup issues
6. **Verify resource names** - Ensure resource names match between AppHost and tests
