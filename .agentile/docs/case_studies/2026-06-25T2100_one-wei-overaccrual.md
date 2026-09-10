---
created: 2026-06-25T21:00:00Z
branch: feat/coop-s1-cooperative-foundation
author: saul
status: accepted
sprint: COOP-S1
---

# Case study: the one-wei over-accrual

> A TLC-green dividend spec still shipped an insolvency bug, because the spec proved the algebra and the arithmetic lived one layer down.

## TL;DR

`PatronageDividend.tla` was TLC-green: conservation, no-retroactive, claim-bounded — all
invariants held across 2,892 states. The Solidity implementation of the same accumulator
nonetheless let members' summed pending dividends exceed the treasury by **1 wei**, which would
revert the last claimant. A Foundry invariant test caught it on run 339. Root cause: I stored the
MasterChef `rewardDebt` *after* dividing by the accumulator scale, so `floor(a) − floor(b)` could
exceed `floor(a − b)`. Fix: store debt *pre-division* and floor the difference once. Cost: ~20
minutes, caught pre-merge. Lesson: **the spec proves the state machine; only a property test over
real integer arithmetic proves the arithmetic.** Both layers are load-bearing.

## What happened

The patronage dividend uses the standard accumulator pattern: `accDividendPerUnit` rises on each
revenue event; a member's claimable is `units · acc − debt`, with `debt` reset on every unit change
so late joiners earn nothing retroactively. The TLA+ model proved exactly this — but it modelled
token amounts as naturals and *constrained revenue to be divisible by `totalUnits`* so the per-unit
share was exact. That abstraction is legitimate for proving the **shape** of the accumulator. It
also quietly assumed away the one thing that bites in Solidity: integer division dust.

In the implementation I wrote `dividendDebt[m] = units[m] * acc / ACC` (post-division). Then
`accrued = units[m] * acc / ACC − dividendDebt[m]` is `floor(units·acc_now/ACC) −
floor(units·acc_old/ACC)`, which can be **1 greater** than the true incremental floor
`floor(units·(acc_now−acc_old)/ACC)`. Summed across members and revenue events, members believed
they were collectively owed a wei or two more than the contract held. The last person to claim would
hit `transfer` with insufficient balance and revert — a liveness failure, and a bad look (a
co-op that can't pay its final member).

## How it was caught

Not by the unit tests — they used round numbers that divided evenly (the same blind spot the spec
had). It was caught by `invariant_solvent` in `DividendConservation.t.sol`: a stateful fuzz handler
that fires random `addPatronage` / `deposit` / `claim` sequences and asserts, after every call,
`salt.balanceOf(coop) >= Σ pendingDividendOf(member)`. Run 339, shrunk to 14 calls, produced the
counterexample: `2766164269049057438718975 < 2766164269049057438718976`. One wei.

## The fix

Store debt pre-division and floor the difference exactly once:

```solidity
// before (over-accrues by up to 1 wei per reset):
dividendDebt[m] = units[m] * accDividendPerUnit / ACC;
accrued = units[m] * accDividendPerUnit / ACC - dividendDebt[m];

// after (exact floor of the incremental share):
dividendDebt[m] = units[m] * accDividendPerUnit;          // PRE-division
accrued = (units[m] * accDividendPerUnit - dividendDebt[m]) / ACC;
```

Now `accrued = floor(units·(acc_now − acc_old)/ACC)`, and `Σ accrued ≤ floor(totalUnits·Δacc/ACC) ≤
credited` — dust rounds *down*, stays stuck in the contract, and solvency holds with margin.

## The generalizable lesson

This is not a co-op bug; it is a **formal-methods seam** bug. TLA+ verifies state-machine
properties (ordering, conservation-as-algebra, reachability). It does **not** verify fixed-point
integer arithmetic — and worse, the act of making a spec tractable (divisible amounts, naturals
instead of `uint256/ACC`) is exactly where the arithmetic gets abstracted away. The spec is not
wrong; it is answering a different question. The implementation needs a *second* proof obligation —
a property/invariant test over real integers — that the spec by design cannot discharge.

Two layers, two questions:
- **TLA+** — "is the state machine correct?" (here: yes, 2,892 states).
- **Foundry invariant** — "is the arithmetic that implements it correct?" (here: no, until the fix).

Neither subsumes the other. A team that trusts a green spec and skips the property test ships this
bug; a team that fuzzes without a spec never knows whether "no counterexample in 256 runs" means
"correct" or "untested path."

## Enforcement surface (so it can't recur)

1. **Invariant retained**: `invariant_solvent` + `invariant_balance_is_credited_minus_claimed` stay
   in the suite and in CI (`.github/workflows/ci.yml`), re-run on every change to the ledger.
2. **Lint candidate** (proposed `scripts/semgrep/` rule for the federation): flag the pattern
   `<x> = <a> * <b> / <SCALE>` stored as a *debt/checkpoint* variable that is later subtracted from
   another `* / SCALE` term — the post-division-debt smell. Reward-accumulator math should store the
   debt pre-division.
3. **Review checklist line** for any accumulator/dividend contract: "Is `rewardDebt` stored
   pre-division? Is there a solvency invariant test with a stateful fuzz handler?"

## Cost

~20 minutes (diagnose + one-line fix + rerun). Caught pre-merge, on a branch, by a test written in
the same sprint. The counterfactual — shipping it — is a contract that reverts for the last claimant
of every fully-claimed round, discovered in production by the unluckiest member.
