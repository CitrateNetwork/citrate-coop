# citrate-coop

*Part of the **[Citrate Network](https://citrate.ai)** — own the means of computation. · [Docs](https://docs.citrate.ai) · [Run a node](https://citrate.ai/download) · [Contribute → free membership](https://github.com/CitrateNetwork/.github/blob/main/CONTRIBUTING.md)*
> On-chain cooperative-ownership layer for the Citrate Network — the contracts that make a
> community-trained model (see [`nat`](https://github.com/CitrateNetwork/nat)) community-owned.

## What it is
Solidity contracts for cooperative governance and patronage: `ModelCooperative`,
`CitrateCooperativeFactory` / `CoopDeployer`, `ContributionRewardPool`, `MembershipSBT`,
and `CitrateAdminSafe`. Design and formal specs are in `COOP_OWNERSHIP_CONTRACT_SPEC.md`,
`SETTLEMENT_SEAM.md`, `specs/`, and the `.agentile/` ADRs. Concept docs:
https://docs.citrate.ai.

## Prerequisites
- [Foundry](https://book.getfoundry.sh/) (`forge`, `cast`) — `curl -L https://foundry.paradigm.xyz | bash && foundryup`
- git

## Build from source
```bash
cd contracts
forge build            # compiles src/ ; artifacts under contracts/out/
```

## Run locally (tests)
```bash
cd contracts
forge test -vvv        # unit + property tests
./scripts/run-tlc.sh   # (optional) TLA+/TLC model-check of the coop spec
```

## Connect it locally
Deploy the cooperative contracts onto a local Citrate devnet:
1. Run a local node from [`citrate-chain`](https://github.com/CitrateNetwork/citrate-chain):
   `citrate devnet` → JSON-RPC `http://127.0.0.1:8545` (chain id 40204). The devnet
   pre-funds Foundry account #0, so no faucet is needed.
2. Deploy with the script in `contracts/script/` (foundry pre-funded key):
   ```bash
   cd contracts
   forge script script/<Deploy>.s.sol --rpc-url http://localhost:8545 \
     --private-key $PRIVATE_KEY --broadcast
   ```
   Note the deployed `CitrateCooperativeFactory` address for downstream use.

## Configuration
Deployment addresses/params live in `contracts/script/` and the spec docs. Chain id is
40204; see `LOCAL_STACK.md` in `citrate-docs` for the full local stack.

## Links
- Docs: https://docs.citrate.ai
- Depends on / pairs with: [citrate-chain](https://github.com/CitrateNetwork/citrate-chain), [nat](https://github.com/CitrateNetwork/nat)
- Contributing (DCO): CONTRIBUTING.md · Security: SECURITY.md · License: LICENSE

## License

Licensed under the Apache License, Version 2.0 (see [`LICENSE`](LICENSE)). This is the open-source infrastructure tier of Citrate's open-core model. The commercial application layer is source-available under BUSL-1.1. Licensor: Citrate Inc.
