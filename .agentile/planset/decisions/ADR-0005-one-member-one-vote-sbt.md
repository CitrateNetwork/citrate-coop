# ADR-0005 — One-member-one-vote via soulbound SBT, commit-reveal ballot, delegation

**Status:** accepted · **Date:** 2026-06-25 · **Program:** RFC-CIT-COOP-0001

## Context
Governance must be democratic (AB 816), Sybil-resistant, secret enough to resist coercion/
vote-buying, and easy to delegate. The chain has no governance randomness primitive — but
`IPFSIncentivesV3` already uses `block.prevrandao` in a **commit-reveal** challenge (sealed
nonce, revealed after `REVEAL_DELAY`) to stop proposer frontrunning.

## Decision
**Governance is one-member-one-vote over a soulbound `MembershipSBT` (one per KYC identity),
with commit-reveal secret ballots reusing the `IPFSIncentivesV3` prevrandao pattern, and liquid-
democracy delegation to representatives.** The SBT carries a registry of the project's `agentId`s
and `modelId`s. Optional prevrandao **sortition** can elect a rotating representative council.

## Rejected
- SALT/stake-weighted voting — violates ADR-0001/ADR-0002 (capital ≠ control).
- Plain open-ballot voting — exposes members to coercion and bandwagon effects.
- A new VRF for governance — the chain's commit-reveal prevrandao precedent already exists; reuse it.

## Why
Commit-reveal gives ballot secrecy with an in-house, audited randomness pattern. Delegation must
not inflate votes: each member's single vote is attributed to exactly one caster (self or rep),
proven by `MembershipVoting.tla::Inv_VoteConservation`. Worker-members keep ≥51% (`Inv_WorkerControl`).

## Seam
`MembershipSBT` (ERC-5192) + `CooperativeGovernor` (commit/reveal, delegate/undelegate). Community
investors get approval-only votes (AB 816). Timelock + decaying guardian veto during Forming.

## Compliance check
- [x] One vote/member, one SBT/identity (TLA)
- [x] Commit-reveal integrity: reveal needs prior commit (`Inv_RevealNeedsCommit`)
- [x] Delegation conserves votes (`Inv_VoteConservation`)
