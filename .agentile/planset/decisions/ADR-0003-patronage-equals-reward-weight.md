# ADR-0003 — Patronage = compute × data-quality (reuse nat-federated reward_weight)

**Status:** accepted · **Date:** 2026-06-25 · **Program:** RFC-CIT-COOP-0001

## Context
The co-op must score "work added" to allocate both the patronage dividend and the CRP
emission. NAT's federated layer already computes exactly this signal
(`StepContribution.reward_weight() = compute_metered × data_quality`) per verified round and
commits an order-independent `merged_hash` on-chain.

## Decision
**A member's patronage unit = `compute_metered × data_quality`, recorded per verified round,
bound to that round's on-chain `merged_hash`.** Governance weights `wCompute`/`wData` let the
balance be retuned without a contract change. "Relative to the pool" is realized because every
distribution is pro-rata `units[m] / totalUnits`.

## Rejected
- A new bespoke scoring formula in the co-op — would diverge from the settled federated signal
  and split the audit surface (cf. NAT ADR-0007: NAT scores, the chain settles).
- Equal per-member allocation — ignores work; not patronage-faithful.

## Why
One settlement action then drives both surfaces: the same `reward_weight` that pays immediate
SALT (via `LearningCycleManager`) mints co-op patronage. Anchoring to `merged_hash` makes
equity provable — an auditor replays the round.

## Seam
`recordContribution(roundId, member, computeMetered, dataQualityBps)` is callable only by
`SETTLER_ROLE` (the federation coordinator) and only after `commitRound(roundId, mergedHash)`.
Idempotent per `(roundId, member)`.

## Compliance check
- [x] Provenance binding modeled (feature `coop_patronage`: "anchored to a verified round")
- [x] Zero-quality ⇒ zero patronage (mirrors NAT `zero_quality_yields_zero_weight`)
- [ ] Join with NAT Gate-4 federated orchestrator (gate4 g4-settler)
