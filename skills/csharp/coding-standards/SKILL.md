---
name: modern-csharp-coding-standards
description: Write modern, high-performance C# code using records, pattern matching, value objects, async/await, Span<T>/Memory<T>, and best-practice API design patterns. Emphasizes functional-style programming with C# 12+ features.
invocable: false
---

# Modern C# Coding Standards

## When to Use This Skill

Use this skill when:
- Writing new C# code or refactoring existing code
- Designing public APIs for libraries or services
- Optimizing performance-critical code paths
- Implementing domain models with strong typing
- Building async/await-heavy applications
- Working with binary data, buffers, or high-throughput scenarios

## Core Principles

1. **Immutability by Default** - Use `record` types and `init`-only properties
2. **Type Safety** - Leverage nullable reference types and value objects
3. **Modern Pattern Matching** - Use `switch` expressions and patterns extensively
4. **Async Everywhere** - Prefer async APIs with proper cancellation support
5. **Zero-Allocation Patterns** - Use `Span<T>` and `Memory<T>` for performance-critical code
6. **API Design** - Accept abstractions, return appropriately specific types
7. **Composition Over Inheritance** - Avoid abstract base classes, prefer composition
8. **Value Objects as Structs** - Use `readonly record struct` for value objects

---

## Language Patterns

### Records for Immutable Data (C# 9+)

Use `record` types for DTOs, messages, events, and domain entities.

```csharp
// Simple immutable DTO
public record CustomerDto(string Id, string Name, string Email);

// Record with validation in constructor
public record EmailAddress
{
    public string Value { get; init; }

    public EmailAddress(string value)
    {
        if (string.IsNullOrWhiteSpace(value) || !value.Contains('@'))
            throw new ArgumentException("Invalid email address", nameof(value));

        Value = value;
    }
}

// Record with computed properties
public record Order(string Id, decimal Subtotal, decimal Tax)
{
    public decimal Total => Subtotal + Tax;
}

// Records with collections - use IReadOnlyList
public record ShoppingCart(
    string CartId,
    string CustomerId,
    IReadOnlyList<CartItem> Items
)
{
    public decimal Total => Items.Sum(item => item.Price * item.Quantity);
}
```

**When to use `record class` vs `record struct`:**
- `record class` (default): Reference types, use for entities, aggregates, DTOs with multiple properties
- `record struct`: Value types, use for value objects (see next section)

---

### Value Objects as readonly record struct

Value objects should **always be `readonly record struct`** for performance and value semantics.

```csharp
// Single-value object
public readonly record struct OrderId(string Value)
{
    public OrderId(string value) : this(
        !string.IsNullOrWhiteSpace(value)
            ? value
            : throw new ArgumentException("OrderId cannot be empty", nameof(value)))
    {
    }

    public override string ToString() => Value;

    // NO implicit conversions - defeats type safety!
    // Access inner value explicitly: orderId.Value
}

// Multi-value object
public readonly record struct Money(decimal Amount, string Currency)
{
    public Money(decimal amount, string currency) : this(
        amount >= 0 ? amount : throw new ArgumentException("Amount cannot be negative", nameof(amount)),
        ValidateCurrency(currency))
    {
    }

    private static string ValidateCurrency(string currency)
    {
        if (string.IsNullOrWhiteSpace(currency) || currency.Length != 3)
            throw new ArgumentException("Currency must be a 3-letter code", nameof(currency));
        return currency.ToUpperInvariant();
    }

    public Money Add(Money other)
    {
        if (Currency != other.Currency)
            throw new InvalidOperationException($"Cannot add {Currency} to {other.Currency}");

        return new Money(Amount + other.Amount, Currency);
    }

    public override string ToString() => $"{Amount:N2} {Currency}";
}

// Complex value object with factory pattern
public readonly record struct PhoneNumber
{
    public string Value { get; }

    private PhoneNumber(string value) => Value = value;

    public static Result<PhoneNumber, string> Create(string input)
    {
        if (string.IsNullOrWhiteSpace(input))
            return Result<PhoneNumber, string>.Failure("Phone number cannot be empty");

        // Normalize: remove all non-digits
        var digits = new string(input.Where(char.IsDigit).ToArray());

        if (digits.Length < 10 || digits.Length > 15)
            return Result<PhoneNumber, string>.Failure("Phone number must be 10-15 digits");

        return Result<PhoneNumber, string>.Success(new PhoneNumber(digits));
    }

    public override string ToString() => Value;
}

// Percentage value object with range validation
public readonly record struct Percentage
{
    private readonly decimal _value;

    public decimal Value => _value;

    public Percentage(decimal value)
    {
        if (value < 0 || value > 100)
            throw new ArgumentOutOfRangeException(nameof(value), "Percentage must be between 0 and 100");
        _value = value;
    }

    public decimal AsDecimal() => _value / 100m;

    public static Percentage FromDecimal(decimal decimalValue)
    {
        if (decimalValue < 0 || decimalValue > 1)
            throw new ArgumentOutOfRangeException(nameof(decimalValue), "Decimal must be between 0 and 1");
        return new Percentage(decimalValue * 100);
    }

    public override string ToString() => $"{_value}%";
}

// Strongly-typed ID
public readonly record struct CustomerId(Guid Value)
{
    public static CustomerId New() => new(Guid.NewGuid());
    public override string ToString() => Value.ToString();
}

// Quantity with units
public readonly record struct Quantity(int Value, string Unit)
{
    public Quantity(int value, string unit) : this(
        value >= 0 ? value : throw new ArgumentException("Quantity cannot be negative"),
        !string.IsNullOrWhiteSpace(unit) ? unit : throw new ArgumentException("Unit cannot be empty"))
    {
    }

    public override string ToString() => $"{Value} {Unit}";
}
```

**Why `readonly record struct` for value objects:**
- **Value semantics**: Equality based on content, not reference
- **Stack allocation**: Better performance, no GC pressure
- **Immutability**: `readonly` prevents accidental mutation
- **Pattern matching**: Works seamlessly with switch expressions

**CRITICAL: NO implicit conversions.** Implicit operators defeat the purpose of value objects by allowing silent type coercion:

```csharp
// WRONG - defeats compile-time safety:
public readonly record struct UserId(Guid Value)
{
    public static implicit operator UserId(Guid value) => new(value);  // NO!
    public static implicit operator Guid(UserId value) => value.Value; // NO!
}

// With implicit operators, this compiles silently:
void ProcessUser(UserId userId) { }
ProcessUser(Guid.NewGuid());  // Oops - meant to pass PostId

// CORRECT - all conversions explicit:
public readonly record struct UserId(Guid Value)
{
    public static UserId New() => new(Guid.NewGuid());
    // No implicit operators
    // Create: new UserId(guid) or UserId.New()
    // Extract: userId.Value
}
```

Explicit conversions force every boundary crossing to be visible:

```csharp
// API boundary - explicit conversion IN
var userId = new UserId(request.UserId);  // Validates on entry

// Database boundary - explicit conversion OUT
await _db.ExecuteAsync(sql, new { UserId = userId.Value });
```

---

### Pattern Matching (C# 8-12)

Leverage modern pattern matching for cleaner, more expressive code.

```csharp
// Switch expressions with value objects
public string GetPaymentMethodDescription(PaymentMethod payment) => payment switch
{
    { Type: PaymentType.CreditCard, Last4: var last4 } => $"Credit card ending in {last4}",
    { Type: PaymentType.BankTransfer, AccountNumber: var account } => $"Bank transfer from {account}",
    { Type: PaymentType.Cash } => "Cash payment",
    _ => "Unknown payment method"
};

// Property patterns
public decimal CalculateDiscount(Order order) => order switch
{
    { Total: > 1000m } => order.Total * 0.15m,
    { Total: > 500m } => order.Total * 0.10m,
    { Total: > 100m } => order.Total * 0.05m,
    _ => 0m
};

// Relational and logical patterns
public string ClassifyTemperature(int temp) => temp switch
{
    < 0 => "Freezing",
    >= 0 and < 10 => "Cold",
    >= 10 and < 20 => "Cool",
    >= 20 and < 30 => "Warm",
    >= 30 => "Hot",
    _ => throw new ArgumentOutOfRangeException(nameof(temp))
};

// List patterns (C# 11+)
public bool IsValidSequence(int[] numbers) => numbers switch
{
    [] => false,                                      // Empty
    [_] => true,                                      // Single element
    [var first, .., var last] when first < last => true,  // First < last
    _ => false
};

// Type patterns with null checks
public string FormatValue(object? value) => value switch
{
    null => "null",
    string s => $"\"{s}\"",
    int i => i.ToString(),
    double d => d.ToString("F2"),
    DateTime dt => dt.ToString("yyyy-MM-dd"),
    Money m => m.ToString(),
    IEnumerable<object> collection => $"[{string.Join(", ", collection)}]",
    _ => value.ToString() ?? "unknown"
};

// Combining patterns for complex logic
public record OrderState(bool IsPaid, bool IsShipped, bool IsCancelled);

public string GetOrderStatus(OrderState state) => state switch
{
    { IsCancelled: true } => "Cancelled",
    { IsPaid: true, IsShipped: true } => "Delivered",
    { IsPaid: true, IsShipped: false } => "Processing",
    { IsPaid: false } => "Awaiting Payment",
    _ => "Unknown"
};

// Pattern matching with value objects
public decimal CalculateShipping(Money total, Country destination) => (total, destination) switch
{
    ({ Amount: > 100m }, _) => 0m,                    // Free shipping over $100
    (_, { Code: "US" or "CA" }) => 5m,                // North America
    (_, { Code: "GB" or "FR" or "DE" }) => 10m,       // Europe
    _ => 25m                                           // International
};
```

---

### Nullable Reference Types (C# 8+)

Enable nullable reference types in your project and handle nulls explicitly.

```csharp
// In .csproj
<PropertyGroup>
    <Nullable>enable</Nullable>
</PropertyGroup>

// Explicit nullability
public class UserService
{
    // Non-nullable by default
    public string GetUserName(User user) => user.Name;

    // Explicitly nullable return
    public string? FindUserName(string userId)
    {
        var user = _repository.Find(userId);
        return user?.Name;  // Returns null if user not found
    }

    // Null-forgiving operator (use sparingly!)
    public string GetRequiredConfigValue(string key)
    {
        var value = Configuration[key];
        return value!;  // Only if you're CERTAIN it's not null
    }

    // Nullable value objects
    public Money? GetAccountBalance(string accountId)
    {
        var account = _repository.Find(accountId);
        return account?.Balance;
    }
}

// Pattern matching with null checks
public decimal GetDiscount(Customer? customer) => customer switch
{
    null => 0m,
    { IsVip: true } => 0.20m,
    { OrderCount: > 10 } => 0.10m,
    _ => 0.05m
};

// Null-coalescing patterns
public string GetDisplayName(User? user) =>
    user?.PreferredName ?? user?.Email ?? "Guest";

// Guard clauses with ArgumentNullException.ThrowIfNull (C# 11+)
public void ProcessOrder(Order? order)
{
    ArgumentNullException.ThrowIfNull(order);

    // order is now non-nullable in this scope
    Console.WriteLine(order.Id);
}
```

---

## Composition Over Inheritance

**Avoid abstract base classes and inheritance hierarchies.** Use composition and interfaces instead.

```csharp
// ❌ BAD: Abstract base class hierarchy
public abstract class PaymentProcessor
{
    public abstract Task<PaymentResult> ProcessAsync(Money amount);

    protected async Task<bool> ValidateAsync(Money amount)
    {
        // Shared validation logic
        return amount.Amount > 0;
    }
}

public class CreditCardProcessor : PaymentProcessor
{
    public override async Task<PaymentResult> ProcessAsync(Money amount)
    {
        await ValidateAsync(amount);
        // Process credit card...
    }
}

// ✅ GOOD: Composition with interfaces
public interface IPaymentProcessor
{
    Task<PaymentResult> ProcessAsync(Money amount, CancellationToken cancellationToken);
}

public interface IPaymentValidator
{
    Task<ValidationResult> ValidateAsync(Money amount, CancellationToken cancellationToken);
}

// Concrete implementations compose validators
public sealed class CreditCardProcessor : IPaymentProcessor
{
    private readonly IPaymentValidator _validator;
    private readonly ICreditCardGateway _gateway;

    public CreditCardProcessor(IPaymentValidator validator, ICreditCardGateway gateway)
    {
        _validator = validator;
        _gateway = gateway;
    }

    public async Task<PaymentResult> ProcessAsync(Money amount, CancellationToken cancellationToken)
    {
        var validation = await _validator.ValidateAsync(amount, cancellationToken);
        if (!validation.IsValid)
            return PaymentResult.Failed(validation.Error);

        return await _gateway.ChargeAsync(amount, cancellationToken);
    }
}

// ✅ GOOD: Static helper classes for shared logic (no inheritance)
public static class PaymentValidation
{
    public static ValidationResult ValidateAmount(Money amount)
    {
        if (amount.Amount <= 0)
            return ValidationResult.Invalid("Amount must be positive");

        if (amount.Amount > 10000m)
            return ValidationResult.Invalid("Amount exceeds maximum");

        return ValidationResult.Valid();
    }
}

// ✅ GOOD: Records for modeling variants (not inheritance)
public enum PaymentType { CreditCard, BankTransfer, Cash }

public record PaymentMethod
{
    public PaymentType Type { get; init; }
    public string? Last4 { get; init; }           // For credit cards
    public string? AccountNumber { get; init; }    // For bank transfers

    public static PaymentMethod CreditCard(string last4) => new()
    {
        Type = PaymentType.CreditCard,
        Last4 = last4
    };

    public static PaymentMethod BankTransfer(string accountNumber) => new()
    {
        Type = PaymentType.BankTransfer,
        AccountNumber = accountNumber
    };

    public static PaymentMethod Cash() => new() { Type = PaymentType.Cash };
}
```

**When inheritance is acceptable:**
- Framework requirements (e.g., `ControllerBase` in ASP.NET Core)
- Library integration (e.g., custom exceptions inheriting from `Exception`)
- **These should be rare cases in your application code**

---

## Performance Patterns

### Async/Await Best Practices

**Always use async for I/O-bound operations:**

```csharp
// ✅ GOOD: Async all the way
public async Task<Order> GetOrderAsync(string orderId, CancellationToken cancellationToken)
{
    var order = await _repository.GetAsync(orderId, cancellationToken);
    var customer = await _customerService.GetCustomerAsync(order.CustomerId, cancellationToken);
    return order;
}

// ❌ BAD: Blocking on async code
public Order GetOrder(string orderId)
{
    return _repository.GetAsync(orderId).Result;  // DEADLOCK RISK!
}

// ✅ GOOD: ValueTask for frequently-called, often-synchronous methods
public ValueTask<Order?> GetCachedOrderAsync(string orderId, CancellationToken cancellationToken)
{
    if (_cache.TryGetValue(orderId, out var order))
        return ValueTask.FromResult<Order?>(order);  // Synchronous path, no allocation

    return GetFromDatabaseAsync(orderId, cancellationToken);  // Async path
}

private async ValueTask<Order?> GetFromDatabaseAsync(string orderId, CancellationToken cancellationToken)
{
    var order = await _repository.GetAsync(orderId, cancellationToken);
    if (order is not null)
        _cache[orderId] = order;
    return order;
}

// ✅ GOOD: IAsyncEnumerable for streaming
public async IAsyncEnumerable<Order> StreamOrdersAsync(
    string customerId,
    [EnumeratorCancellation] CancellationToken cancellationToken = default)
{
    await foreach (var order in _repository.StreamAllAsync(cancellationToken))
    {
        if (order.CustomerId == customerId)
            yield return order;
    }
}

// ✅ GOOD: ConfigureAwait(false) in library code (not application code)
public async Task<string> ProcessDataAsync(string input, CancellationToken cancellationToken)
{
    var data = await FetchDataAsync(cancellationToken).ConfigureAwait(false);
    var result = await TransformDataAsync(data, cancellationToken).ConfigureAwait(false);
    return result;
}
```

**Always accept CancellationToken:**

```csharp
// ✅ GOOD: CancellationToken parameter with default
public async Task<List<Order>> GetOrdersAsync(
    string customerId,
    CancellationToken cancellationToken = default)
{
    var orders = await _repository.GetOrdersByCustomerAsync(customerId, cancellationToken);
    return orders;
}

// Pass cancellation through the call stack
public async Task<OrderSummary> GetOrderSummaryAsync(
    string customerId,
    CancellationToken cancellationToken = default)
{
    var orders = await GetOrdersAsync(customerId, cancellationToken);
    var total = orders.Sum(o => o.Total);
    return new OrderSummary(customerId, orders.Count, total);
}

// Link cancellation tokens when composing operations
public async Task<ProcessResult> ProcessWithTimeoutAsync(
    string data,
    TimeSpan timeout,
    CancellationToken cancellationToken = default)
{
    using var cts = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
    cts.CancelAfter(timeout);

    return await ProcessAsync(data, cts.Token);
}
```

---

### Span<T> and Memory<T> for Zero-Allocation Code

Use `Span<T>` and `Memory<T>` instead of `byte[]` or `string` for performance-critical code.

```csharp
// ✅ GOOD: Span<T> for synchronous, zero-allocation operations
public int ParseOrderId(ReadOnlySpan<char> input)
{
    // Work with data without allocations
    if (!input.StartsWith("ORD-"))
        throw new FormatException("Invalid order ID format");

    var numberPart = input.Slice(4);
    return int.Parse(numberPart);
}

// stackalloc with Span<T>
public void FormatMessage()
{
    Span<char> buffer = stackalloc char[256];
    var written = FormatInto(buffer);
    var message = new string(buffer.Slice(0, written));
}

// SkipLocalsInit with stackalloc - skips zero-initialization for performance
// By default, .NET zero-initializes all locals (.locals init flag). This can have
// measurable overhead with stackalloc. Use [SkipLocalsInit] when:
//   - You write to the buffer before reading (like FormatInto below)
//   - Profiling shows zero-init as a bottleneck
// ⚠️ WARNING: Reading before writing returns garbage data (see docs example)
// Requires: <AllowUnsafeBlocks>true</AllowUnsafeBlocks> in .csproj
// See: https://learn.microsoft.com/en-us/dotnet/csharp/language-reference/attributes/general#skiplocalsinit-attribute
using System.Runtime.CompilerServices;
[SkipLocalsInit]
public void FormatMessage()
{
    Span<char> buffer = stackalloc char[256];
    var written = FormatInto(buffer);
    var message = new string(buffer.Slice(0, written));
}

// ✅ GOOD: Memory<T> for async operations (Span can't cross await)
public async Task<int> ReadDataAsync(
    Memory<byte> buffer,
    CancellationToken cancellationToken)
{
    return await _stream.ReadAsync(buffer, cancellationToken);
}

// ✅ GOOD: String manipulation with Span to avoid allocations
public bool TryParseKeyValue(ReadOnlySpan<char> line, out string key, out string value)
{
    key = string.Empty;
    value = string.Empty;

    int colonIndex = line.IndexOf(':');
    if (colonIndex == -1)
        return false;

    // Only allocate strings once we know the format is valid
    key = new string(line.Slice(0, colonIndex).Trim());
    value = new string(line.Slice(colonIndex + 1).Trim());
    return true;
}

// ✅ GOOD: ArrayPool for temporary large buffers
public async Task ProcessLargeFileAsync(
    Stream stream,
    CancellationToken cancellationToken)
{
    var buffer = ArrayPool<byte>.Shared.Rent(8192);
    try
    {
        int bytesRead;
        while ((bytesRead = await stream.ReadAsync(buffer.AsMemory(), cancellationToken)) > 0)
        {
            ProcessChunk(buffer.AsSpan(0, bytesRead));
        }
    }
    finally
    {
        ArrayPool<byte>.Shared.Return(buffer);
    }
}

// Hybrid buffer pattern for transient UTF-8 work. See caveats of SkipLocalsInit in the corresponding section.

[SkipLocalsInit]
static short GenerateHashCode(string? key)
{
    if (key is null) return 0;

    const int StackLimit = 256;

    var enc = Encoding.UTF8;
    var max = enc.GetMaxByteCount(key.Length);

    byte[]? rented = null;
    Span<byte> buf = max <= StackLimit
        ? stackalloc byte[StackLimit]
        : (rented = ArrayPool<byte>.Shared.Rent(max));

    try
    {
        var written = enc.GetBytes(key.AsSpan(), buf);
        ComputeHash(buf[..written], out var h1, out var h2);
        return unchecked((short)(h1 ^ h2));
    }
    finally
    {
        if (rented is not null) ArrayPool<byte>.Shared.Return(rented);
    }
}

// ✅ GOOD: Span-based parsing without substring allocations
public static (string Protocol, string Host, int Port) ParseUrl(ReadOnlySpan<char> url)
{
    var protocolEnd = url.IndexOf("://");
    var protocol = new string(url.Slice(0, protocolEnd));

    var afterProtocol = url.Slice(protocolEnd + 3);
    var portStart = afterProtocol.IndexOf(':');

    var host = new string(afterProtocol.Slice(0, portStart));
    var portSpan = afterProtocol.Slice(portStart + 1);
    var port = int.Parse(portSpan);

    return (protocol, host, port);
}

// ✅ GOOD: Writing data to Span
public bool TryFormatOrderId(int orderId, Span<char> destination, out int charsWritten)
{
    const string prefix = "ORD-";

    if (destination.Length < prefix.Length + 10)
    {
        charsWritten = 0;
        return false;
    }

    prefix.AsSpan().CopyTo(destination);
    var numberWritten = orderId.TryFormat(
        destination.Slice(prefix.Length),
        out var numberChars);

    charsWritten = prefix.Length + numberChars;
    return numberWritten;
}
```

**When to use what:**

| Type | Use Case |
|------|----------|
| `Span<T>` | Synchronous operations, stack-allocated buffers, slicing without allocation |
| `ReadOnlySpan<T>` | Read-only views, method parameters for data you won't modify |
| `Memory<T>` | Async operations (Span can't cross await boundaries) |
| `ReadOnlyMemory<T>` | Read-only async operations |
| `byte[]` | When you need to store data long-term or pass to APIs requiring arrays |
| `ArrayPool<T>` | Large temporary buffers (>1KB) to avoid GC pressure |

---

## API Design Principles

### Accept Abstractions, Return Appropriately Specific

**For Parameters (Accept):**

```csharp
// ✅ GOOD: Accept IEnumerable<T> if you only iterate once
public decimal CalculateTotal(IEnumerable<OrderItem> items)
{
    return items.Sum(item => item.Price * item.Quantity);
}

// ✅ GOOD: Accept IReadOnlyCollection<T> if you need Count
public bool HasMinimumItems(IReadOnlyCollection<OrderItem> items, int minimum)
{
    return items.Count >= minimum;
}

// ✅ GOOD: Accept IReadOnlyList<T> if you need indexing
public OrderItem GetMiddleItem(IReadOnlyList<OrderItem> items)
{
    if (items.Count == 0)
        throw new ArgumentException("List cannot be empty");

    return items[items.Count / 2];  // Indexed access
}

// ✅ GOOD: Accept ReadOnlySpan<T> for high-performance, zero-allocation APIs
public int Sum(ReadOnlySpan<int> numbers)
{
    int total = 0;
    foreach (var num in numbers)
        total += num;
    return total;
}

// ✅ GOOD: Accept IAsyncEnumerable<T> for async streaming
public async Task<int> CountItemsAsync(
    IAsyncEnumerable<Order> orders,
    CancellationToken cancellationToken)
{
    int count = 0;
    await foreach (var order in orders.WithCancellation(cancellationToken))
        count++;
    return count;
}
```

**For Return Types:**

```csharp
// ✅ GOOD: Return IEnumerable<T> for lazy/deferred execution
public IEnumerable<Order> GetOrdersLazy(string customerId)
{
    foreach (var order in _repository.Query())
    {
        if (order.CustomerId == customerId)
            yield return order;  // Lazy evaluation
    }
}

// ✅ GOOD: Return IReadOnlyList<T> for materialized, immutable collections
public IReadOnlyList<Order> GetOrders(string customerId)
{
    return _repository
        .Query()
        .Where(o => o.CustomerId == customerId)
        .ToList();  // Materialized
}

// ✅ GOOD: Return concrete types when callers need mutation
public List<Order> GetMutableOrders(string customerId)
{
    // Explicitly allow mutation by returning List<T>
    return _repository
        .Query()
        .Where(o => o.CustomerId == customerId)
        .ToList();
}

// ✅ GOOD: Return IAsyncEnumerable<T> for async streaming
public async IAsyncEnumerable<Order> StreamOrdersAsync(
    string customerId,
    [EnumeratorCancellation] CancellationToken cancellationToken = default)
{
    await foreach (var order in _repository.StreamAllAsync(cancellationToken))
    {
        if (order.CustomerId == customerId)
            yield return order;
    }
}

// ✅ GOOD: Return arrays for interop or when caller expects array
public byte[] SerializeOrder(Order order)
{
    // Binary serialization - byte[] is appropriate here
    return MessagePackSerializer.Serialize(order);
}
```

**Summary Table:**

| Scenario | Accept | Return |
|----------|--------|--------|
| Only iterate once | `IEnumerable<T>` | `IEnumerable<T>` (if lazy) |
| Need count | `IReadOnlyCollection<T>` | `IReadOnlyCollection<T>` |
| Need indexing | `IReadOnlyList<T>` | `IReadOnlyList<T>` |
| High-performance, sync | `ReadOnlySpan<T>` | `Span<T>` (rarely) |
| Async streaming | `IAsyncEnumerable<T>` | `IAsyncEnumerable<T>` |
| Caller needs mutation | - | `List<T>`, `T[]` |

---

### Method Signatures Best Practices

```csharp
// ✅ GOOD: Complete async method signature
public async Task<Result<Order, OrderError>> CreateOrderAsync(
    CreateOrderRequest request,
    CancellationToken cancellationToken = default)
{
    // Implementation
}

// ✅ GOOD: Optional parameters at the end
public async Task<List<Order>> GetOrdersAsync(
    string customerId,
    DateTime? startDate = null,
    DateTime? endDate = null,
    CancellationToken cancellationToken = default)
{
    // Implementation
}

// ✅ GOOD: Use record for multiple related parameters
public record SearchOrdersRequest(
    string? CustomerId,
    DateTime? StartDate,
    DateTime? EndDate,
    OrderStatus? Status,
    int PageSize = 20,
    int PageNumber = 1
);

public async Task<PagedResult<Order>> SearchOrdersAsync(
    SearchOrdersRequest request,
    CancellationToken cancellationToken = default)
{
    // Implementation
}

// ✅ GOOD: Primary constructors (C# 12+) for simple classes
public sealed class OrderService(IOrderRepository repository, ILogger<OrderService> logger)
{
    public async Task<Order> GetOrderAsync(OrderId orderId, CancellationToken cancellationToken)
    {
        logger.LogInformation("Fetching order {OrderId}", orderId);
        return await repository.GetAsync(orderId, cancellationToken);
    }
}

// ✅ GOOD: Options pattern for complex configuration
public sealed class EmailServiceOptions
{
    public required string SmtpHost { get; init; }
    public int SmtpPort { get; init; } = 587;
    public bool UseSsl { get; init; } = true;
    public TimeSpan Timeout { get; init; } = TimeSpan.FromSeconds(30);
}

public sealed class EmailService(IOptions<EmailServiceOptions> options)
{
    private readonly EmailServiceOptions _options = options.Value;
}
```

---

## Error Handling

### Result Type Pattern (Railway-Oriented Programming)

For expected errors, use a `Result<T, TError>` type instead of exceptions.

```csharp
// Simple Result type as readonly record struct
public readonly record struct Result<TValue, TError>
{
    private readonly TValue? _value;
    private readonly TError? _error;
    private readonly bool _isSuccess;

    private Result(TValue value)
    {
        _value = value;
        _error = default;
        _isSuccess = true;
    }

    private Result(TError error)
    {
        _value = default;
        _error = error;
        _isSuccess = false;
    }

    public bool IsSuccess => _isSuccess;
    public bool IsFailure => !_isSuccess;

    public TValue Value => _isSuccess
        ? _value!
        : throw new InvalidOperationException("Cannot access Value of a failed result");

    public TError Error => !_isSuccess
        ? _error!
        : throw new InvalidOperationException("Cannot access Error of a successful result");

    public static Result<TValue, TError> Success(TValue value) => new(value);
    public static Result<TValue, TError> Failure(TError error) => new(error);

    public Result<TOut, TError> Map<TOut>(Func<TValue, TOut> mapper)
        => _isSuccess
            ? Result<TOut, TError>.Success(mapper(_value!))
            : Result<TOut, TError>.Failure(_error!);

    public Result<TOut, TError> Bind<TOut>(Func<TValue, Result<TOut, TError>> binder)
        => _isSuccess ? binder(_value!) : Result<TOut, TError>.Failure(_error!);

    public TValue GetValueOr(TValue defaultValue)
        => _isSuccess ? _value! : defaultValue;

    public TResult Match<TResult>(
        Func<TValue, TResult> onSuccess,
        Func<TError, TResult> onFailure)
        => _isSuccess ? onSuccess(_value!) : onFailure(_error!);
}

// Error type as readonly record struct
public readonly record struct OrderError(string Code, string Message);

// Usage example
public sealed class OrderService(IOrderRepository repository)
{
    public async Task<Result<Order, OrderError>> CreateOrderAsync(
        CreateOrderRequest request,
        CancellationToken cancellationToken)
    {
        // Validate
        var validationResult = ValidateRequest(request);
        if (validationResult.IsFailure)
            return Result<Order, OrderError>.Failure(validationResult.Error);

        // Check inventory
        var inventoryResult = await CheckInventoryAsync(request.Items, cancellationToken);
        if (inventoryResult.IsFailure)
            return Result<Order, OrderError>.Failure(inventoryResult.Error);

        // Create order
        var order = new Order(
            OrderId.New(),
            new CustomerId(request.CustomerId),
            request.Items);

        await repository.SaveAsync(order, cancellationToken);

        return Result<Order, OrderError>.Success(order);
    }

    // Pattern matching on Result
    public IActionResult MapToActionResult(Result<Order, OrderError> result)
    {
        return result.Match(
            onSuccess: order => new OkObjectResult(order),
            onFailure: error => error.Code switch
            {
                "VALIDATION_ERROR" => new BadRequestObjectResult(error.Message),
                "INSUFFICIENT_INVENTORY" => new ConflictObjectResult(error.Message),
                "NOT_FOUND" => new NotFoundObjectResult(error.Message),
                _ => new ObjectResult(error.Message) { StatusCode = 500 }
            }
        );
    }
}
```

**When to use Result vs Exceptions:**
- **Use Result**: Expected errors (validation, business rules, not found)
- **Use Exceptions**: Unexpected errors (network failures, system errors, programming bugs)

---

## Testing Patterns

```csharp
// Use record for test data builders
public record OrderBuilder
{
    public OrderId Id { get; init; } = OrderId.New();
    public CustomerId CustomerId { get; init; } = CustomerId.New();
    public Money Total { get; init; } = new Money(100m, "USD");
    public IReadOnlyList<OrderItem> Items { get; init; } = Array.Empty<OrderItem>();

    public Order Build() => new(Id, CustomerId, Total, Items);
}

// Use 'with' expression for test variations
[Fact]
public void CalculateDiscount_LargeOrder_AppliesCorrectDiscount()
{
    // Arrange
    var baseOrder = new OrderBuilder().Build();
    var largeOrder = baseOrder with
    {
        Total = new Money(1500m, "USD")
    };

    // Act
    var discount = _service.CalculateDiscount(largeOrder);

    // Assert
    discount.Should().Be(new Money(225m, "USD")); // 15% of 1500
}

// Span-based testing
[Theory]
[InlineData("ORD-12345", true)]
[InlineData("INVALID", false)]
public void TryParseOrderId_VariousInputs_ReturnsExpectedResult(
    string input,
    bool expected)
{
    // Act
    var result = OrderIdParser.TryParse(input.AsSpan(), out var orderId);

    // Assert
    result.Should().Be(expected);
}

// Testing with value objects
[Fact]
public void Money_Add_SameCurrency_ReturnsSum()
{
    // Arrange
    var money1 = new Money(100m, "USD");
    var money2 = new Money(50m, "USD");

    // Act
    var result = money1.Add(money2);

    // Assert
    result.Should().Be(new Money(150m, "USD"));
}

[Fact]
public void Money_Add_DifferentCurrency_ThrowsException()
{
    // Arrange
    var usd = new Money(100m, "USD");
    var eur = new Money(50m, "EUR");

    // Act & Assert
    var act = () => usd.Add(eur);
    act.Should().Throw<InvalidOperationException>()
        .WithMessage("*different currencies*");
}
```

---

## Avoid Reflection-Based Metaprogramming

**Prefer statically-typed, explicit code over reflection-based "magic" libraries.**

Reflection-based libraries like AutoMapper trade compile-time safety for convenience. When mappings break, you find out at runtime (or worse, in production) instead of at compile time.

### Banned Libraries

| Library | Problem |
|---------|---------|
| **AutoMapper** | Reflection magic, hidden mappings, runtime failures, hard to debug |
| **Mapster** | Same issues as AutoMapper |
| **ExpressMapper** | Same issues |

### Why Reflection Mapping Fails

```csharp
// With AutoMapper - compiles fine, fails at runtime
public record UserDto(string Id, string Name, string Email);
public record UserEntity(Guid Id, string FullName, string EmailAddress);

// This mapping silently produces garbage:
// - Id: string vs Guid mismatch
// - Name vs FullName: no match, null/default
// - Email vs EmailAddress: no match, null/default
var dto = _mapper.Map<UserDto>(entity);  // Compiles! Breaks at runtime.
```

### Use Explicit Mapping Methods Instead

```csharp
// Extension method - compile-time checked, easy to find, easy to debug
public static class UserMappings
{
    public static UserDto ToDto(this UserEntity entity) => new(
        Id: entity.Id.ToString(),
        Name: entity.FullName,
        Email: entity.EmailAddress);

    public static UserEntity ToEntity(this CreateUserRequest request) => new(
        Id: Guid.NewGuid(),
        FullName: request.Name,
        EmailAddress: request.Email);
}

// Usage - explicit and traceable
var dto = entity.ToDto();
var entity = request.ToEntity();
```

### Benefits of Explicit Mappings

| Aspect | AutoMapper | Explicit Methods |
|--------|------------|------------------|
| **Compile-time safety** | No - runtime errors | Yes - compiler catches mismatches |
| **Discoverability** | Hidden in profiles | "Go to Definition" works |
| **Debugging** | Black box | Step through code |
| **Refactoring** | Rename breaks silently | IDE renames correctly |
| **Performance** | Reflection overhead | Direct property access |
| **Testing** | Need integration tests | Simple unit tests |

### Complex Mappings

For complex transformations, explicit code is even more valuable:

```csharp
public static OrderSummaryDto ToSummary(this Order order) => new(
    OrderId: order.Id.Value.ToString(),
    CustomerName: order.Customer.FullName,
    ItemCount: order.Items.Count,
    Total: order.Items.Sum(i => i.Quantity * i.UnitPrice),
    Status: order.Status switch
    {
        OrderStatus.Pending => "Awaiting Payment",
        OrderStatus.Paid => "Processing",
        OrderStatus.Shipped => "On the Way",
        OrderStatus.Delivered => "Completed",
        _ => "Unknown"
    },
    FormattedDate: order.CreatedAt.ToString("MMMM d, yyyy"));
```

This is:
- **Readable**: Anyone can understand the transformation
- **Debuggable**: Set a breakpoint, inspect values
- **Testable**: Pass an Order, assert on the result
- **Refactorable**: Change a property name, compiler tells you everywhere it's used

### When Reflection is Acceptable

Reflection has legitimate uses, but mapping DTOs isn't one of them:

| Use Case | Acceptable? |
|----------|-------------|
| Serialization (System.Text.Json, Newtonsoft) | Yes - well-tested, source generators available |
| Dependency injection container | Yes - framework infrastructure |
| ORM entity mapping (EF Core) | Yes - necessary for database abstraction |
| Test fixtures and builders | Sometimes - for convenience in tests only |
| **DTO/domain object mapping** | **No - use explicit methods** |

### UnsafeAccessorAttribute (.NET 8+)

When you genuinely need to access private or internal members (serializers, test helpers, framework code), use `UnsafeAccessorAttribute` instead of traditional reflection. It provides **zero-overhead, AOT-compatible** member access.

```csharp
// AVOID: Traditional reflection - slow, allocates, breaks AOT
var field = typeof(Order).GetField("_status", BindingFlags.NonPublic | BindingFlags.Instance);
var status = (OrderStatus)field!.GetValue(order)!;

// PREFER: UnsafeAccessor - zero overhead, AOT-compatible
[UnsafeAccessor(UnsafeAccessorKind.Field, Name = "_status")]
static extern ref OrderStatus GetStatusField(Order order);

var status = GetStatusField(order);  // Direct access, no reflection
```

**Supported accessor kinds:**

```csharp
// Private field access
[UnsafeAccessor(UnsafeAccessorKind.Field, Name = "_items")]
static extern ref List<OrderItem> GetItemsField(Order order);

// Private method access
[UnsafeAccessor(UnsafeAccessorKind.Method, Name = "Recalculate")]
static extern void CallRecalculate(Order order);

// Private static field
[UnsafeAccessor(UnsafeAccessorKind.StaticField, Name = "_instanceCount")]
static extern ref int GetInstanceCount(Order order);

// Private constructor
[UnsafeAccessor(UnsafeAccessorKind.Constructor)]
static extern Order CreateOrder(OrderId id, CustomerId customerId);
```

**Why UnsafeAccessor over reflection:**

| Aspect | Reflection | UnsafeAccessor |
|--------|------------|----------------|
| Performance | Slow (100-1000x) | Zero overhead |
| AOT compatible | No | Yes |
| Allocations | Yes (boxing, arrays) | None |
| Compile-time checked | No | Partially (signature) |

**Use cases:**
- Serializers accessing private backing fields
- Test helpers verifying internal state
- Framework code that needs to bypass visibility

**Resources:**
- [A new way of doing reflection with .NET 8](https://steven-giesel.com/blogPost/05ecdd16-8dc4-490f-b1cf-780c994346a4)
- [Accessing private members without reflection in .NET 8.0](https://www.strathweb.com/2023/10/accessing-private-members-without-reflection-in-net-8-0/)
- [Modern .NET Reflection with UnsafeAccessor](https://blog.ndepend.com/modern-net-reflection-with-unsafeaccessor/)

---

## Anti-Patterns to Avoid

### ❌ DON'T: Use mutable DTOs

```csharp
// BAD: Mutable DTO
public class CustomerDto
{
    public string Id { get; set; }
    public string Name { get; set; }
}

// GOOD: Immutable record
public record CustomerDto(string Id, string Name);
```

### ❌ DON'T: Use classes for value objects

```csharp
// BAD: Value object as class
public class OrderId
{
    public string Value { get; }
    public OrderId(string value) => Value = value;
}

// GOOD: Value object as readonly record struct
public readonly record struct OrderId(string Value);
```

### ❌ DON'T: Create deep inheritance hierarchies

```csharp
// BAD: Deep inheritance
public abstract class Entity { }
public abstract class AggregateRoot : Entity { }
public abstract class Order : AggregateRoot { }
public class CustomerOrder : Order { }

// GOOD: Flat structure with composition
public interface IEntity
{
    Guid Id { get; }
}

public record Order(OrderId Id, CustomerId CustomerId, Money Total) : IEntity
{
    Guid IEntity.Id => Id.Value;
}
```

### ❌ DON'T: Return List<T> when you mean IReadOnlyList<T>

```csharp
// BAD: Exposes internal list for modification
public List<Order> GetOrders() => _orders;

// GOOD: Returns read-only view
public IReadOnlyList<Order> GetOrders() => _orders;
```

### ❌ DON'T: Use byte[] when ReadOnlySpan<byte> works

```csharp
// BAD: Allocates array on every call
public byte[] GetHeader()
{
    var header = new byte[64];
    // Fill header
    return header;
}

// GOOD: Zero allocation with Span
public void GetHeader(Span<byte> destination)
{
    if (destination.Length < 64)
        throw new ArgumentException("Buffer too small");

    // Fill header directly into caller's buffer
}
```

### ❌ DON'T: Forget CancellationToken in async methods

```csharp
// BAD: No cancellation support
public async Task<Order> GetOrderAsync(OrderId id)
{
    return await _repository.GetAsync(id);
}

// GOOD: Cancellation support
public async Task<Order> GetOrderAsync(
    OrderId id,
    CancellationToken cancellationToken = default)
{
    return await _repository.GetAsync(id, cancellationToken);
}
```

### ❌ DON'T: Block on async code

```csharp
// BAD: Deadlock risk!
public Order GetOrder(OrderId id)
{
    return GetOrderAsync(id).Result;
}

// BAD: Also deadlock risk!
public Order GetOrder(OrderId id)
{
    return GetOrderAsync(id).GetAwaiter().GetResult();
}

// GOOD: Async all the way
public async Task<Order> GetOrderAsync(
    OrderId id,
    CancellationToken cancellationToken)
{
    return await _repository.GetAsync(id, cancellationToken);
}
```

---

## Code Organization

```csharp
// File: Domain/Orders/Order.cs

namespace MyApp.Domain.Orders;

// 1. Primary domain type
public record Order(
    OrderId Id,
    CustomerId CustomerId,
    Money Total,
    OrderStatus Status,
    IReadOnlyList<OrderItem> Items
)
{
    // Computed properties
    public bool IsCompleted => Status is OrderStatus.Completed;

    // Domain methods returning Result for expected errors
    public Result<Order, OrderError> AddItem(OrderItem item)
    {
        if (Status is not OrderStatus.Draft)
            return Result<Order, OrderError>.Failure(
                new OrderError("ORDER_NOT_DRAFT", "Can only add items to draft orders"));

        var newItems = Items.Append(item).ToList();
        var newTotal = new Money(
            Items.Sum(i => i.Total.Amount) + item.Total.Amount,
            Total.Currency);

        return Result<Order, OrderError>.Success(
            this with { Items = newItems, Total = newTotal });
    }
}

// 2. Enums for state
public enum OrderStatus
{
    Draft,
    Submitted,
    Processing,
    Completed,
    Cancelled
}

// 3. Related types
public record OrderItem(
    ProductId ProductId,
    Quantity Quantity,
    Money UnitPrice
)
{
    public Money Total => new(
        UnitPrice.Amount * Quantity.Value,
        UnitPrice.Currency);
}

// 4. Value objects
public readonly record struct OrderId(Guid Value)
{
    public static OrderId New() => new(Guid.NewGuid());
}

// 5. Errors
public readonly record struct OrderError(string Code, string Message);
```

---

## Best Practices Summary

### DO's ✅
- Use `record` for DTOs, messages, and domain entities
- Use `readonly record struct` for value objects
- Leverage pattern matching with `switch` expressions
- Enable and respect nullable reference types
- Use async/await for all I/O operations
- Accept `CancellationToken` in all async methods
- Use `Span<T>` and `Memory<T>` for high-performance scenarios
- Accept abstractions (`IEnumerable<T>`, `IReadOnlyList<T>`)
- Return appropriate interfaces or concrete types
- Use `Result<T, TError>` for expected errors
- Use `ConfigureAwait(false)` in library code
- Pool buffers with `ArrayPool<T>` for large allocations
- Prefer composition over inheritance
- Avoid abstract base classes in application code

### DON'Ts ❌
- Don't use mutable classes when records work
- Don't use classes for value objects (use `readonly record struct`)
- Don't create deep inheritance hierarchies
- Don't ignore nullable reference type warnings
- Don't block on async code (`.Result`, `.Wait()`)
- Don't use `byte[]` when `Span<byte>` suffices
- Don't forget `CancellationToken` parameters
- Don't return mutable collections from APIs
- Don't throw exceptions for expected business errors
- Don't use `string` concatenation in loops
- Don't allocate large arrays repeatedly (use `ArrayPool`)

---

## Additional Resources

- **C# Language Specification**: https://learn.microsoft.com/en-us/dotnet/csharp/
- **Pattern Matching**: https://learn.microsoft.com/en-us/dotnet/csharp/fundamentals/functional/pattern-matching
- **Span<T> and Memory<T>**: https://learn.microsoft.com/en-us/dotnet/standard/memory-and-spans/
- **Async Best Practices**: https://learn.microsoft.com/en-us/archive/msdn-magazine/2013/march/async-await-best-practices-in-asynchronous-programming
- **.NET Performance Tips**: https://learn.microsoft.com/en-us/dotnet/framework/performance/
