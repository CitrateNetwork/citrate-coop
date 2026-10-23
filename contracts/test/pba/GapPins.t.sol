// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.26;

import "./PbaR2Base.sol";
import "../../src/CooperativeFiatRamp.sol";

/// Guard pins for two checks whose removal no existing test noticed:
///  - the ballot commitment's chain-id and contract-address components (the existing tests
///    cover the proposal id and the all-fields-removed case only);
///  - the hold-period bound in the CooperativeFiatRamp constructor (the existing test covers
///    setHoldPeriod only).
contract GapPinsTest is PbaR2Base {
    function setUp() public {
        _deploy(6, 1);
    }

    function _revealOk(address voter, uint256 id) internal returns (bool ok) {
        vm.prank(voter);
        (ok,) = address(gov)
            .call(
                abi.encodeWithSelector(
                    CooperativeGovernor.revealVote.selector, id, CooperativeGovernor.Choice.Yes, BALLOT_SALT
                )
            );
    }

    /// A commitment computed under another chain id does not reveal on this one.
    function test_ballot_from_another_chain_does_not_reveal() public {
        uint256 id = _propose(workers[0], address(target), _setValueCall(1), CooperativeGovernor.Kind.Standard);
        uint256 here = block.chainid;
        vm.chainId(here + 1);
        bytes32 otherChain = gov.commitVoteHash(id, CooperativeGovernor.Choice.Yes, BALLOT_SALT, workers[1]);
        vm.chainId(here);
        assertTrue(
            otherChain != gov.commitVoteHash(id, CooperativeGovernor.Choice.Yes, BALLOT_SALT, workers[1]),
            "chain id not in the ballot domain"
        );
        vm.prank(workers[1]);
        gov.commitVote(id, otherChain);
        vm.warp(_commitDeadline(id) + 1);
        assertFalse(_revealOk(workers[1], id), "ballot committed for another chain revealed here");
    }

    /// A commitment computed for another governor address does not reveal on this one.
    function test_ballot_for_another_governor_does_not_reveal() public {
        uint256 id = _propose(workers[0], address(target), _setValueCall(1), CooperativeGovernor.Kind.Standard);
        bytes32 otherGov = keccak256(
            abi.encode(block.chainid, address(0xC0FFEE), id, CooperativeGovernor.Choice.Yes, BALLOT_SALT, workers[1])
        );
        vm.prank(workers[1]);
        gov.commitVote(id, otherGov);
        vm.warp(_commitDeadline(id) + 1);
        assertFalse(_revealOk(workers[1], id), "ballot committed for another governor revealed here");
    }

    /// Control: a correctly domained commitment reveals, and the published helper commits to
    /// exactly (chain id, this governor, proposal id, choice, salt, voter).
    function test_ballot_for_this_chain_and_governor_reveals() public {
        uint256 id = _propose(workers[0], address(target), _setValueCall(1), CooperativeGovernor.Kind.Standard);
        bytes32 h = _ballot(id, CooperativeGovernor.Choice.Yes, BALLOT_SALT, workers[1]);
        assertEq(
            gov.commitVoteHash(id, CooperativeGovernor.Choice.Yes, BALLOT_SALT, workers[1]),
            keccak256(
                abi.encode(block.chainid, address(gov), id, CooperativeGovernor.Choice.Yes, BALLOT_SALT, workers[1])
            ),
            "ballot domain must bind chain id and this governor's address"
        );
        vm.prank(workers[1]);
        gov.commitVote(id, h);
        vm.warp(_commitDeadline(id) + 1);
        assertTrue(_revealOk(workers[1], id), "a valid ballot must reveal");
    }

    /// The constructor applies the same [MIN_HOLD, MAX_HOLD] bound as setHoldPeriod.
    function test_ramp_constructor_rejects_out_of_range_hold() public {
        uint64 minHold = 1 days;
        uint64 maxHold = 90 days;
        vm.expectRevert(CooperativeFiatRamp.BadHoldPeriod.selector);
        new CooperativeFiatRamp(address(salt), address(coop), 0, address(this));
        vm.expectRevert(CooperativeFiatRamp.BadHoldPeriod.selector);
        new CooperativeFiatRamp(address(salt), address(coop), minHold - 1, address(this));
        vm.expectRevert(CooperativeFiatRamp.BadHoldPeriod.selector);
        new CooperativeFiatRamp(address(salt), address(coop), maxHold + 1, address(this));
        // the bounds themselves are accepted
        CooperativeFiatRamp lo = new CooperativeFiatRamp(address(salt), address(coop), minHold, address(this));
        CooperativeFiatRamp hi = new CooperativeFiatRamp(address(salt), address(coop), maxHold, address(this));
        assertEq(lo.holdPeriod(), minHold);
        assertEq(hi.holdPeriod(), maxHold);
        assertEq(lo.MIN_HOLD(), minHold);
        assertEq(hi.MAX_HOLD(), maxHold);
    }
}
