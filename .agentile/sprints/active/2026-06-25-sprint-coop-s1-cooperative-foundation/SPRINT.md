---
created: 2026-06-25T00:00:00Z
branch: feat/coop-s1-cooperative-foundation
author: saul
sprint: COOP-S1
status: ready-for-audit
---

# Sprint COOP-S1: Cooperative Foundation

## Sprint Metadata

| Field | Value |
|-------|-------|
| **Sprint ID** | `COOP-S1` |
| **Sprint Name** | Cooperative Foundation — two rails, emission, governance, revenue |
| **Goal** | Stand up the Model Cooperative contract system (membership + patronage + dividend + CRP + governor + revenue rails A/B) green against the TLA+ specs and Gherkin features, with the federated-join and fiat rail scaffolded. |
| **Branch** | `feat/coop-s1-cooperative-foundation` |
| **Start Date** | 2026-06-25 |
| **End Date** | 2026-06-25 |
| **Status** | `READY FOR AUDIT` — 59 tests green, 4 specs TLC-green; WP-7/8 off-chain halves carried forward |
| **Planset** | `.agentile/planset/README.md`, `.agentile/planset/gates.yaml` |
| **Predecessors** | NAT-S3 (federated scaffold); INFER-S4 (durable balances). Design doc `COOP_OWNERSHIP_CONTRACT_SPEC.md` v2. |

## Why this sprint

The federated-training campaign's missing surface is collective model ownership (master brief §8).
California cooperative law gives the legal frame and forces a clean two-rail design (ADR-0001/0002).
This sprint builds the contract system that turns verified training contributions into democratic
membership + patronage dividends + a fixed-cap SALT emission, composing with live citrate-chain contracts.

## Deliverables

- TLA+: `specs/tla/coop/{CoopLifecycle,PatronageDividend,MembershipVoting,ContributionRewardPool}.tla` TLC-green
- Gherkin: `features/coop_*.feature` (6 files) with passing step bindings
- Contracts: `MembershipSBT`, `PatronageLedger`, `ModelCooperative`, `ContributionRewardPool`, `CooperativeGovernor`, `CitrateCooperativeFactory`, `CooperativeFiatRamp` (scaffold)
- Foundry tests under `contracts/test/` green; Foundry invariant suite for conservation
- ADRs 0001–0006 (done); RETRO.md + journal at close

## Test Baseline (start of sprint)

| Metric | Count | Captured | Canonical command |
|--------|-------|----------|-------------------|
| **Tests** | 0 | 2026-06-25 | `forge test` (contracts/) |
| **Formal specs** | 4 (drafted) | 2026-06-25 | `ls specs/tla/coop/*.tla` |
| **TLC-green specs** | 0 | 2026-06-25 | `scripts/run-tlc.sh` (to add) |
| **Gherkin features** | 6 | 2026-06-25 | `ls features/*.feature` |

## Method

Per WP: **TLA+ → BDD/Gherkin → RED (failing test + tripwire) → GREEN → REFACTOR → adversarial → journal.**
TLA+ and Gherkin for the whole sprint are written up front (G1); each WP turns its slice RED→GREEN.
Any skipped step is justified in the WP block.

## Work Packages

### WP-0: TLC-verify the four specs

| Field | Value |
|-------|-------|
| **Status** | `[x] DONE` — 4/4 TLC-green (`-deadlock`); CI `formal` job |
| **Order step** | 1 (TLA+) |
| **Estimated effort** | S |

**Scope:** Run TLC on all four `.tla`/`.cfg` pairs; fix any spec that fails; wire `scripts/run-tlc.sh`
+ a CI tripwire that re-runs TLC. No contract code until specs are green.

**Acceptance Criteria** *(Rule 11)*
- [ ] All four specs TLC-green, recorded in `gates.yaml` g1-formal with state counts (evidence: `scripts/run-tlc.sh` output)
- [ ] CI tripwire re-runs TLC on `specs/tla/coop/**` change (evidence: `.github/workflows` job)

**Tests added:** TLC runs as the regression.

---

### WP-1: MembershipSBT (membership rail)

| Field | Value |
|-------|-------|
| **Status** | `[x] DONE` — `MembershipSBT.t.sol` (9) green |
| **Order step** | 2–7 |
| **Estimated effort** | M |

**Scope:** Soulbound (ERC-5192) membership token, one per KYC identity, Worker/Investor classes,
agentId+modelId registry, registrar role. Enforces worker ≥51% on mint/class-change. NOT governance
voting (that's WP-6).

**Acceptance Criteria** *(Rule 11)*
- [ ] Minting to a KYC-verified identity yields exactly one locked token, verified by `contracts/test/MembershipSBT.t.sol::test_mint_one_per_identity`
- [ ] Second token for same `KYCRegistry.identityOf` reverts, verified by `::test_no_sybil_seat`
- [ ] `transfer` reverts (ERC-5192 locked), verified by `::test_soulbound`
- [ ] Investor admission that would drop workers below 51% reverts, verified by `::test_worker_majority` (mirrors `MembershipVoting.tla::Inv_WorkerControl`)
- [ ] Revoked-KYC member action reverts fail-closed, verified by `::test_revoked_kyc_fail_closed`

**Tests added:** `contracts/test/MembershipSBT.t.sol` — the five above.

---

### WP-2: PatronageLedger (patronage rail)

| Field | Value |
|-------|-------|
| **Status** | `[x] DONE` — `PatronageLedger.t.sol` (9) green |
| **Order step** | 2–7 |
| **Estimated effort** | M |

**Scope:** Non-transferable patronage units = `compute × dataQuality` (weights `wCompute/wData`),
per-round + per-year accounting, `commitRound`/`recordContribution` (SETTLER_ROLE, idempotent,
provenance-bound). No vote effect (ADR-0001).

**Acceptance Criteria** *(Rule 11)*
- [ ] `recordContribution` mints `compute × quality`; zero quality ⇒ zero units, verified by `PatronageLedger.t.sol::test_unit_is_compute_times_quality`
- [ ] Recording against an uncommitted round reverts, verified by `::test_requires_committed_round` (mirrors ADR-0003)
- [ ] Double-recording `(roundId, member)` reverts, verified by `::test_idempotent`
- [ ] Contribution after WindingDown reverts, verified by `::test_window_closed` (mirrors `CoopLifecycle.tla::Inv_ContribClosedAfterWind`)

**Tests added:** `contracts/test/PatronageLedger.t.sol`.

---

### WP-3: ModelCooperative core + patronage dividend

| Field | Value |
|-------|-------|
| **Status** | `[x] DONE` — `ModelCooperative.t.sol` (8) + `DividendConservation` invariant (3) green |
| **Order step** | 2–7 |
| **Estimated effort** | L |

**Scope:** State machine (Forming→Active→WindingDown→Dissolved), treasury, `notifyRevenue`,
`accDividendPerUnit`/`debt`/`pending` dividend math, `claimDividend` (KYC-gated, pull/CEI).

**Acceptance Criteria** *(Rule 11)*
- [ ] Revenue distributes pro-rata by units, verified by `ModelCooperative.t.sol::test_dividend_prorata`
- [ ] Late joiner gets nothing from prior revenue, verified by `::test_no_retroactive` (mirrors `PatronageDividend.tla::Inv_NoRetroactive`)
- [ ] Conservation: Σ claimed = Σ notified − dust, verified by Foundry invariant `invariant_revenue_conserved` (mirrors `Inv_Conservation`)
- [ ] Claim by revoked-KYC member reverts, verified by `::test_claim_kyc_gated`
- [ ] `DividendClaimed` emitted for 1099-PATR, verified by `::test_claim_emits_record`

**Tests added:** `contracts/test/ModelCooperative.t.sol` + invariant test.

---

### WP-4: Revenue rails A (owner-pay) + B (x402)

| Field | Value |
|-------|-------|
| **Status** | `[x] DONE (mocks)` — `RevenueRouting.t.sol` (4) green; live-fork test carried forward |
| **Order step** | 2–7 |
| **Estimated effort** | M |

**Scope:** `receive()` wrap-and-notify; verify co-op-as-owner inflow on a fork against
`ModelRegistry`/`ModelMarketplace`; x402 provider/treasury routed to co-op via `X402Facilitator`.

**Acceptance Criteria** *(Rule 11)*
- [ ] `requestInference` payment lands in co-op + credits dividend, verified by `RevenueRouting.t.sol::test_rail_a_inference` (fork)
- [ ] `purchaseAccess` pays co-op price minus the marketplace fee, verified by `::test_rail_a_marketplace`
- [ ] x402 `settlePayment` nets value to co-op, verified by `::test_rail_b_x402`

**Tests added:** `contracts/test/RevenueRouting.t.sol`.

---

### WP-5: ContributionRewardPool (fixed-cap emission)

| Field | Value |
|-------|-------|
| **Status** | `[x] DONE` — `ContributionRewardPool.t.sol` (7) + `invariant_total_cap` green |
| **Order step** | 2–7 |
| **Estimated effort** | M |

**Scope:** equal annual cohorts over a multi-year schedule, by-year patronage allocation, a governance-set reserve skim, linear vest,
`claimCRP`, expulsion forfeiture.

**Acceptance Criteria** *(Rule 11)*
- [ ] Cohort allocated pro-rata by year-Y patronage, verified by `ContributionRewardPool.t.sol::test_cohort_prorata`
- [ ] The reserve fraction skimmed to reserve per cohort, verified by `::test_reserve_skim`
- [ ] Total grants + reserve ≤ the hard cap, verified by invariant `invariant_total_cap` (mirrors `Inv_TotalCap`)
- [ ] Linear vest; claimed ≤ grant, verified by `::test_linear_vest`

**Tests added:** `contracts/test/ContributionRewardPool.t.sol` + invariant.

---

### WP-6: CooperativeGovernor (one-member-one-vote)

| Field | Value |
|-------|-------|
| **Status** | `[x] DONE` — `CooperativeGovernor.t.sol` (9) green |
| **Order step** | 2–7 |
| **Estimated effort** | L |

**Scope:** 1-vote-per-SBT, commit-reveal ballot (prevrandao, `REVEAL_DELAY`), liquid-democracy
delegation, optional sortition, proposal types (price/publish/upgrade/adapter/fund/param/membership/
treasury/dissolve), timelock, decaying guardian veto. Investor approval-only rights.

**Acceptance Criteria** *(Rule 11)*
- [ ] Three members → three votes regardless of SALT, verified by `CooperativeGovernor.t.sol::test_one_member_one_vote`
- [ ] Reveal without commit reverts, verified by `::test_reveal_needs_commit` (mirrors `Inv_RevealNeedsCommit`)
- [ ] Delegation: rep casts own+delegated, total = member count, verified by `::test_delegation_conserves` (mirrors `Inv_VoteConservation`)
- [ ] Investor non-approval proposal reverts, verified by `::test_investor_approval_only`
- [ ] Passed price proposal executes `ModelRegistry.setInferencePrice` after timelock, verified by `::test_execute_as_owner`

**Tests added:** `contracts/test/CooperativeGovernor.t.sol`.

---

### WP-7: CooperativeFiatRamp (rail C scaffold)

| Field | Value |
|-------|-------|
| **Status** | `[◑] ON-CHAIN DONE` — `CooperativeFiatRamp.t.sol` (4) green; off-chain MSB custodian carried forward |
| **Order step** | 2–7 |
| **Estimated effort** | M |

**Scope:** ATTESTOR_ROLE `creditFromFiat` (signed Stripe/Plaid settlement → USD→wSALT via oracle →
`notifyRevenue`), `holdPeriod`, ramp reserve for chargebacks. Off-chain custodian is out of contract scope.

**Acceptance Criteria** *(Rule 11)*
- [ ] Attested fiat credit after hold period calls `notifyRevenue`, verified by `CooperativeFiatRamp.t.sol::test_fiat_credit_after_hold`
- [ ] Chargeback hits ramp reserve, not distributed dividends, verified by `::test_chargeback_isolation`

**Tests added:** `contracts/test/CooperativeFiatRamp.t.sol`.

---

### WP-8: nat-federated Settlement seam (federated join)

| Field | Value |
|-------|-------|
| **Status** | `[◑] ON-CHAIN SEAM DONE` — `FederatedSettlement.t.sol` (3) green; Rust `Settlement` impl gated on NAT Gate-4 |
| **Order step** | 2–7 |
| **Estimated effort** | M |

**Scope:** Implement the Rust `Settlement` seam so the federation coordinator calls
`commitRound(roundId, merged_hash)` then `recordContribution(...)` per node. Closes master brief §4.3.

**Acceptance Criteria** *(Rule 11)*
- [ ] Coordinator commits round + records each node's `reward_weight` as patronage, verified by `nat-federated` integration test against a local chain
- [ ] Patronage `merged_hash` equals `nat_federated::merge_trace_hashes` output (provenance parity)

**Tests added:** nat-federated integration test (in the nat repo).

---

### WP-9: CitrateCooperativeFactory + deploy

| Field | Value |
|-------|-------|
| **Status** | `[x] DONE` — `CitrateCooperativeFactory.t.sol` (3) green |
| **Order step** | 2–7 |
| **Estimated effort** | S |

**Scope:** Factory deploys + wires a co-op (membership, ledger, governor, CRP), registers it as model
owner, address-book entry. Deploy script.

**Acceptance Criteria** *(Rule 11)*
- [ ] Factory deploys a fully-wired co-op, verified by `CitrateCooperativeFactory.t.sol::test_deploy_wires_all`
- [ ] `cooperativeOf(modelHash)` resolves, verified by `::test_registry`

**Tests added:** `contracts/test/CitrateCooperativeFactory.t.sol`.

## Dependencies

| Dependency | Status | Impact if blocked |
|------------|--------|-------------------|
| `KYCRegistry` (isVerified/identityOf) | Available (live) | WP-1, WP-2, WP-3 KYC gates |
| `ModelRegistry`/`ModelMarketplace` | Available (live) | WP-4 rail A |
| `X402Facilitator`/`WrappedSALT` | Available (live) | WP-4 rail B |
| `ComputePricingOracle`/`StablecoinTreasury` | Available (live) | WP-7 rail C |
| NAT Gate-4 federated orchestrator | Pending | WP-8 (federated join) |
| Licensed MSB custodian | Not engaged | WP-7 (fiat rail) |
| Pool SALT allocation/escrow (governance) | Not approved | WP-5 emission funding |

## Risks

| Risk | Likelihood | Impact | Mitigation |
|------|-----------|--------|------------|
| Securities/co-op characterization wrong | Med | High | Counsel gate (g1-counsel) before mainnet; worker-co-op + patronage posture |
| Dividend accumulator rounding bug | Med | High | TLA conservation invariant + Foundry invariant test; dust favors pool |
| Fiat chargeback drains treasury | Med | Med | holdPeriod + ramp reserve; never claw back distributed dividends |
| NAT Gate-4 slips, blocking WP-8 | High | Med | WP-1..6,9 ship independently; WP-8 is additive |

## Notes

WP-1..6 + WP-9 build now against live contracts. WP-7 (fiat) and WP-8 (federated join) are scaffolded
and explicitly gated. Seed for RETRO.md: did the two-rail separation hold up under the governor's
execution paths (co-op acting as model owner)?
