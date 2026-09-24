// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.26;

import "./ContributionRewardPool.sol";
import "./CooperativeGovernor.sol";

/// @title CoopDeployer — EIP-170 relief for CitrateCooperativeFactory (RFC-CIT-COOP-0001)
/// @notice The factory used to `new` all five children inside `createCooperative`, embedding
///         each child's creationCode in the factory's RUNTIME bytecode and pushing it to
///         31,694 B — over the 24,576 EIP-170 limit, so it could not deploy on chain 40204.
///         This helper holds the creationCode of the two largest children (ContributionRewardPool
///         + CooperativeGovernor). It is created ONCE by the factory's constructor and stored, so
///         its bytecode lives in the factory's INIT-code (constructor), not its runtime. Runtime
///         moves under the limit; the frozen CREATE2 factory address just re-freezes once.
/// @dev Behaviour is identical to the old inline deploy. The Pool is `Auth` — its constructor
///      grants DEFAULT_ADMIN to whoever deploys it (here, this deployer), so we hand that admin
///      to the calling factory and renounce ours; the end state is byte-for-byte what inlining
///      produced. The Governor is not `Auth` (no admin). Only the factory that created this
///      deployer calls it; the Pool admin is transferred to `msg.sender` (that factory).
contract CoopDeployer {
    /// @notice Deploy the reward pool + governor for one co-op and hand the Pool's admin to the
    ///         caller (the factory), which then wires roles + hands admin to the owner.
    /// @param saltToken       the SALT ERC-20 (ModelCooperative/Pool treasury asset)
    /// @param ledger          the co-op's PatronageLedger
    /// @param kyc             the KYC registry
    /// @param reserveTreasury CRP reserve recipient (the co-op treasury)
    /// @param reserveBps      per-cohort reserve skim
    /// @param vestWindow      linear vest duration per cohort
    /// @param sbt             the co-op's MembershipSBT (governor voter roll)
    /// @param coop            the ModelCooperative (governor execution target)
    function deployPoolAndGovernor(
        address saltToken,
        address ledger,
        address kyc,
        address reserveTreasury,
        uint16 reserveBps,
        uint64 vestWindow,
        address sbt,
        address coop
    ) external returns (address pool, address governor) {
        ContributionRewardPool p =
            new ContributionRewardPool(saltToken, ledger, kyc, reserveTreasury, reserveBps, vestWindow);
        // Pool.Auth granted DEFAULT_ADMIN to this deployer at construction. Hand it to the
        // factory (msg.sender) and renounce ours, so the factory can grant YEAR_KEEPER_ROLE and
        // then hand admin to the owner — the same end state as the pre-refactor inline deploy.
        p.grantRole(p.DEFAULT_ADMIN_ROLE(), msg.sender);
        p.revokeRole(p.DEFAULT_ADMIN_ROLE(), address(this));

        governor = address(new CooperativeGovernor(sbt, coop)); // not Auth — no admin handoff
        pool = address(p);
    }
}
