# ADR-0006 — On-chain revenue routing via three rails (SALT, x402, fiat)

**Status:** accepted · **Date:** 2026-06-25 · **Program:** RFC-CIT-COOP-0001

## Context
Model revenue arrives through different channels and must all reach the co-op treasury and
become patronage dividends, on-chain. The owner wants on-chain routing with an x402 path and
traditional card/ACH ramps (Stripe + Plaid).

## Decision
**Three revenue rails converge on `ModelCooperative.notifyRevenue` → patronage dividend:**
- **Rail A (on-chain SALT):** set the co-op as the model/listing `owner`. `ModelRegistry
  .requestInference` pays the owner the full value; `ModelMarketplace.purchaseAccess` pays the
  owner price minus the marketplace fee. **Zero change to those contracts.**
- **Rail B (x402):** route the model resource's x402 provider/treasury to the co-op;
  `X402Facilitator`/`X402Paywall` settle EIP-3009 authorizations via `wSALT
  .transferWithFeeAuthorization` (net→co-op, fee→facilitator).
- **Rail C (fiat):** Stripe (card) / Plaid (ACH) → licensed MSB custodian → signed settlement
  attestation → `CooperativeFiatRamp` converts USD→wSALT via `ComputePricingOracle` (after a
  hold period) → `notifyRevenue`.

## Rejected
- A new on-chain fee-split in `ComputePool` for the inference-gateway path (Option A in the
  design doc) **for v1** — deferred; start with the gateway remitting the model-creator share
  off-chain. Revisit for production.
- Holding fiat off-chain and paying members in fiat — breaks on-chain conservation + auditability.

## Why
Rails A/B need no new core-contract changes and work against live contracts today. Rail C reuses
`StablecoinTreasury` + `ComputePricingOracle` + the `BulkComputeGateway` pattern; only a thin
`CooperativeFiatRamp` adapter and the off-chain custodian are net-new.

## Consequences
- **Positive:** revenue inflow for A/B works immediately on setting ownership; one dividend entry
  point.
- **Negative:** fiat = money transmission → custodian must be a licensed MSB; chargeback/ACH-return
  risk handled by `holdPeriod` + ramp reserve, never clawed back from distributed dividends
  (`coop_revenue_routing` last scenario).

## Compliance check
- [x] Three rails modeled in `coop_revenue_routing.feature`
- [ ] MSB custodian engaged; OFAC screen at fiat intake + at claim (G4 g4-railC, G1 g1-counsel)
