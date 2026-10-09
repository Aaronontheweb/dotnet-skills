# Stateful and async tests

## Use the native model runner when it fits

`SampleModelBased` runs generated operations against two representations and compares them. It remains
a good fit when actual and model transitions can be performed independently. Do not replace it with a
custom runner just because an operation table in one project became complicated.

This stack example uses a list as the reference, with its last element as the top. Pop on an empty stack
is deliberately allowed as a no-op in both models. If an API's return value matters, include that result
in the compared state or assert it explicitly; checking collection contents alone does not check replies.
When a wrapper holds those results, give it informative record fields or supply `printActual:` and
`printModel:`; a failure that prints only the wrapper type names hides the useful difference.

```csharp
using CsCheck;
using Xunit;
using Xunit.Abstractions;

public sealed class StackModelTests(ITestOutputHelper output)
{
    [Fact]
    public void Stack_matches_a_list_model()
    {
        Gen.Int[-10, 10].Array[0, 3]
            .Select(initial => (new Stack<int>(initial), new List<int>(initial)))
            .SampleModelBased(
                Gen.Int[-10, 10].Operation<Stack<int>, List<int>>(
                    (stack, value) => stack.Push(value),
                    (list, value) => list.Add(value)),
                Gen.Operation<Stack<int>, List<int>>(
                    stack => { stack.TryPop(out _); },
                    list => { if (list.Count > 0) list.RemoveAt(list.Count - 1); }),
                equal: (stack, list) => stack.SequenceEqual(list.AsEnumerable().Reverse()),
                writeLine: output.WriteLine);
    }
}
```

The initial generator creates fresh collections each time. `Gen.Const(new MutableState())` would instead
reuse that object across cases. Generate fresh state in `Select` or the API's factory overload where
provided. Avoid sharing mutable input collections between the SUT and model.

For independent async transitions, inspect `SampleModelBasedAsync` and the async `Operation` overloads
in the installed version. Use an actual comparison for `equal:`. Resource ownership and teardown still
need attention; an equality callback is not a disposal hook and may never run after an earlier failure.

## Direct async command properties

A generated array plus `SampleAsync` is useful when each case owns async resources, or checks must
process real observations after every command. CsCheck still owns generation and shrinking. The loop
should be ordinary application code, not another operation-registration framework.

This complete example tests a file-backed register. `Write` and `Delete` are individual generated
commands; there is no forced scenario prefix or suffix. After each command, the expected value is
compared with a read through the SUT. The filename is only fixture isolation, not a behavioral random
input. Replace `FileRegister` with the application interface when adapting the pattern.

```csharp
using CsCheck;
using Xunit;
using Xunit.Abstractions;

public sealed class AsyncRegisterTests(ITestOutputHelper output)
{
    private abstract record Command;
    private sealed record Write(int Value) : Command;
    private sealed record Delete : Command;

    [Fact]
    public Task Register_matches_generated_commands()
    {
        var commands = Gen.Frequency<Command>(
            (3, Gen.Int[-100, 100].Select(value => new Write(value))),
            (1, Gen.Const(new Delete())));

        return commands.Array[0, 30].SampleAsync(async trace =>
        {
            var path = Path.Combine(Path.GetTempPath(), $"cscheck-{Guid.NewGuid():N}.txt");
            var store = new FileRegister(path);
            int? expected = null;
            try
            {
                foreach (var command in trace)
                {
                    switch (command)
                    {
                        case Write write:
                            await store.WriteAsync(write.Value);
                            expected = write.Value;
                            break;
                        case Delete:
                            store.Delete();
                            expected = null;
                            break;
                        default:
                            throw new InvalidOperationException(command.ToString());
                    }
                    Assert.Equal(expected, await store.ReadAsync());
                }
            }
            finally
            {
                File.Delete(path);
            }
        }, writeLine: output.WriteLine);
    }

    private sealed class FileRegister(string path)
    {
        public Task WriteAsync(int value) => File.WriteAllTextAsync(path,
            value.ToString(System.Globalization.CultureInfo.InvariantCulture));
        public void Delete() => File.Delete(path);
        public async Task<int?> ReadAsync() => File.Exists(path)
            ? int.Parse(await File.ReadAllTextAsync(path), System.Globalization.CultureInfo.InvariantCulture)
            : null;
    }
}
```

Cleanup runs for success, assertion failure, and shrink candidates. An `await using` resource belongs
inside that callback too. Keep resource cleanup separate from the observed contract; if a cleanup API
is itself under test, use an independent final cleanup path. Do not swallow an assertion or unexpected
exception to make a sample pass.

`SampleAsync` explores independent cases; it does not turn the operations *within* this loop into a
concurrency test. Each case's commands run sequentially. Control library threads when the harness has a
real shared-resource constraint. Avoid accidentally claiming distributed-system linearizability from
sequential conformance; CsCheck's separate `SampleParallel` family addresses different tests.

## When the next expectation depends on observations

For a delivery/retry system, a command may produce several events before it settles. Keep a direct
flow: execute the generated command, collect observations, validate them against the current model,
then update allowed future behavior. A cumulative journal and an event delta are different contracts;
state which one the model consumes so callers cannot silently omit or double-count events.

An observation-driven model should make uncertainty explicit:

| Observation | What the model may conclude |
| --- | --- |
| Successful durable acknowledgement under the contract | That occurrence is acknowledged; later delivery is forbidden. |
| A timeout alone | Acceptance may be unknown; the timeout does not prove commit or rollback. |
| An injected failure after a write | Use independently known fault inputs and occurrence identity to determine what is known; merely reaching storage is not always acceptance. |
| A later authoritative observation | Narrow the allowed states and reinstate the applicable obligations. |

Compute an expected reply from prior model state and the command before comparing the actual reply.
When multiple outcomes are permitted, assert membership in that allowed set and update from the observed
outcome. Do not implement “whatever happened becomes correct,” globally disable liveness after any
fault, or use production storage rows as the model's expected truth when they are the behavior at issue.

When replacing an older test, map each old assertion to its new check. Preserve the hard parts: reply
codes, payload identity, duplicate/superseded actions, deadlines, recovery obligations, and loss of reply
after successful writes. A simpler shared model can accidentally loosen a stricter healthy-storage
assertion. Keep a small independent check where it establishes a distinct guarantee.

API source: [model-based and async runners](https://github.com/AnthonyLloyd/CsCheck/blob/50503557f23266f140021f65632612ceb4ac248f/CsCheck/Check.cs).
