// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import "forge-std/Test.sol";
import "../script/Salts.sol";
import "../src/CitrateCooperativeFactory.sol";
import "../src/CoopDeployer.sol";

/// @title DeployCoopDeterminismTest — the re-roll stability guarantee for the co-op factory
/// @notice Proves `CitrateCooperativeFactory` has a fixed, predictable CREATE2 address, so
///         every re-roll redeploys it to the SAME address (apps/governance that reference it
///         keep working with no env change). This is the WP-B2 acceptance ratchet.
contract DeployCoopDeterminismTest is Test {
    /// The Arachnid / EIP-2470 deterministic CREATE2 deployer — genesis-allocated on chain
    /// 40204 and Foundry's default for `--broadcast`, so the ceremony's `new X{salt}()`
    /// routes through it. (In a unit-test context `new{salt}` instead uses the test contract
    /// as deployer — hence `test_salt_controls_deployed_address` predicts with address(this),
    /// while the FROZEN canonical address below uses 0x4e59…, the real ceremony deployer.)
    address constant CREATE2_DEPLOYER = 0x4e59b44847b379578588920cA78FbF26c0B4956C;

    function test_salt_is_in_coop_namespace() public pure {
        // Pin the salt preimage — guards against a VERSION/name drift silently moving the address.
        assertEq(
            Salts.salt("CitrateCooperativeFactory"),
            keccak256(abi.encodePacked("citrate.coop.v1.", "CitrateCooperativeFactory")),
            "co-op factory salt drifted from the citrate.coop.v1 namespace"
        );
    }

    /// FROZEN canonical on-chain address — computed from (genesis CREATE2 deployer 0x4e59…,
    /// the co-op salt, the factory creationCode). This is exactly what the re-roll ceremony
    /// (`forge script DeployCoop --broadcast`) produces, and what the address manifest +
    /// any referencing app/governance will pin. If the factory bytecode or the salt drifts,
    /// this fails — the early signal that the address moved (a breaking change). Re-freeze
    /// intentionally (and update the manifest) only when an address move is deliberate.
    function test_canonical_factory_address_is_frozen() public {
        // CoopDeployer is now deployed SEPARATELY (CREATE2) and passed to the factory ctor
        // (chain-40204 constructor-CREATE nonce fix, 2026-08-29). Its canonical address is a
        // function of its own salt + creationCode.
        address coopDeployer = vm.computeCreate2Address(
            Salts.salt("CoopDeployer"),
            keccak256(type(CoopDeployer).creationCode),
            CREATE2_DEPLOYER
        );
        assertEq(
            coopDeployer,
            // Re-frozen 2026-09-23: solc pinned up from 0.8.26 to 0.8.36 to match
            // citrate-chain/contracts/foundry.toml (the byte-reproducibility invariant this
            // repo's foundry.toml declares). The compiler bump changes CoopDeployer's
            // creationCode, so its canonical CREATE2 address moves deliberately from the
            // stale 0xd7CBAeB1…56Fe (0.8.26 freeze) to this 0.8.36 value. Co-op factory is
            // not yet deployed on 40204, so the address manifest must be regenerated to match.
            0xbfFD95A500c55F28d670A079cF96986606b9Aac4, // FROZEN CoopDeployer canonical (solc 0.8.36)
            "CoopDeployer canonical CREATE2 address drifted"
        );
        // The factory address now folds the CoopDeployer arg into init_code:
        // init_code = creationCode ++ abi.encode(coopDeployer).
        address canonical = vm.computeCreate2Address(
            Salts.salt("CitrateCooperativeFactory"),
            keccak256(abi.encodePacked(type(CitrateCooperativeFactory).creationCode, abi.encode(coopDeployer))),
            CREATE2_DEPLOYER
        );
        assertEq(
            canonical,
            // Re-frozen 2026-09-23 (solc 0.8.36): the factory init_code folds in both the
            // factory creationCode and the CoopDeployer arg, and the 0.8.26→0.8.36 compiler bump
            // (chain-match, see foundry.toml) moves both — so the canonical CREATE2 address moves
            // deliberately from the stale 0x3B88731d…C1667 (0.8.26 freeze / SETL-S4 audit fixes:
            // reserveTreasury!=coop H2, the pool's YEAR_KEEPER_ROLE grant H1/M3, PatronageLedger
            // no-credit-before-units M1) to this 0.8.36 value. Address manifest must be regenerated.
            0xcEa6750252d593E5a9FCD1a64C75DC1F081cA3Ff,
            "co-op factory canonical CREATE2 address drifted"
        );
    }

    /// The salt is load-bearing: deploying via `new{salt}` lands at the address predicted for
    /// the deployer doing it. Proves the salt — not nonce/order — controls the address.
    function test_salt_controls_deployed_address() public {
        bytes32 s = Salts.salt("CitrateCooperativeFactory");
        // The factory now takes the CoopDeployer as a constructor arg, so init_code =
        // creationCode ++ abi.encode(deployer). The CREATE2 address is a function of that arg.
        CoopDeployer d = new CoopDeployer();
        bytes memory initCode =
            abi.encodePacked(type(CitrateCooperativeFactory).creationCode, abi.encode(d));
        address predicted = vm.computeCreate2Address(s, keccak256(initCode), address(this));
        CitrateCooperativeFactory f = new CitrateCooperativeFactory{salt: s}(d);
        assertEq(address(f), predicted, "salt must determine the deployed address");
    }
}
