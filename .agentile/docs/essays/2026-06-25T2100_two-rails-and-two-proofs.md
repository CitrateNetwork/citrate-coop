---
created: 2026-06-25T21:00:00Z
branch: feat/coop-s1-cooperative-foundation
author: saul
sprint: COOP-S1
---

# Two rails, two proofs

> "One member, one vote" is not a slogan you bolt onto a token. It is a constraint you refuse to let
> the economics touch.

## Frame

A model-owning cooperative on Citrate has to answer two questions that feel like one and are not:
*who decides?* and *who gets paid?* Every token-governance system I've seen collapses them — your
weight in the vote is your weight in the dividend, both proportional to stake. That collapse is the
original sin of "DAO," and it is illegal for a California cooperative corporation, which by statute
(Corp Code §12200+, AB 816) requires one-member-one-vote and distributes surplus as *patronage* —
proportional to how much you used or worked with the co-op — not as a return on capital.

So COOP-S1 is built on a single architectural commitment: **two rails that never read each other's
state.** This essay is about why that separation is the whole design, and why the same sprint
needed *two kinds of proof* to trust it.

## The membership rail

Governance lives in a soulbound token (`MembershipSBT`, ERC-5192). It is non-transferable, minted
one-per-KYC-identity, and carries a class (Worker / Investor) plus a registry of the `agentId`s and
`modelId`s the member brought to the project. The governor (`CooperativeGovernor`) counts heads, not
balances: `QUORUM_BPS` is a fraction of *members*, a proposal passes on *votes*, and a delegate's
weight is `1 + delegatorCount` — still exactly the votes of real people who chose to stand behind a
representative. There is no `balanceOf` anywhere in the tally. There *cannot* be, or the co-op stops
being one.

Worker-members are held at ≥51% of the roll by an invariant enforced at mint time
(`if (newWorkers * 100 < 51 * newTotal) revert WorkerMajorityViolated();`). That single line is AB
816's worker-control requirement made executable: the community-investor lane can grow, but never
past the point where capital outvotes labor.

## The patronage rail

Economics lives in a completely separate ledger (`PatronageLedger`). Units are minted as
`compute_metered × data_quality` — the same `reward_weight` the NAT federated trainer already
computes off-chain — and surplus flows back as a patronage dividend through a MasterChef
accumulator. Your dividend is a function of work contributed and nothing else. It does not know your
member class. It does not know whether you delegated your vote. It does not know if you voted at all.

This is the part that takes discipline. The temptation, every single time, is to let one rail
"helpfully" read the other: weight the dividend by tenure, gate a vote on minimum contribution,
give founders a governance bonus. ADR-0001 forbids it categorically, and the contracts honor it by
*construction* — `CooperativeGovernor` imports the SBT and never the ledger; the ledger imports
neither the governor nor any balance. The separation is not a convention you have to remember. It is
a missing import.

## Why the law and the software reinforce each other

Here is the part I didn't expect going in. The legal structure and the software invariants are not
two descriptions of the same thing in different languages — they are *load-bearing for each other.*

The co-op statute makes the two-rail separation **mandatory**, which means I cannot be talked out of
it by a clever tokenomics argument; it is not a design preference, it is a compliance boundary. And
the software invariants make the legal structure **enforceable** at machine speed: a California
co-op on paper relies on bylaws and a board to keep capital from capturing governance, but those are
human controls checked annually. The worker-majority invariant checks on *every mint*. The
one-member-one-vote rule is not in a bylaw a court interprets; it is in a tally function that has no
other way to count.

The legal wrapper gives the software its *purpose* (these invariants are not arbitrary — they are
what makes the entity a co-op). The software gives the legal wrapper its *teeth* (the rules execute,
they don't just exist). Neither is decoration on the other.

## Two rails needed two proofs

The same duality showed up in how the sprint was *verified*, which is the thread back to this
sprint's case study. The state machine — forming → active → winding-down → dissolved, who can call
what, conservation of the dividend pool — was proved in **TLA+**. Four specs, TLC-green, thousands
of reachable states explored with zero invariant violations. That proof is real and it is the right
tool for "is the protocol correct."

It is also *not enough*, and the sprint proved that to itself the hard way. The patronage dividend
shipped a one-wei insolvency bug that the TLC model could not see, because the model used divisible
amounts and the bug lived in `uint256` integer division. A **Foundry invariant test** — stateful
fuzzing over real arithmetic — caught it on run 339. (The full autopsy is in
`case_studies/2026-06-25T2100_one-wei-overaccrual.md`.)

So the pattern recurses. Just as the co-op needs two rails because governance and economics are
different questions, the *verification* needs two proofs because "is the state machine correct" and
"is the arithmetic that implements it correct" are different questions. TLA+ answers the first.
Property tests answer the second. A team that picks one and calls it rigor is trusting a proof that,
by its own assumptions, was answering something else.

## What I'd carry forward

1. **When the law mandates a separation, encode it as a missing import, not a guarded branch.** A
   rail that *can't* read the other's state is stronger than one that's *told not to*.
2. **Make compliance invariants execute on the hot path.** Worker-majority at mint, one-vote in the
   tally — checked every time, not audited annually.
3. **Match the proof to the question.** A green TLA+ spec and a green invariant suite are not
   redundant; they cover disjoint failure modes. Ship neither alone.

The co-op is two rails because people are not their capital. The verification is two proofs because
a state machine is not its arithmetic. Same lesson, twice — keep separate things separate, and prove
each on its own terms.
