# Unsafe Contexts and Migration Reference

> **Compatibility — source snapshot 2026-11-26, .NET 11 GA (SDK 11.0.100).** The updated memory-safety model ships in .NET 11 as an off-by-default preview. It is not part of C# 15; it is nominally a C# 16 / .NET 12 feature. Use this reference to identify unsafe contexts, diagnose compiler behavior, and migrate declarations, bodies, callers, and assemblies to that model. Rules marked **later compilers** landed after 11.0.100 (Roslyn milestones 18.13 and 18.14) and are not in the GA SDK. Recheck those, the stable opt-in property name, and library coverage against the installed SDK.

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

The updated model is the migration target: member `unsafe` expresses a **requires-unsafe** caller contract, implementation operations use explicit unsafe regions, declaration shapes change, and the compiler propagates contracts through metadata. .NET 11 ships it as a preview: off by default, gated on the `preview` language version, and still changing after GA. The semantics are documented on Microsoft Learn and exercised by the runtime's own migration, which makes them durable enough to guide migrations. The Roslyn test plan remains open, the runtime tracking issue is open with a 12.0.0 milestone, and the SDK design expects broad adoption in the .NET 12 or 13 timeframe.

Keep a green legacy build while evaluating them. Record the exact SDK observed, and use that SDK's supported opt-in rather than copying configuration from another version. The compatibility note above lists the integration details that still require rechecking. The active design, compiler, runtime, and SDK links in [Primary Sources](#primary-sources) provide provenance. Older sources may call requires-unsafe **caller-unsafe**; runtime PRs call the updated model **unsafe-v2** and the feature **unsafe evolution**.

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
| **Preview language, rules not enabled** | `LangVersion` is `preview` but the assembly has not opted in. | Keep legacy `unsafe` semantics, plus the preview relaxations: pointer declarations, address-of, `fixed`, pointer `stackalloc`, and unmanaged `sizeof` compile in safe code, and `unsafe(expression)`, `safe`, and `await` in unsafe contexts are accepted. Calling a member with pointers in its signature still needs an unsafe context (CS9363). |
| **Updated model** | The `preview` language version and the assembly's opt-in are both active; the compiler stamps the module with `MemorySafetyRulesAttribute`. | Treat member `unsafe` as a requires-unsafe caller contract; do not treat it as an unsafe body context. Require explicit implementation regions for operations that remain unsafe. |

`AllowUnsafeBlocks` and the memory-safety-rule opt-in are independent:

- `AllowUnsafeBlocks` controls whether source may use the `unsafe` keyword: blocks, `unsafe(expression)`, and member modifiers. Later compilers also require it for the `safe` modifier (CS9401).
- The preview relaxations do not need it. Pointer declarations, address-of, and `sizeof(Guid)` compiled with `AllowUnsafeBlocks` unset in an SDK 11.0.100 check.
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
| `fixed` statements and fixed-size buffers | Require unsafe code support and lexical context. Keep the pin no longer than the synchronous pointer use; a fixed buffer also carries layout and initialization obligations. Where a span view suffices, an `[InlineArray<T>]` struct removes the `fixed`/pointer path, though the replacement can add bounds checks (runtime PRs [#125514](https://github.com/dotnet/runtime/pull/125514), [#125574](https://github.com/dotnet/runtime/pull/125574)). |
| `stackalloc` | A pointer result requires unsafe context; a `Span<T>`/`ReadOnlySpan<T>` result can be used without one. Bound the allocation and initialize every byte that can be read or exposed in either form. |
| `sizeof` | Predefined built-in types have safe cases; other unmanaged types require a lexical unsafe context under legacy rules. Do not confuse managed storage size with marshaled native size. |
| Function pointers (`delegate*`) | Declarations and invocation are unsafe-code work. Verify signature, calling convention, target lifetime, and exception behavior. |
| `Span<T>`, `ReadOnlySpan<T>`, refs, and ref structs | Not inherently unsafe syntax. They still impose lifetime, aliasing, mutation, and suspension restrictions; do not carry ref-like state across an `await` or `yield`. |
| `Unsafe`, `MemoryMarshal`, `Marshal`, `IntPtr`/`nint`, native allocation, and pointer-free P/Invoke | Many calls need no lexical unsafe context, but can bypass type, representation, ownership, or lifetime guarantees. Review them as unsafe in the design sense. |
| `[UnsafeAccessor]` extern members | Suppress visibility checks on member binding only. The runtime validates the declared signature and generic constraints; a mismatch throws `MissingFieldException`/`MissingMethodException` instead of mis-binding. Audit for contract drift and encapsulation bypass, not for memory safety. |

Do not search only for the `unsafe` keyword. Include generated code, pointer-bearing public signatures, fixed buffers, function pointers, interop declarations, explicit layout, native handles and allocations, ref-returning APIs, `SkipLocalsInit`, and low-level helper calls. Record where the storage originates, who owns it, how its extent is established, and when every borrow ends.

### Calls and boundaries under legacy rules

A pointer-bearing signature forces callers that mention or construct the pointer value into an appropriate lexical context, but a legacy member-level `unsafe` modifier is not a general declaration of caller responsibility. Conversely, a method using `Unsafe` or `MemoryMarshal` can have an entirely safe-looking signature and no `unsafe` keyword. Judge the boundary by what ordinary callers can cause, not by syntax or naming: a runtime-validated visibility bypass such as `UnsafeAccessor` fails closed on mismatch, while `Unsafe.As` fabricates type conversions by design.

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

A constructor initializer cannot be wrapped in a block. To call a requires-unsafe `base(...)` or `this(...)` constructor, mark the calling constructor `unsafe`; the modifier makes its initializer an unsafe context.

### Unsafe expressions

`unsafe(expression)` creates an unsafe context for one expression and ends at the closing parenthesis. Use it where a block cannot appear: a field initializer, a constructor-initializer argument, a `catch` filter, an expression-bodied member, or the operand of `await`. It needs `AllowUnsafeBlocks` and the `preview` language version. Wrapping an argument covers only that argument; it does not discharge a requires-unsafe `base(...)` or `this(...)` call. SDK 11.0.100 also still reports CS9362 for `unsafe(P)` when `P` is a requires-unsafe property ([roslyn#86211](https://github.com/dotnet/roslyn/issues/86211)); use a block there.

```csharp
// SAFETY: _start points at the buffer this instance pinned in its constructor and unpins in Dispose.
private byte First => unsafe(*_start);
```

Prefer a block when a statement fits, because a block leaves room for the `// SAFETY:` comment next to the operation. The runtime's migration fixer makes the same choice ([#135341](https://github.com/dotnet/runtime/pull/135341)).

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

The `preview` language version relaxes pointer declarations, address-taking, the `fixed` statement, pointer-producing `stackalloc`, `sizeof` on any unmanaged type, and the declaration of fixed-size buffers and function-pointer types. The relaxations apply whether or not the assembly opts in to the updated rules. Pointer dereference, pointer member access, pointer indexing, fixed-size buffer element access, function-pointer invocation, and every use of a requires-unsafe member remain unsafe operations.

The following illustrates the distinction under the `preview` language version:

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

The relaxations are source-breaking in two documented ways. Lambda-to-delegate overloads with pointer parameters become applicable in safe code, which can turn a previously unambiguous call into CS0121. `safe` becomes a contextual keyword, so a type named `safe` needs `@safe`. Later compilers add one restriction: taking the address of a variable that is not definitely assigned requires an unsafe context (CS9403).

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

Under the updated rules, `unsafe` on a type, static constructor, finalizer, or delegate is an error (CS9377); the modifier has no effect there. Lambdas cannot carry the modifier, and a local function is classified on its own rather than inheriting from its containing member. Remove the type-level modifier, classify fields and members individually, and add narrow blocks to bodies. Do not mechanically move `unsafe` from the type to every member; doing so would publish caller obligations that may not be honest.

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
- a property and its accessors: put the modifier on one or the other, not both (CS9396), and on the property when every accessor would carry it (CS9397);
- constructors, including implicit `base()`/`this()` and generic `new()` or `struct` constraint use;
- events, which are marked as a whole;
- fields, whose reads and writes then need an unsafe context;
- `extern` and `[LibraryImport]` declarations, which must state `safe` or `unsafe`;
- method groups and delegate boundaries;
- generated declarations and generated implementations.

Do not strengthen a safe base or interface contract in an implementation (CS9364–CS9366). Callers through the base or interface must not lose the safety promise. Marking a property or event `unsafe` does not make its backing field requires-unsafe; mark the field when the invariant lives there.

### Mark `safe` declarations

`safe` is a contextual declaration modifier: the member does not require an unsafe context at its use site. Under the updated rules it is required, as the alternative to `unsafe`, on every `extern` member, including `[LibraryImport]` partial methods (CS9389, SYSLIB1064), and on instance fields of explicit- or extended-layout types (CS9392). It is allowed on any declaration that can be `unsafe`, but ordinary declarations are safe by default, so omit it there.

```csharp
[LibraryImport("libc")]
internal static safe partial int getpid();

[LibraryImport("libc")]
internal static unsafe partial nint strlen(byte* str);
```

`safe` creates no lexical context, cannot be combined with `unsafe` (CS9388), and must match across both parts of a partial member (CS9390). Later compilers require `AllowUnsafeBlocks` to write it (CS9401).

`safe` is an attestation, not a check. Write it only after auditing what the native code or the overlapping layout can do with every input; no compiler or fixer can justify it. Choose `unsafe` when the callee dereferences a pointer argument or when soundness depends on anything the caller controls. Runtime PRs [#131719](https://github.com/dotnet/runtime/pull/131719) and [#134134](https://github.com/dotnet/runtime/pull/134134) show the audit-then-`safe` pattern.

### Document safety contracts

Record the contract in two places:

- A `<safety>` XML documentation element on a requires-unsafe member states what the caller must guarantee. On an `unsafe` field it states the invariant the enclosing type maintains.
- A `// SAFETY:` comment on an `unsafe` block or expression states why that operation is valid at that point.

The compiler does not process `<safety>`; it copies the tag to the documentation file like any other.

The dotnet/runtime migration tooling builds on these conventions. Its analyzers (IL5005–IL5010) flag `unsafe` members and explicit `safe` modifiers that lack `<safety>` and `unsafe` blocks that lack a `// SAFETY:` comment, and its fixers leave a `// SAFETY: To be audited` placeholder for a human to replace. That tooling is non-shipping and off by default (tracking issue [#131451](https://github.com/dotnet/runtime/issues/131451)); treat it as a model for a review process, not as analyzers the SDK provides. From Roslyn 18.13, IDE0380 no longer offers to remove an `unsafe` modifier from a member that has a `<safety>` element.

### Classify explicit-layout fields

In a type with `LayoutKind.Explicit` or `[ExtendedLayout]`, mark every instance field `safe` or `unsafe` (CS9392). Static and const fields are exempt. For a synthesized backing field, put the modifier on the auto-property or field-like event; a captured primary-constructor parameter or positional record member needs explicitly declared storage to annotate. Later compilers extend the rule to any type with a nonzero `StructLayoutAttribute.Pack` or `Size`; SDK 11.0.100 does not diagnose those.

Audit field overlap separately. A `safe` label cannot make overlapping incompatible representations sound; it states that safe access preserves the model's invariants.

## Migrate in Dependency Order

Use this order to avoid noisy secondary diagnostics:

1. **Freeze the baseline.** Build and test every supported target framework and configuration before opting in.
2. **Inventory declarations and operations.** Include generated code, reference assemblies, interop stubs, analyzers, and source generators.
3. **Remove type-level `unsafe`.** Do this in the migration branch or condition where the updated rules are active.
4. **Set declaration contracts.** Decide which members truly require caller proof. Align overrides, interfaces, partials, accessors, and constructors, and mark every `extern` member and layout field `safe` or `unsafe`.
5. **Repair bodies.** Add narrow explicit blocks around remaining dereferences, indexes, invocations, and requires-unsafe calls.
6. **Repair inward call sites.** Start near the unsafe primitive and move outward. Validate and localize where possible; propagate only genuine obligations.
7. **Replace equivalent low-level code.** Apply span, binary, vector, and interop patterns only with correctness and performance evidence.
8. **Regenerate artifacts.** Re-run generators and API/reference-assembly tools, then inspect emitted signatures and attributes.
9. **Build consumer fixtures.** Compile legacy and updated consumers against old and new producer binaries.
10. **Run runtime validation.** Exercise GC movement, lifetime, native failures, cleanup, boundary lengths, layout, and benchmarks.

For temporary staging:

- Keep updated-model evaluation in a dedicated configuration, branch, or explicit build lane.
- Treat migrated source as preview-only source. `safe`, `unsafe(expression)`, and pointer declarations outside an unsafe context compile only with `LangVersion=preview` (CS8652 or CS0214 otherwise), so the legacy lane cannot build them. Until the feature leaves preview, keep that source on the migration branch or behind conditional compilation. An explicit `unsafe` block inside an `unsafe` member is valid in both lanes.
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

**Preview language version:** `await` is allowed inside an unsafe context, `await` inside a `fixed` statement is an error (CS9398), and `yield return` in an unsafe context remains an error. The compiler does not prove that a pointer kept live across an `await` is still valid after resumption, so the rule above becomes the author's obligation rather than a diagnostic.

## Treat Metadata and Assemblies as Contracts

### Compiler metadata, not source annotation

Source uses the `unsafe` keyword. The compiler represents requires-unsafe in metadata. Writing `RequiresUnsafeAttribute` directly produces CS9379, under legacy rules as well.

.NET 11 ships both attributes as public API ([API issue #125134](https://github.com/dotnet/runtime/issues/125134), [PR #125721](https://github.com/dotnet/runtime/pull/125721)):

- `System.Diagnostics.CodeAnalysis.RequiresUnsafeAttribute` marks a requires-unsafe constructor, event, method, or property.
- `System.Runtime.CompilerServices.MemorySafetyRulesAttribute(int version)` is the module-level marker that an assembly was compiled under the updated rules; the compiler emits and recognizes version `2`.

The language proposal's metadata section still shows an older namespace and version value; follow the shipped API. Never define a polyfill speculatively or emit either attribute by hand. Let the installed compiler emit them from the recognized opt-in.

### Framework reference assemblies

The .NET 11 reference assemblies already carry requires-unsafe contracts on low-level APIs, among them `Unsafe`, `MemoryMarshal`, and `GC.AllocateUninitializedArray` ([#131733](https://github.com/dotnet/runtime/pull/131733)). An opted-in project therefore gets CS9362 on a call such as `Unsafe.As<T>(object)` even when it contains no pointer code, while a legacy project compiles the same call unchanged. Use the diagnostic from the installed reference pack as the authority on which APIs are requires-unsafe. Further library annotation is tracked for .NET 12 ([#125145](https://github.com/dotnet/runtime/issues/125145)).

### Evidence for contract-risk claims

Any claim that a specific API acquires a requires-unsafe contract or newly diagnoses under the updated model is a metadata claim about a specific compiler version. Support it with the installed SDK's reference assemblies, the active design or compiler sources, or a reproduced diagnostic recorded against the environment checklist.

Name similarity, a shared namespace, or a generic caution about generated code are not evidence. `UnsafeAccessor` and `System.Runtime.CompilerServices.Unsafe` share a namespace prefix but not a hazard class: the accessor suppresses visibility checks with runtime-validated binding and fails closed; `Unsafe.As` fabricates type confusion by design. Record unverified possibilities as open questions, never as risks in a migration inventory.

### Asymmetric compatibility

Cross-assembly behavior is asymmetric:

- A legacy consumer does not understand new requires-unsafe metadata and may call a newly annotated API without a diagnostic.
- An updated consumer can conservatively diagnose a legacy assembly's pointer-bearing signatures because the producer has not published complete updated-rule metadata.
- A new producer consumed by an old compiler therefore cannot rely on compiler enforcement of caller obligations.
- An old producer consumed by a new compiler can produce new source diagnostics without a binary change.

The conservative mode covers pointer and function-pointer types anywhere in a parameter or return type, and it applies under the `preview` language version even before the consumer opts in (CS9363). An `extern` member from a legacy assembly is not treated as requires-unsafe.

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

Tools lag the compiler. As of this snapshot GenAPI does not round-trip the safety contract, ApiCompat does not compare it, and StyleCop SA1206 does not know the `safe` modifier ([#131451](https://github.com/dotnet/runtime/issues/131451)). Compare generated source and reference assemblies, not only the implementation assembly.

A source generator must emit code that compiles under both rule sets: each generated body opens its own `unsafe` block, type-level `unsafe` is emitted only for legacy consumers, and `safe` or `unsafe(...)` is emitted only when the consuming compilation uses the updated rules, because both need the `preview` language version. In .NET 11 the `LibraryImport` generator ([#131245](https://github.com/dotnet/runtime/pull/131245)) and the System.Text.Json generator ([#133886](https://github.com/dotnet/runtime/pull/133886)) handle the updated rules; the fix for the COM and JavaScript interop generators ([#131701](https://github.com/dotnet/runtime/pull/131701)) is on runtime main only, so reproduce their output under the opt-in before relying on it. A generator can read `IModuleSymbol.MemorySafetyRulesVersion`, a Roslyn API still marked experimental (RSEXPERIMENTAL006). When testing a generator, also compile without `LangVersion=preview`: the preview language version alone relaxes pointer declarations and hides legacy-rule breaks.

## Investigate Diagnostics

Do not copy diagnostic text from memory. Use the installed compiler output and the [official unsafe-code diagnostic index](https://learn.microsoft.com/en-us/dotnet/csharp/language-reference/compiler-messages/unsafe-code-errors). First capture the complete diagnostic, source span, compiler version, target framework, effective build properties, and generated source. Fix the operation or contract rather than wrapping unrelated code in a broader unsafe scope.

Use the ordinary unsafe-code groups for the legacy model and the updated-model groups only when those rules are active:

| Diagnostics | Area to investigate | Typical check |
| --- | --- | --- |
| **CS0208, CS8500** | Pointer, address, or size operation involves a managed type. | Prove that the pointee is unmanaged/reference-free as required; do not assume layout or pinning makes a managed type valid pointer storage. |
| **CS0211–CS0214** | Invalid address-taking/fixing shape or pointer use outside an unsafe context. | Identify the exact expression and lifetime. Add a narrow context only when the operation is intentional and `AllowUnsafeBlocks` is enabled. |
| **CS0227** | Unsafe code not enabled. | Confirm whether the project intentionally permits unsafe source. Do not conflate `AllowUnsafeBlocks` with the updated-rule opt-in. Prefer a safe replacement when unsafe source is not part of the project contract. |
| **CS0233** | `sizeof` on a non-predefined type requires an unsafe context under the legacy language rules; the `preview` language version relaxes it for unmanaged types. | Determine whether the needed value is compiler-managed size or native marshaled size; use the matching operation rather than adding `unsafe` mechanically. |
| **CS0306** and pointer/fixed-buffer constraint diagnostics | A pointer or restricted type appears where the type system does not permit it. | Redesign the generic or storage boundary; an unsafe block cannot waive generic, fixed-buffer, or managed-type restrictions. |
| **CS8652** | The updated-rules opt-in or preview syntax is used without the `preview` language version. | Set `LangVersion` to `preview` in the evaluation lane only; do not change the production language version to silence it. |
| **CS9360** | An operation that remains unsafe (dereference, pointer member access or indexing, fixed-buffer element access, function-pointer invocation) is outside an unsafe context, including inside the body of an `unsafe` member. | Add the narrowest block or `unsafe(expression)` with its proof, or replace the operation. |
| **CS9361** | A `stackalloc` converted to a span has no initializer inside a `[SkipLocalsInit]` member. | Give the `stackalloc` an initializer; clearing or writing it afterwards does not satisfy the rule. Otherwise wrap the allocation in an unsafe context with proof that every byte is written before it is read. Pointer-typed `stackalloc` is unaffected. The rule may be withdrawn ([roslyn#86293](https://github.com/dotnet/roslyn/issues/86293)). |
| **CS9362** | A member marked `unsafe` is used from a safe context: a call, a constructor, or a field read or write. | Replace, localize with proof, or propagate the obligation. |
| **CS9363** | A member with pointers in its signature, compiled under legacy rules, is used from a safe context. Fires under the `preview` language version even without the opt-in. | Treat it like CS9362; no contract was published, so audit the callee. This includes members of the current project when only `LangVersion=preview` is set. |
| **CS9364–CS9366** | An `unsafe` member overrides, implicitly implements, or explicitly implements a safe member. | Align the hierarchy; never strengthen a safe base or interface contract in an implementation. |
| **CS9376** | A type with an `unsafe` parameterless constructor is used to satisfy a `new()` or `struct` constraint. | In an expression, use an unsafe context. In a declaration position (base type, field type, alias) no block can help; redesign the constructor contract. |
| **CS9377** | `unsafe` appears on a type, static constructor, finalizer, or delegate. | Remove the modifier and classify members individually. |
| **CS9379** | `RequiresUnsafeAttribute` is written in source (reported under legacy rules too). | Remove the attribute and use the `unsafe` modifier. |
| **CS9388** | `safe` and `unsafe` are combined on one declaration. | Choose one after auditing the declaration. |
| **CS9389** | An `extern` member is marked neither `safe` nor `unsafe`. SYSLIB1064 is the `LibraryImport` generator's equivalent. | Audit the native contract, then state it explicitly. |
| **CS9390** | The parts of a partial member disagree on `safe`. | Make both declarations match, including generated parts. |
| **CS9392** | An instance field in an explicit- or extended-layout type (later compilers: also nonzero `Pack` or `Size`) is marked neither `safe` nor `unsafe`. | Classify each field, then audit overlap and representation. |
| **CS9396, CS9397** | `safe`/`unsafe` is on both a property and its accessor, or repeated on every accessor. | Put the modifier on the property, or on the one accessor that differs. |
| **CS9398** | `await` appears inside a `fixed` statement. | End the pin before suspending; copy or use owned memory across the `await`. |
| **CS9401** (later compilers) | A `safe` or `unsafe` declaration modifier is used without `AllowUnsafeBlocks`. | Enable unsafe code only where the project contract allows it; drop `safe` where it is not required. |
| **CS9402** (later compilers, warning) | The `updated-memory-safety-rules` feature flag is deprecated. | Switch the evaluation lane to `MemorySafetyRulesVersion` once the installed compiler recognizes it. |
| **CS9403** (later compilers) | Address-of is applied to a variable that is not definitely assigned. | Assign first, or use an unsafe context with proof that the pointee is written before it is read. |

In an SDK 11.0.100 check, the body diagnostics CS9360–CS9362 appeared only after the declaration errors CS9377, CS9389, CS9392, and CS9396 were fixed, so expect a second wave after the declarations compile. The Learn index also lists CS9367 and CS9368; the compiler no longer defines them.

Treat every diagnostic as blocking until resolved or explicitly staged. Never add a blanket suppression, expand an unsafe scope around unrelated code, or disable the model to declare success.

## Set Up and Evaluate with the Current SDK

Use the installed SDK's supported mechanism. In the .NET 11 SDK (11.0.100) the opt-in is two settings, shown here in a dedicated evaluation configuration:

```xml
<PropertyGroup Condition="'$(Configuration)' == 'MemorySafetyEvaluation'">
  <LangVersion>preview</LangVersion>
  <Features>$(Features);updated-memory-safety-rules</Features>
</PropertyGroup>
```

The `preview` language version enables the new syntax and the pointer relaxations; the feature flag enables the updated rules and the module marker. The flag without the preview language version fails with CS8652. A file-based program uses the equivalent directives, `#:property LangVersion=preview` and `#:property Features=$(Features);updated-memory-safety-rules`.

Later compilers (Roslyn 18.14, after 11.0.100) add an MSBuild property and compiler option: `<MemorySafetyRulesVersion>2</MemorySafetyRulesVersion>` or `-memorysafetyrulesversion:2`, where `1` is the legacy default ([roslyn#85980](https://github.com/dotnet/roslyn/pull/85980)). They still require the preview language version, and they warn CS9402 when the feature flag is used. SDK 11.0.100 silently ignores the property and rejects the compiler option (CS2007), so a project that sets only the property there is not opted in. The [SDK design](https://github.com/dotnet/designs/blob/main/accepted/2025/memory-safety/sdk-memory-safety-enforcement.md) and Microsoft Learn call the planned stable property `MemorySafetyRules`; the name that ships when the feature leaves preview is not settled.

Before enabling the updated model:

1. Confirm the compiler recognizes the setting rather than silently ignoring it: an unmarked `extern` member or a type-level `unsafe` must produce CS9389 or CS9377, and the output module must carry `MemorySafetyRulesAttribute`.
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
- [Enable the updated memory safety rules (compiler options)](https://learn.microsoft.com/en-us/dotnet/csharp/language-reference/compiler-options/language#enable-the-updated-memory-safety-rules)
- [`safe` keyword](https://learn.microsoft.com/en-us/dotnet/csharp/language-reference/keywords/safe)
- [`<safety>` documentation tag](https://learn.microsoft.com/en-us/dotnet/csharp/language-reference/xmldoc/recommended-tags#safety)
- [What's new in C# 15: memory safety](https://learn.microsoft.com/en-us/dotnet/csharp/whats-new/csharp-15#memory-safety)
- [Unsafe code compiler diagnostics](https://learn.microsoft.com/en-us/dotnet/csharp/language-reference/compiler-messages/unsafe-code-errors)
- Roslyn compiler breaking changes for [.NET 11](https://github.com/dotnet/roslyn/blob/main/docs/compilers/CSharp/Compiler%20Breaking%20Changes%20-%20DotNet%2011.md) and [after 11.0.100](https://github.com/dotnet/roslyn/blob/main/docs/compilers/CSharp/Compiler%20Breaking%20Changes%20-%20DotNet%2012.md)
- [Active champion issue #9704](https://github.com/dotnet/csharplang/issues/9704)
- [Active unsafe evolution proposal](https://github.com/dotnet/csharplang/blob/main/proposals/unsafe-evolution.md) (its metadata section lags the shipped API)
- [SDK memory-safety enforcement design](https://github.com/dotnet/designs/blob/main/accepted/2025/memory-safety/sdk-memory-safety-enforcement.md)
- [Earlier caller-unsafe design](https://github.com/dotnet/designs/blob/main/accepted/2025/memory-safety/caller-unsafe.md)
- [Runtime metadata PR #125721](https://github.com/dotnet/runtime/pull/125721) and [attributes API issue #125134](https://github.com/dotnet/runtime/issues/125134) (closed; shipped in .NET 11)
- [Memory Safety v2 Tracking Issue #125800](https://github.com/dotnet/runtime/issues/125800) (open, milestone 12.0.0; .NET 11 ships the model as an opt-in preview)
- [Unsafe-v2 migration tooling tracking issue #131451](https://github.com/dotnet/runtime/issues/131451)
- [CoreLib `safe` placement / `<safety>` audit PR #131719](https://github.com/dotnet/runtime/pull/131719) and [reference-assembly rules PR #131733](https://github.com/dotnet/runtime/pull/131733), both in .NET 11
- [`LibraryImport` generator support PR #131245](https://github.com/dotnet/runtime/pull/131245)
- [Roslyn implementation PR #82547](https://github.com/dotnet/roslyn/pull/82547)
- [Roslyn test plan issue #81207](https://github.com/dotnet/roslyn/issues/81207)
- [Roslyn `MemorySafetyRulesVersion` property PR #85980](https://github.com/dotnet/roslyn/pull/85980)
- [What's new in C# 13](https://learn.microsoft.com/en-us/dotnet/csharp/whats-new/csharp-13)
- [C# 13 ref/unsafe in async and iterators specification](https://learn.microsoft.com/en-us/dotnet/csharp/language-reference/proposals/csharp-13.0/ref-unsafe-in-iterators-async)
