# Infrastructure Testing Patterns

Patterns for testing Redis, RabbitMQ, multi-container networks, container reuse, and database reset with Respawn.

## Contents

- [Redis Integration Tests](#redis-integration-tests)
- [RabbitMQ Integration Tests](#rabbitmq-integration-tests)
- [Multi-Container Networks](#multi-container-networks)
- [Reusing Containers Across Tests](#reusing-containers-across-tests)
- [Database Reset with Respawn](#database-reset-with-respawn)

## Redis Integration Tests

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
public class RabbitMqTests : IAsyncLifetime
{
    private readonly TestcontainersContainer _rabbitContainer;
    private IConnection _connection;

    public RabbitMqTests()
    {
        _rabbitContainer = new TestcontainersBuilder<TestcontainersContainer>()
            .WithImage("rabbitmq:management-alpine")
            .WithPortBinding(5672, true)
            .WithPortBinding(15672, true)
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

        var message = "Hello, RabbitMQ!";
        var body = Encoding.UTF8.GetBytes(message);
        await channel.BasicPublishAsync(exchange: "",
            routingKey: queueName,
            body: body);

        var consumer = new EventingBasicConsumer(channel);
        var tcs = new TaskCompletionSource<string>();

        consumer.Received += (model, ea) =>
        {
            var receivedMessage = Encoding.UTF8.GetString(ea.Body.ToArray());
            tcs.SetResult(receivedMessage);
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

## Database Reset with Respawn

When reusing containers, use [Respawn](https://github.com/jbogard/Respawn) to reset database state between tests:

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
