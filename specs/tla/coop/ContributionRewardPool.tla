\* ---
\* created: 2026-06-25T00:00:00Z
\* branch: main
\* author: saul
\* status: draft
\* ---
\*
\* TLA+ spec — Contribution Reward Pool (the 50M SALT emission).
\* Program: RFC-CIT-COOP-0001 · Gate: G1 · Sprint: COOP-S1 WP-5
\* Mirrors: contracts/src/ContributionRewardPool.sol
\* Companion design doc: COOP_OWNERSHIP_CONTRACT_SPEC.md §6
\*
\* Owner decision: 5% of the 1,000,000,000 SALT supply = 50,000,000 SALT,
\* released 10,000,000/year for 5 years, allocated by THAT year's patronage,
\* linearly vested, with a reserve skim from each cohort.
\* Token amounts here are scaled DOWN (Annual=10 ~ 10M SALT, Years=5,
\* total cap = 50 ~ 50M SALT) to keep TLC tractable.

------------------------------ MODULE ContributionRewardPool ------------------------------
EXTENDS Naturals, FiniteSets, TLC

(***********************************************************************
* WHAT THIS SPEC MODELS
* ---------------------
* A 5-year emission: each year a fixed cohort (Annual) is split between
* a governance reserve skim (Reserve) and a member-distributable pool
* (Annual - Reserve), allocated by in-year patronage and vested
* linearly. Members claim vested grants over time.
*
* WHAT TLA+ CHECKS
* ----------------
*   - Hard cap: total ever emitted (claimed) + reserve <= Years*Annual (50M).
*   - Per-cohort cap: a year never distributes more than (Annual - Reserve).
*   - Reserve conservation: each year skims exactly Reserve to the co-op.
*   - Vesting monotonic: a member's claimed CRP never exceeds its grant,
*     and never decreases.
*
* MODELING CHOICE
* ---------------
* Linear vesting is abstracted to the safety bound "claimed <= grant".
* The time-proportional release schedule is a refinement that only
* tightens this bound; the cap/conservation invariants are unaffected.
***********************************************************************)

CONSTANTS Members, Years, Annual, Reserve, MaxSteps
ASSUME Members # {}
ASSUME Years \in Nat /\ Years >= 1
ASSUME Annual \in Nat /\ Annual >= 1
ASSUME Reserve \in Nat /\ Reserve < Annual
ASSUME MaxSteps \in Nat /\ MaxSteps >= 1

VARIABLES
    year,             \* current cohort year, 0..Years-1, then "done"
    cohortDist,       \* Nat — amount distributed in the CURRENT year so far
    grant,            \* Members -> Nat (cumulative grant across cohorts)
    claimedCRP,       \* Members -> Nat (vested + withdrawn)
    reserveTotal,     \* Nat — cumulative reserve skimmed
    yearsDone,        \* Nat — number of fully advanced years
    stepCount

vars == << year, cohortDist, grant, claimedCRP, reserveTotal, yearsDone, stepCount >>

Distributable == Annual - Reserve

RECURSIVE SumF(_, _)
SumF(f, S) ==
    IF S = {} THEN 0
    ELSE LET m == CHOOSE x \in S : TRUE IN f[m] + SumF(f, S \ {m})

Init ==
    /\ year = 0
    /\ cohortDist = 0
    /\ grant = [m \in Members |-> 0]
    /\ claimedCRP = [m \in Members |-> 0]
    /\ reserveTotal = Reserve        \* year-0 reserve skimmed at open
    /\ yearsDone = 0
    /\ stepCount = 0

\* Allocate one unit of the current cohort to member m (by in-year patronage).
Allocate(m) ==
    /\ stepCount < MaxSteps
    /\ year < Years
    /\ cohortDist < Distributable
    /\ m \in Members
    /\ grant' = [grant EXCEPT ![m] = grant[m] + 1]
    /\ cohortDist' = cohortDist + 1
    /\ UNCHANGED << year, claimedCRP, reserveTotal, yearsDone >>
    /\ stepCount' = stepCount + 1

\* Advance to next cohort year — skims that year's reserve.
AdvanceYear ==
    /\ stepCount < MaxSteps
    /\ year < Years - 1
    /\ year' = year + 1
    /\ cohortDist' = 0
    /\ reserveTotal' = reserveTotal + Reserve
    /\ yearsDone' = yearsDone + 1
    /\ UNCHANGED << grant, claimedCRP >>
    /\ stepCount' = stepCount + 1

\* Claim vested CRP — bounded by the member's grant (linear vest abstracted).
ClaimVested(m) ==
    /\ stepCount < MaxSteps
    /\ m \in Members
    /\ claimedCRP[m] < grant[m]
    /\ claimedCRP' = [claimedCRP EXCEPT ![m] = claimedCRP[m] + 1]
    /\ UNCHANGED << year, cohortDist, grant, reserveTotal, yearsDone >>
    /\ stepCount' = stepCount + 1

Next ==
    \/ \E m \in Members : Allocate(m)
    \/ AdvanceYear
    \/ \E m \in Members : ClaimVested(m)

Spec == Init /\ [][Next]_vars

(***********************************************************************
* INVARIANTS
***********************************************************************)

TotalGranted == SumF(grant, Members)
TotalClaimed == SumF(claimedCRP, Members)

TypeOK ==
    /\ year \in 0..(Years - 1)
    /\ cohortDist \in 0..Distributable
    /\ reserveTotal \in Nat
    /\ stepCount \in 0..MaxSteps

\* Per-cohort cap: the current year never over-distributes.
Inv_CohortCap ==
    cohortDist <= Distributable

\* Hard cap: everything granted plus everything reserved never exceeds the
\* whole 5-cohort program (50M SALT scaled).
Inv_TotalCap ==
    TotalGranted + reserveTotal <= Years * Annual

\* Reserve conservation: reserve skimmed equals (years entered) * Reserve.
Inv_ReserveConservation ==
    reserveTotal = (yearsDone + 1) * Reserve

\* Vesting monotonic / bounded: no member claims more CRP than granted.
Inv_VestBounded ==
    \A m \in Members : claimedCRP[m] <= grant[m]

\* Nothing ever emitted beyond the cap, counting claims + reserve.
Inv_NoOverEmission ==
    TotalClaimed + reserveTotal <= Years * Annual

THEOREM Safety ==
    Spec => [](
        TypeOK
        /\ Inv_CohortCap
        /\ Inv_TotalCap
        /\ Inv_ReserveConservation
        /\ Inv_VestBounded
        /\ Inv_NoOverEmission
    )

==========================================================================
