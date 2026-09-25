// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.26;

// PBA R2 (2026-09-24 pre-bounty adversarial audit, remediation lane COOP) — shared harness.
// Every regression test drives the REAL entry points of a factory-deployed co-op (factory ->
// createCooperative -> registrar mint -> governor propose/commit/reveal/execute), the same wiring
// production uses, never a hand-assembled subset that skips a gate.

import "forge-std/Test.sol";
import "../../src/CitrateCooperativeFactory.sol";
import "../../src/CooperativeGovernor.sol";
import "../../src/ModelCooperative.sol";
import "../../src/PatronageLedger.sol";
import "../../src/MembershipSBT.sol";
import "../../src/ContributionRewardPool.sol";
import "../../src/CoopDeployer.sol";
import "../../src/CitrateAdminSafe.sol";
import "../mocks/MockERC20.sol";

contract PbaR2KYC is IKYCRegistry {
    mapping(address => bool) public ok;
    mapping(address => bytes32) public id;
    function set(address a, bool v, bytes32 ident) external { ok[a] = v; id[a] = ident; }
    function isVerified(address a) external view returns (bool) { return ok[a]; }
    function identityOf(address a) external view returns (bytes32) { return id[a]; }
}

/// A harmless external governance target (stands in for ModelRegistry.setInferencePrice).
contract PbaR2Target {
    uint256 public value;
    function setValue(uint256 v) external { value = v; }
}

abstract contract PbaR2Base is Test {
    MockERC20 salt;
    PbaR2KYC kyc;
    CitrateCooperativeFactory factory;
    CitrateCooperativeFactory.Coop c;
    MembershipSBT sbt;
    PatronageLedger ledger;
    ModelCooperative coop;
    ContributionRewardPool pool;
    CooperativeGovernor gov;
    PbaR2Target target;

    address admin = address(0xAD3155);
    address registrar = address(0x4E6157242);
    address settler = address(0x5E771E5);
    address reserveTreasury = address(0x7EA5);
    bytes32 constant MODEL = keccak256("model");
    bytes32 constant BALLOT_SALT = keccak256("ballot-salt");

    address[] workers;
    address[] investors;

    function _params(bytes32 model, address reg, address set_, address adm)
        internal
        view
        returns (CitrateCooperativeFactory.Params memory p)
    {
        bytes32[] memory ids = new bytes32[](1);
        ids[0] = model;
        p = CitrateCooperativeFactory.Params({
            salt: address(salt), kyc: address(kyc), modelHash: model, modelIds: ids,
            settler: set_, registrar: reg, reserveTreasury: reserveTreasury, admin: adm,
            reserveBps: 2000, vestWindow: 365 days
        });
    }

    /// Deploy a co-op through the factory and seat `nWorkers` workers + `nInvestors` investors.
    function _deploy(uint256 nWorkers, uint256 nInvestors) internal {
        salt = new MockERC20();
        kyc = new PbaR2KYC();
        factory = new CitrateCooperativeFactory(new CoopDeployer());
        c = factory.createCooperative(_params(MODEL, registrar, settler, admin));
        sbt = MembershipSBT(c.membership);
        ledger = PatronageLedger(c.ledger);
        coop = ModelCooperative(c.cooperative);
        pool = ContributionRewardPool(c.rewardPool);
        gov = CooperativeGovernor(c.governor);
        target = new PbaR2Target();
        for (uint256 i = 0; i < nWorkers; i++) workers.push(_admit(address(uint160(0x1000 + i)), MembershipSBT.MemberClass.Worker));
        for (uint256 i = 0; i < nInvestors; i++) investors.push(_admit(address(uint160(0x2000 + i)), MembershipSBT.MemberClass.Investor));
    }

    function _admit(address a, MembershipSBT.MemberClass cls) internal returns (address) {
        kyc.set(a, true, keccak256(abi.encode("id", a)));
        vm.prank(registrar);
        sbt.mint(a, cls, new bytes32[](0));
        return a;
    }

    function _expel(address a) internal {
        vm.prank(registrar);
        sbt.expel(a);
    }

    /// The ballot commitment for `voter` on proposal `id` (single place to track the hash format).
    function _ballot(uint256 id, CooperativeGovernor.Choice choice, bytes32 s, address voter)
        internal
        view
        virtual
        returns (bytes32)
    {
        id; // pre-PBA-L2-040(B-017) ballot format: no proposal/contract/chain domain
        return keccak256(abi.encode(choice, s, voter));
    }

    function _commit(uint256 id, address voter, CooperativeGovernor.Choice choice) internal {
        bytes32 h = _ballot(id, choice, BALLOT_SALT, voter);
        vm.prank(voter);
        gov.commitVote(id, h);
    }

    function _reveal(uint256 id, address voter, CooperativeGovernor.Choice choice) internal {
        vm.prank(voter);
        gov.revealVote(id, choice, BALLOT_SALT);
    }

    function _propose(address proposer, address tgt, bytes memory data, CooperativeGovernor.Kind kind)
        internal
        returns (uint256 id)
    {
        vm.prank(proposer);
        id = gov.propose(tgt, 0, data, kind);
        proposedAt[id] = block.timestamp;
    }

    mapping(uint256 => uint256) internal proposedAt;

    function _commitDeadline(uint256 id) internal view returns (uint256) {
        return proposedAt[id] + gov.COMMIT_PERIOD();
    }

    function _revealDeadline(uint256 id) internal view returns (uint256) {
        return _commitDeadline(id) + gov.REVEAL_PERIOD();
    }

    function _executeAfter(uint256 id) internal view returns (uint256) {
        return _revealDeadline(id) + gov.TIMELOCK();
    }

    /// Commit `yes` Yes-votes and `no` No-votes from the first workers, reveal them all, and warp
    /// to the start of the execution window (executeAfter).
    function _voteWorkers(uint256 id, uint256 yes, uint256 no) internal {
        for (uint256 i = 0; i < yes; i++) _commit(id, workers[i], CooperativeGovernor.Choice.Yes);
        for (uint256 i = yes; i < yes + no; i++) _commit(id, workers[i], CooperativeGovernor.Choice.No);
        vm.warp(_commitDeadline(id) + 1);
        for (uint256 i = 0; i < yes; i++) _reveal(id, workers[i], CooperativeGovernor.Choice.Yes);
        for (uint256 i = yes; i < yes + no; i++) _reveal(id, workers[i], CooperativeGovernor.Choice.No);
        vm.warp(_executeAfter(id));
    }

    function _setValueCall(uint256 v) internal pure returns (bytes memory) {
        return abi.encodeWithSelector(PbaR2Target.setValue.selector, v);
    }
}
