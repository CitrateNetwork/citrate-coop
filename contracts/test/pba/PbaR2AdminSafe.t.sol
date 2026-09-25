// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.26;

import "forge-std/Test.sol";
import "../../src/CitrateAdminSafe.sol";

contract PbaR2Sink {
    uint256 public hits;
    function hit() external { hits += 1; }
}

/// PBA-L2-039 (MEDIUM): CitrateAdminSafe kept counting confirmations from REMOVED signers. After
/// rotating out a compromised signer X, X's pending proposal needed only threshold-1 live
/// confirmations, and actions X had already queued survived the rotation.
contract PbaR2AdminSafeTest is Test {
    address A = address(0x1A);
    address B = address(0x1B);
    address X = address(0x1C);
    address C2 = address(0x1D);
    CitrateAdminSafe safe;
    PbaR2Sink sink;

    function setUp() public {
        address[] memory s = new address[](3);
        s[0] = A; s[1] = B; s[2] = X;
        safe = new CitrateAdminSafe(s, 2, 1 hours);
        sink = new PbaR2Sink();
    }

    function _rotateOutX() internal {
        address[] memory ns = new address[](3);
        ns[0] = A; ns[1] = B; ns[2] = C2;
        vm.prank(A);
        uint256 rot = safe.propose(address(safe), 0, abi.encodeWithSelector(CitrateAdminSafe.setSigners.selector, ns, uint256(2)));
        vm.prank(B); safe.confirm(rot);
        vm.warp(block.timestamp + 1 hours);
        vm.prank(A); safe.execute(rot);
        assertFalse(safe.isSigner(X));
    }

    function _call(address who, bytes memory data) internal returns (bool ok) {
        vm.prank(who);
        (ok,) = address(safe).call(data);
    }

    /// The audit PoC (test_PBA_adminsafe_removed_signer_confirmation_still_counts), inverted.
    function test_PBA_L2_039_removed_signer_confirmation_does_not_count() public {
        vm.prank(X);
        uint256 evil = safe.propose(address(sink), 0, abi.encodeWithSelector(PbaR2Sink.hit.selector));
        _rotateOutX();
        // a single live signer confirming must NOT queue X's action
        _call(C2, abi.encodeWithSelector(CitrateAdminSafe.confirm.selector, evil));
        assertEq(safe.actionOf(evil).eta, 0, "stale-config action queued on one live confirmation");
        vm.warp(block.timestamp + 1 hours);
        assertFalse(_call(C2, abi.encodeWithSelector(CitrateAdminSafe.execute.selector, evil)));
        assertEq(sink.hits(), 0);
    }

    /// An action X had already QUEUED before the rotation must not survive it either.
    function test_PBA_L2_039_queued_action_voided_by_rotation() public {
        vm.prank(X);
        uint256 evil = safe.propose(address(sink), 0, abi.encodeWithSelector(PbaR2Sink.hit.selector));
        vm.prank(A); safe.confirm(evil); // queued with A + X
        assertGt(safe.actionOf(evil).eta, 0);
        _rotateOutX();
        vm.warp(block.timestamp + 1 hours);
        assertFalse(_call(A, abi.encodeWithSelector(CitrateAdminSafe.execute.selector, evil)), "pre-rotation queued action survived");
        assertEq(sink.hits(), 0);
    }

    /// A void (stale-config) action cannot be "cancelled" either: cancel reverts StaleConfig, so no
    /// misleading Canceled event or cancel-confirmation state is ever recorded for it.
    function test_PBA_L2_039_cancel_on_stale_action_reverts() public {
        vm.prank(X);
        uint256 evil = safe.propose(address(sink), 0, abi.encodeWithSelector(PbaR2Sink.hit.selector));
        _rotateOutX();
        vm.prank(A);
        vm.expectRevert(bytes4(keccak256("StaleConfig()")));
        safe.cancel(evil);
        assertEq(safe.cancelConfirmations(evil), 0);
    }

    /// Normal operation after a rotation is unaffected: a fresh proposal under the new set works.
    function test_PBA_L2_039_new_config_actions_work() public {
        _rotateOutX();
        vm.prank(C2);
        uint256 id = safe.propose(address(sink), 0, abi.encodeWithSelector(PbaR2Sink.hit.selector));
        vm.prank(A); safe.confirm(id);
        vm.warp(block.timestamp + 1 hours);
        vm.prank(B); safe.execute(id);
        assertEq(sink.hits(), 1);
    }

    /// TRIPWIRE (the audit's invariant): for every action that executes, the number of CURRENT
    /// signers who confirmed it is at least the current threshold, under random interleavings of
    /// proposals, confirmations, signer rotations and executions.
    function testFuzz_PBA_L2_039_executed_actions_have_live_quorum(uint256 seed) public {
        address[5] memory pool_ = [A, B, X, C2, address(0x1E)];
        uint256 executedChecked;
        for (uint256 step = 0; step < 30; step++) {
            uint256 r = uint256(keccak256(abi.encode(seed, step)));
            address who = pool_[r % 5];
            uint256 op = (r >> 8) % 5;
            uint256 n = safe.actionCount();
            if (op == 0 || n == 0) {
                _call(who, abi.encodeWithSelector(CitrateAdminSafe.propose.selector, address(sink), uint256(0), abi.encodeWithSelector(PbaR2Sink.hit.selector)));
            } else if (op == 1) {
                _call(who, abi.encodeWithSelector(CitrateAdminSafe.confirm.selector, (r >> 16) % n));
            } else if (op == 2) {
                // rotate to a random 3-of-5 subset (via the real timelocked self-call path)
                address[] memory ns = new address[](3);
                uint256 k = (r >> 24) % 5;
                for (uint256 j = 0; j < 3; j++) ns[j] = pool_[(k + j) % 5];
                address[] memory cur = safe.signers();
                vm.prank(cur[0]);
                uint256 rot = safe.propose(address(safe), 0, abi.encodeWithSelector(CitrateAdminSafe.setSigners.selector, ns, uint256(2)));
                _call(cur[1], abi.encodeWithSelector(CitrateAdminSafe.confirm.selector, rot));
                vm.warp(block.timestamp + 1 hours);
                _call(cur[0], abi.encodeWithSelector(CitrateAdminSafe.execute.selector, rot));
            } else {
                vm.warp(block.timestamp + 1 hours);
                uint256 id = (r >> 16) % n;
                if (safe.actionOf(id).target != address(sink)) continue;
                uint256 before = sink.hits();
                _call(who, abi.encodeWithSelector(CitrateAdminSafe.execute.selector, id));
                if (sink.hits() > before) {
                    address[] memory cur = safe.signers();
                    uint256 live;
                    for (uint256 j = 0; j < cur.length; j++) if (safe.confirmedBy(id, cur[j])) live++;
                    assertGe(live, safe.threshold(), "executed with removed-signer confirmations");
                    executedChecked++;
                }
            }
        }
    }
}
