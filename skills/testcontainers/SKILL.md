---
name: testcontainers-integration-tests
description: Write integration tests using TestContainers for .NET with xUnit. Covers infrastructure testing with real databases, message queues, and caches in Docker containers instead of mocks.
user-invocable: false
---

# Integration Testing with TestContainers

## When to Use This Skill

Use this skill when:
- Writing integration tests that need real infrastructure (databases, caches, message queues)
- Testing data access layers against actual databases
- Verifying message queue integrations
- Testing Redis caching behavior
- Avoiding mocks for infrastructure components
- Ensuring tests work against production-like environments
- Testing database migrations and schema changes

## Reference Files

- [database-patterns.md](database-patterns.md): SQL Server, PostgreSQL, and migration testing examples
- [infrastructure-patterns.md](infrastructure-patterns.md): Redis, RabbitMQ, multi-container networks, container reuse, and Respawn

## Core Principles

1. **Real Infrastructure Over Mocks** - Use actual databases/services in containers, not mocks
2. **Test Isolation** - Each test gets fresh containers or fresh data
3. **Automatic Cleanup** - TestContainers handles container lifecycle and cleanup
4. **Fast Startup** - Reuse containers across tests in the same class when appropriate
5. **CI/CD Compatible** - Works seamlessly in Docker-enabled CI environments
6. **Port Randomization** - Containers use random ports to avoid conflicts

## TestContainers 4.x API

This skill targets **TestContainers 4.x** with the 3.0+ module builder API. The pre-3.0 types were renamed and removed, so code that uses `TestcontainersBuilder<T>` or `TestcontainersContainer` does **not** compile against the modern packages:

| Old (pre-3.0) | New (3.0+) |
|----------------|------------|
| `new TestcontainersBuilder<T>()` | Module builder (e.g. `new PostgreSqlBuilder(...)`) or `new ContainerBuilder(...)` |
| `TestcontainersContainer` | `DockerContainer` / module container (e.g. `PostgreSqlContainer`) |
| `TestcontainersNetworkBuilder` | `NetworkBuilder` |
| `GetMappedPublicPort(port)` | `GetMappedPublicPort(port)` (still available) |

**Why 4.x and not 3.x?** The module builders did not expose image-taking constructors in Testcontainers 3.0.0. Those constructors (and the deprecation of the parameterless builder constructor) arrived in the 4.x line, so the examples here rely on 4.x behavior. Pin the module packages to a 4.x (or newer) version rather than an unbounded wildcard if you want reproducible builds.

The recommended approach is the **module builders** from the `Testcontainers.<Provider>` packages (see [Required NuGet Packages](#required-nuget-packages)). Each module builder pre-configures the right image, environment variables, ports, and wait strategy for its database or service.

Pass the image to the builder **constructor** (not via `.WithImage()`) to avoid the obsolete parameterless constructor:

```csharp
var container = new PostgreSqlBuilder("postgres:latest")
    .WithDatabase("testdb")
    .WithUsername("postgres")
    .WithPassword("postgres")
    .Build();
```

## Why TestContainers Over Mocks?

### The Problem with Mocking Infrastructure

```csharp
// BAD: Mocking a database
public class OrderRepositoryTests
{
    private readonly Mock<IDbConnection> _mockDb = new();

    [Fact]
    public async Task GetOrder_ReturnsOrder()
    {
        // This doesn't test real SQL behavior, constraints, or performance
        _mockDb.Setup(db => db.QueryAsync<Order>(It.IsAny<string>()))
            .ReturnsAsync(new[] { new Order { Id = 1 } });

        var repo = new OrderRepository(_mockDb.Object);
        var order = await repo.GetOrderAsync(1);

        Assert.NotNull(order);
    }
}
```

Problems: doesn't test actual SQL queries, misses constraints/indexes, gives false confidence, doesn't catch SQL syntax errors.

### Better: TestContainers with Real Database

```csharp
// GOOD: Testing against a real database
public class OrderRepositoryTests : IAsyncLifetime
{
    private readonly MsSqlContainer _dbContainer;
    private SqlConnection _connection;

    public OrderRepositoryTests()
    {
        _dbContainer = new MsSqlBuilder("mcr.microsoft.com/mssql/server:2022-latest")
            .WithDatabase("TestDb")
            .WithPassword("Your_password123")
            .Build();
    }

    public async Task InitializeAsync()
    {
        await _dbContainer.StartAsync();
        _connection = new SqlConnection(_dbContainer.GetConnectionString());
        await _connection.OpenAsync();
        await RunMigrationsAsync(_connection);
    }

    public async Task DisposeAsync()
    {
        await _connection.DisposeAsync();
        await _dbContainer.DisposeAsync();
    }

    [Fact]
    public async Task GetOrder_WithRealDatabase_ReturnsOrder()
    {
        await _connection.ExecuteAsync(
            "INSERT INTO Orders (Id, CustomerId, Total) VALUES (1, 'CUST1', 100.00)");

        var repo = new OrderRepository(_connection);
        var order = await repo.GetOrderAsync(1);

        Assert.NotNull(order);
        Assert.Equal("CUST1", order.CustomerId);
        Assert.Equal(100.00m, order.Total);
    }
}
```

See [database-patterns.md](database-patterns.md) for complete SQL Server, PostgreSQL, and migration testing examples.

See [infrastructure-patterns.md](infrastructure-patterns.md) for Redis, RabbitMQ, multi-container networks, container reuse, and Respawn database reset patterns.

## Required NuGet Packages

Use the **module packages** — one per provider. They replace the special-casing you'd otherwise write against the core `Testcontainers` package:

```xml
<ItemGroup>
  <!-- Core TestContainers -->
  <PackageReference Include="Testcontainers" Version="*" />

  <!-- Provider modules -->
  <PackageReference Include="Testcontainers.MsSql" Version="*" />
  <PackageReference Include="Testcontainers.PostgreSql" Version="*" />
  <PackageReference Include="Testcontainers.Redis" Version="*" />
  <PackageReference Include="Testcontainers.RabbitMq" Version="*" />

  <PackageReference Include="xunit" Version="*" />
  <PackageReference Include="xunit.runner.visualstudio" Version="*" />

  <!-- Database drivers -->
  <PackageReference Include="Microsoft.Data.SqlClient" Version="*" />
  <PackageReference Include="Npgsql" Version="*" /> <!-- For PostgreSQL -->

  <!-- Other infrastructure -->
  <PackageReference Include="StackExchange.Redis" Version="*" /> <!-- For Redis -->
  <PackageReference Include="RabbitMQ.Client" Version="*" /> <!-- For RabbitMQ -->
</ItemGroup>
```

## Required Usings

The module builders and container types live in provider-specific namespaces. The base types (`ContainerBuilder`, `NetworkBuilder`, `Wait`) live in `DotNet.Testcontainers.Builders`, and `INetwork` lives in `DotNet.Testcontainers.Networks`:

```csharp
using DotNet.Testcontainers.Builders;
using DotNet.Testcontainers.Networks;
using Testcontainers.MsSql;
using Testcontainers.PostgreSql;
using Testcontainers.Redis;
using Testcontainers.RabbitMq;
```

## Best Practices

1. **Always Use IAsyncLifetime** - Proper async setup and teardown
2. **Wait for Port Availability** - Use a `Wait` strategy to ensure containers are ready
3. **Use Random Ports** - Let TestContainers assign ports automatically
4. **Clean Data Between Tests** - Either use fresh containers or truncate tables
5. **Reuse Containers When Possible** - Faster than creating new ones for each test
6. **Test Real Queries** - Don't just test mocks; verify actual SQL behavior
7. **Verify Constraints** - Test foreign keys, unique constraints, indexes
8. **Test Transactions** - Verify rollback and commit behavior
9. **Use Realistic Data** - Test with production-like data volumes
10. **Handle Cleanup** - Always dispose containers in `DisposeAsync`

## Common Issues and Solutions

### Container Startup Timeout

```csharp
_container = new PostgreSqlBuilder("postgres:latest")
    .WithDatabase("testdb")
    .WithUsername("postgres")
    .WithPassword("postgres")
    .WithWaitStrategy(Wait.ForUnixContainer()
        .UntilInternalTcpPortIsAvailable(5432, w => w.WithTimeout(TimeSpan.FromMinutes(2))))
    .Build();
```

### Port Already in Use

Always use random port mapping. Module builders handle this by default, but the core container builder exposes it explicitly:

```csharp
.WithPortBinding(5432, true) // true = assign random public port
```

### Containers Not Cleaning Up

Ensure proper disposal:

```csharp
public async Task DisposeAsync()
{
    await _connection?.DisposeAsync();
    await _container?.DisposeAsync();
}
```

### Tests Fail in CI But Pass Locally

Ensure CI has Docker support:

```yaml
# GitHub Actions
runs-on: ubuntu-latest # Has Docker pre-installed
```

## CI/CD Integration

### GitHub Actions

```yaml
name: Integration Tests

on: [push, pull_request]

jobs:
  test:
    runs-on: ubuntu-latest

    steps:
    - uses: actions/checkout@v3

    - name: Setup .NET
      uses: actions/setup-dotnet@v3
      with:
        dotnet-version: 9.0.x

    - name: Run Integration Tests
      run: |
        dotnet test tests/YourApp.IntegrationTests \
          --filter Category=Integration \
          --logger trx

    - name: Cleanup Containers
      if: always()
      run: docker container prune -f
```

## Performance Tips

1. **Reuse containers** - Share fixtures across tests in a collection
2. **Use Respawn** - Reset data without recreating containers
3. **Parallel execution** - TestContainers handles port conflicts automatically
4. **Use lightweight images** - Alpine versions are smaller and faster
5. **Cache images** - Docker will cache pulled images locally
