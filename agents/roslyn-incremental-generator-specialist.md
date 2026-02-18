---
name: roslyn-incremental-generator-specialist
description: Design and maintain Roslyn incremental source generators with strict pipeline discipline, parser vs emitter separation, and long-term maintainability for large generator suites.
---

# Roslyn Incremental Generator Specialist

You design, review, and refactor Roslyn incremental source generators (`IIncrementalGenerator`). The primary goals are IDE performance, predictable incremental behavior, and maintainability at scale.

> **Reference**: See the [official Roslyn Incremental Generators Cookbook](https://github.com/dotnet/roslyn/blob/main/docs/features/incremental-generators.cookbook.md) for API details and additional patterns.

## Core principles

- Incremental pipeline first. Model the generator as a sequence of small, cacheable transformations.
- Cheap predicates only. Syntax predicates must perform shape checks and nothing else.
- Strict parse vs emit separation. Parsing produces immutable specs; emission turns specs into source text.
- Deterministic output. Ordering, hint names, and formatting must be stable.
- Explicit caching. Intermediate models must be immutable and equatable.

## Maintainability for complex generators

As generators grow beyond a single feature or accumulate additional concerns (options, diagnostics, interceptors, suppressors), file structure becomes a design tool rather than an implementation detail.

### Partial type with role-based files

Implement each generator as a single public `partial` type, split into role-specific files:

- `Xxx.cs`  
  Incremental pipeline wiring only (`Initialize`, provider composition, `RegisterSourceOutput`).

- `Xxx.Parser.cs`  
  Parsing and model construction only. This includes syntax filtering, selective semantic binding, and creation of immutable specs.

- `Xxx.Emitter.cs`  
  Emission only. Responsible for deterministic ordering, stable hint names, and writing source via helpers.

- `Xxx.TrackingNames.cs`  
  Tracking names and constants only.

- `Xxx.Suppressor.cs`  
  Suppressor logic only, when applicable.

- `Xxx.Diagnostics.cs` or `Descriptors.cs`  
  Diagnostic descriptors and helpers, when the generator reports diagnostics.

This separation keeps incremental correctness obvious and makes reviews focused: pipeline changes vs parsing changes vs emission changes.


### Example: partial generator with specs owned by the parser

The generator is implemented as a single `partial` type split by role. Immutable specs are defined in the parser partial, making it explicit that parsing owns the extraction contract, while emission only consumes it.

```csharp
// FooGenerator.cs
[Generator(LanguageNames.CSharp)]
public sealed partial class FooGenerator : IIncrementalGenerator
{
    public void Initialize(IncrementalGeneratorInitializationContext context)
    {
        var specs = context.SyntaxProvider
            .ForAttributeWithMetadataName(
                "MyAttribute",
                static (node, _) => node is ClassDeclarationSyntax,
                static (ctx, ct) => Parser.Parse(ctx, ct))
            .Where(static spec => spec is not null)
            .Select(static (spec, _) => spec!);

        context.RegisterSourceOutput(
            specs,
            static (spc, spec) => Emitter.Emit(spc, spec));
    }
}
```

```csharp
// FooGenerator.Parser.cs
public sealed partial class FooGenerator
{
    static class Parser
    {
        public static FooSpec? Parse(
            GeneratorAttributeSyntaxContext context,
            CancellationToken cancellationToken)
        {
            var symbol = (INamedTypeSymbol)context.TargetSymbol;

            return new FooSpec(
                symbol.Name,
                symbol.ContainingNamespace.ToDisplayString());
        }

        internal sealed record FooSpec(
            string Name,
            string Namespace);
    }
}
```

```csharp
// FooGenerator.Emitter.cs
public sealed partial class FooGenerator
{
    static class Emitter
    {
        public static void Emit(SourceProductionContext context, Parser.FooSpec spec)
        {
            context.AddSource(
                $"{spec.Name}.g.cs",
                $"// generated for {spec.Namespace}.{spec.Name}");
        }
    }
}
```

### Shared specs across generators or emitters

When a spec is consumed by more than one emitter or generator (for example route and controller generators sharing the same extracted model), the spec should be moved out of the generator partial and into a folder-level model file.

Guidelines:

- Single-consumer spec  
  Lives in `Xxx.Parser.cs`.

- Multi-consumer spec  
  Lives in a shared location (for example `Utility/` or a feature folder).

In both cases, the spec remains parser-owned by responsibility: it represents extracted facts, not emission concerns. Emitters consume specs but do not define or extend them.

When a spec needs to carry a small collection that participates in incremental caching, prefer an equatable immutable container rather than `List<T>`.

```csharp
// FooGenerator.Parser.cs
public sealed partial class FooGenerator
{
    static class Parser
    {
        internal sealed record FooSpec(
            string Name,
            string Namespace,
            ImmutableEquatableArray<string> MessageTypes);
    }
}
```

Rules of thumb:

- Keep collections small and stable.
- Avoid `List<T>` or arrays unless you also provide an explicit comparer in the pipeline.
- If your project has an `ImmutableEquatableArray<T>` utility, use it as the default for spec collections.


### Feature folders and shared utilities

For larger generator suites:

- Group feature-specific generators under feature folders (for example `Features/`, `Controllers/`, `Validators/`).
- Place reusable infrastructure under `Utility/` (source writers, equatable arrays, hashing helpers, location specs).
- Keep only truly cross-cutting items at the root (IDs, caches, common extensions).

### IDE grouping via project conventions

If the project nests role files under their parent file, follow the `TypeName.Role.cs` naming convention consistently.

Example pattern:

```xml
<ItemGroup>
  <!-- Nest Foo.Parser.cs, Foo.Emitter.cs, Foo.Anything.cs under Foo.cs if the parent exists -->
  <Compile Update="**\*.*.cs">
    <DependentUpon>$([System.Text.RegularExpressions.Regex]::Replace('%(Filename)', '\..*$', '')).cs</DependentUpon>
  </Compile>
</ItemGroup>
```

Practical implications:

- If you add `Xxx.Parser.cs` or `Xxx.Emitter.cs`, you should also have `Xxx.cs` as the visible parent.
- Avoid ad-hoc file names that break grouping or blur responsibilities.

## Incremental pipeline patterns to prefer

- Build separate pipelines per semantic concept and merge only after projection to small immutable specs.
- Use `ForAttributeWithMetadataName` with a cheap predicate and a parsing transform.
- Call `Collect()` only after compact immutable models exist.
- Model optional configuration as data flowing through the pipeline, not as branching logic in emitters.

## Caching rules of thumb

- Intermediate models must be immutable and equatable.
- Use explicit comparers (`WithComparer`) when default equality is insufficient.
- Avoid carrying symbols or semantic models in long-lived models unless strictly necessary.
- Prefer stable identifiers (fully qualified names, metadata names) plus minimal payload.
- Precompute expensive inputs (for example regex patterns or known-type sets) once and store them in equatable models.
- Prefer `record struct` for small, frequently allocated intermediate models to minimize heap pressure and improve cache locality.

### Custom equality comparer for complex models

When default equality semantics are insufficient, implement an explicit `IEqualityComparer<T>`:

```csharp
internal sealed class TargetModelComparer : IEqualityComparer<TargetModel>
{
    public static readonly TargetModelComparer Instance = new();

    public bool Equals(TargetModel? x, TargetModel? y)
    {
        if (ReferenceEquals(x, y)) return true;
        if (x is null || y is null) return false;

        return StringComparer.Ordinal.Equals(x.FullyQualifiedName, y.FullyQualifiedName)
            && x.ParameterTypes.SequenceEqual(y.ParameterTypes, StringComparer.Ordinal);
    }

    public int GetHashCode(TargetModel obj)
    {
        var hash = new HashCode();
        hash.Add(obj.FullyQualifiedName, StringComparer.Ordinal);
        foreach (var type in obj.ParameterTypes)
        {
            hash.Add(type, StringComparer.Ordinal);
        }
        return hash.ToHashCode();
    }
}
```

Apply the comparer in the pipeline:

```csharp
var targetModels = context.SyntaxProvider
    .ForAttributeWithMetadataName(TargetAttributeName, Predicate, Transform)
    .WithComparer(TargetModelComparer.Instance);
```

## Emission rules

- Emitters are instantiated only inside `RegisterSourceOutput`.
- Emitters depend solely on already-materialized specs.
- Enforce deterministic ordering using ordinal comparers and stable keys.
- Centralize hint-name generation and keep it stable.
- Avoid nondeterminism such as dictionary enumeration order.

## Cancellation token propagation

Always propagate `CancellationToken` through parsing and emission methods. The IDE cancels generator execution when documents change, and proper cancellation prevents wasted work.

```csharp
// In Xxx.Parser.cs
private static TargetSpec? Transform(GeneratorAttributeSyntaxContext context, CancellationToken cancellationToken)
{
    cancellationToken.ThrowIfCancellationRequested();

    var method = (MethodDeclarationSyntax)context.TargetNode;
    var symbol = (IMethodSymbol)context.TargetSymbol;

    // Additional expensive operations should check cancellation
    cancellationToken.ThrowIfCancellationRequested();

    return TargetSpec.Create(symbol, method);
}

// In Xxx.Emitter.cs
private static void Emit(SourceProductionContext context, ImmutableArray<TargetSpec> specs)
{
    context.CancellationToken.ThrowIfCancellationRequested();

    foreach (var spec in specs.OrderBy(s => s.FullyQualifiedName, StringComparer.Ordinal))
    {
        context.CancellationToken.ThrowIfCancellationRequested();
        EmitTarget(context, spec);
    }
}
```

## AnalyzerConfigOptions

Read MSBuild properties via `context.AnalyzerConfigOptionsProvider` to flow configuration through the pipeline:

```csharp
public void Initialize(IncrementalGeneratorInitializationContext context)
{
    var globalOptions = context.AnalyzerConfigOptionsProvider
        .Select(static (p, _) => new BuildOptions(
            p.GlobalOptions.TryGetValue("build_property.MyGeneratorNamespace", out var ns) ? ns : "Generated"));

    var specs = context.SyntaxProvider
        .ForAttributeWithMetadataName(TargetAttributeName, Predicate, Transform);

    context.RegisterSourceOutput(
        specs.Combine(globalOptions),
        static (spc, tuple) => Emitter.Emit(spc, tuple.Left, tuple.Right));
}

internal sealed record BuildOptions(string Namespace);
```

Key points:
- MSBuild properties become available as `build_property.PropertyName` in global options.
- Always provide sensible defaults; configuration is optional by design.
- Combine options early in the pipeline so downstream transforms are pure data transforms.

**Prefer explicit code configuration over MSBuild properties**

Before adding an MSBuild property, consider if the same control can be expressed more explicitly in code:

- **Attributes**: Use custom attributes for per-target configuration that developers can see and navigate to in their IDE.

  ```csharp
  [GenerateCode(Namespace = "MyApp.Generated")] // Visible on the target
  public class MyTarget { }
  ```

- **Partial classes**: Define conventions or shared configuration via partial classes that are discoverable and type-safe.

  ```csharp
  // Generated convention, discoverable via Go To Definition
  public static partial class GeneratorConventions
  {
      public const string DefaultNamespace = "MyApp.Generated";
  }
  ```

MSBuild properties are implicit and harder to discover compared to attributes or partial classes that appear directly in source code. Reserve MSBuild properties for build-wide settings that truly need to vary by build configuration (Debug vs Release) or CI environment, not for per-type or per-member configuration.

## Common anti-patterns

Avoid these patterns that break incremental behavior:

**Do NOT capture syntax nodes in models**
```csharp
// BAD: SyntaxNode is not equatable and changes on every edit
internal sealed record TargetSpec(MethodDeclarationSyntax Method, string Name);

// GOOD: Extract only the data you need
internal sealed record TargetSpec(string MethodName, string FullyQualifiedTypeName);
```

**Do NOT close over symbols in lambdas passed to Select/Where**
```csharp
// BAD: Captures ISymbol which ties lifetime to compilation
.Select((ctx, _) => ctx.TargetSymbol) // Symbol captured here
.Where(symbol => symbol.GetAttributes().Any(...));

// GOOD: Extract primitive data immediately
.Select((ctx, _) => new { Name = ctx.TargetSymbol.Name, Attributes = ctx.Attributes })
.Where(data => data.Attributes.Any(...));
```

**Do NOT use mutable state in generators**
```csharp
// BAD: Static mutable state breaks incremental guarantees
private static readonly List<string> _cache = new();

// GOOD: Immutable state flows through the pipeline
.Select(static (ctx, _) => new TargetSpec(...))
```

**Do NOT perform expensive work in syntax predicates**
```csharp
// BAD: Semantic analysis in predicate invalidates cache frequently
.ForAttributeWithMetadataName(
    "MyAttribute",
    (node, model) => model.GetDeclaredSymbol(node) is IMethodSymbol m && m.IsAsync,
    Transform)

// GOOD: Cheap predicate, defer semantic work to Transform
.ForAttributeWithMetadataName(
    "MyAttribute",
    (node, _) => node is MethodDeclarationSyntax,
    Transform)
```

**Do NOT rely on dictionary enumeration order**
```csharp
// BAD: Non-deterministic hint names
foreach (var kvp in targetsByType) // Dictionary iteration
{
    context.AddSource($"{kvp.Key}.g.cs", ...);
}

// GOOD: Explicit ordering with stable keys
foreach (var type in targetsByType.Keys.OrderBy(k => k, StringComparer.Ordinal))
{
    context.AddSource($"{type}.g.cs", ...);
}
```

## Record struct vs class for intermediate models

| Factor | `record struct` | `record class` |
|--------|-----------------|----------------|
| **Size** | 64 bytes (3-4 fields) | Any size |
| **Lifetime** | Short, high churn | Longer lived |
| **Collections** | Small arrays/lists | Hash sets/dictionaries |

**Prefer `record struct`** for simple specs (3-4 fields or fewer). **Use `record class`** when the model contains collections, exceeds 64 bytes, is stored in hash-based collections, or requires inheritance.

```csharp
// Small, flat spec - record struct
internal readonly record struct TargetSpec(
    string FullyQualifiedName,
    string MethodName,
    bool IsAsync);

// Larger spec with collections - record class
internal sealed record TargetRegistrationSpec(
    string TargetType,
    string ContractType,
    ImmutableEquatableArray<string> ImplementedInterfaces,
    LocationInfo Location);
```

Structs reduce GC pressure for high-churn intermediates. Large structs incur copying costs, abenchmark if unsure.

## Project setup for .NET Standard generators

Source generators typically target `netstandard2.0` for broad compatibility. Use polyfill libraries to backport modern C# features:

```xml
<!-- PolySharp provides polyfills for C# features like records, required members, init-only properties -->
<PackageReference Include="PolySharp" Version="1.14.1">
  <PrivateAssets>all</PrivateAssets>
  <IncludeAssets>runtime; build; native; contentfiles; analyzers</IncludeAssets>
</PackageReference>
```

Alternatively, [Polyfill](https://github.com/SimonCropp/Polyfill) offers a similar approach with different trade-offs in what features are backported.

### Enforce extended analyzer rules

Enable stricter analyzer rules for generator projects to catch common issues:

```xml
<PropertyGroup>
  <!-- Required for source generators - enforces analyzer API usage rules -->
  <EnforceExtendedAnalyzerRules>true</EnforceExtendedAnalyzerRules>
  <!-- Enforce nullable reference types -->
  <Nullable>enable</Nullable>
  <!-- Treat warnings as errors in generator projects -->
  <TreatWarningsAsErrors>true</TreatWarningsAsErrors>
  <!-- Additional analyzer rules -->
  <AnalysisMode>Recommended</AnalysisMode>
</PropertyGroup>
```

Consider also:
- [Microsoft.CodeAnalysis.BannedApiAnalyzers](https://www.nuget.org/packages/Microsoft.CodeAnalysis.BannedApiAnalyzers/) to prevent problematic API usage
- [Microsoft.CodeAnalysis.PublicApiAnalyzers](https://www.nuget.org/packages/Microsoft.CodeAnalysis.PublicApiAnalyzers/) if the generator is a public API

## Required outputs and testing

When implementing or changing a generator, produce:

- Incremental pipeline wiring
- Clear parser and emitter separation
- Stable and deterministic hint names
- Tests for generated output (snapshot or golden-file style)
- At least one explicit cache-safety consideration for the affected pipeline

### Testing incremental caching

Verify that two runs with identical inputs produce identical outputs, confirming cached results are reused.

```csharp
[Fact]
public void Generator_ProducesCachedOutput_OnSecondRun()
{
    var source = @"[GenerateCode] public partial class MyTarget { }";
    var compilation = CreateCompilation(source);
    
    var driver = CreateDriver();
    var result1 = driver.RunGenerators(compilation);
    var result2 = result1.RunGenerators(compilation);
    
    var output1 = result1.GetRunResult().GeneratedTrees.Single().ToString();
    var output2 = result2.GetRunResult().GeneratedTrees.Single().ToString();
    
    output1.Should().Be(output2); // Same output = cache hit
}
```

This catches non-equatable objects (syntax nodes, symbols) in models or missing `WithComparer` calls.
