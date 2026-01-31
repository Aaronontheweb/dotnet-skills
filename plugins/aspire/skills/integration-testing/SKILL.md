---
name: aspire-integration-testing
description: Write integration tests using .NET Aspire's testing facilities with xUnit. Covers test fixtures, distributed application setup, endpoint discovery, and patterns for testing ASP.NET Core apps with real dependencies.
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

**Why this matters:** `[ModuleInitializer]` runs before any test code executes, setting the environment variable globally for all IHost instances created during tests.

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
        // Pass configuration overrides as command-line args (cleaner than Configuration dictionary)
        var builder = await DistributedApplicationTestingBuilder
            .CreateAsync<Projects.YourApp_AppHost>([
                "YourApp:UseVolumes=false",           // No persistence - clean slate each test
                "YourApp:Environment=IntegrationTest",
                "YourApp:Replicas=1"                  // Single instance for tests
            ]);

        _app = await builder.BuildAsync();

        // Phase 1: Start the application (container startup)
        using var startupCts = new CancellationTokenSource(TimeSpan.FromMinutes(10));
        await _app.StartAsync(startupCts.Token);

        // Phase 2: Wait for services to become healthy (use built-in API)
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
// Define a collection to share the fixture across multiple test classes
[CollectionDefinition("Aspire collection")]
public class AspireCollection : ICollectionFixture<AspireAppFixture> { }

// Use the fixture in your test class
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
        // Get the web application resource
        var webApp = _fixture.App.GetResource("yourapp");

        // Get the HTTP endpoint
        var httpClient = _fixture.App.CreateHttpClient("yourapp");

        // Make a request
        var response = await httpClient.GetAsync("/");

        Assert.Equal(HttpStatusCode.OK, response.StatusCode);
    }
}
```

## Pattern 3: Endpoint Discovery

```csharp
public static class DistributedApplicationExtensions
{
    public static ResourceEndpoint GetEndpoint(
        this DistributedApplication app,
        string resourceName,
        string? endpointName = null)
    {
        var resource = app.GetResource(resourceName);

        if (resource is null)
            throw new InvalidOperationException(
                $"Resource '{resourceName}' not found");

        var endpoint = endpointName is null
            ? resource.GetEndpoints().FirstOrDefault()
            : resource.GetEndpoint(endpointName);

        if (endpoint is null)
            throw new InvalidOperationException(
                $"Endpoint '{endpointName}' not found on resource '{resourceName}'");

        return endpoint;
    }

    public static string GetEndpointUrl(
        this DistributedApplication app,
        string resourceName,
        string? endpointName = null)
    {
        var endpoint = app.GetEndpoint(resourceName, endpointName);
        return endpoint.Url;
    }
}

// Usage in tests
[Fact]
public async Task CanAccessWebApplication()
{
    var url = _fixture.App.GetEndpointUrl("yourapp");
    var client = new HttpClient { BaseAddress = new Uri(url) };

    var response = await client.GetAsync("/health");

    Assert.Equal(HttpStatusCode.OK, response.StatusCode);
}
```

## Pattern 4: Testing with Database Dependencies

```csharp
public class DatabaseIntegrationTests
{
    private readonly AspireAppFixture _fixture;

    public DatabaseIntegrationTests(AspireAppFixture fixture)
    {
        _fixture = fixture;
    }

    [Fact]
    public async Task Database_ShouldBeInitialized()
    {
        // Get connection string from Aspire
        var dbResource = _fixture.App.GetResource("yourdb");
        var connectionString = await dbResource
            .GetConnectionStringAsync();

        // Test database access
        await using var connection = new SqlConnection(connectionString);
        await connection.OpenAsync();

        var result = await connection.QuerySingleAsync<int>(
            "SELECT COUNT(*) FROM INFORMATION_SCHEMA.TABLES");

        Assert.True(result > 0, "Database should have tables");
    }
}
```

## Pattern 5: Combining with Playwright for UI Tests

```csharp
using Microsoft.Playwright;

public sealed class AspirePlaywrightFixture : IAsyncLifetime
{
    private DistributedApplication? _app;
    private IPlaywright? _playwright;
    private IBrowser? _browser;

    public DistributedApplication App => _app!;
    public IBrowser Browser => _browser!;

    public async Task InitializeAsync()
    {
        // Start Aspire application
        var appHost = await DistributedApplicationTestingBuilder
            .CreateAsync<Projects.YourApp_AppHost>();

        _app = await appHost.BuildAsync();
        await _app.StartAsync();

        // Wait for app to be fully ready
        await Task.Delay(2000); // Or use proper health check polling

        // Start Playwright
        _playwright = await Playwright.CreateAsync();
        _browser = await _playwright.Chromium.LaunchAsync(new()
        {
            Headless = true
        });
    }

    public async Task DisposeAsync()
    {
        if (_browser is not null)
            await _browser.DisposeAsync();

        _playwright?.Dispose();

        if (_app is not null)
            await _app.DisposeAsync();
    }
}

[Collection("Aspire Playwright collection")]
public class UIIntegrationTests
{
    private readonly AspirePlaywrightFixture _fixture;

    public UIIntegrationTests(AspirePlaywrightFixture fixture)
    {
        _fixture = fixture;
    }

    [Fact]
    public async Task HomePage_ShouldLoad()
    {
        var url = _fixture.App.GetEndpointUrl("yourapp");
        var page = await _fixture.Browser.NewPageAsync();

        await page.GotoAsync(url);

        var title = await page.TitleAsync();
        Assert.NotEmpty(title);
    }
}
```

## Pattern 6: Conditional Volume Configuration in AppHost

Design your AppHost to support test scenarios by making volumes optional:

```csharp
// In your AppHost Program.cs
public class AppConfiguration
{
    /// <summary>
    /// Whether to use persistent volumes for databases.
    /// Defaults to false - tests get a clean database each run.
    /// </summary>
    public bool UseVolumes { get; set; } = false;

    public string Environment { get; set; } = "Development";
    public int Replicas { get; set; } = 1;
}

var builder = DistributedApplication.CreateBuilder(args);

// Bind configuration from command-line args or appsettings
var config = builder.Configuration.GetSection("YourApp")
    .Get<AppConfiguration>() ?? new AppConfiguration();

var postgres = builder.AddPostgres("postgres").WithPgAdmin();

// Only persist data when explicitly enabled (not during tests)
if (config.UseVolumes)
{
    postgres.WithDataVolume();
}

var db = postgres.AddDatabase("appdb");

// Migrations run first
var migrations = builder.AddProject<Projects.YourApp_Migrations>("migrations")
    .WaitFor(db)
    .WithReference(db);

// API waits for migrations to complete
var api = builder.AddProject<Projects.YourApp_Api>("api")
    .WaitForCompletion(migrations)
    .WithReference(db);
```

**Then in tests, pass `UseVolumes=false`:**

```csharp
var builder = await DistributedApplicationTestingBuilder
    .CreateAsync<Projects.YourApp_AppHost>([
        "YourApp:UseVolumes=false"  // Clean database each test run
    ]);
```

## Pattern 7: Database Reset with Respawn

For tests that modify data, use [Respawn](https://github.com/jbogard/Respawn) to reset between tests:

```csharp
using Respawn;

public class AspireFixtureWithReset : IAsyncLifetime
{
    private DistributedApplication? _app;
    private Respawner? _respawner;
    private string? _connectionString;

    public async Task InitializeAsync()
    {
        var builder = await DistributedApplicationTestingBuilder
            .CreateAsync<Projects.YourApp_AppHost>([
                "YourApp:UseVolumes=false"
            ]);

        _app = await builder.BuildAsync();
        await _app.StartAsync();

        // Wait for database and migrations
        await _app.ResourceNotifications.WaitForResourceHealthyAsync("api");

        // Get connection string and create respawner
        var dbResource = _app.GetResource("appdb");
        _connectionString = await dbResource.GetConnectionStringAsync();

        _respawner = await Respawner.CreateAsync(_connectionString, new RespawnerOptions
        {
            TablesToIgnore = new[]
            {
                "__EFMigrationsHistory",
                "schema_version",        // DbUp
                "AspNetRoles"            // Seeded reference data
            },
            DbAdapter = DbAdapter.Postgres
        });
    }

    /// <summary>
    /// Reset database to clean state between tests.
    /// </summary>
    public async Task ResetDatabaseAsync()
    {
        if (_respawner is not null && _connectionString is not null)
        {
            await _respawner.ResetAsync(_connectionString);
        }
    }

    public async Task DisposeAsync()
    {
        if (_app is not null)
            await _app.DisposeAsync();
    }
}
```
```

## Pattern 7: Waiting for Resource Readiness

```csharp
public static class ResourceExtensions
{
    public static async Task WaitForHealthyAsync(
        this DistributedApplication app,
        string resourceName,
        TimeSpan? timeout = null)
    {
        timeout ??= TimeSpan.FromSeconds(30);
        var cts = new CancellationTokenSource(timeout.Value);

        var resource = app.GetResource(resourceName);

        while (!cts.Token.IsCancellationRequested)
        {
            try
            {
                var httpClient = app.CreateHttpClient(resourceName);
                var response = await httpClient.GetAsync(
                    "/health",
                    cts.Token);

                if (response.IsSuccessStatusCode)
                    return;
            }
            catch
            {
                // Resource not ready yet
            }

            await Task.Delay(500, cts.Token);
        }

        throw new TimeoutException(
            $"Resource '{resourceName}' did not become healthy within {timeout}");
    }
}

// Usage
[Fact]
public async Task ServicesShouldBeHealthy()
{
    await _fixture.App.WaitForHealthyAsync("yourapp");
    await _fixture.App.WaitForHealthyAsync("youra pi");

    // Now proceed with tests
}
```

## Pattern 8: Testing Service-to-Service Communication

```csharp
[Fact]
public async Task WebApp_ShouldCallApi()
{
    var webClient = _fixture.App.CreateHttpClient("webapp");
    var apiClient = _fixture.App.CreateHttpClient("api");

    // Verify API is accessible
    var apiResponse = await apiClient.GetAsync("/api/data");
    Assert.True(apiResponse.IsSuccessStatusCode);

    // Verify WebApp calls API correctly
    var webResponse = await webClient.GetAsync("/fetch-data");
    Assert.True(webResponse.IsSuccessStatusCode);

    var content = await webResponse.Content.ReadAsStringAsync();
    Assert.NotEmpty(content);
}
```

## Pattern 9: Testing with Message Queues

```csharp
[Fact]
public async Task MessageQueue_ShouldProcessMessages()
{
    // Get RabbitMQ connection from Aspire
    var rabbitMqResource = _fixture.App.GetResource("messaging");
    var connectionString = await rabbitMqResource
        .GetConnectionStringAsync();

    var factory = new ConnectionFactory
    {
        Uri = new Uri(connectionString)
    };

    using var connection = await factory.CreateConnectionAsync();
    using var channel = await connection.CreateChannelAsync();

    // Publish a test message
    await channel.QueueDeclareAsync("test-queue", durable: false);
    await channel.BasicPublishAsync(
        exchange: "",
        routingKey: "test-queue",
        body: Encoding.UTF8.GetBytes("test message"));

    // Wait for processing
    await Task.Delay(1000);

    // Verify message was processed
    // (check database, file system, or other side effects)
}
```

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
| Tests timeout immediately | Call `await _app.StartAsync()` and wait for services to be healthy before running tests |
| Port conflicts between tests | Use xUnit `CollectionDefinition` to share fixtures and avoid starting multiple instances |
| Flaky tests due to timing | Implement proper health check polling instead of `Task.Delay()` |
| Can't connect to SQL Server | Ensure connection string is retrieved dynamically via `GetConnectionStringAsync()` |
| Parallel tests interfere | Use `[Collection]` attribute to run related tests sequentially |
| Aspire dashboard conflicts | Only one Aspire dashboard can run at a time; tests will reuse the same dashboard instance |

## CI/CD Integration

### GitHub Actions Example

```yaml
name: Integration Tests

on:
  push:
    branches: [ main, dev ]
  pull_request:
    branches: [ main, dev ]

jobs:
  test:
    runs-on: ubuntu-latest

    steps:
    - uses: actions/checkout@v3

    - name: Setup .NET
      uses: actions/setup-dotnet@v3
      with:
        dotnet-version: 9.0.x

    - name: Restore dependencies
      run: dotnet restore

    - name: Build
      run: dotnet build --no-restore -c Release

    - name: Run integration tests
      run: |
        dotnet test tests/YourApp.IntegrationTests \
          --no-build \
          -c Release \
          --logger trx \
          --collect:"XPlat Code Coverage"

    - name: Publish test results
      uses: actions/upload-artifact@v3
      if: always()
      with:
        name: test-results
        path: "**/TestResults/*.trx"
```

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
10. **Monitor test execution time** - If tests are slow, consider parallelization or optimization

## Advanced: Custom Resource Waiters

```csharp
public static class ResourceWaiters
{
    public static async Task WaitForSqlServerAsync(
        this DistributedApplication app,
        string resourceName,
        CancellationToken ct = default)
    {
        var resource = app.GetResource(resourceName);
        var connectionString = await resource.GetConnectionStringAsync(ct);

        var retryCount = 0;
        const int maxRetries = 30;

        while (retryCount < maxRetries)
        {
            try
            {
                await using var connection = new SqlConnection(connectionString);
                await connection.OpenAsync(ct);
                return; // Success!
            }
            catch (SqlException)
            {
                retryCount++;
                await Task.Delay(1000, ct);
            }
        }

        throw new TimeoutException(
            $"SQL Server resource '{resourceName}' did not become ready");
    }

    public static async Task WaitForRedisAsync(
        this DistributedApplication app,
        string resourceName,
        CancellationToken ct = default)
    {
        var resource = app.GetResource(resourceName);
        var connectionString = await resource.GetConnectionStringAsync(ct);

        var retryCount = 0;
        const int maxRetries = 30;

        while (retryCount < maxRetries)
        {
            try
            {
                var redis = await ConnectionMultiplexer.ConnectAsync(
                    connectionString);
                await redis.GetDatabase().PingAsync();
                return; // Success!
            }
            catch
            {
                retryCount++;
                await Task.Delay(1000, ct);
            }
        }

        throw new TimeoutException(
            $"Redis resource '{resourceName}' did not become ready");
    }
}

// Usage
public async Task InitializeAsync()
{
    _app = await appHost.BuildAsync();
    await _app.StartAsync();

    // Wait for dependencies to be ready
    await _app.WaitForSqlServerAsync("yourdb");
    await _app.WaitForRedisAsync("cache");
}
```

## Aspire CLI and MCP Integration

Aspire 13.1+ includes MCP (Model Context Protocol) integration for AI coding assistants like Claude Code. This allows AI tools to query application state, view logs, and inspect traces.

### Installing the Aspire CLI

```bash
# Install the Aspire CLI globally
dotnet tool install -g aspire.cli

# Or update existing installation
dotnet tool update -g aspire.cli
```

### Initializing MCP for Claude Code

```bash
# Navigate to your Aspire project
cd src/MyApp.AppHost

# Initialize MCP configuration (auto-detects Claude Code)
aspire mcp init
```

This creates the necessary configuration files for Claude Code to connect to your running Aspire application.

### Running with MCP Enabled

```bash
# Run your Aspire app with MCP server
aspire run

# The CLI will output the MCP endpoint URL
# Claude Code can then connect and query:
# - Resource states and health status
# - Real-time console logs
# - Distributed traces
# - Available Aspire integrations
```

### MCP Capabilities

When connected, AI assistants can:
- **Query resources** - Get resource states, endpoints, health status
- **Debug with logs** - Access real-time console output from all services
- **Investigate telemetry** - View structured logs and distributed traces
- **Execute commands** - Run resource-specific commands
- **Discover integrations** - List available Aspire hosting integrations (Redis, PostgreSQL, Azure services)

### Benefits for Development

- AI assistants can see your actual running application state
- Debugging assistance uses real telemetry data
- No need for manual log copying/pasting
- AI can help correlate distributed trace spans

For more details, see:
- [Aspire MCP Configuration](https://aspire.dev/get-started/configure-mcp/)
- [Aspire CLI Commands](https://aspire.dev/reference/cli/commands/aspire-mcp-init/)

---

## Debugging Tips

1. **Run Aspire Dashboard** - When tests fail, check the dashboard at `http://localhost:15888`
2. **Use Aspire CLI with MCP** - Let AI assistants query real application state
3. **Enable detailed logging** - Set `ASPIRE_ALLOW_UNSECURED_TRANSPORT=true` for more verbose output
4. **Check container logs** - Use `docker logs` to inspect container output
5. **Use breakpoints in fixtures** - Debug fixture initialization to catch startup issues
6. **Verify resource names** - Ensure resource names match between AppHost and tests
