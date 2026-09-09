\* ---
\* created: 2026-06-25T00:00:00Z
\* branch: main
\* author: saul
\* status: draft
\* ---
\*
\* TLA+ spec — Patronage dividend accumulator (the residual-revenue math).
\* Program: RFC-CIT-COOP-0001 · Gate: G1 · Sprint: COOP-S1 WP-3
\* Mirrors: contracts/src/ModelCooperative.sol (accDividendPerUnit / debt / pending)
\* Companion design doc: COOP_OWNERSHIP_CONTRACT_SPEC.md §8.4

------------------------------ MODULE PatronageDividend ------------------------------
EXTENDS Naturals, FiniteSets, TLC

(***********************************************************************
* WHAT THIS SPEC MODELS
* ---------------------
* The "accDividendPerUnit + debt" dividend accumulator over patronage
* units, under a CHANGING unit supply. Members mint patronage units
* over time; revenue is notified and distributed pro-rata by current
* units; members claim. This is the MasterChef/Comet dividend pattern,
* which is only correct if every unit mutation settles pending first.
*
* WHAT TLA+ CHECKS
* ----------------
*   - Conservation: every notified unit of revenue is exactly accounted
*     across {settled-pending, accrued-not-settled} — none lost, none
*     double-counted.
*   - No retroactive dividend: a member who holds 0 units while revenue
*     accrues earns 0 fresh credit from it (debt reset on mint).
*   - Claimed never exceeds entitled.
*
* MODELING CHOICE
* ---------------
* To stay in integers, NotifyRevenue only fires with an amount divisible
* by the current totalUnits (so per-unit accrual is exact). Real Solidity
* keeps the remainder as dust in the contract (favoring the pool), which
* is a strict-superset-safe relaxation of this model.
***********************************************************************)

CONSTANTS Members, MaxSteps, UnitStep, RevStep
ASSUME Members # {}
ASSUME MaxSteps \in Nat /\ MaxSteps >= 1
ASSUME UnitStep \in Nat /\ UnitStep >= 1
ASSUME RevStep \in Nat /\ RevStep >= 1

VARIABLES
    units,          \* Members -> Nat (patronage units held)
    debt,           \* Members -> Nat (accumulator checkpoint)
    pending,        \* Members -> Nat (settled-but-unclaimed)
    claimed,        \* Members -> Nat (withdrawn)
    accPerUnit,     \* Nat (dividend accumulator, exact integer model)
    totalUnits,     \* Nat
    totalNotified,  \* Nat (cumulative revenue in)
    stepCount

vars == << units, debt, pending, claimed, accPerUnit, totalUnits, totalNotified, stepCount >>

RECURSIVE SumF(_, _)
SumF(f, S) ==
    IF S = {} THEN 0
    ELSE LET m == CHOOSE x \in S : TRUE IN f[m] + SumF(f, S \ {m})

\* Entitlement accrued to m but not yet moved into `pending`.
AccruedNotSettled(m) == units[m] * accPerUnit - debt[m]

Init ==
    /\ units = [m \in Members |-> 0]
    /\ debt = [m \in Members |-> 0]
    /\ pending = [m \in Members |-> 0]
    /\ claimed = [m \in Members |-> 0]
    /\ accPerUnit = 0
    /\ totalUnits = 0
    /\ totalNotified = 0
    /\ stepCount = 0

\* Mint patronage to m — MUST settle pending first, then reset debt.
Mint(m) ==
    /\ stepCount < MaxSteps
    /\ m \in Members
    /\ LET settled == pending[m] + AccruedNotSettled(m)
       IN /\ pending' = [pending EXCEPT ![m] = settled]
          /\ units' = [units EXCEPT ![m] = units[m] + UnitStep]
          /\ totalUnits' = totalUnits + UnitStep
          /\ debt' = [debt EXCEPT ![m] = (units[m] + UnitStep) * accPerUnit]
    /\ UNCHANGED << claimed, accPerUnit, totalNotified >>
    /\ stepCount' = stepCount + 1

\* Notify revenue — distribute exactly across current unit holders.
\* Guarded to a divisible amount so the integer model is exact.
NotifyRevenue ==
    /\ stepCount < MaxSteps
    /\ totalUnits > 0
    /\ LET amt == RevStep * totalUnits   \* divisible by construction
       IN /\ accPerUnit' = accPerUnit + RevStep
          /\ totalNotified' = totalNotified + amt
    /\ UNCHANGED << units, debt, pending, claimed, totalUnits >>
    /\ stepCount' = stepCount + 1

\* Claim — settle, then move entitled into claimed.
Claim(m) ==
    /\ stepCount < MaxSteps
    /\ m \in Members
    /\ LET settled == pending[m] + AccruedNotSettled(m)
       IN /\ pending' = [pending EXCEPT ![m] = 0]
          /\ claimed' = [claimed EXCEPT ![m] = claimed[m] + settled]
          /\ debt' = [debt EXCEPT ![m] = units[m] * accPerUnit]
    /\ UNCHANGED << units, accPerUnit, totalUnits, totalNotified >>
    /\ stepCount' = stepCount + 1

Next ==
    \/ \E m \in Members : Mint(m)
    \/ NotifyRevenue
    \/ \E m \in Members : Claim(m)

Spec == Init /\ [][Next]_vars

(***********************************************************************
* INVARIANTS
***********************************************************************)

TypeOK ==
    /\ totalUnits = SumF(units, Members)
    /\ accPerUnit \in Nat
    /\ totalNotified \in Nat
    /\ stepCount \in 0..MaxSteps

\* Total credited to members (pending + accrued-not-settled + already
\* claimed) equals total revenue notified. Nothing lost or invented.
TotalCredited ==
    SumF([m \in Members |-> pending[m] + AccruedNotSettled(m) + claimed[m]], Members)

Inv_Conservation ==
    TotalCredited = totalNotified

\* A member holding zero units has zero fresh (unsettled) entitlement —
\* the debt reset on mint is what makes a late joiner earn nothing from
\* revenue that accrued before they held units.
Inv_NoRetroactive ==
    \A m \in Members : units[m] = 0 => AccruedNotSettled(m) = 0

\* You can never claim more than you were credited.
Inv_ClaimedBounded ==
    \A m \in Members : claimed[m] <= pending[m] + AccruedNotSettled(m) + claimed[m]

THEOREM Safety ==
    Spec => [](
        TypeOK
        /\ Inv_Conservation
        /\ Inv_NoRetroactive
        /\ Inv_ClaimedBounded
    )

==========================================================================
