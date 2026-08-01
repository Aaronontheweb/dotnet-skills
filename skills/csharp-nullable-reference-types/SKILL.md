---
name: csharp-nullable-reference-types
description: Guidelines for introducing and using nullable reference types (NRT) and System.Diagnostics.CodeAnalysis nullable attributes in C# / .NET codebases. Covers the nullability model, flow analysis, the null-forgiving operator, API design rules, the full attribute catalog (AllowNull, DisallowNull, MaybeNull, NotNull, NotNullWhen, MaybeNullWhen, NotNullIfNotNull, MemberNotNull, MemberNotNullWhen, DoesNotReturn, DoesNotReturnIf), the C# 14 field keyword, incremental migration of legacy codebases, and a code-generation checklist.
version: 1.0.0
tags:
  - csharp
  - nullable
  - nrt
  - code-quality
  - api-design
---

# C# Nullable Reference Types

## When to Use

- Introducing nullable reference types (NRT) into a codebase that has not yet adopted them
- Writing or refactoring C# code that uses `T?` / nullable annotations
- Annotating APIs with `System.Diagnostics.CodeAnalysis` nullable attributes
- Designing public/internal APIs where nullability contracts matter
- Wrapping unannotated or legacy APIs so downstream callers still benefit from NRT
- Reviewing code for correct null-state analysis, guard helpers, and the `field` keyword

## Core Goals

- Prevent `NullReferenceException` at runtime by making null intent explicit in signatures.
- Express contracts the type system cannot represent directly using the official nullable attributes.
- Adopt NRT incrementally in legacy codebases without a big-bang rewrite.

## Core Nullability Model

### Non-nullable vs nullable

- `string` — non-nullable reference. The compiler assumes instances are never `null`; assigning `null` or a maybe-null value produces a warning.
- `string?` — nullable reference. The variable may be `null`; the compiler requires a null check before dereference.

```csharp
string name = "Alice";
name = null;          // Warning: assigning null to non-nullable.

string? nickname = null;
Console.WriteLine(nickname.Length); // Warning: possible null dereference.
```

### Null-state analysis (flow)

The compiler tracks whether a reference is *definitely non-null* or *maybe null*. Null checks and assignments update this state.

```csharp
string? message = GetMessageOrNull();

if (message != null)
{
    // message is definitely non-null in this block.
    Console.WriteLine(message.Length);
}

// Outside the if, message is maybe null again.
```

Introduce explicit null checks (`if (x != null)`, `is not null`, pattern matching) before dereferencing nullable values. Narrow nullability early and keep the non-null state alive. **Null-conditional assignment (C# 14)** lets you write `customer?.Order = CreateOrder();` — the right side is evaluated only when the receiver is non-null.

### Null-forgiving operator (`!`)

`x!` tells the compiler "treat `x` as non-null here." It affects analysis only, not runtime behavior.

- Use `!` only when a real invariant guarantees non-null and the compiler cannot see it.
- Do **not** use `!` as a general fix for warnings. Prefer refactoring control flow, adding attributes, or proper member initialization.

```csharp
_customer = LoadCustomerFromOrm()!; // ORM guarantees this is not null in valid state.
```

### Reorganize code before suppressing warnings

A successful guard clause or pattern match already creates a null-safe region in the current scope. Before adding `!`, make nullable values cross a checked boundary once and keep the remaining code non-nullable:

- narrow early with a guard clause or pattern match;
- copy nullable fields or properties to a local before checking, so repeated reads cannot change underneath the analysis;
- when a method has complex control flow, optionally move the non-null path into a local function or private method with non-nullable parameters;
- keep nullable handling at the boundary instead of spreading `T?`, repeated checks, or `!` through the implementation.

```csharp
public void Process(Order? order)
{
    if (order?.Customer is not { } customer)
    {
        return;
    }

    // The pattern match already proved that customer is non-null here.
    Console.WriteLine(customer.Name);
}
```

Do not extract a function solely to satisfy nullable analysis. Use an explicit non-nullable function boundary when it also simplifies a large or branching implementation. Use `!` only when a real external invariant cannot be represented through control flow, signatures, or nullable-analysis attributes.

## Project Configuration

Enable NRT for new code:

```xml
<PropertyGroup>
  <Nullable>enable</Nullable>
</PropertyGroup>
```

For legacy codebases, enable incrementally with file-level directives (`#nullable enable`, `#nullable disable`, `#nullable enable warnings`, `#nullable enable annotations`). Treat `CS86xx` nullable warnings as important; consider `TreatWarningsAsErrors` or treating nullable warnings as errors in new projects.

See [nrt-migration-playbook-reference.md](nrt-migration-playbook-reference.md) for the full incremental-adoption strategy, `#nullable` directive reference, legacy interop, and known static-analysis limitations (arrays, `default(struct)`).

## API Design Rules (Signatures)

These rules apply to public and internal APIs and to models.

**Parameters** — if `null` is not allowed, use a non-nullable type and add a runtime guard for public APIs:

```csharp
public void SendEmail(string recipient)
{
    ArgumentNullException.ThrowIfNull(recipient);
    // Implementation
}
```

If `null` is allowed and meaningful, use `T?`, document how `null` is interpreted, and implement correct `null` behavior.

**Return types** — `Customer` when the method never returns `null`; `Customer?` when it can legitimately return `null` (callers must check, and the compiler enforces it).

```csharp
public Customer GetRequiredCustomer(Guid id);  // Throws on failure.
public Customer? TryGetCustomer(Guid id);       // Returns null on failure.
```

**Properties and fields** — follow the same rules as parameters and return types. Non-nullable members must be initialized in constructors, via `required` properties with object initializers, via `field`-backed lazy properties, or via helpers annotated with `[MemberNotNull]`.

```csharp
public class Order
{
    public required string Id { get; init; }
    public required Customer Customer { get; init; }
    public string? Comment { get; init; } // Optional.
}
```

When contracts depend on input/output behavior, conditional behavior, or member initialization, apply the nullable attributes described in [nullable-attributes-reference.md](nullable-attributes-reference.md).

### Public API compatibility for libraries

Treat nullable annotations and nullable-analysis attributes as part of a shipped API contract. `T` and `T?` have the same CLR type, so annotation-only changes are generally binary compatible, but they can be source breaking by introducing warnings for nullable-enabled consumers. Those warnings often become build failures when consumers treat warnings as errors.

Review public nullability changes before release, especially:

- weakening an output from `T` to `T?` or adding `[MaybeNull]`;
- tightening an input from `T?` to `T` or adding `[DisallowNull]`;
- changing generic constraints such as `class?`, `class`, or `notnull`;
- changing annotations or attributes on virtual members, interfaces, delegates, and implementations, where mismatches produce compiler warnings.

Adding annotations to a previously nullable-oblivious API can create the same source-compatibility problems. Compare the annotated surface with the last released version, test a nullable-enabled consumer, and document or version intentional source-breaking changes according to the library's compatibility policy.

## The `field` Keyword (C# 14 / .NET 10)

The `field` contextual keyword lets you write a property accessor body without declaring an explicit backing field. This is a primary NRT scenario (lazily-initialized properties) and the compiler performs a special *null-resilience* analysis so you do not get nuisance `CS8618` in constructors:

```csharp
public class C
{
    public C() { } // No warning: the getter is null-resilient.
    string Prop => field ??= GetPropValue();
}
```

See [nullable-attributes-reference.md](nullable-attributes-reference.md) for the full `field` nullability rules (null-resilient vs non-resilient getters, the `[field: AllowNull, MaybeNull]` escape hatch, and setter/constructor analysis).

## Reference Files

- [nullable-attributes-reference.md](nullable-attributes-reference.md): The complete `System.Diagnostics.CodeAnalysis` attribute catalog — preconditions (`AllowNull`, `DisallowNull`), postconditions (`MaybeNull`, `NotNull`), conditional postconditions (`NotNullWhen`, `MaybeNullWhen`, `NotNullIfNotNull`), helper methods (`MemberNotNull`, `MemberNotNullWhen`), unreachable-code helpers (`DoesNotReturn`, `DoesNotReturnIf`), and the `field` keyword nullability rules. Each with intent, pattern, and agent rules.
- [nrt-migration-playbook-reference.md](nrt-migration-playbook-reference.md): Incremental adoption strategy, `#nullable` directive reference, legacy/unannotated API interop, polyfilling nullable attributes for older target frameworks (with tradeoffs and a confirm-before-adding decision process), known static-analysis limitations (arrays of non-nullable references, `default(struct)` with reference fields), warning handling, and the full generation checklist.

## Generation Checklist (Summary)

1. **Project** — `<Nullable>enable</Nullable>` present; disable only around unavoidable legacy code.
2. **Types** — non-nullable for required params/returns/properties; `T?` only when `null` is valid and expected.
3. **Initialization** — constructors, `required` + object initializers, `field`-backed lazy getters, or `[MemberNotNull]` helpers. Avoid `null!` except as a documented escape hatch.
4. **Null checks** — explicit guards at public boundaries; narrow with control flow, and extract a non-nullable helper only when it improves complex code; `!` only with a clear invariant.
5. **Attributes** — apply to express contracts the type system cannot express (see reference file).
6. **Interop** — trust BCL/annotated libraries; add your own guards and attributes when wrapping unannotated APIs.
7. **Warnings** — never ignore; fix design or add attributes rather than suppressing with `!` or `#pragma`.
8. **Compatibility** — for released libraries, review public nullability changes as potential source breaks and test nullable-enabled consumers.

## References

- [Nullable reference types (overview)](https://learn.microsoft.com/dotnet/csharp/nullable-references)
- [Attributes for null-state static analysis](https://learn.microsoft.com/dotnet/csharp/language-reference/attributes/nullable-analysis)
- [Nullable migration strategies](https://learn.microsoft.com/dotnet/csharp/advanced-topics/update-applications/nullable-migration-strategies)
- [Breaking change: Nullable reference type annotation changes](https://learn.microsoft.com/dotnet/core/compatibility/core-libraries/6.0/nullable-ref-type-annotation-changes)
- [Tutorial: Express your design intent with nullable and non-nullable reference types](https://learn.microsoft.com/dotnet/csharp/whats-new/tutorials/nullable-reference-types)
- [What's new in C# 14](https://learn.microsoft.com/dotnet/csharp/whats-new/csharp-14) (extension members, `field` keyword GA, null-conditional assignment)
- [The `field` contextual keyword (feature spec)](https://learn.microsoft.com/dotnet/csharp/language-reference/proposals/csharp-14.0/field-keyword)