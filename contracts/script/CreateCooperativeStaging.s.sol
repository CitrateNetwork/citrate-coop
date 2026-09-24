// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.26;

import "forge-std/Script.sol";
import "./Salts.sol";
import "../src/CitrateCooperativeFactory.sol";

/// @title CreateCooperativeStaging — SETL-S2 pre-audit staging cooperative on 40204
/// @notice Governance call that instantiates the per-model coop surface (MembershipSBT +
///         PatronageLedger + ModelCooperative + ContributionRewardPool + Governor) via the
///         deterministic factory, so SETL-S2 can integrate against REAL addresses.
///
///         ⚠️ PRE-AUDIT (owner decision 2026-08-28: "deploy to staging/dry-run now, pre-audit").
///         The rule8 T1 money-surface security sign-off (gateSec) is NOT yet passed — do NOT
///         route real member SALT through this instance until it is. This exists to unblock
///         coordinator integration, not to open live patronage.
///
///         CUSTODY (owner decision 2026-08-28: "ceremony key, locked design"):
///         - settler (SETTLER_ROLE, the coordinator) = the deployer/ceremony account for staging;
///           the PRODUCTION settler is whatever key citrate-core's SignatureCeremony controls,
///           set once identified. admin can rotate it: `ledger.grantRole/revokeRole(SETTLER_ROLE, …)`.
///         - admin (DEFAULT_ADMIN, the high-value rotator) = deployer for staging; rotate to the
///           owner multisig for production via `_handAdmin`-equivalent grant+revoke.
///         - COOP_ROLE is held by the ModelCooperative + Pool contracts (automatic, not a key).
///
/// Prereq: the factory must be live at the deterministic address (run DeployCoop.s.sol first).
///
/// Run (you hold the signer — like the reroll):
///   cd citrate-coop/contracts
///   forge script script/CreateCooperativeStaging.s.sol \
///     --rpc-url https://rpc.citrate.ai --account citrate-deployer-40204 --broadcast
contract CreateCooperativeStaging is Script {
    // Live 40204 addresses (verified on-chain, 2026-08-28).
    address constant FACTORY = 0x772d215d48d9E8CCBe65629F38Ba8B6b6fEd0b94; // deterministic (post 2026-08-29 CoopDeployer-arg fix)
    address constant WRAPPED_SALT = 0xAa918302B94a4B0E75E01e019cc6b819B4F7c906; // ERC20 SALT the coop escrows
    address constant KYC_REGISTRY = 0xcf41A81c8dFCDb6E61FeBfC34670964D226B33ED;
    address constant STABLECOIN_TREASURY = 0x0e9C5953Bd7c77252119E32f989Ba94f735c8599; // CRP reserve recipient
    // Staging custody (rotatable). Production settler = the SignatureCeremony key; admin = owner multisig.
    address constant DEPLOYER = 0x4fAB35c8c5033c80b3a0452A873B81e6ED4ED732;

    function run() external {
        CitrateCooperativeFactory factory = CitrateCooperativeFactory(FACTORY);
        require(FACTORY.code.length > 0, "factory not deployed - run DeployCoop.s.sol first");

        bytes32 modelHash = keccak256("citrate-staging-model-v1");
        bytes32[] memory modelIds = new bytes32[](1);
        modelIds[0] = modelHash;

        CitrateCooperativeFactory.Params memory p = CitrateCooperativeFactory.Params({
            salt: WRAPPED_SALT,
            kyc: KYC_REGISTRY,
            modelHash: modelHash,
            modelIds: modelIds,
            settler: DEPLOYER, // STAGING coordinator; rotate to the SignatureCeremony key for prod
            registrar: DEPLOYER, // STAGING onboarding; rotate for prod
            reserveTreasury: STABLECOIN_TREASURY,
            admin: DEPLOYER, // STAGING admin; rotate to owner multisig for prod
            reserveBps: 2000, // 20% CRP reserve (coop test fixture)
            vestWindow: 365 days
        });

        vm.startBroadcast();
        CitrateCooperativeFactory.Coop memory c = factory.createCooperative(p);
        vm.stopBroadcast();

        console.log("=== SETL-S2 staging cooperative created on 40204 ===");
        console.log("  MembershipSBT:        ", c.membership);
        console.log("  PatronageLedger:      ", c.ledger, "<-- SETTLER_ROLE target for the coordinator");
        console.log("  ModelCooperative:     ", c.cooperative, "<-- COOP_ROLE + SALT custody");
        console.log("  ContributionRewardPool:", c.rewardPool);
        console.log("  Governor:             ", c.governor);
        console.log("  modelHash:            ");
        console.logBytes32(modelHash);
        console.log("Sync ledger+cooperative into citrate-core/src-tauri/addresses/40204.json + the settlement book.");
    }
}
