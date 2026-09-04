---
name: aot-trimming
description: "Guidelines for making .NET libraries and applications trimming-safe and Native AOT compatible. Covers the trimming/AOT model, the MSBuild properties that enable analysis (IsTrimmable, IsAotCompatible, PublishTrimmed, PublishAot), the trimming attributes (RequiresUnreferencedCode, RequiresDynamicCode, DynamicallyAccessedMembers, UnconditionalSuppressMessage), IL2xxx/IL3xxx warning codes, and a pattern playbook: source generators and UnsafeAccessor, trimming-safe islands and feature switches, migration analyzers, and warning-approval baselines. Use when introducing trimming/AOT support, resolving IL2xxx/IL3xxx warnings, or making reflection-heavy code trimming-safe in C# / .NET codebases. For System.Text.Json AOT scenarios, see also the serialization skill."
version: 1.0.0
tags:
  - csharp
  - dotnet
  - aot
  - trimming
  - nativeaot
  - code-quality
---

# .NET Trimming and Native AOT

## When to Use

- Adding trimming (`PublishTrimmed`) or Native AOT (`PublishAot`) support to a library or application
- Resolving `IL2xxx` (trimming) and `IL3xxx` (AOT/single-file) warnings
- Making reflection-heavy code trimming-safe
- Replacing runtime reflection, assembly scanning, or `Reflection.Emit` with compile-time alternatives
- Reviewing a codebase or PR for trimming/AOT compatibility
- Designing public APIs that must carry trimming annotations

## Core Goals

- Produce code that survives the linker's reachability analysis and runs under Native AOT (no JIT).
- Express what the compiler cannot see — which members reflection needs — using the trimming attributes.
- Keep trimming-safe and trimming-unsafe code separated so unsafe paths are explicit and contained.

## Core Model

### Trimming vs Native AOT

- **Trimming** (`PublishTrimmed`) runs ILLink reachability analysis: only statically reachable code is kept. Reflection the analyzer cannot see is trimmed away and produces warnings.
- **Native AOT** (`PublishAot`) makes trimming mandatory and removes the JIT. `Reflection.Emit` is unsupported, constructing *unknown* generic instantiations at runtime is not guaranteed, `Expression.Compile()` may fall back to interpretation, and reflection works only over members the linker preserved.
- Both run the same static analysis:
  - `IL2xxx` — trimming warnings: `RequiresUnreferencedCode` propagation + `DynamicallyAccessedMembers` dataflow.
  - `IL3xxx` — AOT and single-file warnings: `RequiresDynamicCode` / `RequiresAssemblyFiles`.

A library can be trimmable but **not** AOT-compatible (it uses `Reflection.Emit`, which trimming tolerates but AOT does not).

### The two problems to solve

1. **Unseen reflection** (trimming): the linker removes a member or type you load by name, or reach through `typeof(T)` in a generic method.
2. **Dynamic code generation** (AOT): the JIT is gone, so `Reflection.Emit` is unsupported and constructing *unknown* generic instantiations is not guaranteed.

Both are solved the same way: make the required members *statically visible* to the analyzer, or remove the need for reflection entirely.

### Reflection is not the enemy

Reflection is a legitimate technique and is completely fine in ordinary JIT applications — you need none of this there. The trimming attributes exist to *allow* reflection under trimming/AOT, not to forbid it: annotate what reflection needs, and the linker keeps it. Reach for source generators, `[UnsafeAccessor]`, or capability gating only when you want a specific reflective surface removed or contained (for example, a public registration API you do not want to ship with `[RequiresUnreferencedCode]`).

## Project Configuration

For a **library**, declare compatibility so the analyzers surface warnings and consumers know:

```xml
<PropertyGroup>
  <!-- Trim-compatible: enables trim warnings. -->
  <IsTrimmable>true</IsTrimmable>

  <!-- AOT-compatible: implies IsTrimmable + EnableTrimAnalyzer + EnableSingleFileAnalyzer + EnableAotAnalyzer. -->
  <IsAotCompatible Condition="$([MSBuild]::IsTargetFrameworkCompatible('$(TargetFramework)', 'net8.0'))">true</IsAotCompatible>
</PropertyGroup>
```

For an **application**, publish trimmed or AOT:

```xml
<PropertyGroup>
  <PublishTrimmed>true</PublishTrimmed>
  <!-- or -->
  <PublishAot>true</PublishAot>
</PropertyGroup>
```

Verify by actually publishing — a trimmed/AOT app must produce zero warnings:

```bash
dotnet publish -c Release -r <rid> -p:PublishTrimmed=true
dotnet publish -c Release -r <rid> -p:PublishAot=true
```

A **test app** that roots the library is the standard way to validate a library:

```xml
<PropertyGroup>
  <PublishTrimmed>true</PublishTrimmed>
</PropertyGroup>
<ItemGroup>
  <ProjectReference Include="..\MyLibrary\MyLibrary.csproj" />
  <TrimmerRootAssembly Include="MyLibrary" />
</ItemGroup>
```

See [aot-trimming-playbook-reference.md](aot-trimming-playbook-reference.md) for the full property table, feature switches, and the warning-approval baseline pattern.

## The Attribute Model

These live in `System.Diagnostics.CodeAnalysis`. See [trimming-attributes-reference.md](trimming-attributes-reference.md) for the full catalog with exact signatures, warning codes, and rules.

- `[RequiresUnreferencedCode(message)]` — marks code that needs members the linker cannot see. Suppresses warnings *inside*; emits `IL2026` at every call site.
- `[RequiresDynamicCode(message)]` — marks code that needs a JIT (emitting, dynamic). Emits `IL3050` at call sites.
- `[DynamicallyAccessedMembers(memberTypes)]` — declares which members of a `Type`/`string` must be preserved. Flows *backward* from the reflection site to the `Type` source. Scope it (and the other attributes) to a single accessor with `[set:]`, `[get:]`, `[field:]`, or `[return:]`.
- `[UnconditionalSuppressMessage(category, checkId, Justification = "...")]` — last-resort, IL-persisted suppression; must carry a justification and a real invariant.
- `[DynamicDependency("Member", typeof(T))]` — keeps named members but does **not** silence warnings.

Choose the narrowest `DynamicallyAccessedMemberTypes` for the reflection you actually perform:

| Reflection | Member type |
| --- | --- |
| `Activator.CreateInstance<T>()`, `new T()`, `Activator.CreateInstance(type)` | `PublicParameterlessConstructor` |
| DI activation (`ActivatorUtilities.CreateFactory<T>`) | `PublicConstructors` |
| Explicit non-public activation | `NonPublicConstructors` |
| `type.GetInterfaces()` | `Interfaces` |
| `type.GetMethods()` | `PublicMethods` (add `NonPublicMethods` when needed) |
| `type.GetProperties()` | `PublicProperties` |
| `type.GetFields()` | `PublicFields` |
| `type.GetNestedTypes()` | `PublicNestedTypes` |

## The Pattern Playbook (selection)

First decide whether the code must be trimming/AOT safe at all. A plain JIT app or library needs none of this — reflection is fine there. Only when you or a consumer publish trimmed/AOT does reflection need to become visible to the linker.

The goal is never "remove all reflection"; it is *make the reflection statically visible* so the linker keeps what it needs. Choose per call site:

- **Keep the reflection and annotate it** — the common case. Put `[DynamicallyAccessedMembers(...)]` on the `Type`/`string` source and propagate it through the chain; mark entry points `[RequiresUnreferencedCode]`/`[RequiresDynamicCode]`. The attributes exist precisely to let reflection work under trimming. See [trimming-attributes-reference.md](trimming-attributes-reference.md).

- **Replace the reflection with a compile-time alternative** — when you want a reflective surface gone (for example, a public registration API you do not want to ship with `[RequiresUnreferencedCode]`). A **source generator** emits direct type references (marker attribute → generated registration); `[UnsafeAccessor]` replaces `FieldInfo`/`MethodInfo`/`ConstructorInfo`. See [aot-trimming-playbook-reference.md](aot-trimming-playbook-reference.md#source-generators-and-compile-time-registration) and [aot-trimming-playbook-reference.md](aot-trimming-playbook-reference.md#unsafe-accessors-for-non-public-members).

- **Isolate a whole dynamic path** — when a path is inherently dynamic (emitting proxies, loading plugins by name), move it behind a boundary and provide a trimming-safe alternative selected by `RuntimeFeature.IsDynamicCodeSupported`. See [aot-trimming-playbook-reference.md](aot-trimming-playbook-reference.md#trimming-safe-islands).

- **Suppress only as a last resort** — a single `[UnconditionalSuppressMessage(...)]` at an invariant-proven leaf, with a `Justification`. Never `#pragma` (not persisted in IL).

See [aot-trimming-playbook-reference.md](aot-trimming-playbook-reference.md) for the full playbook, including object-overload → generic-overload redirects, migration analyzers, and warning-approval baselines.

## Reference Files

- [trimming-attributes-reference.md](trimming-attributes-reference.md): The complete attribute catalog — `RequiresUnreferencedCode`, `RequiresDynamicCode`, `DynamicallyAccessedMembers` (full `DynamicallyAccessedMemberTypes` list), `UnconditionalSuppressMessage`, `DynamicDependency` — each with intent, exact signature, and rules, plus the `IL2xxx`/`IL3xxx` warning-code table.
- [aot-trimming-playbook-reference.md](aot-trimming-playbook-reference.md): The full pattern playbook — source generators vs reflection, trimming-safe islands and capability guards, separating safe/unsafe code, System.Text.Json source generation, object-overload → generic-overload redirects with `[OverloadResolutionPriority]` and opt-in analyzers, migration analyzers, warning-approval baselines, known gotchas, and the full generation checklist.

## Generation Checklist (Summary)

1. **Project** — `IsTrimmable`/`IsAotCompatible` on libraries; `PublishTrimmed`/`PublishAot` on apps; zero warnings on publish.
2. **Make reflection visible (or replace it)** — annotate the reflection you keep (`DynamicallyAccessedMembers`/`RequiresUnreferencedCode`/`RequiresDynamicCode`); replace it with source generators, generic (`typeof(T)`) APIs, or `[UnsafeAccessor]` only where you want the reflective surface gone.
3. **Annotate** — narrowest `DynamicallyAccessedMembers` on every `Type`/`string` source; propagate through the chain; `[RequiresUnreferencedCode]`/`[RequiresDynamicCode]` on unsafe entry points.
4. **Isolate** — keep unsafe reflective/emit code behind a boundary; gate *dynamic-code* paths with `RuntimeFeature.IsDynamicCodeSupported`, and separate *trimming* paths with `#if` or annotations.
5. **Suppress** — only with `[UnconditionalSuppressMessage]` + justification at invariant-proven leaves; never `#pragma`/`SuppressMessage`.
6. **Verify** — publish trimmed and AOT, run analyzers, and lock the warning surface with an approval baseline.

## References

- [Trimming options](https://learn.microsoft.com/dotnet/core/deploying/trimming/trimming-options)
- [Prepare .NET libraries for trimming](https://learn.microsoft.com/dotnet/core/deploying/trimming/prepare-libraries-for-trimming)
- [Introduction to trim warnings](https://learn.microsoft.com/dotnet/core/deploying/trimming/fixing-warnings)
- [Native AOT deployment](https://learn.microsoft.com/dotnet/core/deploying/native-aot/)
- [ILLink error codes](https://github.com/dotnet/runtime/blob/main/docs/tools/illink/error-codes.md)
