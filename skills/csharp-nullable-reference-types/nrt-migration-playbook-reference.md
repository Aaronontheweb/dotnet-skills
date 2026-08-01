# NRT Migration Playbook Reference

Incremental adoption of nullable reference types in codebases that have not yet enabled them, plus `#nullable` directives, legacy interop, and known static-analysis limitations.

## Incremental Adoption Strategy

### Project-level

For new code:

```xml
<PropertyGroup>
  <Nullable>enable</Nullable>
</PropertyGroup>
```

For a legacy solution being migrated incrementally, do not flip the whole solution at once. Options, in order of preference:

1. **Enable per-project as you touch it.** When you open a project to modernize it, add `<Nullable>enable</Nullable>` and fix the resulting warnings file by file.
2. **Enable with warnings-only first.** Use `<Nullable>annotations` or `<Nullable>warnings>` to split the rollout: `warnings` enables flow-analysis warnings without requiring annotations; `annotations` enables annotations without warnings. Bring both on once the project is clean.
3. **Use file-level directives** (below) to enable NRT inside individual files in a project that is not yet globally enabled.

### File-level `#nullable` directives

| Directive | Effect |
| --- | --- |
| `#nullable enable` | Enable both warnings and annotations for the rest of the file. |
| `#nullable disable` | Disable both. Temporary escape hatch around unannotated legacy code. |
| `#nullable enable warnings` | Enable only nullable warnings (flow analysis) for the file. |
| `#nullable enable annotations` | Enable only nullable annotations for the file. |
| `#nullable restore` | Restore the project-level setting. |
| `#nullable restore warnings` / `#nullable restore annotations` | Restore the project-level setting for one dimension. |

Use `#nullable enable` at the top of new or heavily edited files in a not-yet-enabled project. Use `#nullable disable` only as a temporary, localized escape hatch around unannotated legacy code you cannot yet fix — scope it to the smallest region possible and leave a comment explaining why.

### Polyfilling the nullable attributes for older target frameworks

The `System.Diagnostics.CodeAnalysis` nullable attributes live in the BCL. Their availability depends on the target framework:

- **Available:** .NET Core 3.0+, .NET 5+, and (partially) .NET Standard 2.1.
- **Not available:** netstandard2.0, .NET Framework (any version), and older UWP.
- **Partial on netstandard2.1:** the earlier attributes (`AllowNull`, `DisallowNull`, `MaybeNull`, `NotNull`, `NotNullWhen`, `MaybeNullWhen`) exist, but `MemberNotNull`, `MemberNotNullWhen`, `DoesNotReturn`, `DoesNotReturnIf`, and `NotNullIfNotNull` were added in .NET 5 and are missing from netstandard2.1.

The attributes are compiler-consumed (the compiler only needs to *see* the types), so on TFMs where they are absent you have a choice. **Do not automatically add a polyfill package.** Evaluate the tradeoffs below, present the options to the user, and confirm before introducing a dependency.

#### Is a polyfill needed at all?

First answer these; a polyfill is only relevant if the answer to all three is yes:

1. The library multi-targets to at least one TFM that lacks the attributes (netstandard2.0, .NET Framework, older UWP, or a netstandard2.1 target that needs the .NET 5+ attributes).
2. You want to expose an *annotated* public API surface to consumers on those old TFMs (not just internally).
3. You are not willing to drop the old TFM (for example, raising the floor to netstandard2.1+ or net6.0+).

If the library only targets `net10.0`/`net8.0`/etc., **do nothing** — the attributes are already in the BCL. If only internal code needs analysis and the public surface is unannotated on the old TFM, consider `#if`-gating annotations instead (below).

#### Options and tradeoffs

| Option | Cost | Benefit | Risk |
| --- | --- | --- | --- |
| **No annotation on old TFMs** (`#if`-gate the `?`/attributes out) | Low effort; zero new dependency. | Keeps old-TFM consumers compiling. | Old-TFM consumers get no NRT flow analysis from your API; surface differs per TFM. |
| **Conditional polyfill reference** (PolySharp only for TFMs missing the attributes) | One `Condition` on the `PackageReference`. Minimal blast radius. | Annotated surface for all TFMs; dependency only compiles in where needed. | Still a third-party source generator in the build for those TFMs. |
| **Unconditional polyfill reference** (PolySharp for all TFMs) | Simplest config. | Annotated surface everywhere; PolySharp no-ops where the BCL already has the types. | Source generator runs in every build regardless; slightly heavier than conditional. |
| **Hand-rolled internal attribute copies** | No dependency. | Full control. | Compiler keys off exact namespace/type; subtle signature/version mismatches break analysis silently; ongoing maintenance. Generally discouraged. |
| **Drop the old TFM** (raise floor to netstandard2.1+ or net6.0+) | Migration effort; may lose consumers. | No polyfill needed; cleanest surface. | Breaking change for existing consumers; not always acceptable. |

#### Candidate packages (evaluate, do not default to one)

- **[PolySharp](https://github.com/Sergio0694/PolySharp)** — source generator, source-only (no runtime assembly, no transitive runtime deps). Polyfills all 11 nullable analysis attributes and auto-detects which are needed per TFM. Targeted to compiler/language attributes only. Configure `PrivateAssets="all"` and set `<LangVersion>` to your desired C# version. Lower supply-chain surface than a normal package, but it is still a third-party source generator executing in your build.
- **[Polyfill](https://github.com/SimonCropp/Polyfill)** — broader source-only package covering newer BCL APIs and C# features too. Consider only when you already need the broader API surface, not just the nullable attributes; otherwise it adds more generated code than the task requires.

#### Decision rules

- **Confirm before adding.** Present the table above and the specific TFM/attribute gap to the user and let them choose. Do not silently add `PackageReference`.
- **Prefer the smallest intervention.** If only a couple of attributes are missing on a rarely-used old TFM, weigh a conditional reference against simply not annotating that surface.
- **Scope the dependency.** If a polyfill is chosen, prefer a conditional reference so it only participates for TFMs that need it:
  ```xml
  <ItemGroup Condition="!$(TargetFramework.StartsWith('net')) or '$(TargetFramework)' == 'netstandard2.0' or '$(TargetFramework)' == 'net48'">
    <!-- Evaluate and confirm with the user before adding. -->
    <PackageReference Include="PolySharp" PrivateAssets="all" />
  </ItemGroup>
  ```
  (Adjust the condition to your actual TFMs; the intent is "only where the BCL lacks the types".)
- **Keep it private.** A polyfill package must be `PrivateAssets="all"` — the generated internal types must not leak into consumers, and consumers must not acquire the dependency transitively.
- **Do not hand-roll** the attributes. If you choose not to use a polyfill, prefer `#if`-gating the annotations out rather than copying the attribute types yourself, to avoid exact-signature mismatches the compiler will silently ignore.
- **A polyfill provides types, not analysis.** You still need `<Nullable>enable</Nullable>` (or `#nullable enable`) for the compiler to run flow analysis. The attributes only describe contracts the flow analysis already does.

#### Quick checklist before introducing a polyfill

1. Which TFM(s) in the project are actually missing the attributes? (Check the table above.)
2. Does the public surface need annotations on those TFMs, or only internal code?
3. Is raising the TFM floor or `#if`-gating cheaper than a dependency?
4. If a polyfill is warranted: PolySharp (attributes only) vs Polyfill (broader)? Conditional vs unconditional reference?
5. Have you confirmed the choice with the user before editing the project file?

### Warning handling

- Treat nullable warnings as important. Do not ignore them.
- Recommended for new projects: `<TreatWarningsAsErrors>true</TreatWarningsAsErrors>` or at least treat `CS86xx` as errors.
- Fix the design or add attributes rather than suppressing with `!` or `#pragma warning disable`.
- When you must suppress, use the narrowest scope and add a justification:
  ```csharp
  #pragma warning disable CS8602 // Justification: ORM guarantees non-null here; cannot be expressed to the compiler.
  ```
- `null!` for non-nullable fields is an explicit, documented escape hatch only — prefer constructors, `required`, `field`-backed getters, or `[MemberNotNull]` helpers.

## Legacy and Unannotated API Interop

### Trust annotated libraries

As of .NET 5, all .NET runtime APIs are annotated, so the analysis benefits any code that calls them. Trust the nullability annotations of the .NET BCL and annotated libraries (most modern NuGet packages).

### Wrapping unannotated or legacy APIs

When you wrap an unannotated or legacy API, add your own guards and attributes so downstream callers still benefit from NRT:

```csharp
// Legacy ORM returns object? but is guaranteed non-null in valid state.
public Customer LoadCustomerOrThrow(Guid id)
{
    var customer = _legacyOrm.Load(id);
    ArgumentNullException.ThrowIfNull(customer, nameof(customer));
    return customer;
}
```

For Try-style wrappers around unannotated dictionaries/mappings, annotate the `out` parameter with `[NotNullWhen(true)]` so callers get flow analysis even though the underlying API is oblivious.

### Gradual annotation of a library

If you maintain a library that is not yet annotated:

1. Enable `<Nullable>annotations` first so you can add `?` annotations without breaking callers on warnings.
2. Annotate the public surface file by file, running tests after each batch.
3. Once the public surface is annotated, enable `<Nullable>enable` (warnings + annotations) and resolve internal warnings.

## Known Static-Analysis Limitations and Safe Patterns

Static analysis has limits. Be aware of these so generated code stays correct at runtime.

### Arrays and default values

- Arrays of non-nullable references are created with all elements set to `null` at runtime. The compiler does not warn when reading from such arrays into non-nullable variables.
- Treat elements of `T[]` as nullable until explicitly assigned, even if `T` is non-nullable. Initialize arrays fully after creation when possible.

```csharp
string[] names = new string[10];

// Prefer: fill before use.
for (int i = 0; i < names.Length; i++)
{
    names[i] = $"Name {i}";
}
```

### Structs with non-nullable fields

- `default(MyStruct)` does not initialize non-nullable reference fields and can produce `null` at runtime. The compiler may not warn in all such cases.
- Avoid `default(T)` for structs that contain non-nullable reference fields. Provide static factories or constructors that fully initialize such structs.

### Other limitations to keep in mind

- **Method-group and lambda captures:** flow analysis does not always track nullness across delegates; verify captures that relay nullable values.
- **Interprocedural limits:** the compiler analyzes constructors and direct helper calls, but not arbitrary call chains — use `[MemberNotNull]` / `[MemberNotNullWhen]` to bridge.
- **Reflection and dynamic:** nullability annotations are erased at runtime; reflection sees only the erased types. Do not rely on runtime nullability via reflection.

## Full Generation Checklist

When generating or refactoring C# code that uses nullable reference types:

1. **Project configuration**
   - Ensure `<Nullable>enable</Nullable>` is present in the project file.
   - For legacy codebases, enable per-project or per-file with `#nullable enable`.
   - Avoid disabling nullability except around unavoidable legacy code, scoped as narrowly as possible.

2. **Type selection**
   - Non-nullable reference types for required parameters, required return values, and required properties/fields.
   - Nullable reference types (`T?`) only when `null` is a valid and expected value the caller must handle.
   - For generic outputs that may be `default`, use `[MaybeNull]` rather than forcing `T?` (which loses value-type semantics).

3. **Initialization**
   - Initialize all non-nullable fields and properties in constructors, with `required` properties and object initializers, via `field`-backed lazy getters (C# 14), or via helpers annotated with `[MemberNotNull]`.
   - Avoid leaving non-nullable members with `null!` except as an explicit, documented escape hatch.

4. **Null checks**
   - Add explicit null guards at public API boundaries (`ArgumentNullException.ThrowIfNull`).
   - Use pattern matching and `if`/`is not null` to narrow nullable types before dereference.
   - Use the null-conditional operators `?.` / `?[]`, and null-conditional assignment (C# 14) `x?.Prop = value;` to guard assignments.
   - Only use `!` when there is a clear invariant that ensures non-null and no better way to express it.

5. **Attributes** (apply to express contracts the type system cannot express)
   - **Inputs:**
     - `[AllowNull]` when non-nullable members accept `null` as a reset or special signal.
     - `[DisallowNull]` when nullable members must not be assigned `null` by callers.
   - **Outputs and contracts:**
     - Use `T?` to indicate nullable returns where possible.
     - `[MaybeNull]` for generic or value-type outputs that may be `null`.
     - `[NotNull]` on null-guard parameters (and `out` params always assigned non-null).
     - `[NotNullWhen(true)]` on nullable `out` parameters in Try-pattern methods.
     - `[NotNullIfNotNull(nameof(param))]` for pure transformations that preserve nullness.
   - **Members:**
     - `[MemberNotNull]` on initialization helpers called by constructors.
     - `[MemberNotNullWhen(true, ...)]` on methods that return success flags for initialization (applied to the method declaration).
   - **Throw helpers:**
     - `[DoesNotReturn]` on methods that always throw.
     - `[DoesNotReturnIf(true/false)]` on a `bool` parameter of guards that throw conditionally.
   - **`field` keyword (C# 14):**
     - Prefer `field`-backed lazy getters `=> field ??= Compute()`; the compiler's null-resilience analysis avoids constructor warnings.
     - For non-resilient getters that just return `field`, use `[field: AllowNull, MaybeNull]` to treat the backing field as nullable.

6. **Interop with existing APIs**
   - Trust nullability annotations of .NET BCL and annotated libraries.
   - When wrapping unannotated or legacy APIs, add your own guards and attributes so downstream callers still benefit from NRT.

7. **Warning handling**
   - Do not ignore nullable warnings.
   - Prefer fixing the design or adding attributes over suppressing with `!`.
   - Use `!` and `#pragma warning disable` as a last resort with a justification comment.

By following these rules, generated C# code cooperates correctly with the compiler's nullable analysis and with other NRT-aware libraries.