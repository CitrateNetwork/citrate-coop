---
created: 2026-06-25T00:00:00Z
branch: feat/coop-s1-cooperative-foundation
author: saul
sprint: COOP-S1
type: journal
wps: [WP-3, WP-5, WP-6]
---

# Journal — economics and governance go green

## What I did
`ModelCooperative` (lifecycle + treasury + dividend), `ContributionRewardPool` (fixed emission), `CooperativeGovernor` (one-member-one-vote). 45 tests green incl. 3
conservation/solvency invariants.

## The bug the invariant caught (worth remembering)
The TLA spec `PatronageDividend.tla` proves conservation *under amounts divisible by
totalUnits* — it abstracts away integer dust deliberately. The Solidity invariant suite did
NOT get to make that assumption, and on run 339 it found a **1-wei over-accrual**: I had
stored `dividendDebt` as `floor(units·acc/ACC)`, so `floor(units·acc_now/ACC) −
floor(units·acc_old/ACC)` could exceed `floor(units·(acc_now−acc_old)/ACC)` by a wei. Summed,
member pending exceeded the treasury — the last claimant would revert. Fix: store debt
**pre-division** (`units·acc`) and floor the difference once. This is the exact MasterChef
lesson, and it's the cleanest example of *why both layers exist*: the spec proves the
algebra, the property test proves the arithmetic. Neither alone would have caught it.

## A governance design fork I resolved
Commit-reveal + liquid-democracy delegation has a soundness hole: if a delegator undelegates
mid-vote and votes while their rep already voted carrying their weight, the vote double-counts
— breaking `Inv_VoteConservation`. Options were (a) snapshot every member's delegate at proposal
creation (expensive), or (b) lock delegation changes while any vote window is open. I let the
invariant drive: conservation must hold *always*, so I took (b) — `lastVotingDeadline` gates
`delegate`/`undelegate`. O(1), sound, and proposals are time-boxed so the lock is bounded. A
representative's weight is then simply `1 + delegatorCount`, and delegators can't vote directly.

## Two-rail separation, now demonstrated not just claimed
`CooperativeGovernor` reads only `MembershipSBT` (memberCount, memberClass) — it never touches
`PatronageLedger`. `ModelCooperative.claimDividend` reads only the ledger — it never reads votes.
ADR-0001 holds by construction: there is no function in either path that reads the other rail.

## Next
WP-4 revenue rails (A owner-pay, B x402) against mocks, WP-9 factory, then the blocked WP-7/8
get honest scaffolds. Then refactor, retro, essay, case study.
