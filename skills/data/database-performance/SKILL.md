---
name: database-performance
description: Database access patterns for performance. Separate read/write models, avoid N+1 queries, use AsNoTracking, apply row limits, and never do application-side joins. Works with EF Core and Dapper.
invocable: false
tags: [cqrs, performance, patterns]
---

# Database Performance Patterns

## When to Use This Skill

Use this skill when:
- Designing data access layers
- Optimizing slow database queries
- Choosing between EF Core and Dapper
- Avoiding common performance pitfalls

---

## Core Principles

1. **Separate read and write models** - Don't use the same types for both
2. **Think in batches** - Avoid N+1 queries
3. **Only retrieve what you need** - No SELECT *
4. **Apply row limits** - Always have a configurable Take/Limit
5. **Do joins in SQL** - Never in application code
6. **AsNoTracking for reads** - EF Core change tracking is expensive

---

## Read/Write Model Separation (CQRS Pattern)

**Read and write models are fundamentally different - they have different shapes, columns, and purposes.** Don't create a single "User" entity and reuse it everywhere.

- **Read models** are denormalized, optimized for query efficiency, and return multiple projection types (UserProfile, UserSummary, UserDetailForAdmin)
- **Write models** are normalized, validation-focused, and accept strongly-typed commands (CreateUserCommand, UpdateUserCommand)

### Architecture

```
src/
  MyApp.Data/
    Users/
      # Read side - multiple optimized projections
      IUserReadStore.cs
      PostgresUserReadStore.cs

      # Write side - command handlers
      IUserWriteStore.cs
      PostgresUserWriteStore.cs

      # Read DTOs - lightweight, denormalized
      UserProfile.cs
      UserSummary.cs

      # Write commands - validation-focused
      CreateUserCommand.cs
      UpdateUserCommand.cs
    Orders/
      IOrderReadStore.cs
      IOrderWriteStore.cs
      (similar structure...)
```

### Read Store Interface

```csharp
// Read models: Multiple specialized projections optimized for different use cases
public interface IUserReadStore
{
    // Returns detailed profile for single-user view
    Task<UserProfile?> GetByIdAsync(UserId id, CancellationToken ct = default);

    // Returns lightweight info for lookups
    Task<UserProfile?> GetByEmailAsync(EmailAddress email, CancellationToken ct = default);

    // Returns paginated summaries - only what the list view needs
    Task<IReadOnlyList<UserSummary>> GetAllAsync(int limit, UserId? cursor = null, CancellationToken ct = default);

    // Boolean query - no entity needed
    Task<bool> EmailExistsAsync(EmailAddress email, CancellationToken ct = default);
}
```

### Write Store Interface

```csharp
// Write model: Accepts strongly-typed commands, minimal return values
public interface IUserWriteStore
{
    // Returns only the created ID - caller doesn't need the full entity
    Task<UserId> CreateAsync(CreateUserCommand command, CancellationToken ct = default);

    // Update validates command, returns void (success or throws)
    Task UpdateAsync(UserId id, UpdateUserCommand command, CancellationToken ct = default);

    // Delete is simple and explicit
    Task DeleteAsync(UserId id, CancellationToken ct = default);
}
```

**Key structural differences illustrated:**
- Read store returns multiple different DTOs (UserProfile, UserSummary, bool flag)
- Write store returns minimal data (just UserId on create) or void
- Read queries are stateless projections - no tracking needed
- Write operations focus on command validation, not retrieving data afterwards
- Different databases/tables can back read vs write (eventual consistency pattern)

---

## Always Apply Row Limits

**Never return unbounded result sets.** Every read method should have a configurable limit.

### Pattern: Limit Parameter

```csharp
public interface IOrderReadStore
{
    // Limit is required, not optional
    Task<IReadOnlyList<OrderSummary>> GetByCustomerAsync(
        CustomerId customerId,
        int limit,
        OrderId? cursor = null,
        CancellationToken ct = default);
}

// Implementation
public async Task<IReadOnlyList<OrderSummary>> GetByCustomerAsync(
    CustomerId customerId,
    int limit,
    OrderId? cursor = null,
    CancellationToken ct = default)
{
    await using var connection = await _dataSource.OpenConnectionAsync(ct);

    const string sql = """
        SELECT id, customer_id, total, status, created_at
        FROM orders
        WHERE customer_id = @CustomerId
        AND (@Cursor IS NULL OR created_at < (SELECT created_at FROM orders WHERE id = @Cursor))
        ORDER BY created_at DESC
        LIMIT @Limit
        """;

    var rows = await connection.QueryAsync<OrderRow>(sql, new
    {
        CustomerId = customerId.Value,
        Cursor = cursor?.Value,
        Limit = limit
    });

    return rows.Select(r => r.ToOrderSummary()).ToList();
}
```

### EF Core with Pagination

```csharp
public async Task<PaginatedList<OrderSummary>> GetOrdersAsync(
    CustomerId customerId,
    Paginator paginator,
    CancellationToken ct = default)
{
    var query = _context.Orders
        .AsNoTracking()
        .Where(o => o.CustomerId == customerId.Value)
        .OrderByDescending(o => o.CreatedAt);

    var totalCount = await query.CountAsync(ct);

    var orders = await query
        .Skip((paginator.PageNumber - 1) * paginator.PageSize)
        .Take(paginator.PageSize)  // Always limit!
        .Select(o => new OrderSummary(
            new OrderId(o.Id),
            o.Total,
            o.Status,
            o.CreatedAt))
        .ToListAsync(ct);

    return new PaginatedList<OrderSummary>(
        orders,
        totalCount,
        paginator.PageSize,
        paginator.PageNumber);
}
```

---

## AsNoTracking for Read Queries

EF Core's change tracking is expensive. Disable it for read-only queries.

```csharp
// DO: Disable tracking for reads
var users = await _context.Users
    .AsNoTracking()
    .Where(u => u.IsActive)
    .ToListAsync();

// DON'T: Track entities you won't modify
var users = await _context.Users
    .Where(u => u.IsActive)
    .ToListAsync();  // Change tracking enabled - wasteful
```

### Configure Default Behavior

```csharp
// For read-heavy applications, consider this in DbContext
protected override void OnConfiguring(DbContextOptionsBuilder optionsBuilder)
{
    optionsBuilder.UseQueryTrackingBehavior(QueryTrackingBehavior.NoTracking);
}
```

Then explicitly enable tracking when needed:

```csharp
var user = await _context.Users
    .AsTracking()  // Explicit - we intend to modify
    .FirstOrDefaultAsync(u => u.Id == userId);
```

---

## Avoid N+1 Queries

The N+1 problem: fetching a list, then querying for each item's related data.

### The Problem

```csharp
// BAD: N+1 queries
var orders = await _context.Orders.ToListAsync();

foreach (var order in orders)
{
    // Each iteration hits the database!
    var items = await _context.OrderItems
        .Where(i => i.OrderId == order.Id)
        .ToListAsync();
}
```

### Solution 1: Include (EF Core)

```csharp
// GOOD: Single query with join
var orders = await _context.Orders
    .AsNoTracking()
    .Include(o => o.Items)
    .ToListAsync();
```

### Solution 2: Batch Query (Dapper)

```csharp
// GOOD: Two queries, no N+1
const string sql = """
    SELECT id, customer_id, total FROM orders WHERE customer_id = @CustomerId;
    SELECT oi.* FROM order_items oi
    INNER JOIN orders o ON oi.order_id = o.id
    WHERE o.customer_id = @CustomerId;
    """;

using var multi = await connection.QueryMultipleAsync(sql, new { CustomerId = customerId });
var orders = (await multi.ReadAsync<OrderRow>()).ToList();
var items = (await multi.ReadAsync<OrderItemRow>()).ToList();

// Join in memory (acceptable - data already fetched)
foreach (var order in orders)
{
    order.Items = items.Where(i => i.OrderId == order.Id).ToList();
}
```

---

## Never Do Application-Side Joins

**Joins must happen in SQL, not in C#.**

```csharp
// BAD: Application join - two queries, memory waste
var customers = await _context.Customers.ToListAsync();
var orders = await _context.Orders.ToListAsync();

var result = customers.Select(c => new
{
    Customer = c,
    Orders = orders.Where(o => o.CustomerId == c.Id).ToList()  // O(n*m) in memory!
});

// GOOD: SQL join - single query
var result = await _context.Customers
    .AsNoTracking()
    .Include(c => c.Orders)
    .ToListAsync();

// GOOD: Explicit join (Dapper)
const string sql = """
    SELECT c.id, c.name, COUNT(o.id) as order_count
    FROM customers c
    LEFT JOIN orders o ON c.id = o.customer_id
    GROUP BY c.id, c.name
    """;
```

---

## Avoid Cartesian Explosions

Multiple `Include` calls can cause Cartesian products.

```csharp
// DANGEROUS: Can explode into millions of rows
var product = await _context.Products
    .Include(p => p.Reviews)      // 100 reviews
    .Include(p => p.Images)       // 20 images
    .Include(p => p.Categories)   // 5 categories
    .FirstOrDefaultAsync(p => p.Id == id);
// Result: 100 * 20 * 5 = 10,000 rows transferred!
```

### Solution: Split Queries

```csharp
// GOOD: Multiple queries, no Cartesian explosion
var product = await _context.Products
    .AsSplitQuery()
    .Include(p => p.Reviews)
    .Include(p => p.Images)
    .Include(p => p.Categories)
    .FirstOrDefaultAsync(p => p.Id == id);
// Result: 4 separate queries, ~125 rows total
```

### Solution: Explicit Projection

```csharp
// BEST: Only fetch what you need
var product = await _context.Products
    .AsNoTracking()
    .Where(p => p.Id == id)
    .Select(p => new ProductDetail(
        p.Id,
        p.Name,
        p.Description,
        p.Reviews.OrderByDescending(r => r.CreatedAt).Take(10).ToList(),
        p.Images.Take(5).ToList(),
        p.Categories.Select(c => c.Name).ToList()))
    .FirstOrDefaultAsync();
```

---

## Constrain Column Sizes

Define maximum lengths in your EF Core model to prevent oversized data.

```csharp
public class UserConfiguration : IEntityTypeConfiguration<User>
{
    public void Configure(EntityTypeBuilder<User> builder)
    {
        builder.Property(u => u.Email)
            .HasMaxLength(254)  // RFC 5321 limit
            .IsRequired();

        builder.Property(u => u.Name)
            .HasMaxLength(100)
            .IsRequired();

        builder.Property(u => u.Bio)
            .HasMaxLength(500);

        // For truly large content, use text type explicitly
        builder.Property(u => u.Notes)
            .HasColumnType("text");
    }
}
```

---

## Don't Build Generic Repositories

Generic repositories hide query complexity and make optimization difficult.

```csharp
// BAD: Generic repository
public interface IRepository<T>
{
    Task<T?> GetByIdAsync(int id);
    Task<IEnumerable<T>> GetAllAsync();  // No limit!
    Task<IEnumerable<T>> FindAsync(Expression<Func<T, bool>> predicate);  // Can't optimize
}

// GOOD: Purpose-built read stores
public interface IOrderReadStore
{
    Task<OrderDetail?> GetByIdAsync(OrderId id, CancellationToken ct = default);
    Task<IReadOnlyList<OrderSummary>> GetByCustomerAsync(CustomerId id, int limit, CancellationToken ct = default);
    Task<IReadOnlyList<OrderSummary>> GetPendingAsync(int limit, CancellationToken ct = default);
}
```

**Problems with generic repositories:**
- Can't optimize specific queries
- No way to enforce limits
- Hide N+1 problems
- Make it easy to fetch too much data
- Encourage lazy thinking about data access

---

## Dapper for Read-Heavy Workloads

For complex read queries, Dapper with explicit SQL is often cleaner and faster.

```csharp
public sealed class PostgresUserReadStore : IUserReadStore
{
    private readonly NpgsqlDataSource _dataSource;

    public PostgresUserReadStore(NpgsqlDataSource dataSource)
    {
        _dataSource = dataSource;
    }

    public async Task<UserProfile?> GetByIdAsync(UserId id, CancellationToken ct = default)
    {
        await using var connection = await _dataSource.OpenConnectionAsync(ct);

        const string sql = """
            SELECT id, email, name, bio, created_at
            FROM users
            WHERE id = @Id
            """;

        var row = await connection.QuerySingleOrDefaultAsync<UserRow>(
            sql, new { Id = id.Value });

        return row?.ToUserProfile();
    }

    // Internal row type for Dapper mapping
    private sealed class UserRow
    {
        public Guid id { get; set; }
        public string email { get; set; } = null!;
        public string name { get; set; } = null!;
        public string? bio { get; set; }
        public DateTime created_at { get; set; }

        public UserProfile ToUserProfile() => new(
            Id: new UserId(id),
            Email: new EmailAddress(email),
            Name: new PersonName(name),
            Bio: bio,
            CreatedAt: new DateTimeOffset(created_at, TimeSpan.Zero));
    }
}
```

---

## When to Use EF Core vs Dapper

| Scenario | Recommendation |
|----------|---------------|
| Simple CRUD | EF Core |
| Complex read queries | Dapper |
| Writes with validation | EF Core |
| Bulk operations | Dapper or raw SQL |
| Reporting/analytics | Dapper |
| Domain-heavy writes | EF Core |

You can use both in the same project - EF Core for writes, Dapper for reads.

---

## Quick Reference

| Anti-Pattern | Solution |
|--------------|----------|
| No row limit | Add `limit` parameter to every read method |
| SELECT * | Project only needed columns |
| N+1 queries | Use Include or batch queries |
| Application joins | Do joins in SQL |
| Cartesian explosion | Use AsSplitQuery or projection |
| Tracking read-only data | Use AsNoTracking |
| Generic repository | Purpose-built read/write stores |
| Unbounded strings | Configure MaxLength in model |

---

## Resources

- **EF Core Performance**: https://learn.microsoft.com/en-us/ef/core/performance/
- **Dapper**: https://github.com/DapperLib/Dapper
- **AsSplitQuery**: https://learn.microsoft.com/en-us/ef/core/querying/single-split-queries
