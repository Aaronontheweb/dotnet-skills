# Advanced Testing Patterns

Extended patterns for Aspire integration testing including endpoint discovery, database testing, Playwright, conditional configuration, Respawn, and service communication.

## Contents

- [Endpoint Discovery](#endpoint-discovery)
- [Testing with Database Dependencies](#testing-with-database-dependencies)
- [Combining with Playwright for UI Tests](#combining-with-playwright-for-ui-tests)
- [Conditional Resource Configuration for Tests](#conditional-resource-configuration-for-tests)
- [Database Reset with Respawn](#database-reset-with-respawn)
- [Waiting for Resource Readiness](#waiting-for-resource-readiness)
- [Testing Service-to-Service Communication](#testing-service-to-service-communication)
- [Testing with Message Queues](#testing-with-message-queues)

## Endpoint Discovery

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

## Testing with Database Dependencies

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

## Combining with Playwright for UI Tests

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

## Conditional Resource Configuration for Tests

Design your AppHost to support different configurations for interactive development (F5/CLI) vs automated test fixtures.

> **Default to production-like behavior in AppHost.** Tests explicitly override what they need to be different.

### Configuration Class in AppHost

```csharp
public class AppHostConfiguration
{
    public bool UseVolumes { get; set; } = true;
    public string ExecutionMode { get; set; } = "Clustered";
    public bool EnableTestAuth { get; set; } = false;
    public bool UseFakeExternalServices { get; set; } = false;
    public int Replicas { get; set; } = 1;
}
```

### AppHost Conditional Logic

```csharp
var builder = DistributedApplication.CreateBuilder(args);

var config = builder.Configuration.GetSection("App")
    .Get<AppHostConfiguration>() ?? new AppHostConfiguration();

var postgres = builder.AddPostgres("postgres").WithPgAdmin();
if (config.UseVolumes)
{
    postgres.WithDataVolume();
}
var db = postgres.AddDatabase("appdb");

var migrations = builder.AddProject<Projects.YourApp_Migrations>("migrations")
    .WaitFor(db)
    .WithReference(db);

var api = builder.AddProject<Projects.YourApp_Api>("api")
    .WaitForCompletion(migrations)
    .WithReference(db)
    .WithEnvironment("AkkaSettings__ExecutionMode", config.ExecutionMode)
    .WithEnvironment("Testing__EnableTestAuth", config.EnableTestAuth.ToString())
    .WithEnvironment("ExternalServices__UseFakes", config.UseFakeExternalServices.ToString());

if (config.Replicas > 1)
{
    api.WithReplicas(config.Replicas);
}

builder.Build().Run();
```

### Test Fixture Overrides

```csharp
var builder = await DistributedApplicationTestingBuilder
    .CreateAsync<Projects.YourApp_AppHost>([
        "App:UseVolumes=false",
        "App:ExecutionMode=LocalTest",
        "App:EnableTestAuth=true",
        "App:UseFakeExternalServices=true"
    ]);
```

### Common Conditional Settings

| Setting | F5/Development | Test Fixture | Purpose |
|---------|----------------|--------------|---------|
| `UseVolumes` | `true` (persist data) | `false` (clean slate) | Database isolation |
| `ExecutionMode` | `Clustered` (realistic) | `LocalTest` or `Clustered` | Actor system mode |
| `EnableTestAuth` | `false` (use real OAuth) | `true` (/dev-login) | Bypass OAuth in tests |
| `UseFakeServices` | `false` (real integrations) | `true` (no external calls) | External API isolation |
| `Replicas` | `1` or more | `1` (simplicity) | Scale configuration |

### Test Authentication Pattern

```csharp
// In API startup, conditionally add test auth
if (builder.Configuration.GetValue<bool>("Testing:EnableTestAuth"))
{
    app.MapPost("/dev-login", async (DevLoginRequest request, IAuthService auth) =>
    {
        var token = await auth.GenerateTokenAsync(request.UserId, request.Roles);
        return Results.Ok(new { token });
    });
}

// In tests
public async Task<string> LoginAsTestUser(string userId, string[] roles)
{
    var response = await _httpClient.PostAsJsonAsync("/dev-login",
        new { UserId = userId, Roles = roles });
    var result = await response.Content.ReadFromJsonAsync<DevLoginResponse>();
    return result!.Token;
}
```

### Fake External Services Pattern

```csharp
public static IServiceCollection AddExternalServices(
    this IServiceCollection services,
    IConfiguration config)
{
    if (config.GetValue<bool>("ExternalServices:UseFakes"))
    {
        services.AddSingleton<IEmailSender, FakeEmailSender>();
        services.AddSingleton<IPaymentProcessor, FakePaymentProcessor>();
        services.AddSingleton<IOAuthProvider, FakeOAuthProvider>();
    }
    else
    {
        services.AddSingleton<IEmailSender, SendGridEmailSender>();
        services.AddSingleton<IPaymentProcessor, StripePaymentProcessor>();
        services.AddSingleton<IOAuthProvider, Auth0Provider>();
    }

    return services;
}
```

## Database Reset with Respawn

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

        await _app.ResourceNotifications.WaitForResourceHealthyAsync("api");

        var dbResource = _app.GetResource("appdb");
        _connectionString = await dbResource.GetConnectionStringAsync();

        _respawner = await Respawner.CreateAsync(_connectionString, new RespawnerOptions
        {
            TablesToIgnore = new[]
            {
                "__EFMigrationsHistory",
                "schema_version",
                "AspNetRoles"
            },
            DbAdapter = DbAdapter.Postgres
        });
    }

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

## Waiting for Resource Readiness

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
```

## Testing Service-to-Service Communication

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

## Testing with Message Queues

```csharp
[Fact]
public async Task MessageQueue_ShouldProcessMessages()
{
    var rabbitMqResource = _fixture.App.GetResource("messaging");
    var connectionString = await rabbitMqResource
        .GetConnectionStringAsync();

    var factory = new ConnectionFactory
    {
        Uri = new Uri(connectionString)
    };

    using var connection = await factory.CreateConnectionAsync();
    using var channel = await connection.CreateChannelAsync();

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
