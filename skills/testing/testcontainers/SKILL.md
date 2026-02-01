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

## Core Principles

1. **Real Infrastructure Over Mocks** - Use actual databases/services in containers, not mocks
2. **Test Isolation** - Each test gets fresh containers or fresh data
3. **Automatic Cleanup** - TestContainers handles container lifecycle and cleanup
4. **Fast Startup** - Reuse containers across tests in the same class when appropriate
5. **CI/CD Compatible** - Works seamlessly in Docker-enabled CI environments
6. **Port Randomization** - Containers use random ports to avoid conflicts

## Why TestContainers Over Mocks?

### ❌ Problems with Mocking Infrastructure

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

Problems:
- Doesn't test actual SQL queries
- Misses database constraints, indexes, and performance
- Can give false confidence
- Doesn't catch SQL syntax errors or schema mismatches

### ✅ Better: TestContainers with Real Database

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

        // Run migrations
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
        // Arrange: Insert real test data
        await _connection.ExecuteAsync(
            "INSERT INTO Orders (Id, CustomerId, Total) VALUES (1, 'CUST1', 100.00)");

        var repo = new OrderRepository(_connection);

        // Act: Execute against real database
        var order = await repo.GetOrderAsync(1);

        // Assert: Verify actual database behavior
        Assert.NotNull(order);
        Assert.Equal(1, order.Id);
        Assert.Equal("CUST1", order.CustomerId);
        Assert.Equal(100.00m, order.Total);
    }
}
```

Benefits:
- Tests real SQL queries and database behavior
- Catches constraint violations, index issues, and performance problems
- Verifies migrations work correctly
- Gives true confidence in data access layer

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

## Pattern 1: SQL Server Integration Tests

```csharp
using Testcontainers;
using Xunit;

public class SqlServerTests : IAsyncLifetime
{
    private readonly TestcontainersContainer _dbContainer;
    private IDbConnection _db;

    public SqlServerTests()
    {
        _dbContainer = new TestcontainersBuilder<TestcontainersContainer>()
            .WithImage("mcr.microsoft.com/mssql/server:2022-latest")
            .WithEnvironment("ACCEPT_EULA", "Y")
            .WithEnvironment("SA_PASSWORD", "Your_password123")
            .WithPortBinding(1433, true)
            .WithWaitStrategy(Wait.ForUnixContainer().UntilPortIsAvailable(1433))
            .Build();
    }

    public async Task InitializeAsync()
    {
        await _dbContainer.StartAsync();

        var port = _dbContainer.GetMappedPublicPort(1433);
        var connectionString = $"Server=localhost,{port};Database=master;User Id=sa;Password=Your_password123;TrustServerCertificate=true";

        _db = new SqlConnection(connectionString);
        await _db.OpenAsync();

        // Create test database
        await _db.ExecuteAsync("CREATE DATABASE TestDb");
        await _db.ExecuteAsync("USE TestDb");

        // Run schema migrations
        await _db.ExecuteAsync(@"
            CREATE TABLE Orders (
                Id INT PRIMARY KEY,
                CustomerId NVARCHAR(50) NOT NULL,
                Total DECIMAL(18,2) NOT NULL,
                CreatedAt DATETIME2 DEFAULT GETUTCDATE()
            )");
    }

    public async Task DisposeAsync()
    {
        await _db.DisposeAsync();
        await _dbContainer.DisposeAsync();
    }

    [Fact]
    public async Task CanInsertAndRetrieveOrder()
    {
        // Arrange
        await _db.ExecuteAsync(@"
            INSERT INTO Orders (Id, CustomerId, Total)
            VALUES (1, 'CUST001', 99.99)");

        // Act
        var order = await _db.QuerySingleAsync<Order>(
            "SELECT * FROM Orders WHERE Id = @Id",
            new { Id = 1 });

        // Assert
        Assert.Equal(1, order.Id);
        Assert.Equal("CUST001", order.CustomerId);
        Assert.Equal(99.99m, order.Total);
    }
}
```

## Pattern 2: PostgreSQL Integration Tests

```csharp
public class PostgreSqlTests : IAsyncLifetime
{
    private readonly TestcontainersContainer _dbContainer;
    private NpgsqlConnection _connection;

    public PostgreSqlTests()
    {
        _dbContainer = new TestcontainersBuilder<TestcontainersContainer>()
            .WithImage("postgres:latest")
            .WithEnvironment("POSTGRES_PASSWORD", "postgres")
            .WithEnvironment("POSTGRES_DB", "testdb")
            .WithPortBinding(5432, true)
            .WithWaitStrategy(Wait.ForUnixContainer().UntilPortIsAvailable(5432))
            .Build();
    }

    public async Task InitializeAsync()
    {
        await _dbContainer.StartAsync();

        var port = _dbContainer.GetMappedPublicPort(5432);
        var connectionString = $"Host=localhost;Port={port};Database=testdb;Username=postgres;Password=postgres";

        _connection = new NpgsqlConnection(connectionString);
        await _connection.OpenAsync();

        // Create schema
        await _connection.ExecuteAsync(@"
            CREATE TABLE orders (
                id SERIAL PRIMARY KEY,
                customer_id VARCHAR(50) NOT NULL,
                total NUMERIC(10,2) NOT NULL,
                created_at TIMESTAMP DEFAULT NOW()
            )");
    }

    public async Task DisposeAsync()
    {
        await _connection.DisposeAsync();
        await _dbContainer.DisposeAsync();
    }

    [Fact]
    public async Task PostgreSql_ShouldHandleTransactions()
    {
        using var transaction = await _connection.BeginTransactionAsync();

        await _connection.ExecuteAsync(
            "INSERT INTO orders (customer_id, total) VALUES (@CustomerId, @Total)",
            new { CustomerId = "CUST1", Total = 100.00m },
            transaction);

        await transaction.RollbackAsync();

        var count = await _connection.QuerySingleAsync<int>(
            "SELECT COUNT(*) FROM orders");

        Assert.Equal(0, count); // Rollback should prevent insert
    }
}
```

## Pattern 3: Redis Integration Tests

```csharp
public class RedisTests : IAsyncLifetime
{
    private readonly TestcontainersContainer _redisContainer;
    private IConnectionMultiplexer _redis;

    public RedisTests()
    {
        _redisContainer = new TestcontainersBuilder<TestcontainersContainer>()
            .WithImage("redis:alpine")
            .WithPortBinding(6379, true)
            .WithWaitStrategy(Wait.ForUnixContainer().UntilPortIsAvailable(6379))
            .Build();
    }

    public async Task InitializeAsync()
    {
        await _redisContainer.StartAsync();

        var port = _redisContainer.GetMappedPublicPort(6379);
        _redis = await ConnectionMultiplexer.ConnectAsync($"localhost:{port}");
    }

    public async Task DisposeAsync()
    {
        await _redis.DisposeAsync();
        await _redisContainer.DisposeAsync();
    }

    [Fact]
    public async Task Redis_ShouldCacheValues()
    {
        var db = _redis.GetDatabase();

        // Set value
        await db.StringSetAsync("key1", "value1");

        // Get value
        var value = await db.StringGetAsync("key1");

        Assert.Equal("value1", value.ToString());
    }

    [Fact]
    public async Task Redis_ShouldExpireKeys()
    {
        var db = _redis.GetDatabase();

        await db.StringSetAsync("temp-key", "temp-value",
            expiry: TimeSpan.FromSeconds(1));

        // Key should exist
        Assert.True(await db.KeyExistsAsync("temp-key"));

        // Wait for expiry
        await Task.Delay(1100);

        // Key should be gone
        Assert.False(await db.KeyExistsAsync("temp-key"));
    }
}
```

## Pattern 4: RabbitMQ Integration Tests

```csharp
public class RabbitMqTests : IAsyncLifetime
{
    private readonly TestcontainersContainer _rabbitContainer;
    private IConnection _connection;

    public RabbitMqTests()
    {
        _rabbitContainer = new TestcontainersBuilder<TestcontainersContainer>()
            .WithImage("rabbitmq:management-alpine")
            .WithPortBinding(5672, true) // AMQP
            .WithPortBinding(15672, true) // Management UI
            .WithWaitStrategy(Wait.ForUnixContainer().UntilPortIsAvailable(5672))
            .Build();
    }

    public async Task InitializeAsync()
    {
        await _rabbitContainer.StartAsync();

        var port = _rabbitContainer.GetMappedPublicPort(5672);
        var factory = new ConnectionFactory
        {
            HostName = "localhost",
            Port = port,
            UserName = "guest",
            Password = "guest"
        };

        _connection = await factory.CreateConnectionAsync();
    }

    public async Task DisposeAsync()
    {
        await _connection.CloseAsync();
        await _rabbitContainer.DisposeAsync();
    }

    [Fact]
    public async Task RabbitMq_ShouldPublishAndConsumeMessage()
    {
        using var channel = await _connection.CreateChannelAsync();

        var queueName = "test-queue";
        await channel.QueueDeclareAsync(queueName, durable: false,
            exclusive: false, autoDelete: true);

        // Publish message
        var message = "Hello, RabbitMQ!";
        var body = Encoding.UTF8.GetBytes(message);
        await channel.BasicPublishAsync(exchange: "",
            routingKey: queueName,
            body: body);

        // Consume message
        var consumer = new EventingBasicConsumer(channel);
        var tcs = new TaskCompletionSource<string>();

        consumer.Received += (model, ea) =>
        {
            var receivedMessage = Encoding.UTF8.GetString(ea.Body.ToArray());
            tcs.SetResult(receivedMessage);
        };

        await channel.BasicConsumeAsync(queueName, autoAck: true,
            consumer: consumer);

        // Wait for message
        var received = await tcs.Task.WaitAsync(TimeSpan.FromSeconds(5));

        Assert.Equal(message, received);
    }
}
```

## Pattern 5: Multi-Container Networks

When you need multiple containers to communicate:

```csharp
public class MultiContainerTests : IAsyncLifetime
{
    private readonly INetwork _network;
    private readonly TestcontainersContainer _dbContainer;
    private readonly TestcontainersContainer _redisContainer;

    public MultiContainerTests()
    {
        _network = new TestcontainersNetworkBuilder()
            .Build();

        _dbContainer = new TestcontainersBuilder<TestcontainersContainer>()
            .WithImage("postgres:latest")
            .WithNetwork(_network)
            .WithNetworkAliases("db")
            .WithEnvironment("POSTGRES_PASSWORD", "postgres")
            .Build();

        _redisContainer = new TestcontainersBuilder<TestcontainersContainer>()
            .WithImage("redis:alpine")
            .WithNetwork(_network)
            .WithNetworkAliases("redis")
            .Build();
    }

    public async Task InitializeAsync()
    {
        await _network.CreateAsync();
        await Task.WhenAll(
            _dbContainer.StartAsync(),
            _redisContainer.StartAsync());
    }

    public async Task DisposeAsync()
    {
        await Task.WhenAll(
            _dbContainer.DisposeAsync().AsTask(),
            _redisContainer.DisposeAsync().AsTask());
        await _network.DisposeAsync();
    }

    [Fact]
    public async Task Containers_CanCommunicate()
    {
        // Both containers can reach each other via network aliases
        // db -> redis://redis:6379
        // redis -> postgres://db:5432
    }
}
```

## Pattern 6: Reusing Containers Across Tests

For faster test execution, reuse containers across tests in a class:

```csharp
[Collection("Database collection")]
public class FastDatabaseTests
{
    private readonly DatabaseFixture _fixture;

    public FastDatabaseTests(DatabaseFixture fixture)
    {
        _fixture = fixture;
    }

    [Fact]
    public async Task Test1()
    {
        // Use _fixture.Connection
        // Clean up data after test if needed
    }

    [Fact]
    public async Task Test2()
    {
        // Reuses the same container
    }
}

// Shared fixture
public class DatabaseFixture : IAsyncLifetime
{
    private readonly TestcontainersContainer _container;
    public IDbConnection Connection { get; private set; }

    public DatabaseFixture()
    {
        _container = new TestcontainersBuilder<TestcontainersContainer>()
            .WithImage("mcr.microsoft.com/mssql/server:2022-latest")
            .WithEnvironment("ACCEPT_EULA", "Y")
            .WithEnvironment("SA_PASSWORD", "Your_password123")
            .WithPortBinding(1433, true)
            .Build();
    }

    public async Task InitializeAsync()
    {
        await _container.StartAsync();
        // Setup connection
    }

    public async Task DisposeAsync()
    {
        await Connection.DisposeAsync();
        await _container.DisposeAsync();
    }
}

[CollectionDefinition("Database collection")]
public class DatabaseCollection : ICollectionFixture<DatabaseFixture> { }
```

## Pattern 7: Testing Migrations with Real Databases

```csharp
public class MigrationTests : IAsyncLifetime
{
    private readonly TestcontainersContainer _container;
    private string _connectionString;

    public async Task InitializeAsync()
    {
        _container = new TestcontainersBuilder<TestcontainersContainer>()
            .WithImage("mcr.microsoft.com/mssql/server:2022-latest")
            .WithEnvironment("ACCEPT_EULA", "Y")
            .WithEnvironment("SA_PASSWORD", "Your_password123")
            .WithPortBinding(1433, true)
            .Build();

        await _container.StartAsync();

        var port = _container.GetMappedPublicPort(1433);
        _connectionString = $"Server=localhost,{port};Database=TestDb;User Id=sa;Password=Your_password123;TrustServerCertificate=true";
    }

    [Fact]
    public async Task Migrations_ShouldRunSuccessfully()
    {
        // Run Entity Framework migrations
        var optionsBuilder = new DbContextOptionsBuilder<AppDbContext>();
        optionsBuilder.UseSqlServer(_connectionString);

        using var context = new AppDbContext(optionsBuilder.Options);

        // Apply migrations
        await context.Database.MigrateAsync();

        // Verify schema
        var canConnect = await context.Database.CanConnectAsync();
        Assert.True(canConnect);

        // Verify tables exist
        var tables = await context.Database.SqlQueryRaw<string>(
            "SELECT TABLE_NAME FROM INFORMATION_SCHEMA.TABLES").ToListAsync();

        Assert.Contains("Orders", tables);
        Assert.Contains("Customers", tables);
    }

    public async Task DisposeAsync()
    {
        await _container.DisposeAsync();
    }
}
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

### Issue 1: Container Startup Timeout

**Problem:** Container takes too long to start

**Solution:**
```csharp
_container = new TestcontainersBuilder<TestcontainersContainer>()
    .WithImage("postgres:latest")
    .WithWaitStrategy(Wait.ForUnixContainer()
        .UntilPortIsAvailable(5432)
        .WithTimeout(TimeSpan.FromMinutes(2)))
    .Build();
```

### Issue 2: Port Already in Use

**Problem:** Tests fail because port is already bound

**Solution:** Always use random port mapping:
```csharp
.WithPortBinding(5432, true) // true = assign random public port
```

### Issue 3: Containers Not Cleaning Up

**Problem:** Containers remain running after tests

**Solution:** Ensure proper disposal:
```csharp
public async Task DisposeAsync()
{
    await _connection?.DisposeAsync();
    await _container?.DisposeAsync();
}
```

### Issue 4: Tests Fail in CI But Pass Locally

**Problem:** CI environment doesn't have Docker

**Solution:** Ensure CI has Docker support:
```yaml
# GitHub Actions
runs-on: ubuntu-latest # Has Docker pre-installed
services:
  docker:
    image: docker:dind
```

## CI/CD Integration

### GitHub Actions

```yaml
name: Integration Tests

on: [push, pull_request]

jobs:
  test:
    runs-on: ubuntu-latest # Has Docker pre-installed

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

## Pattern 8: Database Reset with Respawn

When reusing containers across tests, use [Respawn](https://github.com/jbogard/Respawn) to reset database state between tests instead of recreating containers:

```xml
<PackageReference Include="Respawn" Version="*" />
```

### Basic Respawn Setup

```csharp
using Respawn;

public class DatabaseFixture : IAsyncLifetime
{
    private readonly TestcontainersContainer _container;
    private Respawner _respawner = null!;
    public NpgsqlConnection Connection { get; private set; } = null!;
    public string ConnectionString { get; private set; } = null!;

    public async Task InitializeAsync()
    {
        await _container.StartAsync();

        var port = _container.GetMappedPublicPort(5432);
        ConnectionString = $"Host=localhost;Port={port};Database=testdb;Username=postgres;Password=postgres";

        Connection = new NpgsqlConnection(ConnectionString);
        await Connection.OpenAsync();

        // Run migrations first
        await RunMigrationsAsync();

        // Create respawner after schema exists
        _respawner = await Respawner.CreateAsync(ConnectionString, new RespawnerOptions
        {
            TablesToIgnore = new Table[]
            {
                "__EFMigrationsHistory",  // EF Core migrations table
                "AspNetRoles",            // Identity roles (seeded data)
                "schema_version"          // DbUp/Flyway version table
            },
            DbAdapter = DbAdapter.Postgres
        });
    }

    /// <summary>
    /// Reset database to clean state. Call this in test setup or between tests.
    /// </summary>
    public async Task ResetDatabaseAsync()
    {
        await _respawner.ResetAsync(ConnectionString);
    }

    public async Task DisposeAsync()
    {
        await Connection.DisposeAsync();
        await _container.DisposeAsync();
    }
}
```

### Using Respawn in Tests

```csharp
[Collection("Database collection")]
public class OrderTests : IAsyncLifetime
{
    private readonly DatabaseFixture _fixture;

    public OrderTests(DatabaseFixture fixture)
    {
        _fixture = fixture;
    }

    public async Task InitializeAsync()
    {
        // Reset database before each test
        await _fixture.ResetDatabaseAsync();
    }

    public Task DisposeAsync() => Task.CompletedTask;

    [Fact]
    public async Task CreateOrder_ShouldPersist()
    {
        // Database is clean - no leftover data from other tests
        await _fixture.Connection.ExecuteAsync(
            "INSERT INTO orders (customer_id, total) VALUES (@CustomerId, @Total)",
            new { CustomerId = "CUST1", Total = 100.00m });

        var count = await _fixture.Connection.QuerySingleAsync<int>(
            "SELECT COUNT(*) FROM orders");

        Assert.Equal(1, count);
    }

    [Fact]
    public async Task AnotherTest_StartsWithCleanDatabase()
    {
        // This test also starts with empty tables
        var count = await _fixture.Connection.QuerySingleAsync<int>(
            "SELECT COUNT(*) FROM orders");

        Assert.Equal(0, count); // Clean slate!
    }
}
```

### Respawn Options

```csharp
var respawner = await Respawner.CreateAsync(connectionString, new RespawnerOptions
{
    // Tables to preserve (reference data, migrations history)
    TablesToIgnore = new Table[]
    {
        "__EFMigrationsHistory",
        new Table("public", "lookup_data"),  // Schema-qualified
    },

    // Schemas to clean (default: all schemas)
    SchemasToInclude = new[] { "public", "app" },

    // Or exclude specific schemas
    SchemasToExclude = new[] { "audit", "logging" },

    // Database adapter
    DbAdapter = DbAdapter.Postgres,  // or SqlServer, MySql

    // Handle circular foreign keys
    WithReseed = true  // Reset identity columns (SQL Server)
});
```

### Why Respawn Over Container Recreation

| Approach | Pros | Cons |
|----------|------|------|
| **New container per test** | Complete isolation | Slow (10-30s per container) |
| **Respawn** | Fast (~50ms), preserves schema/migrations | Requires careful table exclusion |
| **Transaction rollback** | Fastest | Can't test commit behavior |

**Use Respawn when:**
- Tests share a container via xUnit collection fixture
- You need to test actual commits (not just rollbacks)
- Container startup time is a bottleneck

## Performance Tips

1. **Reuse containers** - Share fixtures across tests in a collection
2. **Use Respawn** - Reset data without recreating containers
3. **Parallel execution** - TestContainers handles port conflicts automatically
4. **Use lightweight images** - Alpine versions are smaller and faster
5. **Cache images** - Docker will cache pulled images locally
6. **Limit container resources** - Set CPU/memory limits if needed:

```csharp
.WithResourceMapping(new CpuCount(2))
.WithResourceMapping(new MemoryLimit(512 * 1024 * 1024)) // 512MB
```
