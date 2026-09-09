# Settlement Seam — nat-federated → Model Cooperative (WP-8)

> The join point between a real NAT federated training run and co-op patronage. The **on-chain
> half is implemented and tested** (`PatronageLedger.commitRound` + `recordContribution`, see
> `contracts/test/FederatedSettlement.t.sol`). The **Rust half** — a `Settlement` trait impl in
> the `nat-federated` crate — is **gated on NAT Gate-4** (the federated orchestrator; see
> `FEDERATED_TRAINING_MASTER_BRIEF.md` §4.3).

## The flow

```
nat-federated round (off-chain)
  gather signed contributions → verify-before-compose → merged_hash = merge_trace_hashes(...)
        │
        ▼  (the federation coordinator, holding SETTLER_ROLE)
  1. ChainCommit:  anchor merged_hash on Citrate                (existing nat-federated seam)
  2. PatronageLedger.commitRound(roundId, merged_hash)          ← binds equity to the proof
  3. for each accepted node:
        PatronageLedger.recordContribution(roundId, node, compute_metered, data_quality_bps)
        // patronage units minted = compute_metered × data_quality  (== reward_weight)
```

Step 2 makes patronage **provenance-bound**: `recordContribution` reverts unless the round's
`merged_hash` was committed, so co-op equity can only mint against a verified, order-independent
federated aggregation an auditor can replay (ADR-0003).

## The Rust seam (to implement in nat-federated, gated)

```rust
// nat-federated::Settlement impl that targets the co-op ledger
impl Settlement for CoopChainSettlement {
    fn settle(&self, round: &GatherResult) -> Result<()> {
        self.chain.commit_round(round.id, round.merged_hash)?;           // PatronageLedger.commitRound
        for c in &round.accepted {
            // reward_weight() = compute_metered × data_quality  (StepContribution)
            self.chain.record_contribution(round.id, c.node_id, c.compute_metered, c.data_quality_bps)?;
        }
        Ok(())
    }
}
```

The existing `nat_train::StepContribution::reward_weight() = compute_metered × data_quality` is the
exact signal; the co-op's `recordContribution(compute, qualityBps)` recomputes the same product
on-chain. The boundary is unchanged from ADR-0007: NAT scores, the chain settles — the co-op simply
adds the *equity* leg alongside the immediate-SALT leg.

## Status

- ✅ On-chain seam: `commitRound` + `recordContribution`, idempotent, provenance-bound, KYC +
  membership gated, SETTLER-only — tested in `FederatedSettlement.t.sol` (3 tests).
- ⛔ Rust `Settlement` impl + a live multi-node run: **gated on NAT Gate-4** (g4-settler).
