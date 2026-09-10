# ADR-0004 — SALT Contribution Reward Pool; no founder equity

**Status:** accepted · **Date:** 2026-06-25 · **Program:** RFC-CIT-COOP-0001

## Context
The convening company wanted no special equity. Contributors need an upfront-ish reward beyond
the residual dividend, and the co-op needs an operating reserve / flywheel fuel.

## Decision
**Dedicate a fixed fraction of the SALT supply as a Contribution Reward
Pool**, released **in equal annual cohorts over a multi-year schedule**, each annual cohort allocated by **that year's
patronage** and **linearly vested**. A governance-set `reserveBps` is
skimmed from each cohort into the co-op **reserve** — so the reserve comes out of the pool itself.
**The company takes no equity.**

## Rejected
- Founder/sponsor equity allocation — owner deemed it irrelevant; would also concentrate
  patronage and muddy the worker-co-op posture.
- Reserve skimmed from model revenue — keeps the patronage-dividend rail clean for Subchapter T;
  reserve is funded from the emission instead.

## Why
The emission rewards contribution on the same patronage basis as the dividend (one scoring
rail), funds the flywheel (reserve → next training round via `ComputePoolTraining`), and avoids
any capital-class that would trip securities/Subchapter-T treatment. (Specific pool size, annual tranche, and reserve fraction redacted for public release.)

## Consequences
- **Positive:** predictable multi-year incentive; reserve fuels self-sustaining training; no
  capital-control class.
- **Negative:** the pool must be sourced/escrowed at program start — a treasury/governance action
  recorded on-chain. Hard cap enforced (`ContributionRewardPool.tla` `Inv_TotalCap`).

## Compliance check
- [x] Hard cap + per-cohort cap + reserve conservation modeled (TLA)
- [x] Linear vest bounded (`Inv_VestBounded`)
- [ ] Pool allocation source/escrow approved by governance
