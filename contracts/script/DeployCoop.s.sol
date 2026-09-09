// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import "forge-std/Script.sol";
import "./Salts.sol";
import "../src/CitrateCooperativeFactory.sol";
import "../src/CoopDeployer.sol";

/// @title DeployCoop — the co-op surface in the deterministic re-roll ceremony
/// @notice Deploys `CitrateCooperativeFactory` via CREATE2 so it lands at a stable address
///         across re-rolls (Salts.salt — same Arachnid deployer the chain uses). This is the
///         ONLY contract the co-op needs in the genesis ceremony: the factory has no
///         constructor args, and the five per-model contracts (MembershipSBT, PatronageLedger,
///         ModelCooperative, ContributionRewardPool, CooperativeGovernor) are instantiated +
///         role-wired at runtime by `factory.createCooperative(...)`, a governance action run
///         AFTER deploy (one call per model). `CooperativeFiatRamp` is likewise a per-co-op
///         opt-in deploy, not part of the deterministic set.
///
/// @dev Run as a ceremony step alongside the chain's Deploy*.s.sol (I64-S1 WP-B2 / WP-C2):
///        forge script script/DeployCoop.s.sol \
///          --rpc-url "$CITRATE_RPC_URL" --account ceremony --broadcast
///      Signing is the forge CLI's job (--account/--keystore/--private-key); this script
///      never embeds or selects a signer. The emitted factory address feeds the canonical
///      `citrate-chain/contracts/addresses/40204.json` via emit-address-table.sh.
contract DeployCoop is Script {
    function run() external returns (address factory) {
        console.log("=== Citrate Co-op Deterministic Deploy ===");
        console.log("Chain ID:", block.chainid);

        vm.startBroadcast();
        // chain-40204 fix (2026-08-29): deploy CoopDeployer SEPARATELY (CREATE2) and pass it to
        // the factory, instead of the factory `new`ing it in its constructor. On 40204 a
        // constructor CREATE does not advance the creator's persistent nonce, which made
        // createCooperative collide with the constructor-made helper. See the factory constructor.
        CoopDeployer d = new CoopDeployer{salt: Salts.salt("CoopDeployer")}();
        CitrateCooperativeFactory f =
            new CitrateCooperativeFactory{salt: Salts.salt("CitrateCooperativeFactory")}(d);
        vm.stopBroadcast();

        factory = address(f);
        console.log("  CoopDeployer:             ", address(d));
        console.log("  CitrateCooperativeFactory:", factory);
        console.log(
            "  (per-model co-ops are governance-created post-deploy via createCooperative)"
        );
    }
}
