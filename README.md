# citrate-coop — Model Cooperative (RFC-CIT-COOP-0001)

The on-chain ownership layer that makes a community-trained NAT model a
**collectively-owned, revenue-bearing California Cooperative Corporation**. Contributors
earn democratic membership + patronage dividends + a 50M SALT emission for verified
training work; the model's revenue (on-chain SALT, x402, fiat) flows back to them.

This is an **agentile program**: everything is driven **TLA+ → Gherkin → planset/sprint →
failing tests → code → refactor → retro/journal**. The contracts compose with live
citrate-chain contracts and deploy to chain **40204**.

## Layout

```
citrate-coop/
├── COOP_OWNERSHIP_CONTRACT_SPEC.md     # full prose design (v2) — the architecture
├── specs/tla/coop/                     # 1. FORMAL — 4 TLA+ modules + .cfg (the driver)
│   ├── CoopLifecycle.{tla,cfg}
│   ├── PatronageDividend.{tla,cfg}
│   ├── MembershipVoting.{tla,cfg}
│   └── ContributionRewardPool.{tla,cfg}
├── features/                           # 2. BDD — Gherkin, each scenario ↔ a TLA invariant
│   └── coop_*.feature  (6)
├── .agentile/planset/                  # 3. PLANSET — gates + decisions
│   ├── gates.yaml                      #    G1–G5 exit criteria (machine-readable)
│   ├── README.md                       #    program overview + spec↔feature↔gate map
│   └── decisions/ADR-0001..0006.md     #    the six load-bearing decisions
├── .agentile/sprints/active/           # 4. SPRINT — COOP-S1, WP-0..9 (Rule-11 acceptance)
│   └── 2026-06-25-sprint-coop-s1-cooperative-foundation/SPRINT.md
├── contracts/                          # 5. RED — skeletons (revert) + failing Foundry tests
│   ├── foundry.toml
│   ├── src/{MembershipSBT,PatronageLedger}.sol     (skeletons; rest land per WP)
│   └── test/{MembershipSBT,PatronageLedger}.t.sol  (RED)
└── scripts/run-tlc.sh                  # TLC regression (WP-0)
```

## The two rails (the whole idea)

| Rail | Token | Drives | Law (CA co-op / AB 816) |
|------|-------|--------|--------------------------|
| **Membership** | soulbound `MembershipSBT`, 1/identity | **one-member-one-vote** governance | democratic control; worker ≥51% |
| **Patronage** | non-transferable units = `compute × data-quality` | **patronage dividend** + 50M CRP emission | distribution by patronage, not capital |

They never read each other's state (ADR-0001) — more contribution never buys more votes;
more votes never earn more dividend.

## Running the loop

```bash
# 1. FORMAL — verify the specs (WP-0)
./scripts/run-tlc.sh                 # TLC-green all four modules → flips gates.yaml g1-formal

# 5. RED — see the failing tests
cd contracts && forge install foundry-rs/forge-std && forge test   # expect RED until WP-1..

# Status
cat .agentile/planset/gates.yaml     # gate ladder G1–G5
```

## Status (2026-06-25)

G1 **partial** — TLA+ drafted (TLC run pending), Gherkin + ADRs done, counsel review open.
G2–G5 **pending**. WP-1..6 + WP-9 build now against live contracts; WP-7 (fiat ramp) needs a
licensed MSB custodian; WP-8 (federated join) is gated on NAT Gate-4. See the master brief
`../FEDERATED_TRAINING_MASTER_BRIEF.md` §8 for where this sits in the campaign.

## Composition (reuse, don't reinvent)

`KYCRegistry`, `ModelRegistry` + `ModelMarketplace` (owner-pay revenue, zero change),
`LoRAFactory`, `ComputePoolTraining`, `TreasuryGovernor` (pattern), `WrappedSALT` +
`X402Facilitator`/`X402Paywall`, `StablecoinTreasury` + `ComputePricingOracle`,
`IPFSIncentivesV3` (commit-reveal/prevrandao precedent), `AgentDecisionRegistry`.
