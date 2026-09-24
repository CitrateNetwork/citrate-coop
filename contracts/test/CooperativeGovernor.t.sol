// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.26;

import "forge-std/Test.sol";
import "../src/CooperativeGovernor.sol";
import "../src/ModelCooperative.sol";
import "../src/PatronageLedger.sol";
import "../src/MembershipSBT.sol";
import "./mocks/MockERC20.sol";

contract MockKYC is IKYCRegistry {
    mapping(address => bool) public ok;
    mapping(address => bytes32) public id;
    function set(address a, bool v, bytes32 ident) external { ok[a] = v; id[a] = ident; }
    function isVerified(address a) external view returns (bool) { return ok[a]; }
    function identityOf(address a) external view returns (bytes32) { return id[a]; }
}

contract MockModelRegistry {
    mapping(bytes32 => uint256) public price;
    function setInferencePrice(bytes32 modelHash, uint256 p) external { price[modelHash] = p; }
}

/// @notice Tests for CooperativeGovernor (COOP-S1 WP-6).
///         Maps to features/coop_governance.feature + MembershipVoting.tla.
contract CooperativeGovernorTest is Test {
    MockERC20 salt;
    MockKYC kyc;
    MembershipSBT sbt;
    PatronageLedger ledger;
    ModelCooperative coop;
    CooperativeGovernor gov;
    MockModelRegistry registry;

    address alice = address(0xA1);
    address bob = address(0xB2);
    address carol = address(0xC3);
    address dave = address(0xD4); // community investor
    bytes32 constant MODEL = keccak256("model");

    function setUp() public {
        salt = new MockERC20();
        kyc = new MockKYC();
        bytes32[] memory models = new bytes32[](0);
        sbt = new MembershipSBT(address(kyc), models);
        ledger = new PatronageLedger(address(kyc), address(sbt));
        coop = new ModelCooperative(address(salt), address(kyc), address(ledger), MODEL);
        gov = new CooperativeGovernor(address(sbt), address(coop));
        coop.setGovernor(address(gov));
        registry = new MockModelRegistry();

        _admit(alice, MembershipSBT.MemberClass.Worker);
        _admit(bob, MembershipSBT.MemberClass.Worker);
        _admit(carol, MembershipSBT.MemberClass.Worker);
        _admit(dave, MembershipSBT.MemberClass.Investor);
    }

    function _admit(address a, MembershipSBT.MemberClass c) internal {
        kyc.set(a, true, keccak256(abi.encode("id", a)));
        bytes32[] memory agents = new bytes32[](0);
        sbt.mint(a, c, agents);
    }

    function _commit(uint256 id, address voter, CooperativeGovernor.Choice choice, bytes32 salt) internal {
        bytes32 h = keccak256(abi.encode(choice, salt, voter));
        vm.prank(voter);
        gov.commitVote(id, h);
    }

    function _reveal(uint256 id, address voter, CooperativeGovernor.Choice choice, bytes32 salt) internal {
        vm.prank(voter);
        gov.revealVote(id, choice, salt);
    }

    function _propose() internal returns (uint256 id) {
        bytes memory data = abi.encodeWithSelector(MockModelRegistry.setInferencePrice.selector, MODEL, uint256(42));
        vm.prank(alice);
        id = gov.propose(address(registry), 0, data, CooperativeGovernor.Kind.Standard);
    }

    // coop_governance: "each member casts exactly one vote"
    function test_one_member_one_vote() public {
        uint256 id = _propose();
        bytes32 s = keccak256("salt");
        _commit(id, alice, CooperativeGovernor.Choice.Yes, s);
        _commit(id, bob, CooperativeGovernor.Choice.Yes, s);
        _commit(id, carol, CooperativeGovernor.Choice.No, s);
        vm.warp(block.timestamp + gov.COMMIT_PERIOD() + 1);
        _reveal(id, alice, CooperativeGovernor.Choice.Yes, s);
        _reveal(id, bob, CooperativeGovernor.Choice.Yes, s);
        _reveal(id, carol, CooperativeGovernor.Choice.No, s);
        (uint256 yes, uint256 no) = gov.getTally(id);
        assertEq(yes, 2);
        assertEq(no, 1); // exactly 3 votes, one each — no SALT weighting
    }

    // coop_governance: "commit-reveal secret ballot" — reveal needs a prior commit
    function test_reveal_needs_commit() public {
        uint256 id = _propose();
        vm.warp(block.timestamp + gov.COMMIT_PERIOD() + 1);
        vm.prank(bob);
        vm.expectRevert(CooperativeGovernor.BadReveal.selector);
        gov.revealVote(id, CooperativeGovernor.Choice.Yes, keccak256("x"));
    }

    // coop_governance: "delegation reassigns the caster without inflating votes"
    function test_delegation_conserves() public {
        // alice delegates to bob BEFORE any proposal (delegation locked during votes)
        vm.prank(alice);
        gov.delegate(bob);
        assertEq(gov.delegatorCount(bob), 1);

        uint256 id = _propose();
        bytes32 s = keccak256("s");
        // alice has delegated → cannot commit directly
        bytes32 h = keccak256(abi.encode(CooperativeGovernor.Choice.Yes, s, alice));
        vm.prank(alice);
        vm.expectRevert(CooperativeGovernor.HasDelegated.selector);
        gov.commitVote(id, h);
        // bob (weight 2) + carol (weight 1) vote yes
        _commit(id, bob, CooperativeGovernor.Choice.Yes, s);
        _commit(id, carol, CooperativeGovernor.Choice.Yes, s);
        vm.warp(block.timestamp + gov.COMMIT_PERIOD() + 1);
        _reveal(id, bob, CooperativeGovernor.Choice.Yes, s);
        _reveal(id, carol, CooperativeGovernor.Choice.Yes, s);
        (uint256 yes,) = gov.getTally(id);
        assertEq(yes, 3); // 2 (bob+alice) + 1 (carol) == member count of active voters
    }

    // coop_governance: delegation is locked while a vote is open
    function test_delegation_locked_during_vote() public {
        _propose();
        vm.prank(carol);
        vm.expectRevert(CooperativeGovernor.DelegationLocked.selector);
        gov.delegate(bob);
    }

    // coop_governance: "community investors have approval-only rights"
    function test_investor_cannot_propose() public {
        bytes memory data = "";
        vm.prank(dave); // investor
        vm.expectRevert(CooperativeGovernor.NotWorker.selector);
        gov.propose(address(registry), 0, data, CooperativeGovernor.Kind.Standard);
    }

    function test_investor_cannot_vote_standard() public {
        uint256 id = _propose(); // Standard kind
        bytes32 h = keccak256(abi.encode(CooperativeGovernor.Choice.Yes, bytes32("s"), dave));
        vm.prank(dave);
        vm.expectRevert(CooperativeGovernor.InvestorCannotVoteStandard.selector);
        gov.commitVote(id, h);
    }

    function test_investor_can_vote_approval() public {
        bytes memory data = "";
        vm.prank(alice);
        uint256 id = gov.propose(address(0), 0, data, CooperativeGovernor.Kind.Approval);
        bytes32 s = bytes32("s");
        _commit(id, dave, CooperativeGovernor.Choice.Yes, s); // investor allowed on Approval
        assertTrue(gov.commitment(id, dave) != bytes32(0));
    }

    // coop_governance: "governance executes as the model owner"
    function test_execute_as_owner() public {
        uint256 id = _propose();
        bytes32 s = keccak256("s");
        _commit(id, alice, CooperativeGovernor.Choice.Yes, s);
        _commit(id, bob, CooperativeGovernor.Choice.Yes, s);
        _commit(id, carol, CooperativeGovernor.Choice.Yes, s);
        vm.warp(block.timestamp + gov.COMMIT_PERIOD() + 1);
        _reveal(id, alice, CooperativeGovernor.Choice.Yes, s);
        _reveal(id, bob, CooperativeGovernor.Choice.Yes, s);
        _reveal(id, carol, CooperativeGovernor.Choice.Yes, s);
        assertTrue(gov.passed(id));
        // before timelock → not executable
        vm.expectRevert(CooperativeGovernor.NotExecutable.selector);
        gov.execute(id);
        // after timelock → executes as model owner
        vm.warp(block.timestamp + gov.REVEAL_PERIOD() + gov.TIMELOCK() + 1);
        gov.execute(id);
        assertEq(registry.price(MODEL), 42);
    }

    // adversarial: a non-owner cannot execute through the coop directly
    function test_only_governor_executes_on_coop() public {
        vm.prank(address(0xBEEF));
        vm.expectRevert(ModelCooperative.NotGovernor.selector);
        coop.execute(address(registry), 0, "");
    }
}
