# Failure discovery and replay

## Let normal runs discover failures

Do not maintain a seed list or replace CsCheck generation with a loop over `Random(seed)`. Run the
property without a seed and keep the shrunk input, emitted seed, generator revision, package version,
and failing assertion. A seed is a replay tool after discovery, not an additional scenario generator.

The examples in this skill leave iteration and time settings to CsCheck. In the verified version, the
ordinary default is 100 iterations; native environment variables can increase exploration. Explicit
`iter:`/`time:` arguments can override environment defaults, so inspect wrappers that hard-code budgets.
Time budgets are not hard process timeouts; setup, an individual case, shrinking, and cleanup take time.

Bash examples for an xUnit project using `dotnet test` (replace the project/filter with the real ones):

```bash
# Discovery: leave the seed unset and run this property for a bounded sampling budget.
env -u CsCheck_Seed -u CsCheck_Iter CsCheck_Time=10 \
  dotnet test tests/MyProject.Tests -c Release \
  --filter 'FullyQualifiedName~MyProperty' --logger 'console;verbosity=detailed'

# Replay the emitted seed with the same generator. Replace EMITTED_SEED.
env -u CsCheck_Time CsCheck_Seed=EMITTED_SEED CsCheck_Iter=1 CsCheck_Threads=1 \
  dotnet test tests/MyProject.Tests -c Release \
  --filter 'FullyQualifiedName~MyProperty' --logger 'console;verbosity=detailed'
```

`threads: 1` makes sequential demonstrations easier to follow. It does not reproduce external races,
and is not a replacement for the concurrency settings of a `SampleParallel` test. A seed controls
CsCheck choices, not network scheduling, wall-clock timing, or a hidden random generator.

For PowerShell, set `$env:CsCheck_Seed`, `$env:CsCheck_Iter`, and `$env:CsCheck_Threads` before the test,
remove `$env:CsCheck_Time`, and restore or remove those settings afterward so the next discovery run
is not accidentally constrained. Other test runners have different filtering and environment switches;
keep their native invocation rather than copying xUnit's filter blindly.

## Preserve the counterexample

A seed identifies a generated case for a particular generator composition and library version. Reordering
generator choices, changing command weights, or changing the initial-state generator can change the
meaning of the same seed. After such changes, retain concrete inputs as an ordinary regression test.
Keep the generated property too; the fixed regression checks one example while generation explores more.

Use CsCheck's own diagnostics and `writeLine:` output integration. Prefer a short named rule and relevant
before/after values over a giant object dump. Do not add a second minimizer unless there is a demonstrated
capability missing from the native shrinker. Do not promise a globally minimal counterexample from a
bounded random shrinking run.

## Demonstrate that a test detects the bug

For a before/after comparison, use separate worktrees or disposable checkouts. Keep test sources and
inputs equivalent, adapting only unavoidable interface differences. Record both production revisions.
Run the negative control against the known-broken runtime and the positive control against the fixed one.

Require an actual behavioral failure: a missing SDK, compile error, fixture startup failure, timeout in
the test process, or zero discovered tests is not detection of the product bug. Inspect the shrunk trace
and assertion. A self-consistent `Spec.Exhaustive` result does not substitute for failing SUT conformance.

For a video, show unseeded discovery first, then use the emitted seed for repeatable takes. Label which
run is discovery and which is replay. If opening an intentionally failing demo PR, use a historical base
or explicitly check out the historical test head: GitHub's synthetic merge against current `dev` can
silently reintroduce the fixes. Keep the demo separate from the production fix PR and identify it as a
demonstration rather than a merge candidate.

These verification patterns do not authorize pushing branches or opening PRs on their own; perform
external actions only within the user's requested task.

## Reading the examples in this skill

Each `csharp` block in the other references is a complete xUnit test class using C# 12, implicit .NET
usings, and CsCheck 4.9.1. Place them in an existing compatible test project. In a disposable project,
`dotnet new xunit --framework net8.0` and `dotnet add package CsCheck --version 4.9.1` provide a minimal
validation environment. Run `dotnet test -c Release` and require discovered test counts.

The wallet's model-fault test is expected to pass because it asserts the injected defect is caught.
Separately removing the implementation's debit must make its conformance test fail. The sorting property
should reject an implementation that returns zeroes instead of preserving the generated elements.
These checks test the strength of the examples rather than their formatting.

Sources: [native controls and runners](https://github.com/AnthonyLloyd/CsCheck/blob/50503557f23266f140021f65632612ceb4ac248f/CsCheck/Check.cs),
[versioned package](https://www.nuget.org/packages/CsCheck/4.9.1).
