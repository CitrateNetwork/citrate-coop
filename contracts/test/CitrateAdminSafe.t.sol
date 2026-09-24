// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.26;

import "forge-std/Test.sol";
import "../src/CitrateAdminSafe.sol";
import "../src/PatronageLedger.sol";
import "../src/MembershipSBT.sol";

contract MockKYC is IKYCRegistry {
    mapping(address => bool) public ok;
    function set(address a, bool v) external { ok[a] = v; }
    function isVerified(address a) external view returns (bool) { return ok[a]; }
    function identityOf(address) external pure returns (bytes32) { return bytes32(0); }
}

/// @notice Tests for CitrateAdminSafe (SETL-M4 custody move): 2-of-3 multisig + 48h timelock.
contract CitrateAdminSafeTest is Test {
    CitrateAdminSafe safe;
    address a1 = address(0xA1);
    address a2 = address(0xB2);
    address a3 = address(0xC3);
    address outsider = address(0xDEAD);
    uint256 constant DELAY = 48 hours;

    function setUp() public {
        address[] memory s = new address[](3);
        s[0] = a1; s[1] = a2; s[2] = a3;
        safe = new CitrateAdminSafe(s, 2, DELAY);
    }

    // --- config ---

    function test_constructor_sets_config() public view {
        assertEq(safe.signerCount(), 3);
        assertEq(safe.threshold(), 2);
        assertEq(safe.delay(), DELAY);
        assertTrue(safe.isSigner(a1));
        assertTrue(safe.isSigner(a2));
        assertTrue(safe.isSigner(a3));
        assertFalse(safe.isSigner(outsider));
    }

    function test_constructor_rejects_bad_config() public {
        address[] memory s = new address[](2);
        s[0] = a1; s[1] = a2;
        vm.expectRevert(CitrateAdminSafe.BadConfig.selector);
        new CitrateAdminSafe(s, 3, DELAY); // threshold > n
        vm.expectRevert(CitrateAdminSafe.BadConfig.selector);
        new CitrateAdminSafe(s, 0, DELAY); // threshold 0
        address[] memory dup = new address[](2);
        dup[0] = a1; dup[1] = a1;
        vm.expectRevert(CitrateAdminSafe.BadConfig.selector);
        new CitrateAdminSafe(dup, 1, DELAY); // duplicate signer
        address[] memory zero = new address[](1);
        zero[0] = address(0);
        vm.expectRevert(CitrateAdminSafe.BadConfig.selector);
        new CitrateAdminSafe(zero, 1, DELAY); // zero signer
    }

    // --- the full multisig + timelock flow (using a benign target) ---

    function _proposeBump(Counter c) internal returns (uint256 id) {
        vm.prank(a1);
        id = safe.propose(address(c), 0, abi.encodeCall(Counter.bump, ()));
    }

    function test_full_flow_propose_confirm_timelock_execute() public {
        Counter c = new Counter();
        uint256 id = _proposeBump(c); // a1 auto-confirms → 1 confirmation, not yet queued
        assertEq(safe.actionOf(id).confirmations, 1);
        assertEq(safe.actionOf(id).eta, 0);

        vm.prank(a2);
        safe.confirm(id); // 2 confirmations → queued
        uint64 eta = safe.actionOf(id).eta;
        assertEq(eta, uint64(block.timestamp + DELAY));

        vm.warp(block.timestamp + DELAY);
        vm.prank(a3);
        safe.execute(id);
        assertEq(c.count(), 1);
        assertTrue(safe.actionOf(id).executed);
    }

    function test_cannot_execute_before_timelock() public {
        Counter c = new Counter();
        uint256 id = _proposeBump(c);
        vm.prank(a2); safe.confirm(id); // queued
        vm.warp(block.timestamp + DELAY - 1); // one second short
        vm.prank(a1);
        vm.expectRevert(CitrateAdminSafe.Timelocked.selector);
        safe.execute(id);
    }

    function test_cannot_execute_below_threshold() public {
        Counter c = new Counter();
        uint256 id = _proposeBump(c); // only a1 → 1 confirmation
        vm.warp(block.timestamp + DELAY);
        vm.prank(a1);
        vm.expectRevert(CitrateAdminSafe.NotQueued.selector); // never reached threshold
        safe.execute(id);
    }

    // --- access control ---

    function test_non_signer_cannot_propose_confirm_execute() public {
        Counter c = new Counter();
        vm.prank(outsider);
        vm.expectRevert(CitrateAdminSafe.NotSigner.selector);
        safe.propose(address(c), 0, "");

        uint256 id = _proposeBump(c);
        vm.prank(outsider);
        vm.expectRevert(CitrateAdminSafe.NotSigner.selector);
        safe.confirm(id);
        vm.prank(outsider);
        vm.expectRevert(CitrateAdminSafe.NotSigner.selector);
        safe.execute(id);
    }

    function test_no_double_confirm() public {
        Counter c = new Counter();
        uint256 id = _proposeBump(c);
        vm.prank(a1);
        vm.expectRevert(CitrateAdminSafe.AlreadyConfirmed.selector);
        safe.confirm(id); // a1 already auto-confirmed at propose
    }

    // --- cancel is threshold-gated ---

    function test_single_signer_cannot_cancel() public {
        Counter c = new Counter();
        uint256 id = _proposeBump(c);
        vm.prank(a2); safe.confirm(id); // queued
        vm.prank(a1); safe.cancel(id);  // only 1 cancel confirmation < threshold(2)
        assertFalse(safe.actionOf(id).canceled);
        // still executable
        vm.warp(block.timestamp + DELAY);
        vm.prank(a3); safe.execute(id);
        assertEq(c.count(), 1);
    }

    function test_threshold_cancel_stops_execution() public {
        Counter c = new Counter();
        uint256 id = _proposeBump(c);
        vm.prank(a2); safe.confirm(id); // queued
        vm.prank(a1); safe.cancel(id);
        vm.prank(a2); safe.cancel(id);  // 2 cancels ≥ threshold → canceled
        assertTrue(safe.actionOf(id).canceled);
        vm.warp(block.timestamp + DELAY);
        vm.prank(a3);
        vm.expectRevert(CitrateAdminSafe.IsCanceled.selector);
        safe.execute(id);
        assertEq(c.count(), 0);
    }

    // --- self-administration: signer set only rotates through the timelocked flow ---

    function test_setSigners_rejects_external_call() public {
        address[] memory s = new address[](1);
        s[0] = outsider;
        vm.prank(a1);
        vm.expectRevert(CitrateAdminSafe.OnlySelf.selector);
        safe.setSigners(s, 1); // even a signer cannot call it directly
    }

    function test_rotate_signers_via_timelocked_self_call() public {
        address newSigner = address(0x4);
        address[] memory s = new address[](3);
        s[0] = a1; s[1] = a2; s[2] = newSigner; // replace a3 with newSigner
        bytes memory data = abi.encodeCall(CitrateAdminSafe.setSigners, (s, 2));

        vm.prank(a1);
        uint256 id = safe.propose(address(safe), 0, data);
        vm.prank(a2); safe.confirm(id); // queued
        vm.warp(block.timestamp + DELAY);
        vm.prank(a1); safe.execute(id);

        assertTrue(safe.isSigner(newSigner));
        assertFalse(safe.isSigner(a3)); // rotated out
        assertEq(safe.signerCount(), 3);
    }

    // --- integration: the safe holds DEFAULT_ADMIN of the money surface ---

    function test_safe_administers_the_ledger() public {
        MockKYC kyc = new MockKYC();
        bytes32[] memory models = new bytes32[](0);
        MembershipSBT sbt = new MembershipSBT(address(kyc), models);
        PatronageLedger ledger = new PatronageLedger(address(kyc), address(sbt));

        // hand DEFAULT_ADMIN to the safe, renounce this test's admin (mirrors the rotation runbook)
        ledger.grantRole(ledger.DEFAULT_ADMIN_ROLE(), address(safe));
        ledger.revokeRole(ledger.DEFAULT_ADMIN_ROLE(), address(this));
        assertFalse(ledger.hasRole(ledger.DEFAULT_ADMIN_ROLE(), address(this)));

        // now granting SETTLER_ROLE requires the full 2-of-3 + 48h flow
        address settler = address(0x5E7);
        bytes memory data = abi.encodeCall(ledger.grantRole, (ledger.SETTLER_ROLE(), settler));
        vm.prank(a1);
        uint256 id = safe.propose(address(ledger), 0, data);
        vm.prank(a2); safe.confirm(id);
        vm.warp(block.timestamp + DELAY);
        vm.prank(a3); safe.execute(id);

        assertTrue(ledger.hasRole(ledger.SETTLER_ROLE(), settler));
    }
}

/// A benign target for the flow tests.
contract Counter {
    uint256 public count;
    function bump() external { count += 1; }
}
