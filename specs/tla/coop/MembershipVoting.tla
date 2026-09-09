\* ---
\* created: 2026-06-25T00:00:00Z
\* branch: main
\* author: saul
\* status: draft
\* ---
\*
\* TLA+ spec — Membership + one-member-one-vote governance.
\* Program: RFC-CIT-COOP-0001 · Gate: G1 · Sprint: COOP-S1 WP-6
\* Mirrors: contracts/src/MembershipSBT.sol + contracts/src/CooperativeGovernor.sol
\* Companion design doc: COOP_OWNERSHIP_CONTRACT_SPEC.md §7
\* Legal basis: California Cooperative Corporation Law / AB 816 (one member,
\* one vote; worker-members hold >= 51% of voting power).

------------------------------ MODULE MembershipVoting ------------------------------
EXTENDS Naturals, FiniteSets, TLC

(***********************************************************************
* WHAT THIS SPEC MODELS
* ---------------------
* The MEMBERSHIP rail: a soulbound membership token (one per KYC
* identity), worker vs community-investor classes, vote delegation
* (liquid democracy), and a commit-reveal ballot. The economic
* (PATRONAGE) rail is deliberately ABSENT here — proving the two rails
* are separated is the point.
*
* WHAT TLA+ CHECKS
* ----------------
*   - One membership token per identity (no Sybil seats).
*   - Worker-members always hold >= half the votes (AB 816 control).
*   - Vote conservation under delegation: total attributable votes
*     always equals the member count — delegation reassigns a caster,
*     it never inflates the vote.
*   - Commit-reveal integrity: no member can reveal a vote it did not
*     first commit.
*
* OPERATOR-VS-VARIABLE PRINCIPLE
* ------------------------------
* CONSTANT: Identities (the universe of distinct KYC identities),
* MaxSteps. VARIABLES carry membership + ballot state.
***********************************************************************)

CONSTANTS Identities, MaxSteps
ASSUME Identities # {}
ASSUME MaxSteps \in Nat /\ MaxSteps >= 1

VARIABLES
    class,        \* Identities -> {"none","Worker","Investor"}  ("none" = not a member)
    delegate,     \* Identities -> Identities (self unless delegated)
    committed,    \* Identities -> BOOLEAN (committed a ballot this proposal)
    revealed,     \* Identities -> {"none","yes","no"}
    stepCount

vars == << class, delegate, committed, revealed, stepCount >>

IsMember(i) == class[i] \in {"Worker", "Investor"}
MemberSet == { i \in Identities : IsMember(i) }
WorkerSet == { i \in Identities : class[i] = "Worker" }
InvestorSet == { i \in Identities : class[i] = "Investor" }

\* Votes attributed to representative r = members who delegate to r.
DelegatedTo(r) == { i \in MemberSet : delegate[i] = r }

RECURSIVE SumCard(_)
SumCard(S) ==   \* sum of |DelegatedTo(r)| over r in S
    IF S = {} THEN 0
    ELSE LET r == CHOOSE x \in S : TRUE
         IN Cardinality(DelegatedTo(r)) + SumCard(S \ {r})

Init ==
    /\ class = [i \in Identities |-> "none"]
    /\ delegate = [i \in Identities |-> i]
    /\ committed = [i \in Identities |-> FALSE]
    /\ revealed = [i \in Identities |-> "none"]
    /\ stepCount = 0

\* Admit a worker-member (the default; contributors are workers).
AdmitWorker(i) ==
    /\ stepCount < MaxSteps
    /\ i \in Identities
    /\ class[i] = "none"
    /\ class' = [class EXCEPT ![i] = "Worker"]
    /\ UNCHANGED << delegate, committed, revealed >>
    /\ stepCount' = stepCount + 1

\* Admit a community investor — ONLY if workers remain >= half after.
\* (AB 816: worker-members keep control.)
AdmitInvestor(i) ==
    /\ stepCount < MaxSteps
    /\ i \in Identities
    /\ class[i] = "none"
    /\ 2 * Cardinality(WorkerSet) >= (Cardinality(MemberSet) + 1)
    /\ class' = [class EXCEPT ![i] = "Investor"]
    /\ UNCHANGED << delegate, committed, revealed >>
    /\ stepCount' = stepCount + 1

\* Delegate one's vote to another member (liquid democracy).
Delegate(i, r) ==
    /\ stepCount < MaxSteps
    /\ IsMember(i) /\ IsMember(r)
    /\ delegate' = [delegate EXCEPT ![i] = r]
    /\ UNCHANGED << class, committed, revealed >>
    /\ stepCount' = stepCount + 1

\* Commit a sealed ballot (one per member per proposal).
Commit(i) ==
    /\ stepCount < MaxSteps
    /\ IsMember(i)
    /\ committed[i] = FALSE
    /\ committed' = [committed EXCEPT ![i] = TRUE]
    /\ UNCHANGED << class, delegate, revealed >>
    /\ stepCount' = stepCount + 1

\* Reveal — only legal if previously committed.
Reveal(i, c) ==
    /\ stepCount < MaxSteps
    /\ IsMember(i)
    /\ committed[i] = TRUE
    /\ revealed[i] = "none"
    /\ c \in {"yes", "no"}
    /\ revealed' = [revealed EXCEPT ![i] = c]
    /\ UNCHANGED << class, delegate, committed >>
    /\ stepCount' = stepCount + 1

Next ==
    \/ \E i \in Identities : AdmitWorker(i)
    \/ \E i \in Identities : AdmitInvestor(i)
    \/ \E i \in Identities, r \in Identities : Delegate(i, r)
    \/ \E i \in Identities : Commit(i)
    \/ \E i \in Identities, c \in {"yes","no"} : Reveal(i, c)

Spec == Init /\ [][Next]_vars

(***********************************************************************
* INVARIANTS
***********************************************************************)

TypeOK ==
    /\ \A i \in Identities : class[i] \in {"none","Worker","Investor"}
    /\ \A i \in Identities : delegate[i] \in Identities
    /\ \A i \in Identities : revealed[i] \in {"none","yes","no"}
    /\ stepCount \in 0..MaxSteps

\* One soulbound seat per identity — guaranteed structurally by `class`
\* being a single value per identity. Asserted: no identity is both a
\* member and "none", and class is well-formed (tautological guard that
\* catches a malformed transition).
Inv_OneSeatPerIdentity ==
    \A i \in Identities : (class[i] = "none") \/ IsMember(i)

\* Worker-members hold at least half the votes at all times (AB 816).
Inv_WorkerControl ==
    Cardinality(MemberSet) = 0 \/ 2 * Cardinality(WorkerSet) >= Cardinality(MemberSet)

\* Vote conservation: every member's single vote is attributed to exactly
\* one representative (self or delegate). The sum of delegated counts over
\* all members equals the member count — delegation never inflates votes.
Inv_VoteConservation ==
    SumCard(MemberSet) = Cardinality(MemberSet)

\* Commit-reveal integrity: a revealed vote implies a prior commit.
Inv_RevealNeedsCommit ==
    \A i \in Identities : revealed[i] # "none" => committed[i] = TRUE

\* No non-member ever has a ballot.
Inv_OnlyMembersVote ==
    \A i \in Identities : (committed[i] = TRUE \/ revealed[i] # "none") => IsMember(i)

THEOREM Safety ==
    Spec => [](
        TypeOK
        /\ Inv_OneSeatPerIdentity
        /\ Inv_WorkerControl
        /\ Inv_VoteConservation
        /\ Inv_RevealNeedsCommit
        /\ Inv_OnlyMembersVote
    )

==========================================================================
