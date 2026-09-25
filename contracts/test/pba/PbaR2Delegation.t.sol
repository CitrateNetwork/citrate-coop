// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.26;

import "./PbaR2Base.sol";

/// PBA-L2-015 (MEDIUM, COOP-B-001): a representative who already carries delegators could delegate
/// onward. They then could not vote (HasDelegated) and their delegators were not re-pointed, so
/// every delegated vote parked on them was silently annihilated.
contract PbaR2DelegationTest is PbaR2Base {
    bytes4 constant REP_HAS_DELEGATORS = bytes4(keccak256("RepresentativeHasDelegators()"));

    function setUp() public {
        _deploy(6, 0);
    }

    function _tryDelegate(address from, address rep) internal returns (bool ok, bytes4 err) {
        vm.prank(from);
        bytes memory ret;
        (ok, ret) = address(gov).call(abi.encodeWithSelector(CooperativeGovernor.delegate.selector, rep));
        if (!ok && ret.length >= 4) err = bytes4(ret);
    }

    /// The audit PoC (test_PBA_onward_delegation_annihilates_votes_still_open), inverted.
    function test_PBA_L2_015_rep_with_delegators_cannot_delegate_onward() public {
        vm.prank(workers[0]);
        gov.delegate(workers[1]); // A -> B
        (bool ok, bytes4 err) = _tryDelegate(workers[1], workers[2]); // B -> C must be refused
        assertFalse(ok, "a rep carrying delegators must not delegate onward");
        assertEq(err, REP_HAS_DELEGATORS);
        assertEq(gov.delegatorCount(workers[1]), 1);
        assertEq(gov.delegatorCount(workers[2]), 0);
    }

    /// Once the delegators leave, the former rep may delegate normally.
    function test_PBA_L2_015_rep_can_delegate_after_delegators_leave() public {
        vm.prank(workers[0]);
        gov.delegate(workers[1]);
        vm.prank(workers[0]);
        gov.undelegate();
        vm.prank(workers[1]);
        gov.delegate(workers[2]);
        assertEq(gov.delegatorCount(workers[2]), 1);
    }

    /// Verifier bypass test_V_L2_015_chain_via_expel_readmit, inverted: R -> X, X expelled, D -> R,
    /// X re-admitted at the same address. The old R -> X delegation must stay dead (it was bound to X's
    /// former seat), so R votes for R + D and no vote is lost.
    function test_PBA_L2_015_expel_readmit_does_not_reform_chain() public {
        address D = workers[0];
        address R = workers[1];
        address X = workers[2];
        vm.prank(R); gov.delegate(X);
        _expel(X);
        vm.prank(D); gov.delegate(R);
        _admit(X, MembershipSBT.MemberClass.Worker); // same address, new seat
        assertEq(gov.delegatorCount(X), 0, "readmitted rep inherited stale delegators");

        uint256 id = _propose(workers[3], address(target), _setValueCall(1), CooperativeGovernor.Kind.Standard);
        bytes32 h = _ballot(id, CooperativeGovernor.Choice.Yes, BALLOT_SALT, R);
        vm.prank(R);
        (bool ok,) = address(gov).call(abi.encodeWithSelector(CooperativeGovernor.commitVote.selector, id, h));
        assertTrue(ok, "stale delegation to a readmitted rep blocked R from voting");
        _commit(id, X, CooperativeGovernor.Choice.Yes);
        vm.warp(_commitDeadline(id) + 1);
        _reveal(id, R, CooperativeGovernor.Choice.Yes);
        _reveal(id, X, CooperativeGovernor.Choice.Yes);
        (uint256 yes,) = gov.getTally(id);
        assertEq(yes, 3, "D's vote was lost to a re-formed chain"); // R(1) + D(1) + X(1)
    }

    /// Stale delegations can be cleared and re-pointed without underflow, and a readmitted member can
    /// be delegated to afresh.
    function test_PBA_L2_015_stale_delegation_repoint_after_readmit() public {
        address R = workers[1];
        address X = workers[2];
        vm.prank(R); gov.delegate(X);
        _expel(X);
        _admit(X, MembershipSBT.MemberClass.Worker);
        vm.prank(R); gov.undelegate();          // clears the dead pointer, no underflow
        vm.prank(R); gov.delegate(X);           // fresh, live delegation to X's new seat
        assertEq(gov.delegatorCount(X), 1);
        assertEq(gov.delegateOf(R), X);
    }

    /// A stale delegator clearing its dead pointer must not touch the readmitted rep's LIVE count
    /// (otherwise a live delegator's vote is silently dropped from the rep's weight).
    function test_PBA_L2_015_stale_undelegate_keeps_readmitted_rep_count() public {
        address R = workers[1];
        address X = workers[2];
        address W = workers[3];
        vm.prank(R); gov.delegate(X);
        _expel(X);
        _admit(X, MembershipSBT.MemberClass.Worker);
        vm.prank(W); gov.delegate(X);           // live delegation to X's new seat
        assertEq(gov.delegatorCount(X), 1);
        vm.prank(R); gov.undelegate();          // R's pointer to X is dead
        assertEq(gov.delegatorCount(X), 1, "stale undelegate stole a live delegator's weight");
    }

    /// Verifier NEW-2: only the MembershipSBT may call the expel hook. Unguarded, anyone could strip any
    /// member's delegation (and zero a rep's weight) mid-vote.
    function test_PBA_L2_040_expel_hook_is_membership_only() public {
        vm.prank(workers[0]); gov.delegate(workers[1]);
        vm.prank(address(0xBAD));
        vm.expectRevert(bytes4(keccak256("NotMembership()")));
        gov.onMemberExpelled(workers[0]);
        vm.prank(workers[1]);
        vm.expectRevert(bytes4(keccak256("NotMembership()")));
        gov.onMemberExpelled(workers[1]);
        assertEq(gov.delegateOf(workers[0]), workers[1]);
        assertEq(gov.delegatorCount(workers[1]), 1);
    }

    /// TRIPWIRE (the audit's "sum of attainable weight == memberCount"): after any sequence of
    /// delegate/undelegate calls, the weight the active voters can cast (1 + delegators each)
    /// accounts for every member exactly once.
    function testFuzz_PBA_L2_015_attainable_weight_conserved(uint256 seed) public {
        uint256 n = workers.length;
        for (uint256 step = 0; step < 24; step++) {
            uint256 r = uint256(keccak256(abi.encode(seed, step)));
            address from = workers[r % n];
            if ((r >> 8) % 4 == 0) {
                vm.prank(from);
                gov.undelegate();
            } else {
                _tryDelegate(from, workers[(r >> 16) % n]);
            }
        }
        uint256 attainable;
        for (uint256 i = 0; i < n; i++) {
            if (gov.delegateOf(workers[i]) == address(0)) attainable += 1 + gov.delegatorCount(workers[i]);
        }
        assertEq(attainable, sbt.memberCount(), "delegated votes were lost or double counted");
    }
}
