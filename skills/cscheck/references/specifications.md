# Executable specifications

## Model behavior, then check the implementation

Use a native `Spec` when a small pure state machine can express the contract independently of the
implementation. Actions define the legal attempts and transitions; named requirements state what must
hold. CsCheck explores action orderings. Supplying finite argument domains does not prewrite the traces.

Keep model state immutable with equality that reflects the logical state. Scalar records work well.
A record containing a mutable list or an array does not automatically provide immutable, structural
collection equality. Avoid cumulative traces, ever-increasing identifiers, or wall-clock timestamps in
a supposedly finite state space. Bound or abstract them only when that preserves the property in scope.

The example below describes a wallet bounded to three units. Deposits are restricted to those that fit;
withdrawals are always attempted so insufficient-funds rejection remains testable. Amounts `[1, 2]`
allow both exact and insufficient withdrawals. This scope does not test overflow deposits or arbitrary
currency arithmetic.

```csharp
using CsCheck;
using Xunit;
using Xunit.Abstractions;

public sealed class WalletSpecification(ITestOutputHelper output)
{
    private static readonly int[] Amounts = [1, 2];
    private sealed record State(int Balance = 0, int Requested = 0, bool Accepted = false);

    private static Spec<State> Create() => Spec.From(new State())
        .Action("Deposit", Amounts, (s, amount) => s.Balance + amount <= 3,
            (s, amount) => new State(s.Balance + amount, amount, true))
        .Action("Withdraw", Amounts, (s, amount) =>
            s.Balance >= amount
                ? new State(s.Balance - amount, amount, true)
                : new State(s.Balance, amount, false))
        .Invariant("BoundedBalance", "The balance stays between zero and capacity.",
            s => s.Balance is >= 0 and <= 3)
        .Rule("DepositAdds", "An accepted deposit adds its amount.", on: "Deposit",
            then: (before, after) => after.Accepted && after.Balance == before.Balance + after.Requested)
        .Rule("WithdrawalDebits", "A funded withdrawal succeeds and subtracts its amount.", on: "Withdraw",
            when: (before, after) => before.Balance >= after.Requested,
            then: (before, after) => after.Accepted && after.Balance == before.Balance - after.Requested)
        .Rule("InsufficientFunds", "An unfunded withdrawal is rejected without changing the balance.", on: "Withdraw",
            when: (before, after) => before.Balance < after.Requested,
            then: (before, after) => !after.Accepted && after.Balance == before.Balance)
        .Reachable("CanFill", "The wallet can reach capacity.", s => s.Balance == 3);

    [Fact]
    public void Model_requirements_hold_and_are_exercised()
    {
        var report = Create().Exhaustive(out var violation, writeLine: output.WriteLine);
        Assert.Null(violation);
        Assert.True(report.Closed);
        Assert.Equal(0, report.DeadlockStates);
        Assert.Empty(report.NeverTriggered);
        Assert.Empty(report.NeverFired);
    }

    [Fact]
    public void Implementation_conforms()
    {
        Create().Conform(
            create: () => new Wallet(),
            apply: (wallet, step) =>
            {
                var amount = Amounts[step.ArgIndex];
                switch (step.Action)
                {
                    case "Deposit":
                        wallet.Deposit(amount);
                        break;
                    case "Withdraw":
                        var accepted = wallet.TryWithdraw(amount);
                        if (accepted != step.After.Accepted)
                            return $"Withdraw({amount}): expected accepted={step.After.Accepted}, got {accepted}";
                        break;
                    default:
                        throw new InvalidOperationException(step.Action);
                }
                return wallet.Balance == step.After.Balance ? null :
                    $"{step.Action}({amount}): expected balance {step.After.Balance}, got {wallet.Balance}";
            }, writeLine: output.WriteLine);
    }

    [Fact]
    public void Requirements_detect_a_missing_debit()
    {
        Create().Fault("successful withdrawal forgets debit", on: "Withdraw",
            when: (before, after) => before.Balance >= after.Requested,
            perturb: (before, after) => after with { Balance = before.Balance })
            .Faults(writeLine: output.WriteLine);
    }

    // A separate implementation, never used to compute the expected state.
    private sealed class Wallet
    {
        public int Balance { get; private set; }
        public void Deposit(int amount) => Balance += amount;
        public bool TryWithdraw(int amount)
        {
            if (amount > Balance)
                return false;
            Balance -= amount;
            return true;
        }
    }
}
```

For a real system, replace `Wallet` with its public interface and keep the model independent. The adapter
uses the generated action and argument, then compares the actual reply and observable state. Merely
returning `true` from `apply` after calling the SUT would test no conformance. Do not set the SUT to
`step.After` to make the comparison pass.

`Create()` returns a fresh builder: CsCheck freezes a Spec after it is run. Keep the transition functions
pure; they must not inspect a captured live application or share mutable state with another trace.

## What each run establishes

| API | Evidence | Limit |
| --- | --- | --- |
| `Exhaustive` | Explores reachable model states and requirements | A closed search proves only the modeled domain and assumptions. |
| `Sample` | Randomly explores the model when exhaustive search is impractical | No observed failure is not exhaustive proof. |
| `Faults` / `SampleFaults` | Injects declared model-transition defects and checks which requirements detect them | Does not mutate or prove sensitivity to all production defects. |
| `Conform` | Drives the real object along generated model traces | Checks only the observations compared by the adapter on those traces. |

Check `Closed` before making an exhaustive claim. Hitting a state/depth limit is an incomplete search.
Inspect `NeverTriggered` and `NeverFired` rather than counting a rule as covered because it exists.
Define `.Terminal(...)` when an actionless state is an intended end; otherwise deadlock reports can
expose a missing transition. `.Reachable(...)` helps detect models whose guards exclude useful behavior.
Do not require random runs to hit every rare branch unless their budget and domain make that reliable.

The fault example is a positive test of the specification: it passes when CsCheck catches the planted
model defect. To show the *implementation* test is sensitive, independently break `Wallet.TryWithdraw`
in an isolated copy (for example, omit the subtraction) and confirm `Implementation_conforms` fails
with an actual divergent trace. Restore that change afterward.

## Guards, rules, and time

- `Action` guards are generation-time preconditions. Keep an action enabled when the expected outcome
  is a meaningful rejection, duplicate acknowledgement, absent-key result, or other contract response.
- `Rule` checks a before/after transition, optionally for a named action and a `when` condition.
  Put the triggering condition on the cause, not on the success outcome whose correctness is in question.
- `Invariant` checks states. It complements action-specific postconditions, which can explain why a
  balance changed or a reply was rejected.
- `Response` is a bounded obligation over subsequent steps. In 4.9.1, `within` counts steps, or occurrences
  of the action named by `per:`. It is not milliseconds. A response on the triggering step itself needs
  a `Rule`; it does not discharge a `Response` obligation. A `per: "Tick"` claim assumes ticks recur and
  does not prove that the environment keeps ticking.

If a time-advance action can jump by several seconds, counting that action once is not elapsed-time
verification. Model the relevant clock or use a fixed tick quantum and state its units and limits.
Avoid unbounded absolute time in a finite-state claim; use a justified finite abstraction.

## When native Conform does not fit

In the verified 4.9.1 API, argument domains for `Action` are finite arrays. `Conform` generates the pure
model trace before executing the implementation, and its `apply` callback is synchronous. There is no
native async apply or per-trace disposal callback in that API. Check newer installed versions before
assuming these limitations still apply.

If several observable outcomes are allowed, first consider whether a finite independent model can
express them. If expectations must incorporate actual delivery order, fault activation, or ambiguous
commit outcomes, do not disguise application mutation as a pure transition. Use the
[async command property](stateful-and-async.md) with explicit observation checks and per-case cleanup.
Do not copy a blocking `GetAwaiter().GetResult()` adapter into ordinary async tests just to retain the
Spec label. A carefully isolated synchronous bridge is a specific integration tradeoff, not the default.

API source: [Spec.cs](https://github.com/AnthonyLloyd/CsCheck/blob/50503557f23266f140021f65632612ceb4ac248f/CsCheck/Spec.cs).
