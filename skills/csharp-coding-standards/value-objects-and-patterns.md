# Value Objects and Pattern Matching

Full code examples for value objects and pattern matching in modern C#.

## Contents

- [Value Objects as readonly record struct](#value-objects-as-readonly-record-struct)
- [Constraint-Enforcing Value Objects](#constraint-enforcing-value-objects)
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

// Value object with input normalization
public readonly record struct PhoneNumber
{
    public string Value { get; }

    public PhoneNumber(string input)
    {
        if (string.IsNullOrWhiteSpace(input))
            throw new ArgumentException("Phone number cannot be empty", nameof(input));

        // Normalize: remove all non-digits
        var digits = new string(input.Where(char.IsDigit).ToArray());

        if (digits.Length is < 10 or > 15)
            throw new ArgumentException("Phone number must be 10-15 digits", nameof(input));

        Value = digits;
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

## Constraint-Enforcing Value Objects

Value objects aren't just for identifiers. They're equally valuable for **enforcing domain constraints** on strings, numbers, and URIs — making illegal states unrepresentable at the type level.

**Key principle: validate at construction, trust everywhere else.** Once you have an `AbsoluteUrl`, every consumer knows it's valid without re-checking.

```csharp
// AbsoluteUrl - enforces HTTP/HTTPS scheme constraints
public readonly record struct AbsoluteUrl
{
    public Uri Value { get; }

    public AbsoluteUrl(string uriString) : this(new Uri(uriString, UriKind.Absolute)) { }

    public AbsoluteUrl(Uri value)
    {
        if (!value.IsAbsoluteUri)
            throw new ArgumentException(
                $"Value must be an absolute URL. Instead found [{value}]", nameof(value));
        if (value.Scheme != Uri.UriSchemeHttp && value.Scheme != Uri.UriSchemeHttps)
            throw new ArgumentException(
                $"Value must be an HTTP or HTTPS URL. Instead found [{value.Scheme}]", nameof(value));
        Value = value;
    }

    /// <summary>
    /// Resolves a potentially relative URL against a base URL.
    /// Handles Linux quirk where Uri.TryCreate("/path", UriKind.Absolute)
    /// succeeds as file:///path.
    /// </summary>
    public static AbsoluteUrl FromRelative(string? url, AbsoluteUrl baseUrl)
    {
        if (string.IsNullOrEmpty(url))
            throw new ArgumentException("URL cannot be null or empty", nameof(url));

        if (Uri.TryCreate(url, UriKind.Absolute, out var absoluteUri) &&
            (absoluteUri.Scheme == Uri.UriSchemeHttp || absoluteUri.Scheme == Uri.UriSchemeHttps))
            return new AbsoluteUrl(absoluteUri);

        return new AbsoluteUrl(new Uri(baseUrl.Value, url));
    }

    public override string ToString() => Value.ToString();
}

// NonEmptyString - prevents empty/whitespace strings from propagating
public readonly record struct NonEmptyString
{
    public string Value { get; }

    public NonEmptyString(string value)
    {
        if (string.IsNullOrWhiteSpace(value))
            throw new ArgumentException("Value cannot be null or whitespace", nameof(value));
        Value = value;
    }

    public override string ToString() => Value;
}

// EmailAddress - format validation at construction
public readonly record struct EmailAddress
{
    public string Value { get; }

    public EmailAddress(string value)
    {
        if (string.IsNullOrWhiteSpace(value))
            throw new ArgumentException("Email cannot be empty", nameof(value));
        if (!value.Contains('@') || !value.Contains('.'))
            throw new ArgumentException($"Invalid email format: {value}", nameof(value));
        Value = value.ToLowerInvariant();
    }

    public override string ToString() => Value;
}

// PositiveAmount - numeric range constraint
public readonly record struct PositiveAmount
{
    public decimal Value { get; }

    public PositiveAmount(decimal value)
    {
        if (value <= 0)
            throw new ArgumentOutOfRangeException(nameof(value), "Amount must be positive");
        Value = value;
    }

    public override string ToString() => Value.ToString("N2");
}
```

**Why this matters:**
- APIs like Slack Block Kit silently reject relative URLs with cryptic errors. Transactional email links break if they're relative. `AbsoluteUrl` makes the compiler prevent this.
- Platform gotchas belong in the value object — e.g., Linux `Uri.TryCreate` treating `/path` as `file:///path` is handled once in `FromRelative`, not at every call site.

### TypeConverter Support for Configuration Binding

Add a `TypeConverter` so your value objects work with `IOptions<T>` and configuration binding:

```csharp
[TypeConverter(typeof(AbsoluteUrlTypeConverter))]
public readonly record struct AbsoluteUrl
{
    // ... same as above
}

public sealed class AbsoluteUrlTypeConverter : TypeConverter
{
    public override bool CanConvertFrom(ITypeDescriptorContext? context, Type sourceType)
        => sourceType == typeof(string) || base.CanConvertFrom(context, sourceType);

    public override object? ConvertFrom(
        ITypeDescriptorContext? context, CultureInfo? culture, object value)
        => value is string s ? new AbsoluteUrl(s) : base.ConvertFrom(context, culture, value);
}

// Now this works with appsettings.json binding:
public sealed class WebhookOptions
{
    public AbsoluteUrl CallbackUrl { get; set; }
    public AbsoluteUrl HealthCheckUrl { get; set; }
}

// appsettings.json:
// { "Webhook": { "CallbackUrl": "https://example.com/callback" } }
services.Configure<WebhookOptions>(configuration.GetSection("Webhook"));
```

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
