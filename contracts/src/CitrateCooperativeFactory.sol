// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.26;

import "./lib/Auth.sol";
import "./MembershipSBT.sol";
import "./PatronageLedger.sol";
import "./ModelCooperative.sol";
import "./ContributionRewardPool.sol"; // type only (role wiring) — never `new`ed here
import "./CoopDeployer.sol";

/// @title CitrateCooperativeFactory — deploys + wires one co-op per model (RFC-CIT-COOP-0001)
/// @notice Deploys the five contracts and wires the roles so the system is governance-ready:
///         membership ← registrar; ledger ← settler(coordinator) + COOP_ROLE(coop, pool);
///         coop ← governor; pool ← year-keeper(coop, the governance caller); coop ← REGISTRAR on membership (so
///         governance can admit/expel via execute). Hands DEFAULT_ADMIN to `admin` and renounces.
/// @dev Funding the 50M CRP is a separate treasury/governance action (not done here).
/// @dev EIP-170: the ContributionRewardPool + CooperativeGovernor creationCode is off-loaded to
///      `CoopDeployer` (created once in this constructor, so it sits in this factory's INIT-code,
///      not its runtime). That keeps the runtime under 24,576 B. `createCooperative` behaviour is
///      unchanged; the deterministic CREATE2 factory address re-freezes once (see DeployCoop.t).
contract CitrateCooperativeFactory {
    struct Coop {
        address membership;
        address ledger;
        address cooperative;
        address rewardPool;
        address governor;
    }

    /// Off-loads Pool + Governor bytecode out of this factory's runtime (EIP-170). Created in the
    /// constructor, so it lives in this factory's init-code; nothing external references it.
    CoopDeployer public immutable deployer;

    mapping(bytes32 => address) public cooperativeOf; // modelHash => ModelCooperative
    Coop[] public coops;

    event CooperativeCreated(bytes32 indexed modelHash, address indexed cooperative, address governor);

    /// PBA-L2-018: the canonical registry is first-writer-wins. A model that already has a co-op can
    /// never be re-pointed at another one (the prior code let anyone overwrite it with a co-op wired
    /// to their own settler/registrar/admin).
    error ModelAlreadyHasCooperative(bytes32 modelHash);

    struct Params {
        address salt;
        address kyc;
        bytes32 modelHash;
        bytes32[] modelIds;
        address settler;        // federation coordinator (SETTLER_ROLE)
        address registrar;      // initial member onboarding (REGISTRAR_ROLE)
        address reserveTreasury;// CRP reserve recipient (NOT the co-op's dividend balance)
        address admin;          // final DEFAULT_ADMIN (owner multisig)
        uint16 reserveBps;
        uint64 vestWindow;
    }

    /// @param _deployer the CoopDeployer, deployed SEPARATELY and passed in (NOT `new`ed here).
    /// @dev chain-40204 fix (2026-08-29): a contract's nonce is NOT advanced by CREATEs performed
    ///      in its own constructor on 40204. When the factory did `new CoopDeployer()` here, the
    ///      helper landed at this factory's nonce-1 CREATE slot yet the factory's persistent nonce
    ///      stayed 0 — so `createCooperative`'s method-CREATEs started from nonce 0 and its second
    ///      `new` (PatronageLedger, nonce 1) COLLIDED with the constructor-made CoopDeployer, and
    ///      every createCooperative reverted (CreateCollision) on-chain (Foundry's EIP-161-correct
    ///      EVM did not reproduce it, so tests passed). Deploying the helper externally leaves the
    ///      factory's method-CREATE sequence (SBT=0, Ledger=1, Coop=2) collision-free. EIP-170 is
    ///      unaffected: the helper's creationCode is no longer embedded in this factory's init-code,
    ///      and the runtime never held it.
    constructor(CoopDeployer _deployer) {
        require(address(_deployer) != address(0), "deployer=0");
        deployer = _deployer;
    }

    function createCooperative(Params calldata p) external returns (Coop memory c) {
        if (cooperativeOf[p.modelHash] != address(0)) revert ModelAlreadyHasCooperative(p.modelHash);
        MembershipSBT sbt = new MembershipSBT(p.kyc, p.modelIds);
        PatronageLedger ledger = new PatronageLedger(p.kyc, address(sbt));
        ModelCooperative coop = new ModelCooperative(p.salt, p.kyc, address(ledger), p.modelHash);
        // SETL-H2 fix: the CRP reserve MUST go to a treasury distinct from the co-op. If it flowed to
        // the co-op, the permissionless syncDirectRevenue would reclassify the held reserve as member
        // dividends (defeating the reserve, and via SETL-C1 making it rug-able at dissolve).
        require(
            p.reserveTreasury != address(0) && p.reserveTreasury != address(coop),
            "reserveTreasury must be a separate, non-zero address"
        );
        // Pool + Governor are deployed by the helper (their creationCode lives there, not here).
        // The helper hands the Pool's DEFAULT_ADMIN back to this factory before returning.
        (address poolAddr, address govAddr) = deployer.deployPoolAndGovernor(
            p.salt, address(ledger), p.kyc, p.reserveTreasury, p.reserveBps, p.vestWindow, address(sbt), address(coop)
        );
        ContributionRewardPool pool = ContributionRewardPool(poolAddr);

        // --- wire roles (this factory is DEFAULT_ADMIN of each at this point) ---
        coop.setGovernor(govAddr);

        ledger.grantRole(ledger.SETTLER_ROLE(), p.settler);
        ledger.grantRole(ledger.COOP_ROLE(), address(coop));        // creditRevenue/recordClaim/closeWindow
        // SETL-H1/M3 fix: the pool gets ONLY the dedicated year-keeper role (advanceYear), not the
        // broad COOP_ROLE — least-privilege, and there is no bookkeeping-skipping year-advance path.
        ledger.grantRole(ledger.YEAR_KEEPER_ROLE(), poolAddr);

        // PBA-L2-038: the year-keeper is the CO-OP, not the governor. The governor's only outbound
        // call is coop.execute, so on the governance path the pool sees msg.sender == coop; a role on
        // the governor was unreachable and no cohort could ever be closed (or grant forfeited).
        pool.grantRole(pool.YEAR_KEEPER_ROLE(), address(coop));

        sbt.grantRole(sbt.REGISTRAR_ROLE(), p.registrar);     // bootstrap onboarding
        sbt.grantRole(sbt.REGISTRAR_ROLE(), address(coop));   // governance admit/expel via execute
        sbt.setGovernanceHook(govAddr);                       // PBA-L2-040 COOP-02: expel clears delegation

        // --- hand admin to the owner, renounce the factory's admin ---
        _handAdmin(sbt, p.admin);
        _handAdmin(ledger, p.admin);
        _handAdmin(coop, p.admin);
        _handAdmin(pool, p.admin);

        c = Coop(address(sbt), address(ledger), address(coop), poolAddr, govAddr);
        cooperativeOf[p.modelHash] = address(coop);
        coops.push(c);
        emit CooperativeCreated(p.modelHash, address(coop), govAddr);
    }

    function _handAdmin(Auth a, address admin) internal {
        a.grantRole(a.DEFAULT_ADMIN_ROLE(), admin);
        a.revokeRole(a.DEFAULT_ADMIN_ROLE(), address(this));
    }

    function count() external view returns (uint256) {
        return coops.length;
    }
}
