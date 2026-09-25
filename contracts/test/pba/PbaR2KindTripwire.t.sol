// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.26;

import "./PbaR2Base.sol";

/// PBA-L2-017 tripwires (class guards over the governor's Kind derivation).
contract PbaR2KindTripwireTest is PbaR2Base {
    function setUp() public {
        _deploy(3, 1);
    }

    function _activate() internal {
        uint256 id = _propose(workers[0], address(coop), abi.encodeWithSelector(ModelCooperative.activate.selector), CooperativeGovernor.Kind.Standard);
        _voteWorkers(id, 3, 0);
        gov.execute(id);
    }

    /// TRIPWIRE (class guard): every ModelCooperative entry point that governance can reach is
    /// executed as governance from a snapshot; any call that moves the co-op into WindingDown or
    /// Dissolved (the AB 816 approval class) must be classified Approval by the governor. A new
    /// terminal-lifecycle function added without updating requiredKind fails here.
    function test_PBA_L2_017_tripwire_terminal_transitions_are_approval() public {
        _activate();
        bytes[] memory calls = new bytes[](8);
        calls[0] = abi.encodeWithSelector(ModelCooperative.activate.selector);
        calls[1] = abi.encodeWithSelector(ModelCooperative.beginWindDown.selector);
        calls[2] = abi.encodeWithSelector(ModelCooperative.dissolve.selector, address(0xD15));
        calls[3] = abi.encodeWithSelector(ModelCooperative.syncDirectRevenue.selector);
        calls[4] = abi.encodeWithSelector(ModelCooperative.depositRevenue.selector, uint256(0));
        calls[5] = abi.encodeWithSelector(ModelCooperative.claimDividend.selector);
        calls[6] = abi.encodeWithSelector(ModelCooperative.setGovernor.selector, address(0xBEEF));
        calls[7] = abi.encodeWithSelector(ModelCooperative.execute.selector, address(target), uint256(0), _setValueCall(1));
        for (uint256 phase = 0; phase < 2; phase++) {
            for (uint256 i = 0; i < calls.length; i++) {
                uint256 snap = vm.snapshotState();
                ModelCooperative.CoopState before = coop.state();
                vm.prank(address(coop)); // governance self-call path (execute -> coop)
                (bool ok,) = address(coop).call(calls[i]);
                ModelCooperative.CoopState afterS = coop.state();
                bool terminal = ok && afterS != before
                    && (afterS == ModelCooperative.CoopState.WindingDown || afterS == ModelCooperative.CoopState.Dissolved);
                if (terminal) {
                    assertEq(uint8(gov.requiredKind(address(coop), calls[i])), uint8(CooperativeGovernor.Kind.Approval), "terminal lifecycle call not Approval-class");
                }
                vm.revertToState(snap);
            }
            if (phase == 0) {
                // phase 1: from WindingDown (so dissolve is reachable)
                vm.prank(address(coop));
                coop.beginWindDown();
            }
        }
    }

    /// TRIPWIRE: ownership / asset hand-off selectors are Approval-class on ANY target.
    function testFuzz_PBA_L2_017_ownership_selectors_any_target(address tgt, bytes32 tail, uint8 which) public view {
        bytes4[10] memory sels = [
            bytes4(0xf2fde38b), 0x715018a6, 0x23b872dd, 0x42842e0e, 0xb88d4fde, // ownership + ERC-721 transfers
            0x095ea7b3, 0xa22cb465, 0xa9059cbb, 0xf242432a, 0x2eb2c2d6          // approvals, ERC-20, ERC-1155
        ];
        bytes memory data = abi.encodePacked(sels[which % 10], tail);
        assertEq(uint8(gov.requiredKind(tgt, data)), uint8(CooperativeGovernor.Kind.Approval));
    }
}
