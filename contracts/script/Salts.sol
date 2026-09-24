// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.26;

/**
 * @title Salts — the CREATE2 salt registry for the co-op contracts on chain 40204
 * @notice Single source of truth for the co-op deterministic-deploy salts. The factory
 *         is deployed via `new CitrateCooperativeFactory{salt: Salts.salt("…")}()`, which
 *         Foundry routes through the same genesis Arachnid CREATE2 deployer the chain uses
 *         (0x4e59b44847b379578588920cA78FbF26c0B4956C). The resulting address is
 *
 *           keccak256(0xff ++ 0x4e59… ++ salt ++ keccak256(init_code))[12:]
 *
 *         which depends ONLY on (deployer=0x4e59…, salt, init_code) — NOT on deploy order
 *         or the broadcasting EOA's nonce. So every re-roll that deploys the same bytecode
 *         with the same args lands the factory at the same address.
 *
 * @dev SEPARATE namespace from the chain's `Salts.sol` (which uses "citrate.v1."). The co-op
 *      lives in its own repo + foundry project, so it carries its own salt VERSION; this is
 *      ADR-I64-coop-home (deploy the co-op deterministically from `citrate-coop`, do NOT
 *      fold the source into `citrate-chain`). Because the namespaces differ, a co-op salt
 *      can never collide with a chain salt even for an identically-named contract.
 *
 *      DETERMINISM INPUTS (all must be pinned for the factory address to be stable):
 *        1. salts — this file (VERSION below).
 *        2. creationCode — solc 0.8.26 + optimizer(200) + evm_version=cancun +
 *           bytecode_hash="none" (foundry.toml — the metadata-hash strip is what makes
 *           creationCode byte-reproducible across machines).
 *        3. constructor args — the factory takes NONE, so its init_code is just its
 *           creationCode; the per-model contracts are instantiated at runtime by
 *           `createCooperative` (governance), not in the deterministic ceremony.
 *
 *      Bumping VERSION is a deliberate full co-op redeploy — it moves the factory address.
 */
library Salts {
    /// Global co-op salt namespace. Bump to force a co-op factory redeploy.
    string internal constant VERSION = "citrate.coop.v1.";

    /// Deterministic salt for a co-op contract by canonical name.
    function salt(string memory name) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(VERSION, name));
    }
}
