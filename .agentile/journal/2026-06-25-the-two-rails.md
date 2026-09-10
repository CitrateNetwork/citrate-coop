---
created: 2026-06-25T00:00:00Z
branch: feat/coop-s1-cooperative-foundation
author: saul
sprint: COOP-S1
type: journal
wps: [WP-1, WP-2]
---

# Journal — the two rails go green

## What I did
Implemented the membership rail (`MembershipSBT`) and the patronage rail (`PatronageLedger`)
RED→GREEN against the Gherkin features and the TLC-green TLA+ specs. 18 tests pass (9 each,
including fuzz). Added a tiny dependency-free `Auth`/`ReentrancyGuard` lib rather than pull OZ.

## What the specs forced
- **`MembershipVoting.tla::Inv_WorkerControl`** made me put the worker-majority check *inside*
  `mint`, computed on the post-admission counts, not as an afterthought. The contract enforces
  the stricter **≥51%** (AB 816); the TLA models the ≥50% safety floor, so the implementation is
  a strict subset of what the spec permits — exactly the right direction.
- **`PatronageDividend.tla`** is why the dividend accumulator lives *in* `PatronageLedger`
  next to `units`, not in the cooperative: every unit mutation must `_settle` first or the
  no-retroactive property breaks. Co-locating units + `accDividendPerUnit`/`debt` is the
  whole trick. Splitting them across contracts would have re-introduced the bug the spec rules out.

## A fork I hit
Should `PatronageLedger` own the SALT and do dividend transfers, or stay pure accounting? I let
the spec decide: the conservation invariant is about *accounting*, not custody. So the ledger is
pure accounting (`recordClaim` returns the owed amount); the cooperative (WP-3) holds the treasury
and does the transfer + KYC re-check. Custody in one place, accounting in another — smaller blast
radius, and the ledger needs no token approvals.

## Two-rail separation, concretely
`MembershipSBT` has no notion of patronage; `PatronageLedger` has no notion of votes. They share
only the KYC registry. ADR-0001 is therefore true by construction, not by convention — there is no
code path from one rail's state to the other's.

## Next
WP-3 `ModelCooperative` wires the lifecycle state machine + treasury + `notifyRevenue` into the
ledger's accumulator, and is where the Foundry *invariant* test for revenue conservation lands
(mirroring the TLA conservation proof at the Solidity level).
