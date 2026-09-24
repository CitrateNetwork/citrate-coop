// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.26;

import "forge-std/Script.sol";
import "../src/CitrateCooperativeFactory.sol";
import "../src/CitrateAdminSafe.sol";

/// @title CreateCooperativeProd — the post-gateSec production co-op, born under custody
/// @notice One reviewed broadcast that (1) deploys the SETL-M4 `CitrateAdminSafe` (2-of-3 + 48h
///         timelock) and (2) instantiates the whole co-op surface with that safe as `DEFAULT_ADMIN`
///         and the **SignatureCeremony key** as the settler. Because the factory hands admin to
///         `Params.admin` and renounces its own, the co-op is born under custody — there is NO window
///         where an EOA holds admin, and NO settler hot key to rotate out (unlike staging).
///
///         This closes the SETL-M4 custody blocker at deploy time. It assumes the SETL-S4-FIXED
///         factory is already live (run DeployCoop.s.sol first — the fixes moved its deterministic
///         address to 0x3B88731d65F044cc43c5d4589212c0F32A8C1667; see DeployCoop.t.sol).
///
///         ⚠️ DO NOT BROADCAST UNTIL: citrate-labs PR #46 is merged + the fixed stack redeployed, the
///         gateSec review re-run green against the fixed SHA, and owner + security lead have signed
///         the opinion. This script is the redeploy vehicle, not a bypass of the gate.
///
///         ⚠️ EDIT the five owner-decision addresses below (signers ×3, ceremony key, reserve
///         treasury, registrar, model hash). They are obvious placeholders so a stray broadcast
///         fails the require guards.
///
/// Run (you hold the deployer key; forge does the signing):
///   cd citrate-coop/contracts
///   forge script script/CreateCooperativeProd.s.sol \
///     --rpc-url https://rpc.citrate.ai --account citrate-deployer-40204 --broadcast
contract CreateCooperativeProd is Script {
    // --- live 40204 infra (stable) ---
    address constant FACTORY = 0x3B88731d65F044cc43c5d4589212c0F32A8C1667; // SETL-S4-fixed deterministic factory
    address constant WRAPPED_SALT = 0xAa918302B94a4B0E75E01e019cc6b819B4F7c906; // ERC20 SALT the coop escrows
    address constant KYC_REGISTRY = 0xcf41A81c8dFCDb6E61FeBfC34670964D226B33ED;

    // --- OWNER DECISIONS: set all of these before broadcasting ---
    // AdminSafe signers (2-of-3). Distinct custodians / hardware wallets.
    address constant SIGNER_1 = 0x1111111111111111111111111111111111111111; // TODO placeholder
    address constant SIGNER_2 = 0x2222222222222222222222222222222222222222; // TODO placeholder
    address constant SIGNER_3 = 0x3333333333333333333333333333333333333333; // TODO placeholder
    uint256 constant THRESHOLD = 2;
    uint256 constant DELAY = 48 hours;
    // The production settler = the key citrate-core's SignatureCeremony controls (Rule 3/4). NOT the
    // staging hot key 0x9D5d16FD — a fresh prod coop never grants the hot key.
    address constant CEREMONY_KEY = 0x4444444444444444444444444444444444444444; // TODO placeholder
    // The CRP reserve recipient — MUST be a treasury distinct from the ModelCooperative (SETL-H2; the
    // factory asserts reserveTreasury != coop && != 0).
    address constant RESERVE_TREASURY = 0x5555555555555555555555555555555555555555; // TODO placeholder
    // Bootstrap onboarding registrar (can be an ops key or the ceremony key).
    address constant REGISTRAR = 0x6666666666666666666666666666666666666666; // TODO placeholder
    // The model this co-op owns.
    bytes32 constant MODEL_HASH = keccak256("citrate-prod-model-v1"); // TODO confirm the real model id

    function run() external {
        require(FACTORY.code.length > 0, "factory not deployed - run DeployCoop.s.sol first");
        _requirePlaceholdersReplaced();

        address[] memory signers = new address[](3);
        signers[0] = SIGNER_1;
        signers[1] = SIGNER_2;
        signers[2] = SIGNER_3;

        bytes32[] memory modelIds = new bytes32[](1);
        modelIds[0] = MODEL_HASH;

        vm.startBroadcast();

        // 1) custody first: the 2-of-3 + 48h safe that will hold DEFAULT_ADMIN.
        CitrateAdminSafe adminSafe = new CitrateAdminSafe(signers, THRESHOLD, DELAY);

        // 2) the co-op, born under custody: admin = the safe, settler = the ceremony key.
        CitrateCooperativeFactory.Params memory p = CitrateCooperativeFactory.Params({
            salt: WRAPPED_SALT,
            kyc: KYC_REGISTRY,
            modelHash: MODEL_HASH,
            modelIds: modelIds,
            settler: CEREMONY_KEY, // production settler = SignatureCeremony key (no hot key)
            registrar: REGISTRAR,
            reserveTreasury: RESERVE_TREASURY, // != coop, asserted by the factory (SETL-H2)
            admin: address(adminSafe), // DEFAULT_ADMIN → the multisig+timelock (SETL-M4)
            reserveBps: 2000, // 20% CRP reserve
            vestWindow: 365 days
        });

        CitrateCooperativeFactory.Coop memory c = CitrateCooperativeFactory(FACTORY).createCooperative(p);

        vm.stopBroadcast();

        console.log("=== PROD co-op created on 40204 (under custody) ===");
        console.log("  CitrateAdminSafe:      ", address(adminSafe), "<-- DEFAULT_ADMIN (2-of-3 + 48h)");
        console.log("  MembershipSBT:         ", c.membership);
        console.log("  PatronageLedger:       ", c.ledger, "<-- settle target; SETTLER_ROLE = ceremony key");
        console.log("  ModelCooperative:      ", c.cooperative, "<-- SALT custody + claimDividend");
        console.log("  ContributionRewardPool:", c.rewardPool);
        console.log("  Governor:              ", c.governor);
        console.log("Post-deploy: re-pin PatronageLedger+ModelCooperative in the address books;");
        console.log("verify hasRole(DEFAULT_ADMIN, adminSafe)=true and (deployer)=false on all four;");
        console.log("verify hasRole(SETTLER_ROLE, ceremonyKey)=true. Then flip gateSec once the opinion is signed.");
    }

    function _requirePlaceholdersReplaced() internal pure {
        require(SIGNER_1 != 0x1111111111111111111111111111111111111111, "set SIGNER_1");
        require(SIGNER_2 != 0x2222222222222222222222222222222222222222, "set SIGNER_2");
        require(SIGNER_3 != 0x3333333333333333333333333333333333333333, "set SIGNER_3");
        require(CEREMONY_KEY != 0x4444444444444444444444444444444444444444, "set CEREMONY_KEY (prod settler)");
        require(RESERVE_TREASURY != 0x5555555555555555555555555555555555555555, "set RESERVE_TREASURY");
        require(REGISTRAR != 0x6666666666666666666666666666666666666666, "set REGISTRAR");
    }
}
