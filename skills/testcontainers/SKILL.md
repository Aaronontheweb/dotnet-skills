---
name: testcontainers-integration-tests
description: Write integration tests using TestContainers for .NET with xUnit. Covers infrastructure testing with real databases, message queues, and caches in Docker containers instead of mocks.
invocable: false
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
    private readonly TestcontainersContainer _dbContainer;
    private IDbConnection _connection;

    public OrderRepositoryTests()
    {
        _dbContainer = new TestcontainersBuilder<TestcontainersContainer>()
            .WithImage("mcr.microsoft.com/mssql/server:2022-latest")
            .WithEnvironment("ACCEPT_EULA", "Y")
            .WithEnvironment("SA_PASSWORD", "Your_password123")
            .WithPortBinding(1433, true)
            .Build();
    }

    public async Task InitializeAsync()
    {
        await _dbContainer.StartAsync();
        var port = _dbContainer.GetMappedPublicPort(1433);
        var connectionString = $"Server=localhost,{port};Database=TestDb;User Id=sa;Password=Your_password123;TrustServerCertificate=true";
        _connection = new SqlConnection(connectionString);
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

```xml
<ItemGroup>
  <PackageReference Include="Testcontainers" Version="*" />
  <PackageReference Include="xunit" Version="*" />
  <PackageReference Include="xunit.runner.visualstudio" Version="*" />

  <!-- Database-specific packages -->
  <PackageReference Include="Microsoft.Data.SqlClient" Version="*" />
  <PackageReference Include="Npgsql" Version="*" /> <!-- For PostgreSQL -->
  <PackageReference Include="MySqlConnector" Version="*" /> <!-- For MySQL -->

  <!-- Other infrastructure -->
  <PackageReference Include="StackExchange.Redis" Version="*" /> <!-- For Redis -->
  <PackageReference Include="RabbitMQ.Client" Version="*" /> <!-- For RabbitMQ -->
</ItemGroup>
```

## Best Practices

1. **Always Use IAsyncLifetime** - Proper async setup and teardown
2. **Wait for Port Availability** - Use `WaitStrategy` to ensure containers are ready
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
_container = new TestcontainersBuilder<TestcontainersContainer>()
    .WithImage("postgres:latest")
    .WithWaitStrategy(Wait.ForUnixContainer()
        .UntilPortIsAvailable(5432)
        .WithTimeout(TimeSpan.FromMinutes(2)))
    .Build();
```

### Port Already in Use

Always use random port mapping:
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
