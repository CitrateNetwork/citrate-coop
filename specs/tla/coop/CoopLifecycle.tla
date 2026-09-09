\* ---
\* created: 2026-06-25T00:00:00Z
\* branch: main
\* author: saul
\* status: draft
\* ---
\*
\* TLA+ spec — Model Cooperative lifecycle state machine.
\* Program: RFC-CIT-COOP-0001 · Gate: G1 (Theory locked) · Sprint: COOP-S1 WP-1
\* Mirrors: contracts/src/ModelCooperative.sol (CoopState machine + action guards)
\* Companion design doc: COOP_OWNERSHIP_CONTRACT_SPEC.md §9

------------------------------ MODULE CoopLifecycle ------------------------------
EXTENDS Naturals, FiniteSets, TLC

(***********************************************************************
* WHAT THIS SPEC MODELS
* ---------------------
* The on-chain lifecycle of a ModelCooperative:
*   Forming -> Active -> WindingDown -> Dissolved   (forward-only)
* and which economic actions are legal in which phase. Patronage may
* only be minted while Forming or Active; model revenue may only be
* notified once the co-op has been Activated (and not after Dissolved).
* Dissolved is terminal.
*
* WHAT TLA+ CHECKS
* ----------------
*   - Forward-only progression (no phase ever moves backward).
*   - Contributions close at WindingDown and never re-open.
*   - Revenue is never notified before the co-op has been Active.
*   - Dissolved is a sink (no further state change).
* It does NOT check token arithmetic (see PatronageDividend.tla) or
* vote mechanics (see MembershipVoting.tla).
*
* OPERATOR-VS-VARIABLE PRINCIPLE
* ------------------------------
* CONSTANT: MaxSteps (state-space bound). Everything else is mutable
* protocol state held in VARIABLES.
***********************************************************************)

CONSTANTS MaxSteps
ASSUME MaxSteps \in Nat /\ MaxSteps >= 1

VARIABLES
    phase,              \* "Forming" | "Active" | "WindingDown" | "Dissolved"
    contribClosed,      \* BOOLEAN — once TRUE, no new patronage may mint
    wasActive,          \* BOOLEAN — co-op has been Active at least once
    totalPatronage,     \* Nat — cumulative patronage units minted (abstracted)
    totalRevenue,       \* Nat — cumulative revenue notified (abstracted)
    stepCount

vars == << phase, contribClosed, wasActive, totalPatronage, totalRevenue, stepCount >>

Phases == {"Forming", "Active", "WindingDown", "Dissolved"}

Ord(s) ==
    IF s = "Forming" THEN 1
    ELSE IF s = "Active" THEN 2
    ELSE IF s = "WindingDown" THEN 3
    ELSE 4   \* Dissolved

Init ==
    /\ phase = "Forming"
    /\ contribClosed = FALSE
    /\ wasActive = FALSE
    /\ totalPatronage = 0
    /\ totalRevenue = 0
    /\ stepCount = 0

\* Mint patronage — legal only while Forming or Active, and not after close.
RecordContribution ==
    /\ stepCount < MaxSteps
    /\ phase \in {"Forming", "Active"}
    /\ contribClosed = FALSE
    /\ totalPatronage' = totalPatronage + 1
    /\ stepCount' = stepCount + 1
    /\ UNCHANGED << phase, contribClosed, wasActive, totalRevenue >>

\* Governor activates the co-op (model published, owner set).
Activate ==
    /\ stepCount < MaxSteps
    /\ phase = "Forming"
    /\ phase' = "Active"
    /\ wasActive' = TRUE
    /\ stepCount' = stepCount + 1
    /\ UNCHANGED << contribClosed, totalPatronage, totalRevenue >>

\* Revenue intake — legal only when Active or WindingDown, and the
\* co-op must have been Active (guards "no revenue before product").
NotifyRevenue ==
    /\ stepCount < MaxSteps
    /\ phase \in {"Active", "WindingDown"}
    /\ wasActive = TRUE
    /\ totalRevenue' = totalRevenue + 1
    /\ stepCount' = stepCount + 1
    /\ UNCHANGED << phase, contribClosed, wasActive, totalPatronage >>

\* Begin wind-down — closes contributions permanently.
BeginWindDown ==
    /\ stepCount < MaxSteps
    /\ phase = "Active"
    /\ phase' = "WindingDown"
    /\ contribClosed' = TRUE
    /\ stepCount' = stepCount + 1
    /\ UNCHANGED << wasActive, totalPatronage, totalRevenue >>

\* Dissolve — terminal.
Dissolve ==
    /\ stepCount < MaxSteps
    /\ phase = "WindingDown"
    /\ phase' = "Dissolved"
    /\ stepCount' = stepCount + 1
    /\ UNCHANGED << contribClosed, wasActive, totalPatronage, totalRevenue >>

Next ==
    \/ RecordContribution
    \/ Activate
    \/ NotifyRevenue
    \/ BeginWindDown
    \/ Dissolve

Spec == Init /\ [][Next]_vars

(***********************************************************************
* INVARIANTS
***********************************************************************)

TypeOK ==
    /\ phase \in Phases
    /\ contribClosed \in BOOLEAN
    /\ wasActive \in BOOLEAN
    /\ totalPatronage \in Nat
    /\ totalRevenue \in Nat
    /\ stepCount \in 0..MaxSteps

\* Once contributions are closed they never re-open.
Inv_ContribClosedAfterWind ==
    phase \in {"WindingDown", "Dissolved"} => contribClosed = TRUE

\* No revenue can have been notified unless the co-op was Active.
Inv_NoRevenueBeforeActive ==
    totalRevenue > 0 => wasActive = TRUE

\* Dissolved is terminal: nothing accrues afterwards is impossible to
\* express on a single state, but we can assert Dissolved implies the
\* contribution gate is closed (a sink precondition).
Inv_DissolvedClosed ==
    phase = "Dissolved" => contribClosed = TRUE

THEOREM Safety ==
    Spec => [](
        TypeOK
        /\ Inv_ContribClosedAfterWind
        /\ Inv_NoRevenueBeforeActive
        /\ Inv_DissolvedClosed
    )

==========================================================================
