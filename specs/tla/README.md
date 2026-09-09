# TLA+ Spec Index — RFC-CIT-COOP-0001

Run with `../../scripts/run-tlc.sh` (TLC). Each module mirrors a contract state machine and
is the formal driver for the matching Gherkin feature + Foundry tests (COOP-S1 WP-0).

| Module | Mirrors | Key invariants | Feature(s) | Gate |
|--------|---------|----------------|------------|------|
| `coop/CoopLifecycle.tla` | `ModelCooperative` phase machine | forward-only phases; contribution window closes at wind-down; no revenue before Active | (cross-cutting) | g2-lifecycle |
| `coop/PatronageDividend.tla` | `accDividendPerUnit`/`debt`/`pending` | `Inv_Conservation`, `Inv_NoRetroactive`, `Inv_ClaimedBounded` | `coop_patronage`, `coop_revenue_dividend` | g2-patronage, g3-dividend |
| `coop/MembershipVoting.tla` | `MembershipSBT` + `CooperativeGovernor` | `Inv_OneSeatPerIdentity`, `Inv_WorkerControl`, `Inv_VoteConservation`, `Inv_RevealNeedsCommit` | `coop_membership`, `coop_governance` | g2-membership, g3-governor |
| `coop/ContributionRewardPool.tla` | `ContributionRewardPool` (50M) | `Inv_TotalCap`, `Inv_CohortCap`, `Inv_ReserveConservation`, `Inv_VestBounded` | `coop_reward_pool` | g3-crp |

**Modeling notes.** Token amounts are scaled down (Annual=10 ≈ 10M SALT, total 50 ≈ 50M).
`PatronageDividend` constrains revenue to amounts divisible by current `totalUnits` so the
integer model is exact; Solidity keeps the remainder as dust favoring the pool (a safe
strict-superset). Linear vesting is abstracted to `claimed ≤ grant`; the time-proportional
schedule only tightens it.

When TLC-green, record state counts in `.agentile/planset/gates.yaml` g1-formal (as NAT does).
