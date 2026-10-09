# Database Testing Patterns

Full code examples for testing with SQL Server, PostgreSQL, and database migrations using TestContainers.

Uses the **TestContainers 3.0+ module builders**. See `SKILL.md` for the package list, required usings, and the API migration table.

## Contents

- [SQL Server Integration Tests](#sql-server-integration-tests)
- [PostgreSQL Integration Tests](#postgresql-integration-tests)
- [Testing Migrations with Real Databases](#testing-migrations-with-real-databases)

## SQL Server Integration Tests

```csharp
using Microsoft.Data.SqlClient;
using Testcontainers.MsSql;
using Xunit;

public class SqlServerTests : IAsyncLifetime
{
    private readonly MsSqlContainer _dbContainer;
    private SqlConnection _db;

    public SqlServerTests()
    {
        _dbContainer = new MsSqlBuilder("mcr.microsoft.com/mssql/server:2022-latest")
            .WithPassword("Your_password123")
            .Build();
    }

    public async Task InitializeAsync()
    {
        await _dbContainer.StartAsync();

        _db = new SqlConnection(_dbContainer.GetConnectionString());
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

## PostgreSQL Integration Tests

```csharp
using Npgsql;
using Testcontainers.PostgreSql;
using Xunit;

public class PostgreSqlTests : IAsyncLifetime
{
    private readonly PostgreSqlContainer _dbContainer;
    private NpgsqlConnection _connection;

    public PostgreSqlTests()
    {
        _dbContainer = new PostgreSqlBuilder("postgres:latest")
            .WithDatabase("testdb")
            .WithUsername("postgres")
            .WithPassword("postgres")
            .Build();
    }

    public async Task InitializeAsync()
    {
        await _dbContainer.StartAsync();

        _connection = new NpgsqlConnection(_dbContainer.GetConnectionString());
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

## Testing Migrations with Real Databases

```csharp
using Microsoft.Data.SqlClient;
using Testcontainers.MsSql;
using Xunit;

public class MigrationTests : IAsyncLifetime
{
    private readonly MsSqlContainer _container;
    private string _connectionString;

    public MigrationTests()
    {
        _container = new MsSqlBuilder("mcr.microsoft.com/mssql/server:2022-latest")
            .WithPassword("Your_password123")
            .Build();
    }

    public async Task InitializeAsync()
    {
        await _container.StartAsync();
        _connectionString = _container.GetConnectionString();
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
