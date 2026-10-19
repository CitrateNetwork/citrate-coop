// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.26;

import "./PbaR2Base.sol";

/// Exposes Auth's internal grant paths so they can be exercised directly.
contract AuthHarness is Auth {
    bytes32 public constant SOME_ROLE = keccak256("SOME_ROLE");

    constructor(address initialAdmin) Auth(initialAdmin) {}

    function grantInternal(bytes32 role, address account) external {
        _grant(role, account);
    }

    function grantAsInternal(bytes32 role, address account) external {
        _grantAs(role, account, address(0));
    }
}

/// Role-holder validation: every grant path (constructor, grantRole, _grant, _grantAs) rejects the
/// zero address and the CREATE2 relay, and the last-admin guard counts only usable holders, so the
/// sole usable administrator of PatronageLedger / MembershipSBT can never revoke itself.
contract RoleHolderValidationTest is PbaR2Base {
    address constant CREATE2_DEPLOYER = 0x4e59b44847b379578588920cA78FbF26c0B4956C;
    bytes32 constant ADMIN_ROLE = 0x00;
    /// Auth storage: `_roles` at slot 0, `_adminCount` at slot 1 (Auth is the first base).
    uint256 constant ROLES_SLOT = 0;
    uint256 constant ADMIN_COUNT_SLOT = 1;

    function setUp() public {
        _deploy(1, 0);
    }

    function _surfaces() internal view returns (Auth[2] memory) {
        return [Auth(address(ledger)), Auth(address(sbt))];
    }

    function _adminCount(Auth a) internal view returns (uint256) {
        return uint256(vm.load(address(a), bytes32(ADMIN_COUNT_SLOT)));
    }

    /// Writes `_roles[role][account] = true` directly, bypassing every grant path.
    function _plantRole(Auth a, bytes32 role, address account) internal {
        bytes32 inner = keccak256(abi.encode(role, ROLES_SLOT));
        bytes32 slot = keccak256(abi.encode(account, inner));
        vm.store(address(a), slot, bytes32(uint256(1)));
        assertTrue(a.hasRole(role, account), "plant failed");
    }

    function test_grantRole_admin_to_zero_or_relay_reverts() public {
        Auth[2] memory s = _surfaces();
        for (uint256 i = 0; i < s.length; i++) {
            vm.startPrank(admin);
            vm.expectRevert(Auth.ZeroRoleHolder.selector);
            s[i].grantRole(ADMIN_ROLE, address(0));
            vm.expectRevert(Auth.Create2DeployerAsHolder.selector);
            s[i].grantRole(ADMIN_ROLE, CREATE2_DEPLOYER);
            vm.stopPrank();
            assertFalse(s[i].hasRole(ADMIN_ROLE, address(0)));
            assertFalse(s[i].hasRole(ADMIN_ROLE, CREATE2_DEPLOYER));
            assertEq(_adminCount(s[i]), 1, "counter moved");
        }
    }

    function test_grantRole_any_role_to_zero_or_relay_reverts() public {
        bytes32[3] memory ledgerRoles = [ledger.SETTLER_ROLE(), ledger.COOP_ROLE(), ledger.YEAR_KEEPER_ROLE()];
        vm.startPrank(admin);
        for (uint256 r = 0; r < ledgerRoles.length; r++) {
            vm.expectRevert(Auth.ZeroRoleHolder.selector);
            ledger.grantRole(ledgerRoles[r], address(0));
            vm.expectRevert(Auth.Create2DeployerAsHolder.selector);
            ledger.grantRole(ledgerRoles[r], CREATE2_DEPLOYER);
        }
        bytes32 reg = sbt.REGISTRAR_ROLE();
        vm.expectRevert(Auth.ZeroRoleHolder.selector);
        sbt.grantRole(reg, address(0));
        vm.expectRevert(Auth.Create2DeployerAsHolder.selector);
        sbt.grantRole(reg, CREATE2_DEPLOYER);
        vm.stopPrank();
    }

    function test_fuzz_grantRole_unusable_holder_reverts(bytes32 role, bool relay) public {
        address bad = relay ? CREATE2_DEPLOYER : address(0);
        vm.prank(admin);
        vm.expectRevert(relay ? Auth.Create2DeployerAsHolder.selector : Auth.ZeroRoleHolder.selector);
        ledger.grantRole(role, bad);
    }

    function test_internal_grant_paths_reject_unusable_holders() public {
        AuthHarness h = new AuthHarness(admin);
        bytes32[2] memory roles = [ADMIN_ROLE, h.SOME_ROLE()];
        for (uint256 r = 0; r < roles.length; r++) {
            vm.expectRevert(Auth.ZeroRoleHolder.selector);
            h.grantInternal(roles[r], address(0));
            vm.expectRevert(Auth.Create2DeployerAsHolder.selector);
            h.grantInternal(roles[r], CREATE2_DEPLOYER);
            vm.expectRevert(Auth.ZeroRoleHolder.selector);
            h.grantAsInternal(roles[r], address(0));
            vm.expectRevert(Auth.Create2DeployerAsHolder.selector);
            h.grantAsInternal(roles[r], CREATE2_DEPLOYER);
        }
        assertEq(_adminCount(h), 1);
    }

    /// The reported attack: grant admin to an unusable holder, then the sole usable admin revokes
    /// itself. The grant now reverts, and the self-revoke still trips LastAdmin.
    function test_sole_usable_admin_cannot_strand_via_unusable_grant() public {
        Auth[2] memory s = _surfaces();
        for (uint256 i = 0; i < s.length; i++) {
            vm.startPrank(admin);
            vm.expectRevert(Auth.ZeroRoleHolder.selector);
            s[i].grantRole(ADMIN_ROLE, address(0));
            vm.expectRevert(Auth.Create2DeployerAsHolder.selector);
            s[i].grantRole(ADMIN_ROLE, CREATE2_DEPLOYER);
            vm.expectRevert(Auth.LastAdmin.selector);
            s[i].revokeRole(ADMIN_ROLE, admin);
            vm.stopPrank();
            assertTrue(s[i].hasRole(ADMIN_ROLE, admin), "sole usable admin lost");
        }
    }

    /// Even if an unusable admin entry were somehow present (planted directly in storage), it does
    /// not count: the sole usable admin still cannot revoke itself, and removing the unusable entry
    /// neither trips nor decrements the guard.
    function test_unusable_holder_present_does_not_inflate_counter() public {
        Auth[2] memory s = _surfaces();
        for (uint256 i = 0; i < s.length; i++) {
            _plantRole(s[i], ADMIN_ROLE, address(0));
            _plantRole(s[i], ADMIN_ROLE, CREATE2_DEPLOYER);
            assertEq(_adminCount(s[i]), 1, "unusable holders must not be counted");

            vm.prank(admin);
            vm.expectRevert(Auth.LastAdmin.selector);
            s[i].revokeRole(ADMIN_ROLE, admin);

            // Cleaning up the unusable entries leaves the usable count untouched.
            vm.startPrank(admin);
            s[i].revokeRole(ADMIN_ROLE, address(0));
            s[i].revokeRole(ADMIN_ROLE, CREATE2_DEPLOYER);
            vm.stopPrank();
            assertFalse(s[i].hasRole(ADMIN_ROLE, address(0)));
            assertFalse(s[i].hasRole(ADMIN_ROLE, CREATE2_DEPLOYER));
            assertEq(_adminCount(s[i]), 1);
            assertTrue(s[i].hasRole(ADMIN_ROLE, admin));

            vm.prank(admin);
            vm.expectRevert(Auth.LastAdmin.selector);
            s[i].revokeRole(ADMIN_ROLE, admin);
        }
    }

    /// Rotation to a second USABLE admin still works: count goes 1 -> 2 -> 1, then LastAdmin.
    function test_usable_rotation_still_works() public {
        address next = address(0xBEEF);
        Auth[2] memory s = _surfaces();
        for (uint256 i = 0; i < s.length; i++) {
            vm.startPrank(admin);
            s[i].grantRole(ADMIN_ROLE, next);
            assertEq(_adminCount(s[i]), 2);
            s[i].revokeRole(ADMIN_ROLE, admin);
            vm.stopPrank();
            assertEq(_adminCount(s[i]), 1);
            vm.prank(next);
            vm.expectRevert(Auth.LastAdmin.selector);
            s[i].revokeRole(ADMIN_ROLE, next);
            assertTrue(s[i].hasRole(ADMIN_ROLE, next));
        }
    }
}
