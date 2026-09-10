# ADR-0002 — Legal wrapper is a California Cooperative Corporation (worker co-op, AB 816)

**Status:** accepted · **Date:** 2026-06-25 · **Program:** RFC-CIT-COOP-0001

## Context
On-chain "ownership" of a revenue-bearing model needs a legal home, or residual payments
look like an unregistered securities offering. The owner chose a California Cooperative
Corporation.

## Decision
**Form a California Cooperative Corporation electing worker-cooperative status under AB 816.**
Contributors (who bring compute + data = *work*) are worker-members. Outside capital, if any,
enters only via the AB-816 **community-investor** lane (≤ $1,000 each, no securities
registration, approval-only votes over merger/sale/reorg/dissolution).

## Rejected
| Alternative | Why rejected |
|-------------|--------------|
| Delaware/Wyoming DAO LLC | member-managed but not a true patronage cooperative; weaker fit for "earn by work + residual" |
| C-corp issuing shares | shares = securities; capital controls governance; opposite of the goal |
| Unincorporated association | no liability shield; unclear tax + member rights |

## Why
The cooperative form gives the exact properties the design needs and the owner specified:
one-member-one-vote, **patronage** dividends (not capital returns), Subchapter T pass-through,
worker control (≥51%). Distributions by patronage are materially safer than selling equity.

## Consequences
- **Positive:** the contract mirrors statute (votes, patronage, worker-majority); residuals
  are patronage dividends with 1099-PATR-style records.
- **Negative:** capital returns capped at 15%/fiscal year (CA); community-investor cap
  ($1,000) limits outside funding — acceptable, the CRP funds the program (ADR-0004).

## Compliance check
- [x] One-member-one-vote encoded (`MembershipVoting.tla`)
- [x] Worker ≥51% invariant (`Inv_WorkerControl`)
- [ ] Bylaws ↔ contract parity reviewed by counsel (G1 g1-counsel); MSB review for fiat ramp

## References
- CA Corporations Code §12200+ · AB 816 (2015) · Subchapter T (IRC)
