// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.26;

import "forge-std/Test.sol";
import "../src/CitrateCooperativeFactory.sol";
import "../src/CooperativeGovernor.sol";
import "../src/ModelCooperative.sol";
import "../src/PatronageLedger.sol";
import "../src/MembershipSBT.sol";
import "../src/ContributionRewardPool.sol";
import "../src/CoopDeployer.sol";
import "../src/CitrateAdminSafe.sol";
import "./mocks/MockERC20.sol";

contract MockKYC is IKYCRegistry {
    mapping(address => bool) public ok;
    mapping(address => bytes32) public id;
    function set(address a, bool v, bytes32 ident) external { ok[a] = v; id[a] = ident; }
    function isVerified(address a) external view returns (bool) { return ok[a]; }
    function identityOf(address a) external view returns (bytes32) { return id[a]; }
}

/// @notice Tests for CitrateCooperativeFactory (COOP-S1 WP-9).
///         Maps to gates g5-factory. Includes a governance-driven activation smoke test
///         that exercises the uniform execute() path end-to-end.
contract CitrateCooperativeFactoryTest is Test {
    MockERC20 salt;
    MockKYC kyc;
    CitrateCooperativeFactory factory;

    address admin = address(0xAD3155);
    address registrar = address(0x4E6157242);
    address settler = address(0x5E771E5);
    address reserveTreasury = address(0x7EA5);
    bytes32 constant MODEL = keccak256("model");

    CitrateCooperativeFactory.Coop c;

    function setUp() public {
        salt = new MockERC20();
        kyc = new MockKYC();
        factory = new CitrateCooperativeFactory(new CoopDeployer());
        bytes32[] memory modelIds = new bytes32[](1);
        modelIds[0] = MODEL;
        c = factory.createCooperative(CitrateCooperativeFactory.Params({
            salt: address(salt),
            kyc: address(kyc),
            modelHash: MODEL,
            modelIds: modelIds,
            settler: settler,
            registrar: registrar,
            reserveTreasury: reserveTreasury,
            admin: admin,
            reserveBps: 2000,
            vestWindow: 365 days
        }));
    }

    function test_deploy_wires_all() public view {
        MembershipSBT sbt = MembershipSBT(c.membership);
        PatronageLedger ledger = PatronageLedger(c.ledger);
        ModelCooperative coop = ModelCooperative(c.cooperative);
        ContributionRewardPool pool = ContributionRewardPool(c.rewardPool);

        // governor wired
        assertEq(coop.governor(), c.governor);
        // ledger roles
        assertTrue(ledger.hasRole(ledger.SETTLER_ROLE(), settler));
        assertTrue(ledger.hasRole(ledger.COOP_ROLE(), c.cooperative));
        // SETL-H1/M3: the pool holds ONLY the dedicated year-keeper role, NOT the broad COOP_ROLE.
        assertTrue(ledger.hasRole(ledger.YEAR_KEEPER_ROLE(), c.rewardPool));
        assertFalse(ledger.hasRole(ledger.COOP_ROLE(), c.rewardPool));
        // pool year-keeper = the co-op, the actual caller on the governance execute path (PBA-L2-038)
        assertTrue(pool.hasRole(pool.YEAR_KEEPER_ROLE(), c.cooperative));
        assertFalse(pool.hasRole(pool.YEAR_KEEPER_ROLE(), c.governor));
        // membership registrar (bootstrap + governance-via-coop)
        assertTrue(sbt.hasRole(sbt.REGISTRAR_ROLE(), registrar));
        assertTrue(sbt.hasRole(sbt.REGISTRAR_ROLE(), c.cooperative));
        // admin handed over, factory renounced
        assertTrue(sbt.hasRole(sbt.DEFAULT_ADMIN_ROLE(), admin));
        assertFalse(sbt.hasRole(sbt.DEFAULT_ADMIN_ROLE(), address(factory)));
    }

    function test_registry() public view {
        assertEq(factory.cooperativeOf(MODEL), c.cooperative);
        assertEq(factory.count(), 1);
    }

    // SETL-H2: the CRP reserve recipient must be a treasury DISTINCT from the co-op, so the held
    // reserve is never reclassified as member dividends by the permissionless syncDirectRevenue.
    function test_reserve_treasury_is_separate_from_coop() public view {
        ContributionRewardPool pool = ContributionRewardPool(c.rewardPool);
        assertTrue(pool.coopTreasury() != c.cooperative);
        assertEq(pool.coopTreasury(), reserveTreasury);
    }

    // SETL-M4: the production path (CreateCooperativeProd.s.sol) — the co-op is BORN under custody.
    // Deploy the AdminSafe, pass it as Params.admin + the ceremony key as settler; assert no EOA holds
    // admin anywhere and no hot key holds SETTLER.
    function test_prod_wiring_born_under_custody() public {
        address[] memory s = new address[](3);
        s[0] = address(0xA1); s[1] = address(0xB2); s[2] = address(0xC3);
        CitrateAdminSafe adminSafe = new CitrateAdminSafe(s, 2, 48 hours);
        address ceremonyKey = address(0xCE7E);

        bytes32 modelHash = keccak256("prod-model");
        bytes32[] memory modelIds = new bytes32[](1);
        modelIds[0] = modelHash;
        CitrateCooperativeFactory.Coop memory pc = factory.createCooperative(CitrateCooperativeFactory.Params({
            salt: address(salt),
            kyc: address(kyc),
            modelHash: modelHash,
            modelIds: modelIds,
            settler: ceremonyKey,          // prod settler = ceremony key, never a hot key
            registrar: registrar,
            reserveTreasury: reserveTreasury, // separate (SETL-H2)
            admin: address(adminSafe),      // DEFAULT_ADMIN → the multisig+timelock (SETL-M4)
            reserveBps: 2000,
            vestWindow: 365 days
        }));

        bytes32 ADMIN = 0x00;
        address[4] memory contracts_ = [pc.ledger, pc.cooperative, pc.rewardPool, pc.membership];
        for (uint256 i = 0; i < 4; i++) {
            // the safe is admin everywhere; neither the deployer (this test) nor the factory is
            assertTrue(Auth(contracts_[i]).hasRole(ADMIN, address(adminSafe)));
            assertFalse(Auth(contracts_[i]).hasRole(ADMIN, address(this)));
            assertFalse(Auth(contracts_[i]).hasRole(ADMIN, address(factory)));
        }
        // settler is the ceremony key
        assertTrue(PatronageLedger(pc.ledger).hasRole(PatronageLedger(pc.ledger).SETTLER_ROLE(), ceremonyKey));
        // reserve treasury is separate from the coop (SETL-H2)
        assertTrue(ContributionRewardPool(pc.rewardPool).coopTreasury() != pc.cooperative);
    }

    function test_createCooperative_rejects_zero_reserve_treasury() public {
        bytes32[] memory modelIds = new bytes32[](1);
        modelIds[0] = keccak256("model2");
        vm.expectRevert(bytes("reserveTreasury must be a separate, non-zero address"));
        factory.createCooperative(CitrateCooperativeFactory.Params({
            salt: address(salt),
            kyc: address(kyc),
            modelHash: keccak256("model2"),
            modelIds: modelIds,
            settler: settler,
            registrar: registrar,
            reserveTreasury: address(0), // rejected
            admin: admin,
            reserveBps: 2000,
            vestWindow: 365 days
        }));
    }

    // End-to-end smoke: governance activates the co-op via the uniform execute() path.
    function test_governance_activates_via_execute() public {
        MembershipSBT sbt = MembershipSBT(c.membership);
        ModelCooperative coop = ModelCooperative(c.cooperative);
        CooperativeGovernor gov = CooperativeGovernor(c.governor);

        // registrar onboards three worker-members
        address[3] memory ms = [address(0xA1), address(0xB2), address(0xC3)];
        for (uint256 i = 0; i < 3; i++) {
            kyc.set(ms[i], true, keccak256(abi.encode("id", ms[i])));
            bytes32[] memory agents = new bytes32[](0);
            vm.prank(registrar);
            sbt.mint(ms[i], MembershipSBT.MemberClass.Worker, agents);
        }

        // a worker proposes: target = coop, data = activate()  (self-call via execute)
        bytes memory data = abi.encodeWithSelector(ModelCooperative.activate.selector);
        vm.prank(ms[0]);
        uint256 id = gov.propose(address(coop), 0, data, CooperativeGovernor.Kind.Standard);

        bytes32 s = keccak256("s");
        for (uint256 i = 0; i < 3; i++) {
            bytes32 h = gov.commitVoteHash(id, CooperativeGovernor.Choice.Yes, s, ms[i]); // PBA-L2-040 B-017 domain
            vm.prank(ms[i]);
            gov.commitVote(id, h);
        }
        vm.warp(block.timestamp + gov.COMMIT_PERIOD() + 1);
        for (uint256 i = 0; i < 3; i++) {
            vm.prank(ms[i]);
            gov.revealVote(id, CooperativeGovernor.Choice.Yes, s);
        }
        assertTrue(gov.passed(id));
        vm.warp(block.timestamp + gov.REVEAL_PERIOD() + gov.TIMELOCK() + 1);
        gov.execute(id);

        assertEq(uint8(coop.state()), uint8(ModelCooperative.CoopState.Active)); // governance drove lifecycle
    }
}
