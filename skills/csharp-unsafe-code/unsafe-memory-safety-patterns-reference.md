# Unsafe Memory-Safety Patterns Reference

> Use this reference to replace or contain low-level C# memory operations and prove safe-callable boundaries. Where an example names version-dependent syntax or an API, verify that the installed SDK and target framework provide it.

## Contents

- [Define the safety proof](#define-the-safety-proof)
- [Prefer bounded span traversal](#prefer-bounded-span-traversal)
- [Read and write binary representations explicitly](#read-and-write-binary-representations-explicitly)
- [Distinguish size operations](#distinguish-size-operations)
- [Use vector span APIs when code generation holds](#use-vector-span-apis-when-code-generation-holds)
- [Contain unavoidable unsafe code](#contain-unavoidable-unsafe-code)
- [Design interop and ownership boundaries](#design-interop-and-ownership-boundaries)
- [Preserve hot paths when evidence requires it](#preserve-hot-paths-when-evidence-requires-it)
- [Avoid common unsafe substitutions](#avoid-common-unsafe-substitutions)
- [Write useful SAFETY comments](#write-useful-safety-comments)
- [Apply the review rubric](#apply-the-review-rubric)
- [Run focused validation](#run-focused-validation)
- [Unsafe-reduction evidence and sources](#unsafe-reduction-evidence-and-sources)

## Define the Safety Proof

A compiler-accepted safe region is not a borrow-checked proof. Before making a low-level implementation safe-callable, prove all applicable invariants:

| Invariant | Questions to answer |
| --- | --- |
| Bounds | What establishes the readable/writable byte or element count? Are offset addition and multiplication overflow-checked? |
| Ownership | Who allocates, mutates, frees, disposes, returns, or reuses the storage? Can ownership transfer twice? |
| Lifetime | Can a pointer, ref, span, callback, or native operation outlive its source, pin, stack frame, lease, or handle? |
| Pinning | Is movable managed storage pinned for the entire native/pointer use and no longer? Can the GC run or a callback reenter? |
| Alignment | Does the access require natural or platform-specific alignment? Is the native ABI stricter than managed access? |
| Initialization | Is every byte or element initialized before read, including padding and tail bytes? What changes under `SkipLocalsInit`? |
| Representation | Is the value interpreted with the correct endian, encoding, signedness, width, and floating-point representation? |
| Layout | Is the type unmanaged, blittable where required, and laid out with the expected packing, offsets, padding, and architecture? |
| Overlap | May source and destination alias or overlap? Does the selected copy/transform API define that case? |
| Native ABI | Do calling convention, entry point, character set, Boolean width, integer width, and error reporting match native code? |
| Cleanup | Are handles, pins, buffers, and native allocations released exactly once on every success, failure, cancellation, and exception path? |
| Concurrency | Can another thread, callback, finalizer, or dispose path invalidate data between validation and use? |

Add a safe abstraction only after all externally controllable conditions are validated or structurally impossible. Propagate a requires-unsafe contract when the caller must guarantee an otherwise unverifiable condition.

## Prefer Bounded Span Traversal

### Replace pointer walking with slices

Prefer `Span<T>`/`ReadOnlySpan<T>` when the operation is over a contiguous region with known length. Advance by slicing so the remaining length travels with the data. For example, a fixed-width parser keeps the exact length gate adjacent to each slice:

```csharp
public static uint SumBigEndianWords(ReadOnlySpan<byte> source)
{
    uint sum = 0;

    while (source.Length >= sizeof(uint))
    {
        sum += System.Buffers.Binary.BinaryPrimitives.ReadUInt32BigEndian(source);
        source = source[sizeof(uint)..];
    }

    return sum;
}
```

Do not weaken `>= width` to a non-equivalent gate, move slicing ahead of validation, or silently ignore a tail unless the existing contract does so. Test empty, short, exact-width, multiple-width, and trailing-byte inputs.

### Use constant-step loops deliberately

Prefer a loop shape the JIT can reason about:

```csharp
while (source.Length >= 8)
{
    ReadOnlySpan<byte> chunk = source[..8];
    ConsumeEight(chunk);
    source = source[8..];
}
```

Keep the step constant and the guard structurally obvious. Avoid repeatedly recomputing end pointers or combining several unchecked offsets. Inspect generated code or benchmark the supported runtimes when the old path relied on bounds-check elimination.

A span rewrite improves local reasoning but may add bounds checks, alter vectorization, or change inlining. Representative runtime work includes [#127382](https://github.com/dotnet/runtime/pull/127382), [#127388](https://github.com/dotnet/runtime/pull/127388), and [#129625](https://github.com/dotnet/runtime/pull/129625). Treat each PR as evidence for a pattern in its specific runtime-main context; note that #127388 closed without merge at this snapshot.

## Read and Write Binary Representations Explicitly

### Prefer BinaryPrimitives for wire formats

Use `BinaryPrimitives` for protocol or file formats with explicit endian. Check the required length before reading or writing.

```csharp
using System.Buffers.Binary;

public static uint ReadFrameLength(ReadOnlySpan<byte> header)
{
    if (header.Length < sizeof(uint))
    {
        throw new ArgumentException("A frame header requires four bytes.", nameof(header));
    }

    return BinaryPrimitives.ReadUInt32BigEndian(header);
}

public static void WriteFrameLength(Span<byte> destination, uint value)
{
    if (destination.Length < sizeof(uint))
    {
        throw new ArgumentException("A frame header requires four bytes.", nameof(destination));
    }

    BinaryPrimitives.WriteUInt32BigEndian(destination, value);
}
```

Prefer `TryRead`/`TryWrite` shapes where failure is expected and the API provides them. Preserve whether the old code accepted trailing bytes, sign-extended values, reversed only on little-endian machines, or wrote partial output before failure.

Representative runtime unsafe reductions: [#127485](https://github.com/dotnet/runtime/pull/127485), [#127913](https://github.com/dotnet/runtime/pull/127913), and [#127921](https://github.com/dotnet/runtime/pull/127921).

### Treat BitConverter span APIs as host-endian

`BitConverter` span overloads interpret values in machine endianness. Use them for explicitly host-native data, not implicitly for network or persistent formats.

```csharp
public static int ReadHostEndianInt32(ReadOnlySpan<byte> source)
{
    if (source.Length < sizeof(int))
    {
        throw new ArgumentException("Four bytes are required.", nameof(source));
    }

    return BitConverter.ToInt32(source);
}
```

Use `BinaryPrimitives.ReadInt32LittleEndian` or `ReadInt32BigEndian` when the representation has a declared byte order. Runtime PR [#127394](https://github.com/dotnet/runtime/pull/127394) demonstrates replacing generic `MemoryMarshal` reads/writes with `BitConverter` in cases where host-endian semantics were intended; it is not a rule to replace every `MemoryMarshal` use.

### Review MemoryMarshal use by representation

Do not use `MemoryMarshal.Cast`, `Read`, `Write`, or `AsBytes` merely to avoid a copy. Confirm:

- the source length is sufficient and divisibility/tail behavior is intentional;
- `T` has the required unmanaged/reference-free representation;
- endian is correct for the stored format;
- padding bytes are initialized before exposure or hashing;
- aliasing and mutation through the reinterpreted view are intended;
- architecture-specific alignment and atomicity requirements are met;
- the resulting span cannot escape the source lifetime.

A managed API name does not make representation reinterpretation semantically portable.

## Distinguish Size Operations

Do not interchange these operations:

| Operation | Meaning | Constraints and review |
| --- | --- | --- |
| `sizeof(T)` | Managed storage size known to the C# compiler for an unmanaged type. | Built-in types have long-standing safe cases. General unmanaged use is legacy-unsafe and relaxed by the updated rules. It does not describe custom marshaling. |
| `Unsafe.SizeOf<T>()` | Size of `T` as represented in managed storage, exposed through a low-level API. | Does not mean native marshaled size. Audit low-level API contracts and generic/reference-containing cases. |
| `Marshal.SizeOf<T>()` | Size of the unmanaged representation used by marshaling rules. | Can differ because of layout, packing, character/Boolean marshaling, or custom marshaling; may reject unsupported types. |

An installed compiler implementing the updated rules may allow this without a lexical unsafe context:

```csharp
public static int ManagedUnmanagedSize<T>() where T : unmanaged
    => sizeof(T);
```

Recheck compiler behavior. Runtime-main PR [#130727](https://github.com/dotnet/runtime/pull/130727) is evidence that runtime source adopted `sizeof` during unsafe-reduction work; it does **not** establish released compiler/API availability for a user's SDK.

For native structs, verify `StructLayout`, `FieldOffset`, `Pack`, fixed buffers, nested layout, platform pointer width, and the native compiler's ABI. Add layout tests for every supported architecture when the value crosses an interop boundary.

## Use Vector Span APIs When Code Generation Holds

**API availability varies by target framework:** Prefer `Vector64/128/256/512.Create(span)` and span slicing over `LoadUnsafe`/`StoreUnsafe` when the target framework provides the needed overload and benchmarks show equivalent code generation.

```csharp
using System.Runtime.Intrinsics;

public static Vector128<byte> ReadVector(ReadOnlySpan<byte> source)
{
    if (source.Length < Vector128<byte>.Count)
    {
        throw new ArgumentException("A complete vector is required.", nameof(source));
    }

    return Vector128.Create(source);
}
```

For looped processing:

1. Guard with `source.Length >= Vector128<T>.Count`.
2. Create from the current span.
3. Process the vector.
4. Slice by exactly `Vector128<T>.Count`.
5. Handle the tail with a defined scalar or masked path.

Do not assume `Create(span)` is available on every downlevel target, that it accepts short spans, or that it produces the same instruction sequence on every JIT. Representative runtime PRs: [#127456](https://github.com/dotnet/runtime/pull/127456), [#127845](https://github.com/dotnet/runtime/pull/127845), and [#127846](https://github.com/dotnet/runtime/pull/127846).

## Contain Unavoidable Unsafe Code

### Keep the smallest block

Keep the public/member boundary safe-callable only after checking its inputs, then isolate the pointer-only primitive. Assume this native API's documented ABI uses `cdecl`, requires a non-null pointer, and reads the buffer synchronously:

```csharp
[System.Runtime.InteropServices.DllImport(
    "nativecodec",
    EntryPoint = "native_checksum",
    CallingConvention = System.Runtime.InteropServices.CallingConvention.Cdecl)]
private static extern uint NativeChecksum(System.IntPtr data, nuint length);

public static uint ComputeChecksum(ReadOnlySpan<byte> source)
{
    if (source.IsEmpty)
    {
        throw new ArgumentException("At least one byte is required.", nameof(source));
    }

    unsafe
    {
        fixed (byte* pointer = source)
        {
            // SAFETY: source is caller-controlled, but the non-empty check and span bounds prove
            // source.Length readable bytes, and fixed pins them for this call. NativeChecksum's
            // documented contract reads exactly length bytes synchronously and neither writes to
            // nor retains the pointer; source.Length fits nuint on supported .NET architectures.
            return NativeChecksum((System.IntPtr)pointer, (nuint)source.Length);
        }
    }
}
```

This safe-callable wrapper is justified only while that native contract holds; a retaining, asynchronous, or writing API requires a different ownership design. The example requires `AllowUnsafeBlocks` and compiles under the legacy model. The call site's block—not a member modifier—makes the proof boundary visible and also follows the updated model's explicit-region rule.

Use this approach for downlevel target frameworks that lack an equivalent safe overload. Keep conditional code target-specific only when API availability actually differs. Runtime System.Text.Json work in [#114154](https://github.com/dotnet/runtime/pull/114154) and [#114490](https://github.com/dotnet/runtime/pull/114490) provides representative examples of reducing rather than pretending to eliminate every unsafe region.

### Preserve pinning and lifetime

Never let a managed pointer escape its `fixed` or other pinning lifetime:

```csharp
public static void Send(ReadOnlySpan<byte> payload)
{
    unsafe
    {
        fixed (byte* pointer = payload)
        {
            NativeSend(pointer, payload.Length);
        } // Do not store pointer or use it after this point.
    }
}
```

The native callee must finish using the pointer before returning. If native code retains the pointer or invokes asynchronously, copy into appropriately owned unmanaged memory or use an explicitly managed long-lived pin with deterministic cleanup and documented costs. Do not return the pointer, capture it in a callback, store it in an `IntPtr`, or queue work that outlives the pin.

Avoid `Unsafe.AsPointer` for movable managed data. Converting a ref to a pointer does not pin its owner. `GC.KeepAlive` can extend liveness but does not by itself pin movable memory.

### Initialize stack memory

Initialize every byte that may be read or exposed:

```csharp
Span<byte> scratch = stackalloc byte[64];
scratch.Clear();
```

Or use a complete initializer and prove that all elements are assigned before read. Review padding and tail bytes, not only logical fields. Be especially strict under `SkipLocalsInit`; the updated rules may require an unsafe context for uninitialized `stackalloc`.

Bound stack allocations. Reject or switch to pooled/heap storage for attacker-controlled or large lengths to avoid stack exhaustion.

## Design Interop and Ownership Boundaries

### Prefer generated interop and SafeHandle

**Target-framework dependent:** Prefer `[LibraryImport]` source-generated interop where supported and represent owned native resources with a `SafeHandle` subclass. This centralizes ABI declarations and makes cleanup resilient to exceptions and finalization.

```csharp
using System.Runtime.InteropServices;
using Microsoft.Win32.SafeHandles;

internal static partial class NativeMethods
{
    [LibraryImport("example", EntryPoint = "open_resource", StringMarshalling = StringMarshalling.Utf8)]
    internal static partial SafeFileHandle OpenResource(string name);
}
```

Use the handle type that actually matches the native resource; `SafeFileHandle` above is only valid if the native API returns a file-handle-compatible value and invalid-handle conventions match. Otherwise define a correct `SafeHandle` implementation.

Audit generated signatures and native headers together:

- calling convention and entry point;
- pointer direction and buffer length units;
- null termination and string encoding;
- native `bool`, integer, enum, and structure widths;
- ownership transfer and close function;
- last-error capture and failure sentinel;
- callback calling convention, rooting, lifetime, and exception behavior;
- platform-specific layout and architecture.

Under the updated model, interop declarations and generated code may acquire explicit safety contracts. Do not assume generation exempts them from diagnostics.

### Treat IntPtr and nint as pointer-smuggling

`IntPtr`, `UIntPtr`, `nint`, and `nuint` can carry addresses without pointer syntax. Treat conversion, arithmetic, storage, and API boundaries as unsafe in the design sense even when the shipped compiler permits them in ordinary code.

Validate provenance, ownership, width, alignment, lifetime, and allowed range before conversion or dereference. Never infer that a nonzero integer is a valid live pointer or handle.

### Separate borrowed and owned memory

Make ownership visible:

- Use spans for bounded synchronous borrows.
- Use `Memory<T>` for managed storage that must survive async suspension, while reacquiring a span only in non-suspending regions.
- Use `SafeHandle` for owned native handles.
- Use a disposable owner for native allocations and expose spans only while the owner remains alive.
- Copy when a callee needs data beyond the borrow lifetime.

Do not store a span in heap state, return a ref into an object whose lifetime is not guaranteed, or expose mutable aliases that violate invariants.

### Treat pools as manual lifetime systems

Returning an array to a pool ends the lease. Do not retain spans, refs, pointers, or callbacks into it afterward. Clear sensitive contents as required by the threat model and ensure return happens exactly once:

```csharp
byte[] buffer = System.Buffers.ArrayPool<byte>.Shared.Rent(minimumLength);
try
{
    Span<byte> active = buffer.AsSpan(0, minimumLength);
    active.Clear();
    UseSynchronously(active);
}
finally
{
    System.Buffers.ArrayPool<byte>.Shared.Return(buffer, clearArray: true);
}
```

The compiler model is not a general use-after-return checker. The same caution applies to custom arenas, object pools, slab allocators, and recycled native buffers.

## Preserve Hot Paths When Evidence Requires It

Do not equate compiling without `unsafe` with equivalent throughput. A rewrite can change:

- bounds-check elimination;
- vectorization and instruction selection;
- inlining, register pressure, and code size;
- allocations, copies, and pinning;
- startup, tiered compilation, and AOT behavior;
- behavior on short inputs versus steady-state bulk inputs.

Use this decision sequence:

1. Lock correctness with differential tests.
2. Benchmark the old and candidate paths on representative data distributions.
3. Test every supported runtime/JIT and architecture that matters.
4. Inspect disassembly for extremely sensitive loops.
5. Keep the safe rewrite only when regressions are within the project's accepted budget.
6. Otherwise retain the measured unsafe path, narrow its scope, and document the proof and benchmark.

Runtime PR [#127539](https://github.com/dotnet/runtime/pull/127539) records UniqueId/XML unsafe-reduction work and the decision to revert some candidate safe rewrites after performance regressions. Use that as evidence to measure, not as permission to keep unreviewed unsafe code.

## Avoid Common Unsafe Substitutions

| Anti-pattern | Safer alternative |
| --- | --- |
| Walk from `start` to `end` with raw pointers and unchecked increments. | Carry a `Span<T>`/`ReadOnlySpan<T>`, guard exact lengths, and advance by constant slices. |
| Use `MemoryMarshal.Read<T>` for a wire integer without defining endian. | Use the matching `BinaryPrimitives.Read*LittleEndian` or `Read*BigEndian`. |
| Use `BitConverter` for a network/file format because it accepts a span. | Use `BinaryPrimitives`; reserve `BitConverter` for explicitly host-endian representations. |
| Replace `sizeof(T)`, `Unsafe.SizeOf<T>()`, and `Marshal.SizeOf<T>()` interchangeably. | Select managed compiler size, managed storage size, or marshaled native size deliberately; test layout. |
| Call `Unsafe.AsPointer(ref value)` on movable managed data. | Keep a ref/span, or pin with `fixed` for the complete synchronous pointer use. |
| Return or cache a pointer obtained inside `fixed`. | Complete the operation inside the pin, or copy/use explicitly owned stable memory. |
| Cast arbitrary `nint`/`IntPtr` to a pointer after checking only nonzero. | Validate provenance, lifetime, range, alignment, ownership, and ABI; encapsulate handles with `SafeHandle`. |
| Leave `stackalloc` partially initialized because only a prefix is expected to be read. | Clear or fully initialize the entire exposed/read region; test tails and padding. |
| Allocate attacker-controlled `stackalloc` lengths. | Impose a small fixed threshold and use pooled/heap storage above it. |
| Mark an entire type or member `unsafe` to silence one operation. | Use the smallest block; under updated rules, reserve member `unsafe` for a genuine caller obligation. |
| Put a low-level call in a safe wrapper without validating its contract. | Validate every invariant or propagate an honest requires-unsafe contract. |
| Use broad `#pragma`, `NoWarn`, or disable the updated model. | Resolve each diagnostic by replacement, localization, or propagation; stage only narrow temporary exceptions. |
| Apply `RequiresUnsafeAttribute` in source or copy a proposal namespace. | Use supported `unsafe` syntax and let the compiler emit metadata. |
| Keep a pointer/span/ref after returning an array or arena block to a pool. | End all borrows before return and prevent callbacks/tasks from retaining them. |
| Assume reflection, `dynamic`, or a delegate preserves compiler safety contracts. | Validate at runtime boundaries and test indirect invocation paths. |
| Free native memory in both failure cleanup and owner disposal. | Establish one owner, transfer explicitly, and release exactly once with `SafeHandle`/`IDisposable`. |
| Accept callback reentrancy while a raw pointer assumes stable object state. | Pin/lock/copy as required, minimize callback scope, and revalidate state after reentrancy. |

## Write Useful SAFETY Comments

Write a comment for a non-obvious unsafe block or safe wrapper. State facts that a reviewer can verify, not confidence.

Template:

```csharp
// SAFETY:
// - Bounds: <expression/test proving readable and writable extent>.
// - Lifetime/pinning: <owner and why the address/reference remains valid>.
// - Representation/alignment: <layout, endian, alignment, and type proof>.
// - Ownership/cleanup: <who releases or returns storage and on which paths>.
unsafe
{
    // Minimal unchecked operation.
}
```

Keep only applicable lines. Prefer a concise single line when one invariant suffices:

```csharp
// SAFETY: fixed pins all 16 validated bytes until NativeConsume returns synchronously.
```

Do not write `// SAFETY: this is safe`, restate syntax, cite passing tests as the proof, or omit a caller-controlled precondition. Update the comment when the code or native contract changes.

For a requires-unsafe public member, document caller obligations in API documentation as well as the implementation's `SAFETY` comment. The member contract tells callers what they must guarantee; the block comment explains why the implementation operation is valid at that point.

## Apply the Review Rubric

Approve a low-level change only when each applicable item has concrete evidence.

### Declaration and boundary

- Identify the active legacy, C# 13, or updated rule set.
- Justify remove/localize/propagate for every changed unsafe declaration.
- Keep public, virtual, interface, partial, delegate, and generated contracts aligned.
- Confirm a safe-callable wrapper validates all caller-controlled conditions.
- Avoid direct compiler metadata attributes and type-level syntax invalid under updated rules.

### Memory region

- Derive byte/element count without integer overflow.
- Check empty, minimum, exact, tail, and maximum lengths.
- Prove every read is initialized and every write is within capacity.
- Define overlap/aliasing behavior.
- Bound stack allocations and pooled-buffer slices.

### Type and representation

- Prove unmanaged/reference-free constraints where required.
- Define endian, signedness, width, encoding, and padding.
- Verify alignment and architecture assumptions.
- Compare managed layout, marshaled layout, and native ABI.
- Avoid exposing uninitialized padding through hashing, serialization, or native calls.

### Lifetime and ownership

- Name the owner and the end of every borrow.
- Keep movable data pinned for the complete pointer use and no longer.
- Prevent pointers, refs, or spans from escaping stack, pin, lease, or owner lifetime.
- Handle callbacks, reentrancy, finalization, dispose races, and thread races.
- Release, unpin, return, or free exactly once on every path.

### Tooling and performance

- Compile generated code and inspect generated declarations.
- Test all target frameworks and consumer/compiler combinations.
- Run GC stress and native failure cleanup where applicable.
- Benchmark performance-sensitive paths with representative distributions.
- Record why retained unsafe code is necessary and what measurement guards it.

## Run Focused Validation

Use a matrix tailored to the operation:

| Dimension | Cases | Failure being sought |
| --- | --- | --- |
| Length | empty, one short, exact, one over, multiple blocks, tail, maximum | Off-by-one, invalid slice, partial read/write, overflow. |
| Alignment | naturally aligned and deliberately unaligned offsets where supported | Architecture fault, wrong value, hidden alignment dependence. |
| Endian | known byte vectors for little and big endian | Host-endian leakage, reversed fields, sign error. |
| Overlap | same region, exact alias, forward overlap, backward overlap, disjoint | Copy corruption or undefined alias behavior. |
| Initialization | zero, full initializer, partial-tail sentinel, `SkipLocalsInit` lane | Read/exposure of undefined bytes or padding. |
| GC/lifetime | forced collections, compaction, repeated pin/unpin, callback/reentrancy | Movable pointer escape, premature collection, stale ref. |
| Ownership | success, throw before/after transfer, double-dispose, cancellation | Leak, double free, use after return/free. |
| Interop failure | null/invalid handles, short native writes, last-error path, callback exception | ABI mismatch, cleanup loss, invalid sentinel handling. |
| Cross-TFM | every supported target and conditional implementation | Missing safe overload, divergent semantics, compilation gap. |
| Consumers | old/new producer crossed with old/new compiler | Lost or spurious caller diagnostics, metadata/tool lag. |
| Performance | tiny, typical, large, adversarial distributions; tiered/AOT as relevant | Regression hidden by a single throughput average. |

Recommended techniques:

- Compare old and new implementations over randomized and boundary inputs.
- Use checked arithmetic or explicit overflow tests for byte-count calculations.
- Force compacting collections while exercising pinned/borrowed paths.
- Add native test doubles that fail at every acquisition/transfer stage.
- Run architecture-specific CI when layout or intrinsics differ.
- Benchmark both throughput and allocation; inspect disassembly for critical loops.
- Keep unsafe diagnostics as errors in the evaluation lane once initial staging is complete.

Tests do not replace the invariant proof. They challenge it.

## Unsafe-Reduction Evidence and Sources

Start with authoritative guidance:

- [Unsafe code best practices](https://learn.microsoft.com/en-us/dotnet/standard/unsafe-code/best-practices)
- [Updated memory-safety model (preview)](https://learn.microsoft.com/en-us/dotnet/csharp/language-reference/unsafe-code#the-updated-memory-safety-model-preview)
- [Improving C# memory safety (.NET blog)](https://devblogs.microsoft.com/dotnet/improving-csharp-memory-safety/)
- [Runtime adoption tracking issue #125800](https://github.com/dotnet/runtime/issues/125800)
- [Merged runtime PR search for “reduce unsafe”](https://github.com/dotnet/runtime/pulls?q=is%3Apr+is%3Amerged+%22reduce+unsafe%22)

Use representative runtime PRs as implementation evidence, not universal prescriptions:

| Pattern | Pull requests |
| --- | --- |
| Span slicing and bounded traversal | [#127382](https://github.com/dotnet/runtime/pull/127382), [#127388](https://github.com/dotnet/runtime/pull/127388), [#129625](https://github.com/dotnet/runtime/pull/129625) |
| Explicit binary/primitive reads and writes | [#127485](https://github.com/dotnet/runtime/pull/127485), [#127913](https://github.com/dotnet/runtime/pull/127913), [#127921](https://github.com/dotnet/runtime/pull/127921), [#127394](https://github.com/dotnet/runtime/pull/127394) |
| `sizeof` unsafe-reduction evidence on runtime main | [#130727](https://github.com/dotnet/runtime/pull/130727) |
| Vector creation from spans | [#127456](https://github.com/dotnet/runtime/pull/127456), [#127845](https://github.com/dotnet/runtime/pull/127845), [#127846](https://github.com/dotnet/runtime/pull/127846) |
| Narrow unavoidable unsafe on downlevel paths | [#114154](https://github.com/dotnet/runtime/pull/114154), [#114490](https://github.com/dotnet/runtime/pull/114490) |
| Performance-driven retention/reversion | [#127539](https://github.com/dotnet/runtime/pull/127539) |

Check each PR's merge state, final diff, target branch, benchmark evidence, and later follow-up before copying a pattern. At this snapshot, #127388 is closed without merge; its discussion remains representative but not adopted runtime code.
