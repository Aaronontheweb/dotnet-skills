---
name: type-design-performance
description: Design .NET types for performance. Seal classes, use readonly structs, prefer static pure functions, avoid premature enumeration, and choose the right collection types.
invocable: false
---

# Type Design for Performance

## When to Use This Skill

Use this skill when:
- Designing new types and APIs
- Reviewing code for performance issues
- Choosing between class, struct, and record
- Working with collections and enumerables

---

## Core Principles

1. **Seal your types** - Unless explicitly designed for inheritance
2. **Prefer readonly structs** - For small, immutable value types
3. **Prefer static pure functions** - Better performance and testability
4. **Defer enumeration** - Don't materialize until you need to
5. **Return immutable collections** - From API boundaries

---

## Seal Classes by Default

Sealing classes enables JIT devirtualization and communicates API intent.

```csharp
// DO: Seal classes not designed for inheritance
public sealed class OrderProcessor
{
    public void Process(Order order) { }
}

// DO: Seal records (they're classes)
public sealed record OrderCreated(OrderId Id, CustomerId CustomerId);

// DON'T: Leave unsealed without reason
public class OrderProcessor  // Can be subclassed - intentional?
{
    public virtual void Process(Order order) { }  // Virtual = slower
}
```

**Benefits:**
- JIT can devirtualize method calls
- Communicates "this is not an extension point"
- Prevents accidental breaking changes

---

## Readonly Structs for Value Types

Structs should be `readonly` when immutable. This prevents defensive copies.

```csharp
// DO: Readonly struct for immutable value types
public readonly record struct OrderId(Guid Value)
{
    public static OrderId New() => new(Guid.NewGuid());
    public override string ToString() => Value.ToString();
}

// DO: Readonly struct for small, short-lived data
public readonly struct Money
{
    public decimal Amount { get; }
    public string Currency { get; }

    public Money(decimal amount, string currency)
    {
        Amount = amount;
        Currency = currency;
    }
}

// DON'T: Mutable struct (causes defensive copies)
public struct Point  // Not readonly!
{
    public int X { get; set; }  // Mutable!
    public int Y { get; set; }
}
```

### When to Use Structs

| Use Struct When | Use Class When |
|-----------------|----------------|
| Small (≤16 bytes typically) | Larger objects |
| Short-lived | Long-lived |
| Frequently allocated | Shared references needed |
| Value semantics required | Identity semantics required |
| Immutable | Mutable state |

---

## Prefer Static Pure Functions

Static methods with no side effects are faster and more testable.

```csharp
// DO: Static pure function
public static class OrderCalculator
{
    public static Money CalculateTotal(IReadOnlyList<OrderItem> items)
    {
        var total = items.Sum(i => i.Price * i.Quantity);
        return new Money(total, "USD");
    }
}

// Usage - predictable, testable
var total = OrderCalculator.CalculateTotal(items);
```

**Benefits:**
- No vtable lookup (faster)
- No hidden state
- Easier to test (pure input → output)
- Thread-safe by design
- Forces explicit dependencies

```csharp
// DON'T: Instance method hiding dependencies
public class OrderCalculator
{
    private readonly ITaxService _taxService;  // Hidden dependency
    private readonly IDiscountService _discountService;  // Hidden dependency

    public Money CalculateTotal(IReadOnlyList<OrderItem> items)
    {
        // What does this actually depend on?
    }
}

// BETTER: Explicit dependencies via parameters
public static class OrderCalculator
{
    public static Money CalculateTotal(
        IReadOnlyList<OrderItem> items,
        decimal taxRate,
        decimal discountPercent)
    {
        // All inputs visible
    }
}
```

**Don't go overboard** - Use instance methods when you genuinely need state or polymorphism.

---

## Defer Enumeration

Don't materialize enumerables until necessary. Avoid excessive LINQ chains.

```csharp
// BAD: Premature materialization
public IReadOnlyList<Order> GetActiveOrders()
{
    return _orders
        .Where(o => o.IsActive)
        .ToList()  // Materialized!
        .OrderBy(o => o.CreatedAt)  // Another iteration
        .ToList();  // Materialized again!
}

// GOOD: Defer until the end
public IReadOnlyList<Order> GetActiveOrders()
{
    return _orders
        .Where(o => o.IsActive)
        .OrderBy(o => o.CreatedAt)
        .ToList();  // Single materialization
}

// GOOD: Return IEnumerable if caller might not need all items
public IEnumerable<Order> GetActiveOrders()
{
    return _orders
        .Where(o => o.IsActive)
        .OrderBy(o => o.CreatedAt);
    // Caller decides when to materialize
}
```

### Async Enumeration

Be careful with async and IEnumerable:

```csharp
// BAD: Async in LINQ - hidden allocations
var results = orders
    .Select(async o => await ProcessOrderAsync(o))  // Task per item!
    .ToList();
await Task.WhenAll(results);

// GOOD: Use IAsyncEnumerable for streaming
public async IAsyncEnumerable<OrderResult> ProcessOrdersAsync(
    IEnumerable<Order> orders,
    [EnumeratorCancellation] CancellationToken ct = default)
{
    foreach (var order in orders)
    {
        ct.ThrowIfCancellationRequested();
        yield return await ProcessOrderAsync(order, ct);
    }
}

// GOOD: Batch processing for parallelism
var results = await Task.WhenAll(
    orders.Select(o => ProcessOrderAsync(o)));
```

---

## ValueTask vs Task

Use `ValueTask` for hot paths that often complete synchronously. For real I/O, just use `Task`.

```csharp
// DO: ValueTask for cached/synchronous paths
public ValueTask<User?> GetUserAsync(UserId id)
{
    if (_cache.TryGetValue(id, out var user))
    {
        return ValueTask.FromResult<User?>(user);  // No allocation
    }

    return new ValueTask<User?>(FetchUserAsync(id));
}

// DO: Task for real I/O (simpler, no footguns)
public Task<Order> CreateOrderAsync(CreateOrderCommand cmd)
{
    // This always hits the database
    return _repository.CreateAsync(cmd);
}
```

**ValueTask rules:**
- Never await a ValueTask more than once
- Never use `.Result` or `.GetAwaiter().GetResult()` before completion
- If in doubt, use Task

---

## Span and Memory for Bytes

Use `Span<T>` and `Memory<T>` instead of `byte[]` for low-level operations.

```csharp
// DO: Accept Span for synchronous operations
public static int ParseInt(ReadOnlySpan<char> text)
{
    return int.Parse(text);
}

// DO: Accept Memory for async operations
public async Task WriteAsync(ReadOnlyMemory<byte> data)
{
    await _stream.WriteAsync(data);
}

// DON'T: Force array allocation
public static int ParseInt(string text)  // String allocated
{
    return int.Parse(text);
}
```

### Common Span Patterns

```csharp
// Slice without allocation
ReadOnlySpan<char> span = "Hello, World!".AsSpan();
var hello = span[..5];  // No allocation

// Stack allocation for small buffers
Span<byte> buffer = stackalloc byte[256];

// Use ArrayPool for larger buffers
var buffer = ArrayPool<byte>.Shared.Rent(4096);
try
{
    // Use buffer...
}
finally
{
    ArrayPool<byte>.Shared.Return(buffer);
}
```

---

## Collection Return Types

### Return Immutable Collections from APIs

```csharp
// DO: Return immutable collection
public IReadOnlyList<Order> GetOrders()
{
    return _orders.ToList();  // Caller can't modify internal state
}

// DO: Use frozen collections for static data (.NET 8+)
private static readonly FrozenDictionary<string, Handler> _handlers =
    new Dictionary<string, Handler>
    {
        ["create"] = new CreateHandler(),
        ["update"] = new UpdateHandler(),
    }.ToFrozenDictionary();

// DON'T: Return mutable collection
public List<Order> GetOrders()
{
    return _orders;  // Caller can modify!
}
```

### Internal Mutation is Fine

```csharp
public IReadOnlyList<OrderItem> BuildOrderItems(Cart cart)
{
    var items = new List<OrderItem>();  // Mutable internally

    foreach (var cartItem in cart.Items)
    {
        items.Add(CreateOrderItem(cartItem));
    }

    return items;  // Return as IReadOnlyList
}
```

### Collection Guidelines

| Scenario | Return Type |
|----------|-------------|
| API boundary | `IReadOnlyList<T>`, `IReadOnlyCollection<T>` |
| Static lookup data | `FrozenDictionary<K,V>`, `FrozenSet<T>` |
| Internal building | `List<T>`, then return as readonly |
| Single item or none | `T?` (nullable) |
| Zero or more, lazy | `IEnumerable<T>` |

---

## Quick Reference

| Pattern | Benefit |
|---------|---------|
| `sealed class` | Devirtualization, clear API |
| `readonly record struct` | No defensive copies, value semantics |
| Static pure functions | No vtable, testable, thread-safe |
| Defer `.ToList()` | Single materialization |
| `ValueTask` for hot paths | Avoid Task allocation |
| `Span<T>` for bytes | Stack allocation, no copying |
| `IReadOnlyList<T>` return | Immutable API contract |
| `FrozenDictionary` | Fastest lookup for static data |

---

## Anti-Patterns

```csharp
// DON'T: Unsealed class without reason
public class OrderService { }  // Seal it!

// DON'T: Mutable struct
public struct Point { public int X; public int Y; }  // Make readonly

// DON'T: Instance method that could be static
public int Add(int a, int b) => a + b;  // Make static

// DON'T: Multiple ToList() calls
items.Where(...).ToList().OrderBy(...).ToList();  // One ToList at end

// DON'T: Return List<T> from public API
public List<Order> GetOrders();  // Return IReadOnlyList<T>

// DON'T: ValueTask for always-async operations
public ValueTask<Order> CreateOrderAsync();  // Just use Task
```

---

## Resources

- **Performance Best Practices**: https://learn.microsoft.com/en-us/dotnet/standard/performance/
- **Span<T> Guidance**: https://learn.microsoft.com/en-us/dotnet/standard/memory-and-spans/
- **Frozen Collections**: https://learn.microsoft.com/en-us/dotnet/api/system.collections.frozen
