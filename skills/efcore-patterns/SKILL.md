---
name: efcore-patterns
description: Entity Framework Core best practices including NoTracking by default, query splitting for navigation collections, migration management, dedicated migration services, and common pitfalls to avoid.
invocable: false
---

# Entity Framework Core Patterns

## When to Use This Skill

Use this skill when:
- Setting up EF Core in a new project
- Optimizing query performance
- Managing database migrations
- Integrating EF Core with .NET Aspire
- Debugging change tracking issues
- Loading multiple navigation collections efficiently (query splitting)

## Core Principles

1. **NoTracking by Default** - Most queries are read-only; opt-in to tracking
2. **Never Edit Migrations Manually** - Always use CLI commands
3. **Dedicated Migration Service** - Separate migration execution from application startup
4. **ExecutionStrategy for Retries** - Handle transient database failures
5. **Explicit Updates** - When NoTracking, explicitly mark entities for update

---

## Pattern 1: NoTracking by Default

Configure your DbContext to disable change tracking by default. This improves performance for read-heavy workloads.

```csharp
public class ApplicationDbContext : DbContext
{
    public ApplicationDbContext(DbContextOptions<ApplicationDbContext> options)
        : base(options)
    {
        // Disable change tracking by default for better performance on read-only queries
        // Use .AsTracking() explicitly for queries that need to track changes
        ChangeTracker.QueryTrackingBehavior = QueryTrackingBehavior.NoTracking;
    }

    public DbSet<Order> Orders => Set<Order>();
    public DbSet<Customer> Customers => Set<Customer>();
}
```

### When NoTracking is Active

**Read-only queries work normally:**
```csharp
// ✅ Fast read - no tracking overhead
var orders = await dbContext.Orders
    .Where(o => o.Status == OrderStatus.Pending)
    .ToListAsync();
```

**Writes require explicit handling:**
```csharp
// ❌ WRONG - Entity not tracked, SaveChanges does nothing
var order = await dbContext.Orders.FirstOrDefaultAsync(o => o.Id == orderId);
order.Status = OrderStatus.Shipped;
await dbContext.SaveChangesAsync(); // Nothing happens!

// ✅ CORRECT - Explicitly mark entity for update
var order = await dbContext.Orders.FirstOrDefaultAsync(o => o.Id == orderId);
order.Status = OrderStatus.Shipped;
dbContext.Orders.Update(order); // Marks entire entity as modified
await dbContext.SaveChangesAsync();

// ✅ ALSO CORRECT - Use AsTracking() for the query
var order = await dbContext.Orders
    .AsTracking()
    .FirstOrDefaultAsync(o => o.Id == orderId);
order.Status = OrderStatus.Shipped;
await dbContext.SaveChangesAsync(); // Works!
```

### When to Use Tracking

| Scenario | Use Tracking? | Why |
|----------|---------------|-----|
| Display data in UI | No | Read-only, no updates |
| API GET endpoints | No | Returning data, no mutations |
| Update single entity | Yes or explicit Update() | Need to save changes |
| Complex update with navigation | Yes | Tracking handles relationships |
| Batch operations | No + ExecuteUpdate | More efficient |

### Explicit Add/Update Pattern

```csharp
public class OrderService
{
    private readonly ApplicationDbContext _db;

    // CREATE - Always use Add (works regardless of tracking)
    public async Task<Order> CreateOrderAsync(Order order)
    {
        _db.Orders.Add(order);
        await _db.SaveChangesAsync();
        return order;
    }

    // UPDATE - Explicitly mark as modified
    public async Task UpdateOrderStatusAsync(Guid orderId, OrderStatus newStatus)
    {
        var order = await _db.Orders.FirstOrDefaultAsync(o => o.Id == orderId)
            ?? throw new NotFoundException($"Order {orderId} not found");

        order.Status = newStatus;
        order.UpdatedAt = DateTimeOffset.UtcNow;

        // Explicitly mark as modified since DbContext uses NoTracking by default
        _db.Orders.Update(order);
        await _db.SaveChangesAsync();
    }

    // DELETE - Attach and remove
    public async Task DeleteOrderAsync(Guid orderId)
    {
        var order = new Order { Id = orderId };
        _db.Orders.Remove(order);
        await _db.SaveChangesAsync();
    }
}
```

---

## Pattern 2: Never Edit Migrations Manually

**CRITICAL:** Always use EF Core CLI commands to manage migrations. Never:
- Manually edit migration files (except for custom SQL in `Up()`/`Down()`)
- Delete migration files directly
- Rename migration files
- Copy migrations between projects

### Creating Migrations

```bash
# Create a new migration
dotnet ef migrations add AddCustomerTable \
    --project src/MyApp.Infrastructure \
    --startup-project src/MyApp.Api

# With a specific DbContext (if you have multiple)
dotnet ef migrations add AddCustomerTable \
    --context ApplicationDbContext \
    --project src/MyApp.Infrastructure \
    --startup-project src/MyApp.Api
```

### Removing Migrations

```bash
# Remove the last migration (if not yet applied)
dotnet ef migrations remove \
    --project src/MyApp.Infrastructure \
    --startup-project src/MyApp.Api

# NEVER do this:
# rm Migrations/20240101_AddCustomerTable.cs  # ❌ BAD!
```

### Applying Migrations

```bash
# Apply all pending migrations
dotnet ef database update \
    --project src/MyApp.Infrastructure \
    --startup-project src/MyApp.Api

# Apply to a specific migration
dotnet ef database update AddCustomerTable \
    --project src/MyApp.Infrastructure \
    --startup-project src/MyApp.Api

# Rollback to a previous migration
dotnet ef database update PreviousMigrationName \
    --project src/MyApp.Infrastructure \
    --startup-project src/MyApp.Api
```

### Generating SQL Scripts

```bash
# Generate SQL script for all migrations
dotnet ef migrations script \
    --project src/MyApp.Infrastructure \
    --startup-project src/MyApp.Api \
    --output migrations.sql

# Generate idempotent script (safe to run multiple times)
dotnet ef migrations script \
    --idempotent \
    --project src/MyApp.Infrastructure \
    --startup-project src/MyApp.Api
```

---

## Pattern 3: Dedicated Migration Service with Aspire

Separate migration execution from your main application using a dedicated migration service. This ensures:
- Migrations complete before the app starts
- Clean separation of concerns
- Controlled seeding in test environments

### Project Structure

```
src/
├── MyApp.AppHost/           # Aspire orchestration
├── MyApp.Api/               # Main application
├── MyApp.Infrastructure/    # DbContext and migrations
└── MyApp.MigrationService/  # Dedicated migration runner
```

### MigrationService Program.cs

```csharp
using MyApp.Infrastructure.Data;
using MyApp.MigrationService;
using Microsoft.EntityFrameworkCore;

var builder = Host.CreateApplicationBuilder(args);

// Add Aspire service defaults
builder.AddServiceDefaults();

// Add PostgreSQL DbContext
var connectionString = builder.Configuration.GetConnectionString("appdb")
    ?? throw new InvalidOperationException("Connection string 'appdb' not found.");

builder.Services.AddDbContext<ApplicationDbContext>(options =>
    options.UseNpgsql(connectionString, npgsqlOptions =>
        npgsqlOptions.MigrationsAssembly("MyApp.Infrastructure")));

// Add the migration worker
builder.Services.AddHostedService<MigrationWorker>();

var host = builder.Build();
host.Run();
```

### MigrationWorker.cs

```csharp
public class MigrationWorker : BackgroundService
{
    private readonly IServiceProvider _serviceProvider;
    private readonly IHostApplicationLifetime _hostApplicationLifetime;
    private readonly ILogger<MigrationWorker> _logger;

    public MigrationWorker(
        IServiceProvider serviceProvider,
        IHostApplicationLifetime hostApplicationLifetime,
        ILogger<MigrationWorker> logger)
    {
        _serviceProvider = serviceProvider;
        _hostApplicationLifetime = hostApplicationLifetime;
        _logger = logger;
    }

    protected override async Task ExecuteAsync(CancellationToken stoppingToken)
    {
        _logger.LogInformation("Migration service starting...");

        try
        {
            using var scope = _serviceProvider.CreateScope();
            var dbContext = scope.ServiceProvider.GetRequiredService<ApplicationDbContext>();

            await RunMigrationsAsync(dbContext, stoppingToken);

            _logger.LogInformation("Migration service completed successfully.");
        }
        catch (Exception ex)
        {
            _logger.LogError(ex, "Migration service failed: {Error}", ex.Message);
            throw;
        }
        finally
        {
            // Stop the application after migrations complete
            _hostApplicationLifetime.StopApplication();
        }
    }

    private async Task RunMigrationsAsync(ApplicationDbContext dbContext, CancellationToken ct)
    {
        // Use execution strategy for transient failure handling
        var strategy = dbContext.Database.CreateExecutionStrategy();

        await strategy.ExecuteAsync(async () =>
        {
            var pendingMigrations = await dbContext.Database.GetPendingMigrationsAsync(ct);

            if (pendingMigrations.Any())
            {
                _logger.LogInformation("Applying {Count} pending migrations...",
                    pendingMigrations.Count());

                await dbContext.Database.MigrateAsync(ct);

                _logger.LogInformation("Migrations applied successfully.");
            }
            else
            {
                _logger.LogInformation("No pending migrations. Database is up to date.");
            }
        });
    }
}
```

### AppHost Configuration

```csharp
var builder = DistributedApplication.CreateBuilder(args);

var postgres = builder.AddPostgres("postgres");
var db = postgres.AddDatabase("appdb");

// Migrations run first, then exit
var migrations = builder.AddProject<Projects.MyApp_MigrationService>("migrations")
    .WaitFor(db)
    .WithReference(db);

// API waits for migrations to complete
var api = builder.AddProject<Projects.MyApp_Api>("api")
    .WaitForCompletion(migrations)  // Key: waits for migrations to finish
    .WithReference(db);
```

---

## Pattern 4: ExecutionStrategy for Transient Failures

Always use `CreateExecutionStrategy()` for operations that might fail transiently:

```csharp
public async Task UpdateWithRetryAsync(Guid id, Action<Order> update)
{
    var strategy = _dbContext.Database.CreateExecutionStrategy();

    await strategy.ExecuteAsync(async () =>
    {
        var order = await _dbContext.Orders
            .AsTracking()
            .FirstOrDefaultAsync(o => o.Id == id);

        if (order is null) return;

        update(order);
        await _dbContext.SaveChangesAsync();
    });
}
```

**Important:** You cannot use `CreateExecutionStrategy()` with user-initiated transactions. If you need transactions with retry:

```csharp
var strategy = _dbContext.Database.CreateExecutionStrategy();

await strategy.ExecuteAsync(async () =>
{
    // Transaction must be INSIDE the strategy callback
    await using var transaction = await _dbContext.Database.BeginTransactionAsync();

    try
    {
        // ... your operations ...
        await _dbContext.SaveChangesAsync();
        await transaction.CommitAsync();
    }
    catch
    {
        await transaction.RollbackAsync();
        throw;
    }
});
```

---

## Pattern 5: Bulk Operations with ExecuteUpdate/ExecuteDelete

For bulk operations, use EF Core 7+ `ExecuteUpdateAsync` and `ExecuteDeleteAsync` instead of loading entities:

```csharp
// ❌ SLOW - Loads all entities into memory
var expiredOrders = await _db.Orders
    .Where(o => o.ExpiresAt < DateTimeOffset.UtcNow)
    .ToListAsync();

foreach (var order in expiredOrders)
{
    order.Status = OrderStatus.Expired;
}
await _db.SaveChangesAsync();

// ✅ FAST - Single SQL UPDATE statement
await _db.Orders
    .Where(o => o.ExpiresAt < DateTimeOffset.UtcNow)
    .ExecuteUpdateAsync(setters => setters
        .SetProperty(o => o.Status, OrderStatus.Expired)
        .SetProperty(o => o.UpdatedAt, DateTimeOffset.UtcNow));

// ✅ FAST - Single SQL DELETE statement
await _db.Orders
    .Where(o => o.Status == OrderStatus.Cancelled && o.CreatedAt < cutoffDate)
    .ExecuteDeleteAsync();
```

---

## Common Pitfalls

### 1. Forgetting to Update When NoTracking

```csharp
// ❌ Silent failure - entity not tracked
var customer = await _db.Customers.FindAsync(id);
customer.Name = "New Name";
await _db.SaveChangesAsync(); // Does nothing!

// ✅ Explicit update
var customer = await _db.Customers.FindAsync(id);
customer.Name = "New Name";
_db.Customers.Update(customer);
await _db.SaveChangesAsync();
```

### 2. N+1 Query Problem

```csharp
// ❌ N+1 queries - one query per order
var customers = await _db.Customers.ToListAsync();
foreach (var customer in customers)
{
    var orders = customer.Orders; // Lazy load triggers query
}

// ✅ Eager loading - single query
var customers = await _db.Customers
    .Include(c => c.Orders)
    .ToListAsync();
```

### 3. Tracking Conflicts with Multiple DbContext Instances

```csharp
// ❌ Tracking conflict - entity tracked by different context
var order1 = await _db1.Orders.AsTracking().FindAsync(id);
var order2 = await _db2.Orders.AsTracking().FindAsync(id);
order2.Status = OrderStatus.Shipped;
await _db2.SaveChangesAsync(); // May throw or behave unexpectedly

// ✅ Use single context or detach first
_db1.Entry(order1).State = EntityState.Detached;
```

### 4. Not Using Async Consistently

```csharp
// ❌ Blocking call in async context
var orders = _db.Orders.ToList(); // Blocks thread

// ✅ Async all the way
var orders = await _db.Orders.ToListAsync();
```

### 5. Querying Inside Loops

```csharp
// ❌ Query per iteration
foreach (var orderId in orderIds)
{
    var order = await _db.Orders.FindAsync(orderId);
    // process order
}

// ✅ Single query
var orders = await _db.Orders
    .Where(o => orderIds.Contains(o.Id))
    .ToListAsync();
```

---

## DbContext Lifetime in DI

### ASP.NET Core (Scoped by Default)

```csharp
// Scoped = one instance per HTTP request
builder.Services.AddDbContext<ApplicationDbContext>(options =>
    options.UseNpgsql(connectionString));
```

### Background Services (Create Scope)

```csharp
public class MyBackgroundService : BackgroundService
{
    private readonly IServiceProvider _serviceProvider;

    protected override async Task ExecuteAsync(CancellationToken stoppingToken)
    {
        // ✅ Create scope for each unit of work
        using var scope = _serviceProvider.CreateScope();
        var dbContext = scope.ServiceProvider.GetRequiredService<ApplicationDbContext>();

        // ... use dbContext ...
    }
}
```

### Actors / Long-Lived Objects (Factory Pattern)

```csharp
public class OrderActor : ReceiveActor
{
    private readonly IDbContextFactory<ApplicationDbContext> _dbFactory;

    public OrderActor(IDbContextFactory<ApplicationDbContext> dbFactory)
    {
        _dbFactory = dbFactory;

        ReceiveAsync<GetOrder>(async msg =>
        {
            // Create fresh context for each operation
            await using var db = await _dbFactory.CreateDbContextAsync();
            var order = await db.Orders.FindAsync(msg.OrderId);
            Sender.Tell(order);
        });
    }
}

// Registration
builder.Services.AddDbContextFactory<ApplicationDbContext>(options =>
    options.UseNpgsql(connectionString));
```

---

## Pattern 6: Query Splitting to Prevent Cartesian Explosion

When you load multiple navigation collections via `Include()`, EF Core generates a single query that can cause cartesian explosion. If you have 10 orders with 10 items each, you get 100 rows instead of 10 + 10.

### Global Configuration (Recommended for Most Cases)

Enable query splitting globally in your DbContext configuration:

```csharp
services.AddDbContext<ApplicationDbContext>(options =>
    options.UseNpgsql(connectionString, npgsqlOptions =>
        {
            npgsqlOptions.UseQuerySplittingBehavior(QuerySplittingBehavior.SplitQuery);
        }));
```

### Per-Query Override

Use single query when you know it's more efficient:

```csharp
// Use single query when you know the structure is well-understood
var orders = await dbContext.Orders
    .Include(o => o.Items)
    .Include(o => o.Payments)
    .AsSingleQuery()  // Override global split behavior
    .ToListAsync();
```

### Trade-offs

| Behavior | Pros | Cons |
|-----------|-------|-------|
| SplitQuery | No cartesian explosion, better for large collections | Multiple round-trips, potential consistency issues |
| SingleQuery | Single round-trip, transactional consistency | Cartesian explosion with multiple collections |

**Recommendation**: Default to `SplitQuery` globally, override with `AsSingleQuery()` for specific queries where single-query is known to be better.

### When to Prefer SingleQuery

- Small, well-understood navigation graphs (2-3 levels)
- Queries where all related data is always needed
- Performance-critical paths where round-trip cost is lower than cartesian explosion

### When to Prefer SplitQuery

- Large or unpredictable navigation graphs
- Many-to-many relationships
- Queries loading collections that may not all be needed

---

## Testing with EF Core

### In-Memory Provider (Unit Tests Only)

```csharp
// Only for simple unit tests - doesn't match real database behavior
var options = new DbContextOptionsBuilder<ApplicationDbContext>()
    .UseInMemoryDatabase(databaseName: Guid.NewGuid().ToString())
    .Options;

using var context = new ApplicationDbContext(options);
```

### Real Database with TestContainers (Integration Tests)

See the `testcontainers-integration-tests` skill for proper database testing.

```csharp
// Use real PostgreSQL in container
var container = new PostgreSqlBuilder()
    .WithImage("postgres:16-alpine")
    .Build();

await container.StartAsync();

var options = new DbContextOptionsBuilder<ApplicationDbContext>()
    .UseNpgsql(container.GetConnectionString())
    .Options;
```
