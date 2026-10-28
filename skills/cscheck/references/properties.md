# Properties and generators

## Start with observable laws

Choose laws that constrain useful behavior: preservation of information, round trips, idempotence,
ordering, conservation, agreement with an independent reference, or invariance under a transformation.
Several complementary assertions are often stronger than one convenient equality. For example, a sort
that returns an empty array is ordered and idempotent, but does not preserve its input elements.

This complete example checks ordering **and multiplicities**. `Array.Sort` is the implementation under
test here; substitute your implementation at that call. The expected multiset comes from the untouched
input, not the sorted result. Bounded integers deliberately make duplicates common.

```csharp
using CsCheck;
using Xunit;
using Xunit.Abstractions;

public sealed class SortingProperties(ITestOutputHelper output)
{
    [Fact]
    public void Sorting_preserves_values_and_orders_them()
    {
        Gen.Int[-100, 100].Array[0, 100].Sample(input =>
        {
            var actual = (int[])input.Clone();
            Array.Sort(actual);

            Assert.Equal(input.Length, actual.Length);
            Assert.True(actual.Zip(actual.Skip(1), (a, b) => a <= b).All(x => x));
            var before = input.GroupBy(x => x).ToDictionary(g => g.Key, g => g.Count());
            var after = actual.GroupBy(x => x).ToDictionary(g => g.Key, g => g.Count());
            Assert.Equal(before.Count, after.Count);
            foreach (var (value, count) in before)
                Assert.Equal(count, after.GetValueOrDefault(value));
        }, writeLine: output.WriteLine);
    }
}
```

A failed assertion throws inside `Sample`; CsCheck captures and shrinks the generated input. Returning a
boolean predicate is also supported. Do not catch the assertion and continue sampling as if it passed.
Keep the original input available when the implementation mutates its arguments.

## Construct dependent inputs

When one input constrains another, generate in dependency order. This example generates every slice
within an array, including empty slices and the end offset. `Skip`/`Take` is a separate reference for
`AsSpan`; the property is not comparing two calls to `AsSpan`.

```csharp
using CsCheck;
using Xunit;
using Xunit.Abstractions;

public sealed class SliceProperties(ITestOutputHelper output)
{
    [Fact]
    public void A_slice_contains_exactly_the_requested_segment()
    {
        var slices =
            from data in Gen.Int.Array[0, 50]
            from offset in Gen.Int[0, data.Length]
            from length in Gen.Int[0, data.Length - offset]
            select (data, offset, length);

        slices.Sample(sample =>
        {
            var (data, offset, length) = sample;
            var actual = data.AsSpan(offset, length).ToArray();
            Assert.Equal(data.Skip(offset).Take(length), actual);
        }, writeLine: output.WriteLine);
    }
}
```

Constructing valid inputs directly keeps the generator productive and its dependencies intact during
shrinking. Filtering can be appropriate for a cheap, common predicate, but repeated rejection of almost
all generated inputs is a sign to change the construction. Do not constrain inputs using the SUT's own
validation logic when the validator is part of what you are testing.

## Give the generator a meaningful domain

| Need | CsCheck shape | Design consideration |
| --- | --- | --- |
| Bounded integer | `Gen.Int[min, max]` | Include contract boundaries; integer endpoints are inclusive. |
| Small argument set | `Gen.OneOfConst(0, 1, 10)` | These are values, not prewritten execution scenarios. |
| Dependent values | LINQ `from` / `SelectMany` | Generate the prerequisite before the dependent value. |
| More weight near boundaries | `Gen.Frequency((weight, generator), ...)` | Keep broad values available alongside targeted edges. |
| Variable-length collection | `element.Array[min, max]` | Include empty and singleton collections when meaningful. |
| Async property | `generator.SampleAsync(async input => ...)` | Await work and keep fixture lifetime inside the callback. |

Weights control exploration effort; they do not establish coverage. Choose domains from the contract,
not just values that make the implementation easy to run. Record deliberate scope limits, such as
positive intervals or bounded queue capacity. Include malformed inputs in a separate property if their
rejection is required rather than filtering them away everywhere.

Do not obtain ordinary inputs from `Random.Shared`, timestamps, or an external RNG inside the property.
CsCheck cannot shrink those hidden choices. Generate those values as part of the case. Per-case unique
resource names are fine when they only isolate fixtures and do not alter the behavior being checked.

## Assess the property

Ask what a wrong implementation could return and still pass. Examples:

- An identity function satisfies “applying it twice has the same result”; add the actual normalization law.
- A serializer/deserializer pair can share a bug; supplement round trips with contract fixtures or an
  independent representation when wire compatibility matters.
- Comparing counts alone misses reordered, duplicated, or substituted values.
- Testing an operation only on valid states leaves rejection behavior unexplored.

Keep failure messages about the input and violated law. Default printing is often sufficient; use
`print:` or record fields when domain names materially improve the shrunk example. Avoid reflection-based
pretty-printer infrastructure just to make every failure pasteable as C#.

API source: [Gen.cs](https://github.com/AnthonyLloyd/CsCheck/blob/50503557f23266f140021f65632612ceb4ac248f/CsCheck/Gen.cs)
and [Sample / SampleAsync](https://github.com/AnthonyLloyd/CsCheck/blob/50503557f23266f140021f65632612ceb4ac248f/CsCheck/Check.cs).
