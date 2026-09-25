// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.26;

import "./PbaR2Base.sol";

/// PBA-L2-017 (HIGH, COOP-B-003): the proposal Kind was proposer-chosen and never bound to the
/// calldata, so wind-down / dissolution could be routed as Standard (simple majority, investors
/// excluded), bypassing the AB 816 2/3 supermajority and the community-investor approval right.
contract PbaR2KindBindingTest is PbaR2Base {
    bytes4 constant KIND_MISMATCH = bytes4(keccak256("KindMismatch()"));

    function setUp() public {
        _deploy(3, 1);
    }

    function _activate() internal {
        uint256 id = _propose(workers[0], address(coop), abi.encodeWithSelector(ModelCooperative.activate.selector), CooperativeGovernor.Kind.Standard);
        _voteWorkers(id, 3, 0);
        gov.execute(id);
        assertEq(uint8(coop.state()), uint8(ModelCooperative.CoopState.Active));
    }

    /// Propose through the real entry point and return (ok, revert selector).
    function _tryPropose(address tgt, bytes memory data, CooperativeGovernor.Kind kind) internal returns (bool ok, bytes4 err) {
        vm.prank(workers[0]);
        bytes memory ret;
        (ok, ret) = address(gov).call(abi.encodeWithSelector(CooperativeGovernor.propose.selector, tgt, uint256(0), data, kind));
        if (!ok && ret.length >= 4) err = bytes4(ret);
    }

    function test_PBA_L2_017_dissolve_as_standard_rejected() public {
        (bool ok, bytes4 err) = _tryPropose(address(coop), abi.encodeWithSelector(ModelCooperative.dissolve.selector, address(0xD15)), CooperativeGovernor.Kind.Standard);
        assertFalse(ok, "dissolve routed as Standard must be refused");
        assertEq(err, KIND_MISMATCH);
    }

    /// The end-to-end bypass: a 2-of-3 worker simple majority (below 2/3, investor shut out) wound
    /// the co-op down permanently. Routed as Standard it is refused at propose time.
    function test_PBA_L2_017_winddown_as_standard_rejected() public {
        _activate();
        (bool ok, bytes4 err) = _tryPropose(address(coop), abi.encodeWithSelector(ModelCooperative.beginWindDown.selector), CooperativeGovernor.Kind.Standard);
        assertFalse(ok, "beginWindDown routed as Standard must be refused");
        assertEq(err, KIND_MISMATCH);
        assertEq(uint8(coop.state()), uint8(ModelCooperative.CoopState.Active));
    }

    /// The sale / merger path on any target (model ownership hand-off) is Approval-class too.
    function test_PBA_L2_017_ownership_transfer_as_standard_rejected() public {
        (bool ok, bytes4 err) = _tryPropose(address(0x0DE1), abi.encodeWithSignature("transferOwnership(address)", address(0xB0B)), CooperativeGovernor.Kind.Standard);
        assertFalse(ok);
        assertEq(err, KIND_MISMATCH);
    }

    /// The legitimate path still works: wind-down as Approval needs 2/3 and admits the investor.
    function test_PBA_L2_017_winddown_as_approval_executes_with_investor() public {
        _activate();
        uint256 id = _propose(workers[0], address(coop), abi.encodeWithSelector(ModelCooperative.beginWindDown.selector), CooperativeGovernor.Kind.Approval);
        _commit(id, workers[0], CooperativeGovernor.Choice.Yes);
        _commit(id, workers[1], CooperativeGovernor.Choice.Yes);
        _commit(id, investors[0], CooperativeGovernor.Choice.Yes); // investor votes on Approval
        _commit(id, workers[2], CooperativeGovernor.Choice.No);
        vm.warp(_commitDeadline(id) + 1);
        _reveal(id, workers[0], CooperativeGovernor.Choice.Yes);
        _reveal(id, workers[1], CooperativeGovernor.Choice.Yes);
        _reveal(id, investors[0], CooperativeGovernor.Choice.Yes);
        _reveal(id, workers[2], CooperativeGovernor.Choice.No);
        vm.warp(_executeAfter(id));
        assertTrue(gov.passed(id)); // 3/4 >= 2/3
        gov.execute(id);
        assertEq(uint8(coop.state()), uint8(ModelCooperative.CoopState.WindingDown));
    }

    /// A 2-of-3 simple majority is NOT enough for an Approval action (2/3 supermajority rule).
    function test_PBA_L2_017_approval_needs_supermajority() public {
        _activate();
        uint256 id = _propose(workers[0], address(coop), abi.encodeWithSelector(ModelCooperative.beginWindDown.selector), CooperativeGovernor.Kind.Approval);
        _commit(id, workers[0], CooperativeGovernor.Choice.Yes);
        _commit(id, workers[1], CooperativeGovernor.Choice.Yes);
        _commit(id, workers[2], CooperativeGovernor.Choice.No);
        _commit(id, investors[0], CooperativeGovernor.Choice.No);
        vm.warp(_commitDeadline(id) + 1);
        _reveal(id, workers[0], CooperativeGovernor.Choice.Yes);
        _reveal(id, workers[1], CooperativeGovernor.Choice.Yes);
        _reveal(id, workers[2], CooperativeGovernor.Choice.No);
        _reveal(id, investors[0], CooperativeGovernor.Choice.No);
        vm.warp(_executeAfter(id));
        assertFalse(gov.passed(id)); // 2/4 < 2/3
        vm.expectRevert(CooperativeGovernor.NotExecutable.selector);
        gov.execute(id);
    }

    /// Standard actions are unaffected (no false positives on ordinary governance).
    function test_PBA_L2_017_standard_actions_still_standard() public {
        (bool ok,) = _tryPropose(address(coop), abi.encodeWithSelector(ModelCooperative.activate.selector), CooperativeGovernor.Kind.Standard);
        assertTrue(ok);
        (ok,) = _tryPropose(address(target), _setValueCall(1), CooperativeGovernor.Kind.Standard);
        assertTrue(ok);
    }
}
