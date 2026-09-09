# Citrate Model Co-op — Ownership Contract Specification (v2)

> **What this is.** A buildable spec for the contract system that makes a community-trained NAT model
> a **collectively-owned, revenue-bearing cooperative**, structured as a **California Cooperative
> Corporation** (worker co-op under AB 816). Contributors earn **patronage** from verified work
> (compute FLOPs × data-quality, relative to the pool); the model's revenue (on-chain SALT, x402,
> and fiat via Stripe/Plaid) flows into a co-op treasury and is distributed as **patronage
> dividends**; a **50M SALT** contribution-reward emission (5% of supply, 1%/yr × 5yr, linear vest)
> rewards contributors and seeds the reserve; governance is **one-member-one-vote** via a soulbound
> membership token with commit-reveal (prevrandao) secret ballots and delegation to representatives.
>
> **Companion to** `FEDERATED_TRAINING_MASTER_BRIEF.md`. **Target:** Solidity ^0.8.26, chain 40204.
> **v2 incorporates the owner's decisions of 2026-06-25.** Supersedes v1.
>
> **Design principle: compose, don't reinvent, and mirror the legal wrapper in code.** The chain
> already ships `KYCRegistry`, `ContributionAccounting`, `LearningCycleManager`, `ModelRegistry`,
> `ModelMarketplace`, `LoRAFactory`, `TreasuryGovernor`, `WrappedSALT`, `X402Facilitator`,
> `X402Paywall`, `BulkComputeGateway`, `StablecoinTreasury`, `ComputePricingOracle`,
> `IPFSIncentivesV3` (the commit-reveal precedent), `AgentDecisionRegistry`. The co-op adds a small
> module set on top.

---

## 1. The legal frame drives the contract (California Cooperative Corporation, AB 816)

The owner chose a **California Cooperative Corporation** wrapper. California co-op law (Corporations
Code Title 1, Div. 3, Part 2, §§12200+) and the **Worker Cooperative Act (AB 816, 2015)** impose a
structure the contract must mirror exactly — and it happens to match the owner's decisions one-to-one:

| Legal requirement | Contract consequence |
|---|---|
| **One member, one vote** — regardless of capital (§12300-range principle) | Governance = soulbound **MembershipSBT**, 1 vote each. **Never** SALT-weighted. |
| **Patronage dividends** — distributed by each member's **patronage** (use/contribution), not capital; worker-co-op apportions by ratio of member patronage to total patronage in the period | Economics = **PatronageLedger** units = compute×data-quality, **relative to the pool**. Residuals paid pro-rata by patronage units. |
| **Capital returns capped at 15%/fiscal year** | Any capital-contributor return (rare here) is capped; patronage dividends are **not** capital returns, so **not** capped — keep economics on the patronage rail. |
| **Worker-members ≥51% of workforce; workers hold ≥51% of voting power** | Contributors (who bring compute+data = *work*) are worker-members. Any non-worker "community investor" is a minority with **approval-only** rights. |
| **Community investor**: non-worker holder, ≤ **$1,000** each without securities registration; voting limited to **approval over merger/sale/reorg/dissolution only**, cannot propose | This is the *only* lane for outside capital; the contract encodes a separate `CommunityInvestor` role with approval-only votes. |
| **Subchapter T** pass-through taxation of patronage-sourced income | Patronage dividends are accounted per-member, per-period, with on-chain records suitable for 1099-PATR-style reporting. |

**Net:** the contract has **two strictly separated interests** — *membership* (democratic, 1-vote,
SBT) and *patronage* (economic, contribution-weighted, dividend-bearing). This is the heart of co-op
law and of the design. The sponsoring company takes **no equity** (the owner deemed founder
allocation irrelevant); it is a service provider / convener, optionally a capped community investor.

Sources: [Corp Code §12200 (Justia)](https://law.justia.com/codes/california/code-corp/title-1/division-3/part-2/chapter-1/article-1/section-12200/) · [California Cooperative Corporation Law (NCBA CLUSA PDF)](https://ncbaclusa.coop/images/StateCooperativeStatutes/California-General-Statute.pdf) · [AB 816 bill text](https://leginfo.legislature.ca.gov/faces/billNavClient.xhtml?bill_id=201520160AB816) · [SELC CA Worker Cooperative Act](https://www.theselc.org/ca-worker-cooperative-act) · [AB 816 Community Investor memo](https://communityenterpriselaw.org/wp-content/uploads/2015/07/AB-816-Community-Investor-Memo.FINAL_.pdf) · [Legal Sourcebook for California Cooperatives](https://cccd.coop/sites/default/files/resources/LegalSourcebookForCaliforniaCooperatives_0.pdf). *Not legal advice — counsel gate before mainnet (see §11).*

---

## 2. Membership vs Patronage — the two rails

```
        ┌──────────────── MEMBERSHIP RAIL (governance) ────────────────┐
        │  MembershipSBT  — soulbound, 1 per KYC identity              │
        │  • 1 member = 1 vote (AB 816)                               │
        │  • registry of agentIds + modelIds bound to the project     │
        │  • delegable to a representative (liquid democracy)         │
        │  • commit-reveal secret ballot (prevrandao precedent)       │
        └─────────────────────────────────────────────────────────────┘
                              (a person; democratic)

        ┌──────────────── PATRONAGE RAIL (economics) ──────────────────┐
        │  PatronageLedger — non-transferable units                   │
        │  • units = computeMetered × dataQuality  (relative to pool) │
        │  • drives PATRONAGE DIVIDEND (model revenue, pro-rata)      │
        │  • drives CRP emission allocation (50M SALT, by-year)       │
        └─────────────────────────────────────────────────────────────┘
                          (work contributed; proportional)
```

A worker-member holds **one** MembershipSBT (governance) **and** an evolving **patronage balance**
(economics). The two never mix: more contribution never buys more votes; more votes never earn more
dividend. This is both legally required and the owner's explicit instruction ("1 vote per member no
salt basis").

---

## 3. Decision → mechanism map (the owner's seven calls)

| Decision (owner) | Mechanism in this spec |
|---|---|
| **Share rate** = work via compute + data, scored on data quality balanced with FLOPs, *relative to the pool* | **Patronage unit** minted per round = `computeMetered × dataQuality` (= nat-federated `reward_weight`), with governance weights `wCompute/wData` to rebalance. "Relative to pool" is realized because *all* distributions are pro-rata `units[m]/totalUnits`. (§5) |
| **Founder allocation** = irrelevant; instead **5% of supply (50M SALT) over 5 yrs, 1%/yr linear vest, by individual contribution within each year's 1%** | **ContributionRewardPool (CRP)**: 5 annual cohorts of **10M SALT**, each allocated pro-rata by *that year's* patronage, each **linearly vested**. No company equity. (§6) |
| **Reserve ratio** = comes from that 5% / 50M | A governance-set `reserveBps` is skimmed **from each annual CRP cohort** (not from revenue) into the co-op **reserve/treasury**. Revenue residuals pass through to members in full as patronage dividends. (§6.3) |
| **Vesting** = linear, per-year cohort | Linear vest of each member's CRP grant over the cohort window (default 12 months from grant). (§6.2) |
| **Voting** = prevrandao setup + 1 vote/member, no-SALT, **SBT** with agentId/modelId registry; **delegation to a representative** | **CooperativeGovernor**: one-member-one-vote over MembershipSBT; **commit-reveal secret ballot** (the chain's `IPFSIncentivesV3` prevrandao pattern); **liquid-democracy delegation**; optional prevrandao **sortition** of a representative council. (§7) |
| **Legal wrapper** = **California Cooperative Corporation** | Worker co-op (AB 816): worker-members ≥51% votes; community-investor approval-only lane; patronage dividends; Subchapter T. (§1, §11) |
| **Revenue routing** = **on-chain**, with **x402** path + **fiat (Stripe/Plaid)** ramps | Three intake rails all converging on `notifyRevenue` → patronage dividend: (a) on-chain SALT (ModelRegistry/Marketplace owner-pay), (b) **x402** (`X402Facilitator`/`X402Paywall` → wSALT), (c) **fiat** (Stripe/Plaid → custodian → USDC → `StablecoinTreasury` → co-op). (§8) |

---

## 4. Contract set

```
CitrateCooperativeFactory         deploys one co-op per project/model
        │
        ├── MembershipSBT          ERC-5192 soulbound; 1/KYC-identity; agentId+modelId registry
        ├── PatronageLedger        non-transferable units; per-round + per-year accounting
        ├── ModelCooperative       core: state machine, treasury, revenue intake, dividend math
        ├── ContributionRewardPool 50M SALT emission (10M/yr × 5), by-year alloc, linear vest, reserve skim
        ├── CooperativeGovernor    1-member-1-vote, commit-reveal ballot, delegation, sortition
        └── CooperativeFiatRamp    Stripe/Plaid attested fiat → wSALT → notifyRevenue (adapter)
```

For v1 you may inline `PatronageLedger` into `ModelCooperative`. `MembershipSBT`, `CooperativeGovernor`,
`ContributionRewardPool`, and `CooperativeFiatRamp` stay separate (distinct audit + legal surfaces).

---

## 5. Patronage accounting — the share rate

```solidity
// PatronageLedger
uint256 public totalUnits;                               // Σ all members' lifetime patronage
mapping(address => uint256) public units;                // lifetime patronage (drives revenue dividend)
mapping(uint256 => uint256) public yearTotalUnits;       // year → Σ patronage that year (drives CRP)
mapping(uint256 => mapping(address => uint256)) public yearUnits;  // year → member → patronage that year

uint16 public wCompute = 10_000;  // governance weights (bps) to rebalance compute vs data emphasis
uint16 public wData    = 10_000;

/// SETTLER_ROLE (federation coordinator) calls this AFTER committing the round merged_hash on-chain.
/// computeMetered: normalized FLOP-seconds (Q16.16→uint). dataQuality: 0..1 in bps (from nat-data).
/// patronage unit = computeMetered × dataQuality, weighted. This is nat-federated's reward_weight.
function recordContribution(
    bytes32 roundId, address member, uint256 computeMetered, uint16 dataQualityBps
) external onlyRole(SETTLER_ROLE) {
    require(roundMergedHash[roundId] != 0, "round not committed");      // provenance-bound (§5.1)
    require(!recorded[roundId][member], "double count");                // idempotent
    require(IKyc(kyc).isVerified(member), "not kyc");
    require(membership.isMember(member), "not member");                 // worker-member only

    recorded[roundId][member] = true;
    uint256 c = computeMetered * wCompute / 10_000;
    uint256 p = c * dataQualityBps / 10_000 * wData / 10_000;           // compute × quality, weighted

    uint256 y = coopYear();                                             // 0..4 (5-year program)
    _settleDividend(member);                                           // checkpoint revenue before unit change
    units[member]      += p;  totalUnits        += p;
    yearUnits[y][member] += p;  yearTotalUnits[y] += p;
    _resetDividendDebt(member);
    emit PatronageRecorded(roundId, member, y, computeMetered, dataQualityBps, p);
}
```

**Why this is the right unit (and legally correct):** patronage = member's *use of / work for* the
co-op. Compute FLOPs and data quality are exactly that work. A member's slice of any distribution is
`units[m] / totalUnits` — inherently **relative to the pool**, as the owner specified. Sybil-splitting
gains nothing (your compute×quality is fixed). `wCompute/wData` let governance tune the balance later
without changing the contract.

### 5.1 Provenance binding (equity anchored to the federated proof)

```solidity
mapping(bytes32 => bytes32) public roundMergedHash;     // roundId → nat-federated merge_trace_hashes()
function commitRound(bytes32 roundId, bytes32 mergedHash) external onlyRole(SETTLER_ROLE) {
    require(roundMergedHash[roundId] == 0 && mergedHash != 0, "bad round");
    roundMergedHash[roundId] = mergedHash;              // == the on-chain ChainCommit hash (brief §4)
    emit RoundCommitted(roundId, mergedHash);
}
```

Patronage only mints for a round whose `merged_hash` was committed — so units are anchored to the
verified, order-independent federated aggregation. An auditor replays the round and checks the hash.

---

## 6. The 50M SALT Contribution Reward Pool (CRP)

5% of the 1,000,000,000 SALT supply = **50,000,000 SALT**, released **10,000,000/year for 5 years**,
allocated by *that year's* patronage, linearly vested, with a reserve skim.

```solidity
// ContributionRewardPool
uint256 constant ANNUAL = 10_000_000e18;   // 10M SALT/yr
uint8   constant YEARS  = 5;               // 50M total
uint16  public reserveBps;                 // skim from each cohort → co-op reserve (owner: "reserve from the 5%")
uint64  public immutable programStart;     // block/timestamp anchor
mapping(uint8 => uint256) public cohortReserveTaken;
mapping(uint8 => mapping(address => uint256)) public claimedFromYear;
```

### 6.1 Allocation (by-year patronage)

For year `y`, member `m`'s **gross** cohort grant:
```
distributable_y = ANNUAL − (ANNUAL × reserveBps / 10_000)         // reserve skimmed first
grant_y(m)      = distributable_y × yearUnits[y][m] / yearTotalUnits[y]
```
The reserve skim (`ANNUAL × reserveBps/10_000`) is swept to the co-op reserve — this is the owner's
"reserve comes from the 50M."

### 6.2 Linear vesting

Each member's `grant_y(m)` vests **linearly** over `VEST_WINDOW` (default 365 days) from the year's
close (or from contribution, governance-selectable):
```
vested_y(m, t) = grant_y(m) × clamp((t − vestStart_y) / VEST_WINDOW, 0, 1)
claimable_y(m) = vested_y(m, now) − claimedFromYear[y][m]
```
`claimCRP()` transfers `Σ_y claimable_y(msg.sender)` in wSALT, KYC re-checked at claim. Unvested
balance is forfeitable on expulsion-for-cause (governance), returning to the pool.

### 6.3 Reserve / treasury (the flywheel)

The reserve (from the CRP skim) funds: (a) compute for the **next** training round via
`ComputePoolTraining` (revenue/rewards → better model → more revenue), (b) operations, (c) audits.
Spends are governance proposals (§7), capped per epoch. **Model-revenue residuals are NOT skimmed** —
they pass through to members in full as patronage dividends (§8), keeping the patronage rail clean for
Subchapter T.

---

## 7. Governance — one member, one vote (`CooperativeGovernor`)

### 7.1 MembershipSBT (the vote)

```solidity
// MembershipSBT — ERC-5192 minimal soulbound (locked = true; non-transferable)
struct Member {
    bytes32 kycIdentity;     // KYCRegistry.identityOf(addr) — one SBT per identity (Sybil-proof)
    uint64  joinedAt;
    MemberClass class;       // Worker | CommunityInvestor (AB 816 §1)
    bytes32[] agentIds;      // from citrate-agent-runtime / AgentDecisionRegistry, bound to project
}
mapping(address => uint256) public tokenOf;          // addr → tokenId (0 = none)
bytes32[] public projectModelIds;                    // modelId(s) this co-op owns (ModelRegistry)

function mint(address to, bytes32 kycId, MemberClass c, bytes32[] calldata agentIds) external onlyRole(REGISTRAR_ROLE);
function isMember(address a) external view returns (bool);
function memberClass(address a) external view returns (MemberClass);
```
- **One SBT per KYC identity.** `kycIdentity` from `KYCRegistry.identityOf` prevents a person holding
  multiple member seats (AB 816: democratic control).
- **Worker vs CommunityInvestor.** Worker-members (contributed compute/data) have full votes;
  CommunityInvestors get **approval-only** votes on merger/sale/reorg/dissolution (AB 816 cap, ≤$1,000,
  no securities registration). The governor enforces **worker-members hold ≥51% of votes** at all times.
- **Project registry.** The SBT carries the member's `agentIds`; the co-op carries `projectModelIds`
  — binding the membership graph to the project's on-chain agent + model identities, exactly as the
  owner asked ("registry of agentId's and modelId's from the chain attached to the project").

### 7.2 Voting: commit-reveal secret ballot (the prevrandao precedent)

The chain's prevrandao usage lives in **`IPFSIncentivesV3`**: a challenge nonce is **committed** bound
to `block.prevrandao`, then **revealed** after `REVEAL_DELAY` blocks to stop proposer frontrunning.
The governor reuses this pattern for **secret ballots** (prevents vote-buying / coercion / bandwagon):

```solidity
// commit phase: voter submits hash(vote ‖ salt); reveal phase (after REVEAL_DELAY): voter reveals
function commitVote(uint256 proposalId, bytes32 voteCommitment) external onlyMember;
function revealVote(uint256 proposalId, uint8 choice, bytes32 salt) external onlyMember;
// tally seeds tie-breaks / sortition from block.prevrandao at reveal close (in-house precedent)
```
- **1 vote per member** (the SBT), counted at reveal. No SALT, no stake weighting.
- Quorum + approval thresholds governance-set (default quorum = 33% of members, approval = simple
  majority; supermajority for merger/dissolution per AB 816 + capital matters).

### 7.3 Delegation — liquid democracy + representative sortition

The owner wants "an easy way for DAO participants to stake their identity/vote in the pool to delegate
to a representative":

```solidity
mapping(address => address) public delegateOf;   // member → representative (self if unset)
function delegate(address representative) external onlyMember;      // liquid democracy
function undelegate() external onlyMember;
// a representative votes with their own vote + all delegated votes (one-member-one-vote preserved:
// each delegated vote is still ONE member's single vote, just cast by their chosen rep)
```
- **Delegation is revocable**, KYC-bound, and **never transfers the SBT** (you delegate the *vote*, not
  membership). A rep's weight = number of members who delegated (still one-person-one-vote in aggregate).
- **Optional prevrandao sortition:** governance can elect a rotating **Representative Council** by
  random selection (seeded from `block.prevrandao`, commit-reveal) from the set of members willing to
  serve — citizen-assembly style, anti-capture. Off by default; enable by proposal.

### 7.4 Proposal types (co-op executes as model owner)

`SetInferencePrice` · `Publish/Retire` · `UpgradeWeights` (`ModelRegistry.updateModel`) ·
`ApproveAdapter` (`LoRAFactory`) · `FundNextRound` (`ComputePoolTraining` from reserve) ·
`SetParameter` (`reserveBps`, `wCompute/wData`, vesting, thresholds) · `Membership`
(admit/expel-for-cause, class changes) · `TreasurySpend` (capped) · `Wind/Dissolve` (supermajority +
community-investor approval per AB 816). Timelock on execution; `GUARDIAN` veto-only role during
Forming, decaying as membership grows (progressive decentralization — matches the federation's
owner-gated→roster-driven pattern).

---

## 8. Revenue routing — on-chain, x402, and fiat (Stripe/Plaid)

All three rails converge on one entry point and one distribution (the patronage dividend):

```solidity
function notifyRevenue(uint256 amountWSalt) public;     // credits the patronage dividend accumulator
```

### 8.1 Rail A — On-chain SALT (works today, zero new wiring)

`ModelRegistry.requestInference` pays `model.owner` the full `msg.value`; `ModelMarketplace.purchaseAccess`
pays `listing.owner` price−2.5%. **Set the co-op as the model/listing owner → revenue lands in the
co-op** `receive()`, which wraps to wSALT and calls `notifyRevenue`.

### 8.2 Rail B — x402 micropayments

`X402Facilitator.settlePayment` / `X402Paywall.verifyAndGrant` settle EIP-3009 signed authorizations
through `wSALT.transferWithFeeAuthorization`, splitting **(net → provider, fee → treasury)**. Point the
**provider** (or `treasury`) address at the co-op for the model's `resourceId` → per-call x402
micropayments accrue to the co-op. This is the high-frequency machine-payment rail for agent/inference
traffic. Already on-chain; only the off-chain 402 gateway is operational glue.

### 8.3 Rail C — Fiat (Stripe cards + Plaid ACH) → on-chain

```
Buyer pays USD
  ├─ Stripe (card)  ─┐
  └─ Plaid (ACH/bank)┘→ off-chain payment processor (custodian) receives USD, KYC/AML
                          │ on settled+cleared funds, signs an attestation
                          ▼
        CooperativeFiatRamp.creditFromFiat(coop, usd, stripeRef, sig)   [ATTESTOR_ROLE]
                          │ converts USD→wSALT via ComputePricingOracle (saltPriceUsdCents, staleness-checked)
                          │ pulls/mints wSALT from a funded ramp treasury (or USDC via StablecoinTreasury.deposit)
                          ▼
                  ModelCooperative.notifyRevenue(wSaltAmount)  → patronage dividend
```
- **Reuses existing rails:** `StablecoinTreasury.deposit` (USDC accumulation, epoch revenue tracking)
  + `ComputePricingOracle` (USD↔SALT, BFT-quorum, staleness guard) + `BulkComputeGateway` pattern
  (stablecoin→credits) already exist. `CooperativeFiatRamp` is a thin adapter with an `ATTESTOR_ROLE`
  (the custodian's on-chain key) that turns a **signed Stripe/Plaid settlement webhook** into an
  on-chain credit. ACH reversal window handled by a `holdPeriod` before `notifyRevenue` fires.
- **Build:** the off-chain custodian service (Stripe/Plaid webhooks → signed attestation) + the
  `CooperativeFiatRamp` contract are the only net-new pieces; everything downstream exists.
- **Compliance:** fiat ramp = money transmission surface → the custodian must be a licensed
  MSB/processor; ties into the federation's existing MSB/KYC track. Card chargebacks/ACH returns are
  absorbed by `holdPeriod` + a ramp reserve, never clawed back from members post-distribution.

### 8.4 The patronage dividend (distribution math)

Standard `accDividendPerUnit` + `debt` accumulator over **patronage units**, correct under a changing
unit supply because every unit mutation settles first:

```solidity
uint256 public accDividendPerUnit;                    // scaled 1e18
mapping(address => uint256) public dividendDebt;
mapping(address => uint256) public pendingDividend;
uint256 constant ACC = 1e18;

function notifyRevenue(uint256 amt) public {
    require(state == Active || state == WindingDown, "not earning");
    if (totalUnits == 0) { unallocated += amt; }      // pre-patronage revenue buffered
    else { accDividendPerUnit += amt * ACC / totalUnits; }
    emit RevenueReceived(amt);
}
function _settleDividend(address m) internal {
    if (units[m] > 0)
        pendingDividend[m] += units[m] * accDividendPerUnit / ACC - dividendDebt[m];
}
function _resetDividendDebt(address m) internal { dividendDebt[m] = units[m] * accDividendPerUnit / ACC; }

function claimDividend() external nonReentrant {
    require(IKyc(kyc).isVerified(msg.sender), "not kyc");   // revocation re-checked at claim
    _settleDividend(msg.sender);
    uint256 owed = pendingDividend[msg.sender];
    require(owed > 0, "nothing");
    pendingDividend[msg.sender] = 0;
    _resetDividendDebt(msg.sender);
    require(IERC20(salt).transfer(msg.sender, owed), "transfer");
    emit DividendClaimed(msg.sender, owed);   // record for Subchapter T / 1099-PATR reporting
}
```
No member can claim revenue accrued before they held patronage; rounding dust favors the pool; payouts
are pull-only, CEI, reentrancy-guarded, KYC-gated.

---

## 9. Lifecycle

```
Forming ──(governor.activate; co-op set as ModelRegistry owner)──► Active ──(vote)──► WindingDown ──► Dissolved
  patronage minted from founding rounds;        steady state: rounds keep        no new patronage; final
  CRP year 0 opens; community-investor lane     minting patronage, revenue       dividend + CRP sweep;
  optional; no revenue yet                      flows, dividends + CRP claim     model retired/transferred
```

---

## 10. Security invariants (test suite + TLA+ if Tier-1)

1. **Two-rail separation:** patronage units never affect vote count; MembershipSBT never affects dividend.
2. **One member, one vote; one SBT per KYC identity** (AB 816 democratic control; Sybil-proof).
3. **Worker-majority:** worker-members always ≥51% of total votes (enforced on mint / class change).
4. **Patronage conservation:** `Σ units == totalUnits`; `Σ yearUnits[y] == yearTotalUnits[y]`.
5. **Revenue conservation:** every wei via `notifyRevenue` ∈ {unallocated, accumulator, pending, claimed}; never lost/double-counted.
6. **CRP conservation:** `Σ grants_y + cohortReserveTaken[y] ≤ ANNUAL`; total emitted ≤ 50M; unvested forfeits return to pool.
7. **No retroactive dividends / CRP:** settle-before-mutate; vesting monotonic.
8. **Provenance binding:** patronage mints only against a committed `roundMergedHash`.
9. **KYC fail-closed:** unverified/revoked cannot hold SBT, mint patronage, or claim.
10. **Capital-return cap:** any community-investor capital return ≤15%/fiscal year (AB 816 / CA cap).
11. **Pull-only, CEI, nonReentrant** on all value moves; **governance+timelock** on privileged ops; `SETTLER_ROLE` limited to commitRound + recordContribution.
12. **Fiat-ramp safety:** `holdPeriod` ≥ ACH-return window before `notifyRevenue`; chargebacks hit ramp reserve, never clawback distributed dividends.

---

## 11. Compliance posture & owner TODOs

- **Entity:** form a **California Cooperative Corporation**, electing **worker-cooperative** status
  under **AB 816**. Bylaws must encode one-member-one-vote, patronage-dividend method, worker-member
  ≥51% control, and the community-investor lane (≤$1,000, approval-only).
- **Tax:** operate under **Subchapter T**; patronage dividends issued with written notices of
  allocation; on-chain `DividendClaimed` records feed 1099-PATR reporting.
- **Securities:** worker-co-op membership + patronage is materially safer than selling investment
  shares; keep a primary market in tradeable equity **out** of v1; community-investor cap (≤$1,000,
  no registration) is the only outside-capital lane.
- **Money transmission:** the **Stripe/Plaid fiat ramp** custodian must be a licensed MSB/processor;
  fold into the federation's existing MSB/KYC/OFAC track. OFAC screen at fiat intake + at claim.
- **Counsel gate:** **do not deploy to mainnet without legal sign-off** (treat like the INFER-S1
  custody review). Confirm: CA co-op bylaws ↔ contract parity; token (SALT/patronage) characterization;
  CRP emission not deemed a securities offering.

*This section is structural guidance from primary sources, not legal advice.*

---

## 12. Implementation plan (sprint COOP-S1) & dependencies

| WP | Deliverable | Buildable now? |
|---|---|---|
| WP-1 | `MembershipSBT` (ERC-5192, KYC-identity-bound, worker/investor classes, agentId/modelId registry) | ✅ vs KYCRegistry/AgentDecisionRegistry |
| WP-2 | `PatronageLedger` (units, per-round + per-year, `wCompute/wData`) + invariants 1,4,7 | ✅ |
| WP-3 | `ModelCooperative` core: state machine, `commitRound`/`recordContribution`, dividend accumulator (§8.4) | ✅ |
| WP-4 | Revenue Rail A (`receive`+wrap, owner-wiring fork test) + Rail B (x402 provider/treasury routing) | ✅ vs live X402/ModelRegistry |
| WP-5 | `ContributionRewardPool` (50M, by-year alloc, linear vest, reserve skim) + invariant 6 | ✅ (needs 50M SALT allocation source) |
| WP-6 | `CooperativeGovernor`: 1-vote, commit-reveal (IPFSIncentivesV3 pattern), delegation, sortition, AB-816 worker-majority | ✅ vs TreasuryGovernor pattern |
| WP-7 | `CooperativeFiatRamp` + off-chain Stripe/Plaid custodian + attestation (Rail C) | ⚠️ needs MSB custodian + holdPeriod |
| WP-8 | nat-federated `Settlement`-seam impl → `commitRound`+`recordContribution` (closes brief §4) | ⛔ gated on NAT Gate-4 / WP-F3-F4 |
| WP-9 | `CitrateCooperativeFactory` + deploy + address-book | ✅ |
| WP-10 | TLA+ (two-rail separation, conservation), Foundry invariant tests, **counsel gate** | — |

**Critical path:** WP-1–6 + WP-9 build **now** against live contracts (governance, patronage, CRP,
revenue Rails A/B). WP-7 needs the MSB custodian. WP-8 is the join with the federated orchestrator
(brief §4.3) — where co-op patronage meets the real multi-node run.

---

## 13. End-to-end campaign flow

1. Form the CA worker co-op; deploy via `CitrateCooperativeFactory`; register co-op as `ModelRegistry`
   owner of the project model; open CRP year 0. Company convenes — **no equity**.
2. Contributors KYC (AUTHSPINE) → `MembershipSBT` minted (1 vote, agentIds bound) → join `LearningPool`,
   bring data (license/PII/quality-scored by `nat-data`) + model/weights.
3. Federated rounds run on the compute pool. Each round: `nat-federated` gathers signed contributions →
   `merged_hash` → coordinator `commitRound` + `recordContribution` (patronage = compute×quality). Same
   weights pay immediate SALT via `LearningCycleManager`; **and** accrue CRP year-Y allocation.
4. Governor `activate`s; model published + listed. Revenue flows in via Rail A (on-chain), Rail B
   (x402), Rail C (Stripe/Plaid). All → `notifyRevenue` → patronage dividend.
5. Members `claimDividend()` (residual revenue) + `claimCRP()` (vested emission), KYC re-checked.
   Governance (1-vote, delegable) steers price/upgrades/adapters and spends reserve to fund the next
   round — the flywheel. Worker-members hold ≥51% control throughout.
6. The model is a living, democratically-governed, patronage-paying California cooperative on Citrate.

---

## 14. Remaining open knobs (defaults proposed; change by governance later)

| Knob | Proposed default | Note |
|---|---|---|
| `wCompute` / `wData` | 10000 / 10000 (equal) | rebalance compute vs data emphasis in patronage |
| CRP `reserveBps` | 2000 (20% of each 10M → 2M/yr reserve) | owner: "reserve from the 5%"; tune to flywheel needs |
| CRP `VEST_WINDOW` | 365 days, linear, per-year cohort | owner: "linear vest, 1%/yr" |
| Quorum / approval | 33% members / simple majority; ⅔ for merger/dissolution | AB 816 supermajority for major acts |
| Community-investor lane | enabled, ≤$1,000, approval-only | AB 816; optional |
| Fiat `holdPeriod` | 5 business days (ACH) | absorb returns before distribution |
| Sortition council | off by default | enable by proposal (anti-capture) |

---

*End of v2. Two rails (membership + patronage), a California worker-cooperative wrapper, a 50M SALT
contribution emission with reserve, one-member-one-vote commit-reveal governance with delegation, and
three on-chain revenue rails (SALT / x402 / fiat). WP-1–6 buildable now; the federated join lands with
NAT Gate-4.*
