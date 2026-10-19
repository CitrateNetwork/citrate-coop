// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.26;

import "./PbaR2Base.sol";
import "../../src/CooperativeFiatRamp.sol";

/// Explicit initial admin: Auth (and MembershipSBT's registrar) take the initial role holder as a
/// constructor argument and never infer it from msg.sender. The deploying account — whoever
/// actually broadcasts, or the CREATE2 relay — must gain NO role unless it is the named holder.
contract ExplicitInitialAdminTest is PbaR2Base {
    address constant CREATE2_DEPLOYER = 0x4e59b44847b379578588920cA78FbF26c0B4956C;
    address constant NAMED = address(0xA11);
    address constant BROADCASTER = address(0xB0B);
    bytes32 constant ADMIN_ROLE = 0x00;

    function setUp() public {
        _deploy(1, 0);
    }

    /// Configured holder A, deployed by B: A is admin, B holds nothing (the chain#320 shape).
    function test_deployer_is_not_admin_unless_named() public {
        bytes32[] memory ids = new bytes32[](0);
        vm.startPrank(BROADCASTER);
        MembershipSBT s = new MembershipSBT(address(kyc), ids, NAMED, NAMED);
        PatronageLedger l = new PatronageLedger(address(kyc), address(s), NAMED);
        ModelCooperative m = new ModelCooperative(address(salt), address(kyc), address(l), keccak256("x"), NAMED);
        ContributionRewardPool p =
            new ContributionRewardPool(address(salt), address(l), address(kyc), reserveTreasury, 0, 1 days, NAMED);
        CooperativeFiatRamp r = new CooperativeFiatRamp(address(salt), address(m), 5 days, NAMED);
        vm.stopPrank();

        address[5] memory all = [address(s), address(l), address(m), address(p), address(r)];
        for (uint256 i = 0; i < all.length; i++) {
            assertTrue(Auth(all[i]).hasRole(ADMIN_ROLE, NAMED), "named holder must be admin");
            assertFalse(Auth(all[i]).hasRole(ADMIN_ROLE, BROADCASTER), "broadcaster must not be admin");
        }
        assertTrue(s.hasRole(s.REGISTRAR_ROLE(), NAMED));
        assertFalse(s.hasRole(s.REGISTRAR_ROLE(), BROADCASTER), "broadcaster must not be registrar");
    }

    /// The broadcaster cannot use admin powers on a contract it deployed for someone else.
    function test_broadcaster_cannot_act_as_admin() public {
        vm.prank(BROADCASTER);
        PatronageLedger l = new PatronageLedger(address(kyc), address(sbt), NAMED);
        vm.prank(BROADCASTER);
        vm.expectRevert(abi.encodeWithSelector(Auth.Unauthorized.selector, ADMIN_ROLE, BROADCASTER));
        l.grantRole(ADMIN_ROLE, BROADCASTER);
    }

    function test_zero_initial_admin_rejected() public {
        vm.expectRevert(Auth.ZeroRoleHolder.selector);
        new PatronageLedger(address(kyc), address(sbt), address(0));
        vm.expectRevert(Auth.ZeroRoleHolder.selector);
        new ModelCooperative(address(salt), address(kyc), address(ledger), keccak256("z"), address(0));
        vm.expectRevert(Auth.ZeroRoleHolder.selector);
        new ContributionRewardPool(address(salt), address(ledger), address(kyc), reserveTreasury, 0, 1 days, address(0));
        vm.expectRevert(Auth.ZeroRoleHolder.selector);
        new CooperativeFiatRamp(address(salt), address(coop), 5 days, address(0));
        vm.expectRevert(Auth.ZeroRoleHolder.selector);
        new MembershipSBT(address(kyc), new bytes32[](0), address(0), NAMED);
    }

    function test_create2_relay_rejected_as_admin() public {
        vm.expectRevert(Auth.Create2DeployerAsHolder.selector);
        new PatronageLedger(address(kyc), address(sbt), CREATE2_DEPLOYER);
        vm.expectRevert(Auth.Create2DeployerAsHolder.selector);
        new MembershipSBT(address(kyc), new bytes32[](0), CREATE2_DEPLOYER, NAMED);
    }

    function test_registrar_must_be_explicit_and_real() public {
        vm.expectRevert(Auth.ZeroRoleHolder.selector);
        new MembershipSBT(address(kyc), new bytes32[](0), NAMED, address(0));
        vm.expectRevert(Auth.Create2DeployerAsHolder.selector);
        new MembershipSBT(address(kyc), new bytes32[](0), NAMED, CREATE2_DEPLOYER);
    }

    /// Factory path: after createCooperative neither the factory nor its CoopDeployer holds ANY
    /// admin or registrar role (the factory previously kept a stale REGISTRAR_ROLE on the SBT).
    function test_factory_and_helper_hold_no_roles_after_create() public view {
        address helper = address(factory.deployer());
        address[4] memory all = [c.membership, c.ledger, c.cooperative, c.rewardPool];
        for (uint256 i = 0; i < all.length; i++) {
            assertTrue(Auth(all[i]).hasRole(ADMIN_ROLE, admin));
            assertFalse(Auth(all[i]).hasRole(ADMIN_ROLE, address(factory)), "factory kept admin");
            assertFalse(Auth(all[i]).hasRole(ADMIN_ROLE, helper), "helper kept admin");
            assertFalse(Auth(all[i]).hasRole(ADMIN_ROLE, address(this)), "caller became admin");
        }
        assertFalse(sbt.hasRole(sbt.REGISTRAR_ROLE(), address(factory)), "factory kept registrar");
        assertTrue(sbt.hasRole(sbt.REGISTRAR_ROLE(), registrar));
    }

    function test_factory_rejects_zero_or_relay_final_admin() public {
        vm.expectRevert(CitrateCooperativeFactory.BadFinalAdmin.selector);
        factory.createCooperative(_params(keccak256("m-zero"), registrar, settler, address(0)));
        vm.expectRevert(CitrateCooperativeFactory.BadFinalAdmin.selector);
        factory.createCooperative(_params(keccak256("m-relay"), registrar, settler, CREATE2_DEPLOYER));
    }

    function test_factory_rejects_zero_registrar() public {
        vm.expectRevert(Auth.ZeroRoleHolder.selector);
        factory.createCooperative(_params(keccak256("m-noreg"), address(0), settler, admin));
    }
}
