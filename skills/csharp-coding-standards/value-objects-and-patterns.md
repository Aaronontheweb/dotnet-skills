# Value Objects and Pattern Matching

Full code examples for value objects and pattern matching in modern C#.

## Contents

- [Value Objects as readonly record struct](#value-objects-as-readonly-record-struct)
- [No Implicit Conversions](#no-implicit-conversions)
- [Pattern Matching (C# 8-12)](#pattern-matching-c-8-12)

## Value Objects as readonly record struct

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

## No Implicit Conversions

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

## Pattern Matching (C# 8-12)

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
