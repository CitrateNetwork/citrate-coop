// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import "forge-std/Script.sol";
import "../src/CitrateAdminSafe.sol";

/// @title DeployAdminSafe — the SETL-M4 custody move: a 2-of-3 multisig + 48h timelock that holds
///        DEFAULT_ADMIN of the co-op money surface, replacing the single deployer EOA.
/// @notice Deploy this FIRST, verify its config on-chain, then either:
///         (a) FRESH deploy — pass its address as `Params.admin` to createCooperative (the coop is
///             born under custody, no rotation needed); or
///         (b) LIVE rotate — the current admin EOA grants DEFAULT_ADMIN to this safe on each of the
///             four contracts (PatronageLedger, ModelCooperative, ContributionRewardPool,
///             MembershipSBT) then revokes its own.
///         See handoffs/SETL-M4_CUSTODY_ROTATION_2026-08-30.md for the full ceremony.
///
/// ⚠️ EDIT THE THREE SIGNER ADDRESSES below to the real key-holders before broadcasting. They are
///    intentionally left as obvious placeholders so a stray broadcast fails review.
///
/// Run (you hold the deployer key):
///   cd citrate-coop/contracts
///   forge script script/DeployAdminSafe.s.sol \
///     --rpc-url https://rpc.citrate.ai --account citrate-deployer-40204 --broadcast
contract DeployAdminSafe is Script {
    // --- OWNER: set these to the real signer key-holders (2-of-3) ---
    address constant SIGNER_1 = 0x1111111111111111111111111111111111111111; // TODO placeholder
    address constant SIGNER_2 = 0x2222222222222222222222222222222222222222; // TODO placeholder
    address constant SIGNER_3 = 0x3333333333333333333333333333333333333333; // TODO placeholder
    uint256 constant THRESHOLD = 2;
    uint256 constant DELAY = 48 hours;

    function run() external {
        require(
            SIGNER_1 != 0x1111111111111111111111111111111111111111
                && SIGNER_2 != 0x2222222222222222222222222222222222222222
                && SIGNER_3 != 0x3333333333333333333333333333333333333333,
            "set the real signer addresses before broadcasting"
        );
        address[] memory signers = new address[](3);
        signers[0] = SIGNER_1;
        signers[1] = SIGNER_2;
        signers[2] = SIGNER_3;

        vm.startBroadcast();
        CitrateAdminSafe safe = new CitrateAdminSafe(signers, THRESHOLD, DELAY);
        vm.stopBroadcast();

        console.log("=== SETL-M4 CitrateAdminSafe deployed on 40204 ===");
        console.log("  CitrateAdminSafe:", address(safe), "<-- pass as Params.admin OR rotate DEFAULT_ADMIN to it");
        console.log("  threshold:", THRESHOLD, "of 3");
        console.log("  timelock (s):", DELAY);
        console.log("Next: verify signers()/threshold()/delay() on-chain, then run the custody rotation runbook.");
    }
}
