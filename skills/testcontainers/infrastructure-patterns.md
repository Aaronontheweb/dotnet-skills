# Infrastructure Testing Patterns

Patterns for testing Redis, RabbitMQ, multi-container networks, container reuse, and database reset with Respawn.

Uses the **TestContainers 3.0+ module builders**. See `SKILL.md` for the package list, required usings, and the API migration table.

## Contents

- [Redis Integration Tests](#redis-integration-tests)
- [RabbitMQ Integration Tests](#rabbitmq-integration-tests)
- [Multi-Container Networks](#multi-container-networks)
- [Reusing Containers Across Tests](#reusing-containers-across-tests)
- [Database Reset with Respawn](#database-reset-with-respawn)

## Redis Integration Tests

```csharp
using StackExchange.Redis;
using Testcontainers.Redis;
using Xunit;

public class RedisTests : IAsyncLifetime
{
    private readonly RedisContainer _redisContainer;
    private IConnectionMultiplexer _redis;

    public RedisTests()
    {
        _redisContainer = new RedisBuilder("redis:alpine")
            .Build();
    }

    public async Task InitializeAsync()
    {
        await _redisContainer.StartAsync();

        _redis = await ConnectionMultiplexer.ConnectAsync(_redisContainer.GetConnectionString());
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

        await db.StringSetAsync("key1", "value1");
        var value = await db.StringGetAsync("key1");

        Assert.Equal("value1", value.ToString());
    }

    [Fact]
    public async Task Redis_ShouldExpireKeys()
    {
        var db = _redis.GetDatabase();

        await db.StringSetAsync("temp-key", "temp-value",
            expiry: TimeSpan.FromSeconds(1));

        Assert.True(await db.KeyExistsAsync("temp-key"));

        await Task.Delay(1100);

        Assert.False(await db.KeyExistsAsync("temp-key"));
    }
}
```

## RabbitMQ Integration Tests

```csharp
using RabbitMQ.Client;
using RabbitMQ.Client.Events;
using Testcontainers.RabbitMq;
using Xunit;

public class RabbitMqTests : IAsyncLifetime
{
    private readonly RabbitMqContainer _rabbitContainer;
    private IConnection _connection;

    public RabbitMqTests()
    {
        _rabbitContainer = new RabbitMqBuilder("rabbitmq:management-alpine")
            .WithUsername("guest")
            .WithPassword("guest")
            .Build();
    }

    public async Task InitializeAsync()
    {
        await _rabbitContainer.StartAsync();

        var factory = new ConnectionFactory
        {
            HostName = "localhost",
            Port = _rabbitContainer.GetMappedPublicPort(5672),
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

        var message = "Hello, RabbitMQ!";
        var body = Encoding.UTF8.GetBytes(message);
        await channel.BasicPublishAsync(exchange: "",
            routingKey: queueName,
            body: body);

        var consumer = new AsyncEventingBasicConsumer(channel);
        var tcs = new TaskCompletionSource<string>();

        consumer.ReceivedAsync += async (model, ea) =>
        {
            var receivedMessage = Encoding.UTF8.GetString(ea.Body.ToArray());
            tcs.TrySetResult(receivedMessage);
            await Task.CompletedTask;
        };

        await channel.BasicConsumeAsync(queueName, autoAck: true,
            consumer: consumer);

        var received = await tcs.Task.WaitAsync(TimeSpan.FromSeconds(5));

        Assert.Equal(message, received);
    }
}
```

## Multi-Container Networks

When you need multiple containers to communicate:

```csharp
using DotNet.Testcontainers.Builders;
using DotNet.Testcontainers.Networks;
using Testcontainers.PostgreSql;
using Testcontainers.Redis;
using Xunit;

public class MultiContainerTests : IAsyncLifetime
{
    private readonly INetwork _network;
    private readonly PostgreSqlContainer _dbContainer;
    private readonly RedisContainer _redisContainer;

    public MultiContainerTests()
    {
        _network = new NetworkBuilder()
            .Build();

        _dbContainer = new PostgreSqlBuilder("postgres:latest")
            .WithDatabase("testdb")
            .WithUsername("postgres")
            .WithPassword("postgres")
            .WithNetwork(_network)
            .WithNetworkAliases("db")
            .Build();

        _redisContainer = new RedisBuilder("redis:alpine")
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

## Reusing Containers Across Tests

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
    }

    [Fact]
    public async Task Test2()
    {
        // Reuses the same container
    }
}

// Shared fixture
using Microsoft.Data.SqlClient;
using Testcontainers.MsSql;

public class DatabaseFixture : IAsyncLifetime
{
    private readonly MsSqlContainer _container;
    public SqlConnection Connection { get; private set; }

    public DatabaseFixture()
    {
        _container = new MsSqlBuilder("mcr.microsoft.com/mssql/server:2022-latest")
            .WithDatabase("TestDb")
            .WithPassword("Your_password123")
            .Build();
    }

    public async Task InitializeAsync()
    {
        await _container.StartAsync();
        Connection = new SqlConnection(_container.GetConnectionString());
        await Connection.OpenAsync();
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

## Database Reset with Respawn

When reusing containers, use [Respawn](https://github.com/jbogard/Respawn) to reset database state between tests:

```xml
<PackageReference Include="Respawn" Version="*" />
```

### Basic Respawn Setup

```csharp
using Npgsql;
using Respawn;
using Testcontainers.PostgreSql;

public class DatabaseFixture : IAsyncLifetime
{
    private readonly PostgreSqlContainer _container;
    private Respawner _respawner = null!;
    public NpgsqlConnection Connection { get; private set; } = null!;
    public string ConnectionString { get; private set; } = null!;

    public DatabaseFixture()
    {
        _container = new PostgreSqlBuilder("postgres:latest")
            .WithDatabase("testdb")
            .WithUsername("postgres")
            .WithPassword("postgres")
            .Build();
    }

    public async Task InitializeAsync()
    {
        await _container.StartAsync();

        ConnectionString = _container.GetConnectionString();

        Connection = new NpgsqlConnection(ConnectionString);
        await Connection.OpenAsync();

        await RunMigrationsAsync();

        _respawner = await Respawner.CreateAsync(ConnectionString, new RespawnerOptions
        {
            TablesToIgnore = new Table[]
            {
                "__EFMigrationsHistory",
                "AspNetRoles",
                "schema_version"
            },
            DbAdapter = DbAdapter.Postgres
        });
    }

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
        await _fixture.ResetDatabaseAsync();
    }

    public Task DisposeAsync() => Task.CompletedTask;

    [Fact]
    public async Task CreateOrder_ShouldPersist()
    {
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
    TablesToIgnore = new Table[]
    {
        "__EFMigrationsHistory",
        new Table("public", "lookup_data"),
    },
    SchemasToInclude = new[] { "public", "app" },
    SchemasToExclude = new[] { "audit", "logging" },
    DbAdapter = DbAdapter.Postgres,
    WithReseed = true
});
```

### Why Respawn Over Container Recreation

| Approach | Pros | Cons |
|----------|------|------|
| **New container per test** | Complete isolation | Slow (10-30s per container) |
| **Respawn** | Fast (~50ms), preserves schema/migrations | Requires careful table exclusion |
| **Transaction rollback** | Fastest | Can't test commit behavior |
