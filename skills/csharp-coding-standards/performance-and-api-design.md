# Performance and API Design Patterns

Zero-allocation patterns with Span<T>/Memory<T> and API design principles for accepting and returning the right types.

## Contents

- [Span<T> and Memory<T> for Zero-Allocation Code](#spant-and-memoryt-for-zero-allocation-code)
- [API Design Principles](#api-design-principles)
- [Method Signatures Best Practices](#method-signatures-best-practices)

## Span<T> and Memory<T> for Zero-Allocation Code

Use `Span<T>` and `Memory<T>` instead of `byte[]` or `string` for performance-critical code.

```csharp
// Span<T> for synchronous, zero-allocation operations
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
// WARNING: Reading before writing returns garbage data
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

// Memory<T> for async operations (Span can't cross await)
public async Task<int> ReadDataAsync(
    Memory<byte> buffer,
    CancellationToken cancellationToken)
{
    return await _stream.ReadAsync(buffer, cancellationToken);
}

// String manipulation with Span to avoid allocations
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

// ArrayPool for temporary large buffers
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

// Span-based parsing without substring allocations
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

// Writing data to Span
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

## API Design Principles

### Accept Abstractions, Return Appropriately Specific

**For Parameters (Accept):**

```csharp
// Accept IEnumerable<T> if you only iterate once
public decimal CalculateTotal(IEnumerable<OrderItem> items)
{
    return items.Sum(item => item.Price * item.Quantity);
}

// Accept IReadOnlyCollection<T> if you need Count
public bool HasMinimumItems(IReadOnlyCollection<OrderItem> items, int minimum)
{
    return items.Count >= minimum;
}

// Accept IReadOnlyList<T> if you need indexing
public OrderItem GetMiddleItem(IReadOnlyList<OrderItem> items)
{
    if (items.Count == 0)
        throw new ArgumentException("List cannot be empty");

    return items[items.Count / 2];  // Indexed access
}

// Accept ReadOnlySpan<T> for high-performance, zero-allocation APIs
public int Sum(ReadOnlySpan<int> numbers)
{
    int total = 0;
    foreach (var num in numbers)
        total += num;
    return total;
}

// Accept IAsyncEnumerable<T> for async streaming
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
// Return IEnumerable<T> for lazy/deferred execution
public IEnumerable<Order> GetOrdersLazy(string customerId)
{
    foreach (var order in _repository.Query())
    {
        if (order.CustomerId == customerId)
            yield return order;  // Lazy evaluation
    }
}

// Return IReadOnlyList<T> for materialized, immutable collections
public IReadOnlyList<Order> GetOrders(string customerId)
{
    return _repository
        .Query()
        .Where(o => o.CustomerId == customerId)
        .ToList();  // Materialized
}

// Return concrete types when callers need mutation
public List<Order> GetMutableOrders(string customerId)
{
    // Explicitly allow mutation by returning List<T>
    return _repository
        .Query()
        .Where(o => o.CustomerId == customerId)
        .ToList();
}

// Return IAsyncEnumerable<T> for async streaming
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

// Return arrays for interop or when caller expects array
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

## Method Signatures Best Practices

```csharp
// Complete async method signature
public async Task<Result<Order, OrderError>> CreateOrderAsync(
    CreateOrderRequest request,
    CancellationToken cancellationToken = default)
{
    // Implementation
}

// Optional parameters at the end
public async Task<List<Order>> GetOrdersAsync(
    string customerId,
    DateTime? startDate = null,
    DateTime? endDate = null,
    CancellationToken cancellationToken = default)
{
    // Implementation
}

// Use record for multiple related parameters
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

// Primary constructors (C# 12+) for simple classes
public sealed class OrderService(IOrderRepository repository, ILogger<OrderService> logger)
{
    public async Task<Order> GetOrderAsync(OrderId orderId, CancellationToken cancellationToken)
    {
        logger.LogInformation("Fetching order {OrderId}", orderId);
        return await repository.GetAsync(orderId, cancellationToken);
    }
}

// Options pattern for complex configuration
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
