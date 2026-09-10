# ADR-0001 — Membership and patronage are two strictly separated rails

**Status:** accepted · **Date:** 2026-06-25 · **Program:** RFC-CIT-COOP-0001 · **Sprint:** COOP-S1

## Context
A model co-op must do two things that pull in opposite directions: govern democratically
(every member equal) and reward proportionally (those who did more work earn more). Mixing
them — e.g. token-weighted voting — would both violate California cooperative law and let
capital capture governance.

## Decision
**Governance and economics are two separate rails that never read each other's state.**
- **Membership rail:** a soulbound `MembershipSBT`, one per KYC identity, one vote each.
- **Patronage rail:** non-transferable patronage units (`compute × data-quality`) that drive
  dividends and the reward-pool emission, and have **zero** effect on vote count.

## Rejected
- **Share-weighted (ERC-20) governance** — capital captures control; not a cooperative;
  securities-shaped.
- **Single token for both vote and dividend** — couples the two, breaks one-member-one-vote.

## Why
California Cooperative Corporation Law / AB 816 mandate one-member-one-vote and
patronage-based (not capital-based) distribution. The separation is also the cleanest
security model: each rail has a small, independently-auditable state machine
(`MembershipVoting.tla` vs `PatronageDividend.tla`) with no shared variables.

## Consequences
- **Positive:** legal parity by construction; Sybil-resistant economics (splitting addresses
  doesn't multiply contribution); democratic governance immune to whales.
- **Negative:** two ledgers to keep consistent at lifecycle boundaries — mitigated by the
  `CoopLifecycle.tla` guards and shared KYC gating.

## Compliance check
- [x] TLA+: separation is structural (disjoint state across the two specs)
- [x] Rule-12 frontmatter present (in the .md header convention)
- [ ] Counsel parity review (G1 g1-counsel)
