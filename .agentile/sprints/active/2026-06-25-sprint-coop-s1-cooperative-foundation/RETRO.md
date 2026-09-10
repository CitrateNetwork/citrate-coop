---
created: 2026-06-25T21:00:00Z
branch: feat/coop-s1-cooperative-foundation
author: saul
sprint: COOP-S1
status: ready-for-audit
---

# RETRO — COOP-S1: Cooperative Foundation

## Outcome

| WP | Title | Status | Evidence |
|----|-------|--------|----------|
| WP-0 | TLC-verify the four specs | ✅ Done | `scripts/run-tlc.sh` green (4/4, `-deadlock`); CI `formal` job |
| WP-1 | MembershipSBT (membership rail) | ✅ Done | `MembershipSBT.t.sol` (9) green |
| WP-2 | PatronageLedger (patronage rail) | ✅ Done | `PatronageLedger.t.sol` (9) green |
| WP-3 | ModelCooperative + dividend | ✅ Done | `ModelCooperative.t.sol` (8) + `invariant/DividendConservation.t.sol` (3) green |
| WP-4 | Revenue rails A (owner-pay) + B (x402) | ✅ Done (mocks) | `RevenueRouting.t.sol` (4) green — faithful mocks; **live-fork test carried forward** |
| WP-5 | ContributionRewardPool (fixed-cap emission) | ✅ Done | `ContributionRewardPool.t.sol` (7) green |
| WP-6 | CooperativeGovernor (1-member-1-vote) | ✅ Done | `CooperativeGovernor.t.sol` (9) green |
| WP-7 | CooperativeFiatRamp (rail C) | ◑ On-chain done; **off-chain custodian gated** | `CooperativeFiatRamp.t.sol` (4) green; needs licensed MSB |
| WP-8 | nat-federated Settlement seam | ◑ On-chain seam done; **Rust impl gated on NAT Gate-4** | `FederatedSettlement.t.sol` (3) green; `SETTLEMENT_SEAM.md` |
| WP-9 | CitrateCooperativeFactory + deploy | ✅ Done | `CitrateCooperativeFactory.t.sol` (3) green |

**Goal: met for all buildable scope.** All seven contracts compile, deploy via the factory, and are
green against the four TLA+ specs and six Gherkin features. The two blocked WPs (7, 8) have their
*on-chain* halves implemented and tested; only the off-chain dependencies (MSB custodian, NAT Gate-4
orchestrator) are carried forward, exactly as scoped at kickoff.

## Metrics delta

| Metric | Start | End | Δ |
|--------|-------|-----|---|
| Foundry tests | 0 | **59** (10 suites: unit + fuzz + invariant) | +59 |
| TLC-green specs | 0 | **4** (`CoopLifecycle`, `PatronageDividend`, `MembershipVoting`, `ContributionRewardPool`) | +4 |
| Foundry invariants | 0 | **4** (`invariant_solvent`, `invariant_balance_is_credited_minus_claimed`, `invariant_revenue_conserved`, `invariant_total_cap`) | +4 |
| Contracts shipped | 0 | **7** + factory + 2 lib | +10 src files |
| CI tripwires | 0 | **1 workflow, 2 jobs** (`formal` TLC + `forge` suite) | +1 |
| ADRs | 0 | 6 | +6 |
| Journals / essays / case studies | 0 | 2 / 1 / 1 | +4 |

## What went right

- **Specs-first paid off twice.** Writing all four TLA+ specs and six features before any Solidity
  meant each WP turned a *pre-agreed* slice RED→GREEN. No design drift mid-sprint.
- **The two-rail invariant held under the hard case.** The kickoff RETRO seed asked: does
  membership/patronage separation survive the governor acting as model owner? It did — `onlyGovernance`
  (governor OR self) routes every privileged call through `execute()` uniformly, and neither rail
  imports the other's state. The separation is enforced by *missing imports*, not discipline.
- **Invariant tests caught a real bug the spec couldn't see** (see below). The cost of catching it
  pre-merge was ~20 minutes; the cost of shipping it was a contract that reverts for the last claimant.

## What went wrong (and the lesson)

- **The one-wei over-accrual.** TLC was green, but the Solidity dividend accumulator let summed
  pending exceed the treasury by 1 wei because I stored MasterChef `rewardDebt` *post-division*.
  Caught by `invariant_solvent` on fuzz run 339. Fix: store debt pre-division, floor the difference
  once. Full autopsy: `.agentile/docs/case_studies/2026-06-25T2100_one-wei-overaccrual.md`. **Lesson:
  TLA+ proves the state machine; only a property test over real integers proves the arithmetic. Ship
  both.**
- **A governance/reentrancy clash surfaced late.** A `dissolve()` proposal routed `execute`
  (nonReentrant) → `dissolve` (also nonReentrant) → false reentrancy revert. Fix: drop nonReentrant
  from `dissolve` (CEI + terminal state set before the single transfer). Lesson: guard at the entry
  point, not redundantly on internal terminal actions reachable through it.

## Carry-forward (audit + follow-on sprints)

1. **Counsel gate (g1-counsel)** — securities/co-op characterization review before any mainnet deploy.
2. **WP-4 live-fork test** — rail A is proven against faithful mocks of `ModelRegistry`/`ModelMarketplace`
   pay-out behavior; add a `--fork-url` test against the live contracts to close the fork AC verbatim.
3. **WP-7 MSB custodian** — engage a licensed money-services custodian for the Stripe/Plaid → wSALT leg.
4. **WP-8 Rust `Settlement` impl** — gated on NAT Gate-4 orchestrator; on-chain seam is ready.
5. **Pool SALT escrow** — governance approval to fund `ContributionRewardPool`.
6. **Proposed federation tripwire** — semgrep rule for the post-division-debt smell (case study §Enforcement).

## Verification at close

- `./scripts/run-tlc.sh` → 4/4 specs, 0 invariant violations.
- `forge test` → 59 passing across 10 suites (unit + fuzz + invariant).
