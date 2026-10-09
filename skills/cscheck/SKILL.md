---
name: cscheck
description: Write and simplify C# property-based, model-based, and executable specification tests with CsCheck. Use for generators, shrinking, stateful command sequences, Spec guards and rules, implementation conformance, or replaying generated failures.
---

# CsCheck

Use CsCheck to explore inputs and action sequences; keep the application's contract visible in the test.
Let the library generate, shrink, print, and replay counterexamples. Start with the smallest test that
can falsify the claim, rather than building a testing framework around CsCheck.

## Choose the test shape

| What needs checking | Start with | Read when needed |
| --- | --- | --- |
| A function, round trip, algebraic law, or data transformation | `Gen` + `Sample` | [Properties and generators](references/properties.md) |
| An implementation with a simpler reference representation | `SampleModelBased` / `SampleModelBasedAsync` | [Stateful and async tests](references/stateful-and-async.md) |
| A protocol or lifecycle with explicit state, guards, and requirements | `Spec.From`, then `Exhaustive` and `Conform` | [Executable specifications](references/specifications.md) |
| Async resources or expectations that must incorporate observed outcomes | Generated command arrays + `SampleAsync`, with cleanup inside each case | [Stateful and async tests](references/stateful-and-async.md) |
| A failing property, seed replay, or a before/after bug demonstration | Native sampling controls and a concrete regression | [Failure discovery and replay](references/failures.md) |

Read only the references needed for the task. These examples use xUnit, but CsCheck itself is test-framework
independent. Preserve the project's existing framework and package-management conventions.

## Establish the contract first

Identify an observable requirement and a plausible wrong result it would reject. Separate generated
inputs, expected behavior, and actual observations. A model may consume observations, but must validate
them against prior expectations before accepting them as new state. Do not use the implementation's
answer to manufacture its expected answer.

Generate **individual operations and their arguments**, allowing CsCheck to compose arbitrary sequences.
Finite domains, weighted boundary values, and preconditions are legitimate modeling choices. Handwritten
whole scenarios are useful regressions, but are not a substitute for exploring action orderings.

Keep rejected requests testable when rejection is part of the contract. A guard saying “only withdraw
when funds exist” cannot test insufficient-funds rejection. Preconditions describe what can be attempted;
postconditions describe the response, including allowed failures.

## Keep the test machinery small

- Prefer composed `Gen` values to `Random`, hand-chosen seed lists, custom shrinkers, or retries-until-green.
- Construct a fresh mutable implementation and model for each generated case, including shrinking.
- Use ordinary records, direct calls, and meaningful comparisons. `equal:` must compare behavior or state;
  cleanup belongs in `finally`/`using`, not an equality predicate that always returns true.
- Keep seeds out of ordinary discovery runs. Replay a seed emitted by a failure, then pin concrete inputs
  when the regression must survive generator changes.
- Preserve domain coverage and historical counterexamples when simplifying. Fewer lines alone do not
  establish that the replacement checks the same behavior.

## Verify the right thing

`Spec.Exhaustive` checks the **model**. `Spec.Conform` checks the real implementation through the adapter
and only for sampled traces and compared observations. Keep both claims explicit. Inspect unreachable
requirements, deadlocks, and search cutoffs; a green run can be vacuous.

When practical, show that the test rejects a known broken implementation or a small deliberate defect
in an isolated copy. Compile and execute examples rather than assuming similarly named FsCheck APIs
exist in CsCheck. Reuse native model-based APIs when their independent transitions and comparison fit;
a custom async loop is a useful alternative, not a universal replacement.

## API baseline

The linked examples were compiled and run with **CsCheck 4.9.1** on .NET 8. Its package identifies
[source revision `5050355`](https://github.com/AnthonyLloyd/CsCheck/tree/50503557f23266f140021f65632612ceb4ac248f).
Check the installed package before adapting signatures. For upgrades, verify the
[NuGet package](https://www.nuget.org/packages/CsCheck) and upstream source; do not infer a major version
or native async `Spec.Conform` support from another library's API.
