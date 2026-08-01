# Nullable Attributes Reference

Attributes in `System.Diagnostics.CodeAnalysis` describe null-state contracts the type system cannot express directly. Apply them to express preconditions, postconditions, conditional behavior, member initialization guarantees, and unreachable code.

```csharp
using System.Diagnostics.CodeAnalysis;
```

## Attribute Catalog

| Attribute | Category | Meaning |
| --- | --- | --- |
| `[AllowNull]` | Precondition | A non-nullable parameter, field, or property might be null. |
| `[DisallowNull]` | Precondition | A nullable parameter, field, or property should never be null. |
| `[MaybeNull]` | Postcondition | A non-nullable parameter, field, property, or return value might be null. |
| `[NotNull]` | Postcondition | A nullable parameter, field, property, or return value is never null. |
| `[MaybeNullWhen(bool)]` | Conditional postcondition | A non-nullable argument might be null when the method returns the specified `bool` value. |
| `[NotNullWhen(bool)]` | Conditional postcondition | A nullable argument isn't null when the method returns the specified `bool` value. |
| `[NotNullIfNotNull(string)]` | Conditional postcondition | A return value, property, or argument isn't null if the argument for the specified parameter isn't null. |
| `[MemberNotNull(string...)]` | Helper method | The listed members are non-null when the method returns. |
| `[MemberNotNullWhen(bool, string...)]` | Helper method | The listed member isn't null when the method returns the specified `bool` value. |
| `[DoesNotReturn]` | Unreachable code | The method or property never returns (always throws). |
| `[DoesNotReturnIf(bool)]` | Unreachable code | The method or property never returns if the associated `bool` parameter has the specified value. |

---

## Preconditions: `AllowNull` and `DisallowNull`

### `[AllowNull]`

**Intent:** Allow `null` to be passed into a non-nullable input so callers do not get warnings, even though the member remains non-nullable externally.

**Typical use:** Properties that never return `null` but accept `null` to reset to a default; parameters that interpret `null` as "use default".

```csharp
private string _screenName = GenerateRandomScreenName();

[AllowNull]
public string ScreenName
{
    get => _screenName;               // Non-nullable to callers.
    set => _screenName = value ?? GenerateRandomScreenName();
}
```

**Rules:**
- Use `[AllowNull]` only on inputs (parameters, property setters).
- Do not put `[AllowNull]` on outputs (getters, return types).

### `[DisallowNull]`

**Intent:** Forbid `null` for an input whose type is nullable. Useful when the type must be nullable for compatibility or internal reasons but callers should not explicitly pass `null`.

```csharp
private string? _reviewComment;

[DisallowNull]
public string? ReviewComment
{
    get => _reviewComment; // May return null (for example not set yet).
    set => _reviewComment = value ?? throw new ArgumentNullException(nameof(value));
}
```

**Rules:**
- Use `[DisallowNull]` on parameters or property setters where the type is nullable but actual usage expects non-null in normal operation.
- Do not use `[DisallowNull]` on outputs.

---

## Postconditions (unconditional): `MaybeNull` and `NotNull`

### `[MaybeNull]`

**Intent:** The output may be `null` even though the declared type is non-nullable. Common scenario: generic methods where `default(T)` can be `null` for reference type `T`, or outputs using `default` as a "not found"/"no value" sentinel.

```csharp
[return: MaybeNull]
public static T Find<T>(IEnumerable<T> source, Func<T, bool> predicate)
{
    foreach (var item in source)
    {
        if (predicate(item))
        {
            return item;  // non default
        }
    }

    return default;       // may be null for reference T
}
```

**Rules:**
- Use `[MaybeNull]` on return values of generic methods, and on `out` parameters when the type is non-nullable but some flows may produce null.
- Do not use `[MaybeNull]` on already-nullable return types; instead use `T?`.

### `[NotNull]`

**Intent:** Guarantee that an output is not null even though its declared type is nullable. Also used on parameters to guarantee the parameter is not null once the method returns successfully.

**Guard pattern:**

```csharp
public static class Guard
{
    public static void ThrowIfNull([NotNull] object? value, string paramName)
    {
        if (value is null)
        {
            throw new ArgumentNullException(paramName);
        }
    }
}
```

At call sites, after `Guard.ThrowIfNull(customer, nameof(customer));`, the compiler treats `customer` as non-null. (Prefer the BCL `ArgumentNullException.ThrowIfNull`, which is already annotated.)

**Rules:**
- Use `[NotNull]` on parameters that are nullable but guaranteed non-null after the method returns normally, and on `out` parameters where the method always assigns a non-null value.
- Prefer non-nullable types for return types that are never null. Only apply `[NotNull]` to returns in edge generic scenarios.

---

## Conditional postconditions: `NotNullWhen`, `MaybeNullWhen`, `NotNullIfNotNull`

### `[NotNullWhen(bool)]`

**Intent:** Indicate that a `ref`, `out`, or `in` parameter is non-null when the method returns a specific boolean value. Important for the Try pattern and null-checking helper methods.

**Try pattern:**

```csharp
public bool TryGetMessage(
    string key,
    [NotNullWhen(true)] out string? message)
{
    if (_messages.TryGetValue(key, out var result))
    {
        message = result;
        return true;
    }

    message = null;
    return false;
}
```

At call sites:

```csharp
if (TryGetMessage(key, out var message))
{
    // message is non null here.
    Console.WriteLine(message.Length);
}
```

**Null-check helper:**

```csharp
public static bool IsNotNullOrEmpty([NotNullWhen(true)] string? value)
    => !string.IsNullOrEmpty(value);
```

> **BCL convention note:** `string.IsNullOrEmpty` is annotated `[NotNullWhen(false)] string? value` — when it returns `false`, the argument is not null. Mirror the standard helper direction where possible; use `[NotNullWhen(true)]` only for the inverted helper (`IsNotNullOrEmpty`).

**Rules:**
- For Try pattern methods `bool TryX(..., out T? value)`, annotate the `out` parameter with `[NotNullWhen(true)]`.
- For helper methods returning `bool` to indicate success of a null check, annotate the nullable parameter with `[NotNullWhen(true)]` when `true` means "value is not null".

### `[MaybeNullWhen(bool)]`

**Intent:** Indicate that an output may be null when the method returns a specific boolean value. Useful when a method returns `bool` and an output is non-null in one case and maybe null in another.

```csharp
public bool TryGetValue(
    string key,
    [MaybeNullWhen(false)] out string value)
{
    if (_map.TryGetValue(key, out var result))
    {
        value = result;
        return true;
    }

    value = default;  // here default is null
    return false;
}
```

**Rules:**
- Prefer `[NotNullWhen(true)]` for classical Try patterns with nullable `out` types.
- Use `[MaybeNullWhen]` when returning a non-nullable type but allowing null only on specific return values.

### `[NotNullIfNotNull(string)]`

**Intent:** Indicate that the return value is non-null if and only if a specified parameter is non-null. Useful for wrappers and conversion helpers. Prefer `nameof(param)` over a string literal for refactor safety.

```csharp
public static string? NormalizeUrl([NotNullIfNotNull(nameof(url))] string? url)
{
    if (url is null)
    {
        return null;
    }

    return url.Trim().ToLowerInvariant();
}
```

At call sites, if input is non-null the compiler treats the return as non-null; if input may be null the return is also maybe null.

**Rules:**
- Use `[NotNullIfNotNull(nameof(param))]` for "pure transformation" functions that preserve nullness between input and output.

---

## Helper methods: `MemberNotNull` and `MemberNotNullWhen`

### `[MemberNotNull]`

**Intent:** Declare that a method initializes specific members so they are non-null once the method returns. Used when non-nullable fields/properties are initialized in helper methods the compiler cannot track through.

```csharp
public class CustomerContext
{
    private string _tenantId;
    private Customer _currentCustomer;

    public CustomerContext()
    {
        Initialize();
    }

    [MemberNotNull(nameof(_tenantId), nameof(_currentCustomer))]
    private void Initialize()
    {
        _tenantId = LoadTenantId();
        _currentCustomer = LoadCustomer(_tenantId);
    }
}
```

**Rules:**
- Use `[MemberNotNull]` on private helper methods called from constructors to satisfy non-nullable field initialization.
- The method must assign non-null values to the members on all non-throwing paths.

### `[MemberNotNullWhen(bool)]`

**Intent:** Declare that certain members are non-null when the method returns a specified boolean value. The attribute is applied to the **method/property declaration** (like `MemberNotNull`); the `bool` is the return-value condition, not a parameter.

```csharp
public class LazyHolder
{
    private string? _value;

    [MemberNotNullWhen(true, nameof(_value))]
    public bool EnsureLoaded()
    {
        if (_value is null)
        {
            _value = LoadValue();
        }

        return _value is not null;
    }
}
```

**Rules:**
- Use `[MemberNotNullWhen(true, ...)]` on methods that return a boolean indicating successful initialization and initialize one or more members to non-null when returning true.
- Do **not** place `[MemberNotNullWhen]` on a parameter; it applies to the method declaration.

---

## Unreachable code: `DoesNotReturn` and `DoesNotReturnIf`

These attributes tell the compiler that code after a call is unreachable, so null-state analysis does not warn there. They are essential for throw/guard helpers when introducing NRT.

### `[DoesNotReturn]`

**Intent:** The method or property never returns (always throws).

```csharp
[DoesNotReturn]
private void FailFast()
{
    throw new InvalidOperationException();
}

public void SetState(object containedField)
{
    if (containedField is null)
    {
        FailFast();
    }

    // containedField can't be null: no warning here.
    _field = containedField;
}
```

### `[DoesNotReturnIf(bool)]`

**Intent:** The method never returns if the associated `bool` parameter has the specified value. Apply to a Boolean parameter of the helper.

```csharp
private void FailFastIf([DoesNotReturnIf(true)] bool isNull)
{
    if (isNull)
    {
        throw new InvalidOperationException();
    }
}

public void SetFieldState(object? containedField)
{
    FailFastIf(containedField == null);
    // No warning: containedField can't be null here.
    _field = containedField;
}
```

**Rules:**
- Use `[DoesNotReturn]` on exception/abort helpers that always throw.
- Use `[DoesNotReturnIf(true/false)]` on a `bool` parameter of guards that throw conditionally. This is how the compiler learns the maybe-null argument is non-null after the call.

---

## The `field` Keyword (C# 14 / .NET 10) and Nullability

The `field` contextual keyword lets an accessor body reference a compiler-synthesized backing field. This is a primary NRT scenario (lazy properties) and has dedicated nullable-analysis rules.

### Lazy-initialized property (null-resilient getter)

```csharp
public class C
{
    public C() { } // No CS8618: the getter is null-resilient.
    string Prop => field ??= GetPropValue();
}
```

### Null-resilience

The backing field's nullable annotation can differ from the property's. The compiler performs a special *null-resilience* analysis on the `get` accessor (only when the property may be of reference type and is not-annotated):

- A property is **null-resilient** when its `get` accessor preserves null-safety even when the field contains `default`. Two analysis passes run: one with `field` not-annotated, one annotated. If the not-annotated pass has no extra nullable diagnostics, the property is null-resilient.
- If the property has no `get` accessor, it is (vacuously) null-resilient. An auto-implemented `get;` is **not** null-resilient.

The backing field's nullable annotation is then:
- If the property's annotation is annotated or oblivious: same as the property.
- If the property's annotation is not-annotated: annotated when null-resilient, not-annotated when not.

### Non-resilient getter escape hatch

When the getter just returns `field` (not null-resilient), the backing field is not-annotated and you will get constructor/setter warnings. Use field-targeted attributes to treat the backing field as nullable:

```csharp
[field: AllowNull, MaybeNull]
public string Prop => field ??= GetPropValue();
```

`[field: MaybeNull, AllowNull]` gives the field a maybe-null initial flow state and allows null values to be written — the "little-l lazy" scenario without nuisance constructor warnings.

### Setter and constructor analysis

- **Constructor analysis:** field-backed properties are treated as proxies to their backing field; the backing field's nullable annotation is used for the return-point check. A null-resilient property does not need to be initialized in the constructor.
- **Setter analysis:** the initial flow state of `field` in a setter is the state after the initializer if one exists, otherwise `field = default;`. At each return, a warning is reported if the backing field's flow state is incompatible with its annotations/attributes.

### Other notes

- `nameof(field)` does not compile — `field` is a keyword in accessor scope. Use `nameof(value)` in setter `ArgumentException`s.
- Field-targeted attributes (`[field: Xyz]`) are valid only when an accessor uses `field`.
- Overriding properties may use `field`; it refers to the overriding property's own backing field, separate from the base.
- Ref-returning properties cannot use `field`.

---

## Summary

- `[AllowNull]` / `[DisallowNull]`: preconditions on inputs.
- `[MaybeNull]` / `[NotNull]`: unconditional postconditions on outputs/parameters.
- `[NotNullWhen]` / `[MaybeNullWhen]` / `[NotNullIfNotNull]`: conditional postconditions tied to a `bool` return or another argument's nullness.
- `[MemberNotNull]` / `[MemberNotNullWhen]`: helper-method initialization guarantees (apply to the method, not a parameter).
- `[DoesNotReturn]` / `[DoesNotReturnIf]`: throw/abort helpers so the compiler treats following code as unreachable.
- `field` (C# 14): lazily-initialized properties with dedicated null-resilience analysis; use `[field: AllowNull, MaybeNull]` for non-resilient getters.