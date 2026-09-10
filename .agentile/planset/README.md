---
created: 2026-06-25T00:00:00Z
branch: main
author: saul
status: active
---

# Planset — RFC-CIT-COOP-0001 · Citrate Model Cooperative

The on-chain ownership layer that makes a community-trained NAT model a
**collectively-owned, revenue-bearing California Cooperative Corporation**. This
planset is the agentile recasting of the design doc
[`COOP_OWNERSHIP_CONTRACT_SPEC.md`](../../COOP_OWNERSHIP_CONTRACT_SPEC.md) (v2),
driven the agentile way: **TLA+ → Gherkin → planset/sprint → failing tests → code →
refactor → retro/journal**.

## The thesis

A trained model is a co-op asset. Two **strictly separated rails** mirror California
cooperative law (Corporations Code §12200+; Worker Cooperative Act, AB 816):

- **Membership rail (governance)** — a soulbound `MembershipSBT`, **one member, one
  vote**, one token per KYC identity, worker-members hold ≥51%, delegable to
  representatives via commit-reveal liquid democracy.
- **Patronage rail (economics)** — non-transferable patronage units = `compute ×
  data-quality` (relative to the pool), driving the **patronage dividend** (model
  revenue) and the **SALT Contribution Reward Pool** (a fixed fraction of supply,
  equal annual tranches over a multi-year schedule, by-year, linear vest, reserve skim).

More contribution never buys more votes; more votes never earn more dividend. That
separation is both legally required and the load-bearing design invariant.

## Where the work lives (agentile artifact map)

| Layer | Location | Drives |
|-------|----------|--------|
| **Formal (TLA+)** | `specs/tla/coop/*.tla` + `.cfg` | the invariants every test and contract must satisfy |
| **Acceptance (Gherkin)** | `features/*.feature` | the BDD scenarios, each tracing to a TLA invariant |
| **Gates** | `.agentile/planset/gates.yaml` | machine-readable exit criteria G1–G5 |
| **Decisions** | `.agentile/planset/decisions/ADR-*.md` | the six load-bearing choices |
| **Sprint** | `.agentile/sprints/active/.../SPRINT.md` | WP decomposition + Rule-11 acceptance |
| **Tests (RED)** | `contracts/test/*.t.sol` | failing tests that the code must turn green |
| **Design doc** | `../../COOP_OWNERSHIP_CONTRACT_SPEC.md` | full prose architecture (v2) |

## Formal specs ↔ features ↔ gates

| TLA+ module | Verifies | Feature | Gate criterion |
|-------------|----------|---------|----------------|
| `CoopLifecycle.tla` | phase machine, contribution/revenue gating | (cross-cutting) | g2-lifecycle |
| `MembershipVoting.tla` | one-seat/identity, worker ≥51%, vote conservation, commit-reveal | `coop_membership`, `coop_governance` | g2-membership, g3-governor |
| `PatronageDividend.tla` | dividend conservation, no-retroactive, claim bound | `coop_patronage`, `coop_revenue_dividend` | g2-patronage, g3-dividend |
| `ContributionRewardPool.tla` | hard cap, cohort cap, reserve conservation, vest bound | `coop_reward_pool` | g3-crp |

## Gate ladder

1. **G1 Theory locked** — TLA+ TLC-green, Gherkin written, ADRs, counsel review. *(partial: specs drafted, TLC + counsel pending)*
2. **G2 Two rails** — MembershipSBT + PatronageLedger green; two-rail separation proven.
3. **G3 Revenue/emission/governance** — dividend, CRP, governor, revenue rails A/B.
4. **G4 Federated join + live wiring** — settler seam to nat-federated (gated on NAT Gate-4); fiat rail C; owner-wire on fork.
5. **G5 Productize** — factory, audit, counsel sign-off, mainnet.

## Composition (reuse, don't reinvent)

Builds on live citrate-chain contracts: `KYCRegistry` (isVerified/identityOf),
`ModelRegistry` + `ModelMarketplace` (owner-pay revenue, zero change), `LoRAFactory`,
`ComputePoolTraining`, `TreasuryGovernor` (pattern), `WrappedSALT` + `X402Facilitator`
/`X402Paywall` (EIP-3009), `StablecoinTreasury` + `ComputePricingOracle` (fiat→SALT),
`IPFSIncentivesV3` (the commit-reveal/prevrandao precedent), `AgentDecisionRegistry`.

## Critical path

WP-1..6 build **now** against live contracts. WP-7 (fiat ramp) needs a licensed MSB
custodian. WP-8 is the join with the NAT federated orchestrator — where patronage
minting meets the real multi-node training run (see master brief §4.3).
