---
name: csharp-unsafe-code
description: Write, review, audit, reduce, and migrate C# unsafe code. Use for designing safe-callable boundaries and requires-unsafe contracts; diagnosing unsafe compiler errors; choosing safe replacements; or working with AllowUnsafeBlocks, unsafe contexts, pointers, fixed, stackalloc, function pointers, Span/ref structs, Unsafe, MemoryMarshal, Marshal, native allocation, and P/Invoke.
---

# C# Unsafe Code

Use unsafe code deliberately. Identify the lexical context and any caller obligation, prove the bounds, lifetime, ownership, representation, ABI, and cleanup invariants, and keep the unchecked region as small as the operation permits. Preserve behavior and measured performance when replacing low-level code. Under the updated memory-safety model, migrate declarations, bodies, and callers as separate contracts.

## Task Router

Choose the mode that matches the request:

- **Write, review, or audit current unsafe code** — record the installed compiler and target frameworks, inventory the operations and data lifetimes, choose remove/localize/propagate under [Choose the Boundary](#choose-the-boundary), then use [unsafe-memory-safety-patterns-reference.md](unsafe-memory-safety-patterns-reference.md) for invariants, interop, `SAFETY` comments, tests, and performance checks. Use the contexts reference when lexical scope or a diagnostic is unclear.
- **Reduce an unsafe implementation** — start at [Choose the Boundary](#choose-the-boundary), compare the safe replacements in the safety-patterns reference, and retain a narrow unsafe path when equivalence, target-framework availability, or measured performance requires it. Do not treat “compiles without `unsafe`” as proof of safety or equivalence.
- **Diagnose unsafe diagnostics** — capture the exact SDK/compiler, target framework, `LangVersion`, `AllowUnsafeBlocks`, active safety-rule opt-in, generated source, and full diagnostic. Then use [unsafe-contexts-and-migration-reference.md](unsafe-contexts-and-migration-reference.md) to classify the active rules and investigate the reported construct before changing scope or configuration.
- **Migrate legacy code to updated rules** — execute the full [migration playbook](#migrate-to-updated-rules), treating member contracts, explicit body regions, call sites, metadata, and consumers as one coordinated change.

## Apply the Core Method

1. **Establish the environment.** Record every target framework, SDK/compiler, `LangVersion`, `AllowUnsafeBlocks`, safety-rule opt-in, configuration, generated source producer, analyzer, native dependency, and consuming assembly that affects the code.
2. **Map contexts and operations.** Distinguish lexical `unsafe` contexts, pointer-bearing signatures, low-level APIs that do not use unsafe syntax, and requires-unsafe caller contracts under the updated model. Locate pointer and function-pointer use, `fixed`, pointer-producing `stackalloc`, general unmanaged `sizeof`, ref-like code, `Unsafe`, `MemoryMarshal`, `Marshal`, native allocation, and interop.
3. **Choose the boundary.** Remove equivalent unsafe work, localize operations whose preconditions the implementation can validate, and propagate only obligations that the caller must establish or preserve.
4. **Prove the operation.** Check bounds, ownership, lifetime, pinning, alignment, initialization, representation, layout, blittability, native ABI, overlap, concurrency, and cleanup. Account for callbacks, suspension, exceptions, disposal, and GC movement.
5. **Minimize unchecked regions.** Prefer the smallest lexical unsafe block around the operation. Keep validation adjacent, prevent pointers and refs from escaping their valid lifetime, and add a concise `// SAFETY:` comment when the proof is not obvious.
6. **Validate behavior and cost.** Test boundary inputs, lifetime and GC behavior, native failure cleanup, generated code, every supported target framework, and consumers. Benchmark hot paths before claiming a safe rewrite is equivalent.

## Choose the Boundary

For each declaration or call, choose one outcome:

- **Remove unsafe** when a supported safe API preserves exact semantics, representation, lifetime, ABI, target-framework coverage, and acceptable performance.
- **Localize unsafe** when the implementation can validate every precondition and expose only a bounded or owned safe abstraction. Put the smallest unsafe block after validation.
- **Propagate unsafe** when correctness depends on memory, initialization, ownership, or lifetime conditions only the caller can establish or preserve. Under updated rules, make that requires-unsafe contract explicit and keep body operations in explicit inner unsafe regions.

A safe-callable API asserts that ordinary callers cannot violate memory safety through its inputs, state transitions, callbacks, failures, concurrency, or lifetime. Do not create one merely because a wrapper compiles.

> **Compatibility:** Verify the installed SDK/compiler and its current opt-in before enabling updated rules; exact property names, diagnostics, and tool support can still change. See [unsafe-contexts-and-migration-reference.md](unsafe-contexts-and-migration-reference.md) for the source snapshot, setup, and compatibility matrix.

## Migrate to Updated Rules

1. **Inventory the build and surface.** Record every target framework, SDK/compiler, `LangVersion`, `AllowUnsafeBlocks`, safety-rule opt-in, configuration, generated source, analyzer, dependency, and consuming assembly. Inventory every low-level declaration and operation identified by the core method.
2. **Classify the active rules.** Reproduce diagnostics with the installed compiler. Distinguish the legacy model, C# 13 async/iterator behavior, and the updated model.
3. **Establish a green baseline.** Build and test every supported target framework and relevant configuration before enabling updated rules or changing annotations. Capture API baselines and performance numbers for hot paths.
4. **Fix declaration shape first.** Remove type-level `unsafe`. Decide whether each member must impose a requires-unsafe caller contract. Align overrides, interfaces, partial declarations, accessors, delegates, constructors, and explicit-layout fields.
5. **Fix bodies second.** Put the smallest explicit `unsafe` block around each operation that still requires unchecked reasoning. Preserve pinning, initialization, and lifetime boundaries.
6. **Fix call sites.** Either propagate an honest caller obligation or validate all invariants and expose a safe-callable boundary containing a narrow unsafe block.
7. **Reduce unsafe where equivalent.** Prefer bounds-checked spans, `BinaryPrimitives`, supported vector span APIs, generated interop, and `SafeHandle`. Keep unsafe code when a safe rewrite changes semantics, availability, ABI, or measured performance.
8. **Audit invariants.** Apply the complete proof from the safety-patterns reference and add concise `// SAFETY:` comments for non-obvious obligations.
9. **Validate the matrix.** Test updated and legacy consumers, generated output, boundary inputs, GC/lifetime behavior, native failures, all target frameworks, and performance-sensitive paths.
10. **Block on diagnostics.** Fix or explicitly stage every unsafe diagnostic. Never broaden unsafe scopes, disable the model, add blanket suppressions, or write compiler metadata attributes directly as a shortcut.

## Load the Detailed References

- Read [unsafe-contexts-and-migration-reference.md](unsafe-contexts-and-migration-reference.md) when identifying lexical unsafe contexts, classifying language behavior, diagnosing compiler errors, translating legacy declarations, handling requires-unsafe contracts and metadata, ordering a migration, or testing cross-assembly compatibility.
- Read [unsafe-memory-safety-patterns-reference.md](unsafe-memory-safety-patterns-reference.md) when writing or reviewing low-level code, replacing pointer or low-level API usage, proving boundary invariants, designing interop and ownership, writing `SAFETY` comments, testing GC/interop/boundary behavior, or deciding whether a performance-sensitive unsafe path should remain.

Keep both references one link away from this file. Use the installed SDK's supported setup rather than inferring configuration from a code sample.

## Completion Checklist

- Record the installed SDK/compiler, language version, target frameworks, `AllowUnsafeBlocks`, and any active safety-rule opt-in.
- Identify every lexical context, low-level operation, lifetime, owner, and caller-controlled obligation in scope, including generated code.
- Justify remove, localize, or propagate for each changed boundary; do not broaden an unsafe context to silence a diagnostic.
- Validate bounds, initialization, pinning, representation, ABI, concurrency, cleanup, and suspension boundaries as applicable.
- Keep public, virtual, interface, partial, delegate, interop, and generated contracts aligned.
- Test boundary and failure cases, GC/lifetime behavior, every supported target framework, and measured hot-path performance.
- For updated-model migration, keep the legacy supported build green and test updated and legacy producer/consumer combinations.
- Leave no unexplained unsafe diagnostic, suppression, direct `RequiresUnsafeAttribute` use, or undocumented non-obvious proof.
