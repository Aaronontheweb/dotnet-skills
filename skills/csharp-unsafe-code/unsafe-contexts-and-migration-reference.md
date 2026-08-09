# Unsafe Contexts and Migration Reference

> **Compatibility — source snapshot 2026-08-09.** Use this reference to identify unsafe contexts, diagnose compiler behavior, and migrate declarations, bodies, callers, and assemblies to the updated memory-safety model. Recheck only version-sensitive integration details: the installed SDK's exact opt-in/property spelling, release branding, diagnostic wording/numbers, metadata namespace and tooling behavior, and incomplete library coverage.

## Contents

- [Compatibility and terminology](#compatibility-and-terminology)
- [Classify the active model](#classify-the-active-model)
- [Map current unsafe code](#map-current-unsafe-code)
- [Understand lexical and caller contexts](#understand-lexical-and-caller-contexts)
- [Classify declarations and contracts](#classify-declarations-and-contracts)
- [Migrate in dependency order](#migrate-in-dependency-order)
- [Handle async, iterators, and ref-like state](#handle-async-iterators-and-ref-like-state)
- [Treat metadata and assemblies as contracts](#treat-metadata-and-assemblies-as-contracts)
- [Investigate diagnostics](#investigate-diagnostics)
- [Set up and evaluate with the current SDK](#set-up-and-evaluate-with-the-current-sdk)
- [Validate the consumer matrix](#validate-the-consumer-matrix)
- [Primary sources](#primary-sources)

## Compatibility and Terminology

The updated model is the migration target: member `unsafe` expresses a **requires-unsafe** caller contract, implementation operations use explicit unsafe regions, declaration shapes change, and the compiler propagates contracts through metadata. Roslyn implementation and test work plus more than 200 runtime reduce-unsafe changes make those semantics durable enough to guide migrations.

Keep a green legacy build while evaluating them. Record the exact SDK observed, and use that SDK's supported opt-in rather than copying configuration from another version. The compatibility note above lists the integration details that still require rechecking. The active design, compiler, runtime, and SDK links in [Primary Sources](#primary-sources) provide provenance. Older sources may call requires-unsafe **caller-unsafe**.

## Classify the Active Model

Record these inputs before interpreting a diagnostic:

```text
SDK and csc version:
TargetFramework(s):
LangVersion:
AllowUnsafeBlocks:
Safety-rule opt-in/property:
Configuration and constants:
Generated-source producers:
Referenced assembly versions:
Consumer compiler versions:
```

Classify each build independently:

| Rule layer | How to recognize it | What `unsafe` means |
| --- | --- | --- |
| **Legacy unsafe semantics** | Updated memory-safety rules are not active. | Establish a lexical unsafe context on a type, member, or block. It does not encode a general caller obligation. |
| **C# 13 placement overlay** | C# 13 or later language behavior without the updated model. | Keep legacy unsafe semantics while allowing more ref/unsafe declarations in non-suspending regions of async/iterator code. Apply this row together with legacy semantics. |
| **Updated model** | The installed compiler's updated memory-safety rules are active. | Treat member `unsafe` as a requires-unsafe caller contract; do not treat it as an unsafe body context. Require explicit implementation regions for operations that remain unsafe. |

`AllowUnsafeBlocks` and the memory-safety-rule opt-in are independent:

- `AllowUnsafeBlocks` controls whether source may use unsafe code constructs requiring `/unsafe`.
- Updated rules can diagnose calls to requires-unsafe APIs even when a project does not allow its own unsafe blocks.
- A project that does not allow unsafe blocks may need to remove the dependency or call, rather than enabling unsafe merely to silence the diagnostic.

## Map Current Unsafe Code

Unsafe code has two related dimensions. The language requires an unsafe context for particular syntax and operations; the design still requires a memory-safety proof for low-level APIs that may compile in an ordinary safe context. Audit both.

### Legacy lexical contexts

`<AllowUnsafeBlocks>true</AllowUnsafeBlocks>` (or the equivalent compiler option) permits unsafe code to compile. It does not make an operation safe. An `unsafe` type, member, or block creates a lexical context in which pointer-related constructs are permitted. Prefer a block when only part of a body needs that context; a type-wide or member-wide context can hide which operations need unchecked reasoning.

Map each occurrence and the region that authorizes it:

| Construct or API | Current-work classification |
| --- | --- |
| Pointer types and operations (`T*`, `&`, `*`, `->`, pointer indexing, arithmetic, and conversions) | Pointer declarations and uses generally require a lexical unsafe context. Prove provenance, bounds, lifetime, alignment, and representation independently of compiler acceptance. |
| `fixed` statements and fixed-size buffers | Require unsafe code support and lexical context. Keep the pin no longer than the synchronous pointer use; a fixed buffer also carries layout and initialization obligations. |
| `stackalloc` | A pointer result requires unsafe context; a `Span<T>`/`ReadOnlySpan<T>` result can be used without one. Bound the allocation and initialize every byte that can be read or exposed in either form. |
| `sizeof` | Predefined built-in types have safe cases; other unmanaged types require a lexical unsafe context under legacy rules. Do not confuse managed storage size with marshaled native size. |
| Function pointers (`delegate*`) | Declarations and invocation are unsafe-code work. Verify signature, calling convention, target lifetime, and exception behavior. |
| `Span<T>`, `ReadOnlySpan<T>`, refs, and ref structs | Not inherently unsafe syntax. They still impose lifetime, aliasing, mutation, and suspension restrictions; do not carry ref-like state across an `await` or `yield`. |
| `Unsafe`, `MemoryMarshal`, `Marshal`, `IntPtr`/`nint`, native allocation, and pointer-free P/Invoke | Many calls need no lexical unsafe context, but can bypass type, representation, ownership, or lifetime guarantees. Review them as unsafe in the design sense. |

Do not search only for the `unsafe` keyword. Include generated code, pointer-bearing public signatures, fixed buffers, function pointers, interop declarations, explicit layout, native handles and allocations, ref-returning APIs, `SkipLocalsInit`, and low-level helper calls. Record where the storage originates, who owns it, how its extent is established, and when every borrow ends.

### Calls and boundaries under legacy rules

A pointer-bearing signature forces callers that mention or construct the pointer value into an appropriate lexical context, but a legacy member-level `unsafe` modifier is not a general declaration of caller responsibility. Conversely, a method using `Unsafe` or `MemoryMarshal` can have an entirely safe-looking signature and no `unsafe` keyword. Judge the boundary by what ordinary callers can cause, not by syntax alone.

A safe-callable wrapper must validate every caller-controlled precondition and contain the unchecked operation. If the caller supplies an address, guarantees external initialization, owns native storage, or must preserve a lifetime the implementation cannot verify, expose and document that obligation honestly instead of hiding it behind a safe-looking helper.

## Understand Lexical and Caller Contexts

### Legacy member context

In the legacy model, member-level `unsafe` makes its body an unsafe context. It does not make every caller write an unsafe context.

```csharp
public static unsafe int Read(int* pointer)
{
    return *pointer; // Allowed because the member body is an unsafe context.
}

unsafe
{
    int value = 42;
    Console.WriteLine(Read(&value));
}
```

This example requires `AllowUnsafeBlocks`. The call is already inside an unsafe block because creating and passing the pointer requires legacy unsafe context; the legacy member modifier itself is not a general caller contract.

### Updated member contract and explicit body region

Under the updated rules, `unsafe` on a member means that callers must use an unsafe context. The modifier no longer grants one to the body. Wrap actual implementation operations explicitly:

```csharp
public static unsafe int Read(int* pointer)
{
    // SAFETY: The caller must provide a readable pointer to at least one int.
    unsafe
    {
        return *pointer;
    }
}
```

The outer modifier propagates an obligation. The inner block discharges the implementation operation. Do not delete the inner block because the declaration is marked `unsafe`, and do not mark a wrapper `unsafe` merely to avoid proving its invariants.

### Safe-callable boundary

Keep a member safe-callable when it can establish all obligations itself:

```csharp
public static int ReadFirst(ReadOnlySpan<int> values)
{
    if (values.IsEmpty)
    {
        throw new ArgumentException("At least one value is required.", nameof(values));
    }

    // Bounds are checked before the operation; no pointer is required.
    return values[0];
}
```

If a downlevel implementation needs an unsafe primitive, retain a safe signature and place only the primitive in a block after validating its preconditions. Read the safety-pattern reference before claiming the wrapper is safe.

### Pointer creation versus use

The updated rules relax pointer declarations, address-taking, `fixed`, pointer-producing `stackalloc`, and general unmanaged `sizeof`. Pointer dereference, pointer member access, pointer indexing, and function-pointer invocation remain unsafe operations.

The following illustrates the distinction under an SDK that implements the updated rules:

```csharp
int value = 42;
int* pointer = &value; // Declaration and address-taking are relaxed.

// SAFETY: pointer still refers to the live stack local value.
unsafe
{
    Console.WriteLine(*pointer); // Dereference remains unsafe.
}
```

Also keep pointer arithmetic and conversions under review even when the active compiler permits their syntax outside a block. A relaxed syntactic operation does not prove bounds, provenance, lifetime, or alignment.

### Type-level unsafe

In the legacy model, type-level `unsafe` makes nested declarations and bodies lexically unsafe.

```csharp
public unsafe sealed class NativeView
{
    private readonly byte* _start;

    public NativeView(byte* start) => _start = start;
    public byte Read(int offset) => _start[offset];
}
```

Under the updated rules, type-level `unsafe` becomes invalid or meaningless. Remove it, classify fields and members individually, and add narrow blocks to bodies. Do not mechanically move `unsafe` from the type to every member; doing so would publish caller obligations that may not be honest.

## Classify Declarations and Contracts

Use this decision table for each declaration:

| Outcome | Choose when | Declaration action | Body and call-site action |
| --- | --- | --- | --- |
| **Remove unsafe** | A supported safe API preserves behavior, representation, lifetime, and acceptable performance. | Remove unnecessary modifier or pointer surface. | Replace the operation; add focused tests and benchmarks where relevant. |
| **Localize unsafe** | The implementation can validate bounds, type/layout, ownership, lifetime, pinning, and cleanup before entering the unchecked region. | Keep a safe-callable signature. | Add the smallest block and a `SAFETY` comment; prevent unchecked state from escaping. |
| **Propagate unsafe** | A precondition depends on memory supplied, owned, initialized, or kept alive by the caller. | Mark the member `unsafe` under the updated rules and document the caller obligation. | Use an explicit inner block for body operations; require callers to propagate or discharge the obligation. |

Ask these questions before choosing:

1. Can any valid-looking input cause out-of-bounds, unaligned, uninitialized, expired, or wrongly typed access?
2. Can a callback, override, race, finalizer, exception, or reentrancy invalidate the proof?
3. Does the proof depend on an object, pin, pool lease, native allocation, or handle remaining alive?
4. Can the API express the region as `Span<T>`, `ReadOnlySpan<T>`, `SafeHandle`, or another bounded/owned abstraction?
5. Would marking the member requires-unsafe merely transfer a condition that the implementation could check cheaply and reliably?
6. Would a safe wrapper hide an obligation that only the caller knows?

### Align related declarations

Treat requires-unsafe as a source/tooling contract and align it across:

- virtual and abstract members and their overrides;
- interface declarations and implicit or explicit implementations;
- both parts of a partial method or partial property;
- property accessors and their containing property;
- constructors, including implicit `base()`/`this()` and generic `new()` use;
- events and fields where the installed SDK permits contracts;
- method groups and delegate boundaries;
- generated declarations and generated implementations.

Do not strengthen a safe base or interface contract in an implementation. Callers through the base or interface must not lose the safety promise.

### Classify explicit-layout fields

In explicit or extended layout types, classify each instance field as `safe` or `unsafe`; synthesized backing fields can shift the declaration requirement to an auto-property or field-like event. Treat this syntax and `ExtendedLayout` support as moving. Follow the installed compiler's diagnostics rather than preemptively adding modifiers to production code.

Audit field overlap separately. A `safe` label cannot make overlapping incompatible representations sound; it states that safe access preserves the model's invariants.

## Migrate in Dependency Order

Use this order to avoid noisy secondary diagnostics:

1. **Freeze the baseline.** Build and test every supported target framework and configuration before opting in.
2. **Inventory declarations and operations.** Include generated code, reference assemblies, interop stubs, analyzers, and source generators.
3. **Remove type-level `unsafe`.** Do this in the migration branch or condition where the updated rules are active.
4. **Set declaration contracts.** Decide which members truly require caller proof. Align overrides, interfaces, partials, accessors, constructors, and layout fields.
5. **Repair bodies.** Add narrow explicit blocks around remaining dereferences, indexes, invocations, and requires-unsafe calls.
6. **Repair inward call sites.** Start near the unsafe primitive and move outward. Validate and localize where possible; propagate only genuine obligations.
7. **Replace equivalent low-level code.** Apply span, binary, vector, and interop patterns only with correctness and performance evidence.
8. **Regenerate artifacts.** Re-run generators and API/reference-assembly tools, then inspect emitted signatures and attributes.
9. **Build consumer fixtures.** Compile legacy and updated consumers against old and new producer binaries.
10. **Run runtime validation.** Exercise GC movement, lifetime, native failures, cleanup, boundary lengths, layout, and benchmarks.

For temporary staging:

- Keep updated-model evaluation in a dedicated configuration, branch, or explicit build lane.
- Record each remaining diagnostic by owner and reason.
- Prefer a short-lived, narrow suppression only when the installed compiler exposes a confirmed migration mechanism.
- Do not recommend a permanent broad opt-out, blanket `NoWarn`, broad `unsafe` wrapper, or rollback of `AllowUnsafeBlocks` as the migration result.
- Do not change production language version or feature properties merely to make an example compile.

## Handle Async, Iterators, and Ref-Like State

**C# 13:** Permit `ref` locals, `ref struct` locals, and unsafe blocks in async and iterator methods when their lifetimes stay within a non-suspending region.

```csharp
public static async Task<int> ReadThenPauseAsync(Memory<int> memory)
{
    int value;
    {
        Span<int> span = memory.Span;
        value = span[0];
    } // span is no longer live.

    await Task.Yield();
    return value;
}
```

Do not carry a `Span<T>`, ref local, pointer tied to a movable object, `fixed` variable, or stack allocation across `await` or `yield`. Split the method into pre-suspension and post-suspension regions, or copy the required value into ordinary managed state.

Newer unsafe-evolution discussions include further async/iterator ergonomics. Treat syntax beyond C# 13 as version-sensitive and verify the installed compiler's behavior.

## Treat Metadata and Assemblies as Contracts

### Compiler metadata, not source annotation

Source uses the `unsafe` keyword. The compiler represents requires-unsafe in metadata. Writing `RequiresUnsafeAttribute` directly produces CS9379.

Current runtime source places `RequiresUnsafeAttribute` in `System.Diagnostics.CodeAnalysis`; older design examples used `System.Runtime.CompilerServices`. Recheck the installed reference assemblies and [runtime metadata PR #125721](https://github.com/dotnet/runtime/pull/125721). Never hard-code a namespace, define a polyfill speculatively, or emit the attribute by hand.

The module-level memory-safety rules marker is also compiler/tooling metadata. Let the installed compiler emit it from the recognized opt-in.

### Asymmetric compatibility

Cross-assembly behavior is asymmetric:

- A legacy consumer does not understand new requires-unsafe metadata and may call a newly annotated API without a diagnostic.
- An updated consumer can conservatively diagnose a legacy assembly's pointer-bearing signatures because the producer has not published complete updated-rule metadata.
- A new producer consumed by an old compiler therefore cannot rely on compiler enforcement of caller obligations.
- An old producer consumed by a new compiler can produce new source diagnostics without a binary change.

Treat caller obligations as source/tooling contracts, not runtime guards. Preserve runtime validation at safe boundaries.

### Tooling and generated code

Generated code is not exempt. Audit:

- source generators and incremental generators;
- P/Invoke and COM generators;
- serializers and proxy generators;
- reference-assembly generation;
- API baseline tools such as GenAPI and ApiCompat;
- documentation and signature renderers;
- trimming/AOT-generated paths;
- analyzers that parse or rewrite unsafe syntax.

Tools may lag compiler metadata or syntax. Compare generated source and reference assemblies, not only the implementation assembly. See [early reference-assembly rules PR #131733](https://github.com/dotnet/runtime/pull/131733) as runtime-main evidence of adoption work, not a guarantee for every SDK/tool version.

## Investigate Diagnostics

Do not copy diagnostic text from memory. Use the installed compiler output and the [official unsafe-code diagnostic index](https://learn.microsoft.com/en-us/dotnet/csharp/language-reference/compiler-messages/unsafe-code-errors). First capture the complete diagnostic, source span, compiler version, target framework, effective build properties, and generated source. Fix the operation or contract rather than wrapping unrelated code in a broader unsafe scope.

Use the ordinary unsafe-code groups for the legacy model and the updated-model groups only when those rules are active:

| Diagnostics | Area to investigate | Typical check |
| --- | --- | --- |
| **CS0208, CS8500** | Pointer, address, or size operation involves a managed type. | Prove that the pointee is unmanaged/reference-free as required; do not assume layout or pinning makes a managed type valid pointer storage. |
| **CS0211–CS0214** | Invalid address-taking/fixing shape or pointer use outside an unsafe context. | Identify the exact expression and lifetime. Add a narrow context only when the operation is intentional and `AllowUnsafeBlocks` is enabled. |
| **CS0227** | Unsafe code not enabled. | Confirm whether the project intentionally permits unsafe source. Do not conflate `AllowUnsafeBlocks` with the updated-rule opt-in. Prefer a safe replacement when unsafe source is not part of the project contract. |
| **CS0233** | `sizeof` use requires an unsafe context for the active language rules. | Determine whether the needed value is compiler-managed size or native marshaled size; use the matching operation rather than adding `unsafe` mechanically. |
| **CS0306** and pointer/fixed-buffer constraint diagnostics | A pointer or restricted type appears where the type system does not permit it. | Redesign the generic or storage boundary; an unsafe block cannot waive generic, fixed-buffer, or managed-type restrictions. |
| **CS9360–CS9363** | Unsafe operation, uninitialized `stackalloc` under relevant settings, requires-unsafe/extern call, or legacy pointer-signature compatibility behavior. | Find the exact operation; replace, localize with proof, or propagate the obligation. |
| **CS9364–CS9368** | Safety-contract mismatch or metadata applicability/rule-set issue. | Align base/interface/implementation contracts and verify the producer's active rules and supported symbols. |
| **CS9376** | Implicit requires-unsafe constructor use through `new()` constraints. | Inspect generic construction and constructor contracts; do not hide the call through a generic helper. |
| **CS9377** | `unsafe` has no effect under the active rules. | Remove meaningless syntax or relocate the contract/context after verifying intent. |
| **CS9379** | Direct source use of compiler metadata. | Remove the attribute and express the source contract with supported syntax. |
| **CS9388–CS9390** | Moving `safe`/`unsafe` rules for extern and partial declarations. | Make extern intent explicit and keep partial declarations consistent under the installed compiler. |
| **CS9392** | Explicit/extended-layout field classification. | Classify each affected field using the compiler-supported syntax, then audit overlap and representation. |

Treat every diagnostic as blocking until resolved or explicitly staged. Never add a blanket suppression, expand an unsafe scope around unrelated code, or disable the model to declare success.

## Set Up and Evaluate with the Current SDK

Use the installed SDK's supported mechanism. This XML is only a version-sensitive example and may not match the current property spelling:

```xml
<PropertyGroup Condition="'$(Configuration)' == 'MemorySafetyEvaluation'">
  <LangVersion>preview</LangVersion>
  <Features>$(Features);updated-memory-safety-rules</Features>
</PropertyGroup>
```

The [SDK design](https://github.com/dotnet/designs/blob/main/accepted/2025/memory-safety/sdk-memory-safety-enforcement.md) also describes a versioned property such as `MemorySafetyRules`. Confirm the installed SDK's recognized property and value; do not copy a numeric value into production configuration.

Before enabling the updated model:

1. Confirm the compiler recognizes the setting rather than silently ignoring it.
2. Capture `dotnet --info` and the effective compiler command line or binlog.
3. Keep the normal supported build unchanged and green.
4. Run the evaluation lane over all relevant source, including generated files.
5. Record differences as migration findings.

## Validate the Consumer Matrix

Build small source consumers rather than relying only on unit tests inside the producer repository:

| Producer | Consumer | Required observation |
| --- | --- | --- |
| Legacy binary | Legacy compiler | Existing supported behavior remains green. |
| Legacy binary | Updated compiler | Record conservative pointer-signature or other compatibility diagnostics. |
| Updated binary | Updated compiler | Requires-unsafe calls and aligned contracts diagnose as intended. |
| Updated binary | Legacy compiler | Confirm binary compatibility and document that the compiler cannot enforce new metadata obligations. |
| Reference assembly | Both consumers | Match the implementation assembly's public safety contract as far as each tool understands it. |
| Generated source | Updated compiler | Compile under the updated semantics; do not assume generated unsafe members still grant body context. |

Also run:

- API diff and reference-assembly comparison;
- override/interface/partial build fixtures;
- multi-target builds, including downlevel targets;
- package-consumer builds with warnings as errors where consumers commonly use them;
- native and AOT configurations relevant to the library;
- focused runtime and performance tests from the safety-pattern reference.

## Primary Sources

Use primary sources in this order:

- [Improving C# memory safety (.NET blog)](https://devblogs.microsoft.com/dotnet/improving-csharp-memory-safety/)
- [Updated memory-safety model (preview) on Microsoft Learn](https://learn.microsoft.com/en-us/dotnet/csharp/language-reference/unsafe-code#the-updated-memory-safety-model-preview)
- [Unsafe code compiler diagnostics](https://learn.microsoft.com/en-us/dotnet/csharp/language-reference/compiler-messages/unsafe-code-errors)
- [Active champion issue #9704](https://github.com/dotnet/csharplang/issues/9704)
- [Active unsafe evolution proposal](https://github.com/dotnet/csharplang/blob/main/proposals/unsafe-evolution.md)
- [SDK memory-safety enforcement design](https://github.com/dotnet/designs/blob/main/accepted/2025/memory-safety/sdk-memory-safety-enforcement.md)
- [Earlier caller-unsafe design](https://github.com/dotnet/designs/blob/main/accepted/2025/memory-safety/caller-unsafe.md)
- [Runtime metadata PR #125721](https://github.com/dotnet/runtime/pull/125721)
- [Runtime adoption tracking issue #125800](https://github.com/dotnet/runtime/issues/125800)
- [Early reference-assembly rules PR #131733](https://github.com/dotnet/runtime/pull/131733)
- [Roslyn implementation PR #82547](https://github.com/dotnet/roslyn/pull/82547)
- [Roslyn test plan issue #81207](https://github.com/dotnet/roslyn/issues/81207)
- [What's new in C# 13](https://learn.microsoft.com/en-us/dotnet/csharp/whats-new/csharp-13)
- [C# 13 ref/unsafe in async and iterators specification](https://learn.microsoft.com/en-us/dotnet/csharp/language-reference/proposals/csharp-13.0/ref-unsafe-in-iterators-async)
