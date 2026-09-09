// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import "forge-std/Test.sol";
import "../src/MembershipSBT.sol";

/// @notice RED tests for MembershipSBT (COOP-S1 WP-1).
///         Each maps to features/coop_membership.feature + MembershipVoting.tla.
///         These FAIL until WP-1 is implemented (skeleton reverts NotImplemented).
contract MockKYC is IKYCRegistry {
    mapping(address => bool) public ok;
    mapping(address => bytes32) public id;
    function set(address a, bool v, bytes32 ident) external { ok[a] = v; id[a] = ident; }
    function isVerified(address a) external view returns (bool) { return ok[a]; }
    function identityOf(address a) external view returns (bytes32) { return id[a]; }
}

contract MembershipSBTTest is Test {
    MembershipSBT sbt;
    MockKYC kyc;
    address alice = address(0xA11CE);
    address bob = address(0xB0B);
    address alice2 = address(0xA11CE2); // second address, same identity as alice

    function setUp() public {
        kyc = new MockKYC();
        bytes32[] memory models = new bytes32[](1);
        models[0] = keccak256("nat-community-model-v1");
        sbt = new MembershipSBT(address(kyc), models);
        kyc.set(alice, true, keccak256("identity:alice"));
        kyc.set(bob, true, keccak256("identity:bob"));
        kyc.set(alice2, true, keccak256("identity:alice")); // same identity
    }

    // coop_membership: "admitted as a worker-member" + records identity/agentIds
    function test_mint_one_per_identity() public {
        bytes32[] memory agents = new bytes32[](1);
        agents[0] = keccak256("agent:alice-1");
        sbt.mint(alice, MembershipSBT.MemberClass.Worker, agents);
        assertTrue(sbt.isMember(alice));
        assertEq(uint8(sbt.memberClass(alice)), uint8(MembershipSBT.MemberClass.Worker));
    }

    // coop_membership: "one membership token per KYC identity (no Sybil seats)"
    function test_no_sybil_seat() public {
        bytes32[] memory agents = new bytes32[](0);
        sbt.mint(alice, MembershipSBT.MemberClass.Worker, agents);
        vm.expectRevert();
        sbt.mint(alice2, MembershipSBT.MemberClass.Worker, agents); // same identity → reject
    }

    // coop_membership: "the membership token is soulbound"
    function test_soulbound() public {
        bytes32[] memory agents = new bytes32[](0);
        sbt.mint(alice, MembershipSBT.MemberClass.Worker, agents);
        vm.expectRevert(); // ERC-5192 locked
        sbt.transferFrom(alice, bob, 0);
    }

    // coop_membership + MembershipVoting.tla::Inv_WorkerControl (impl enforces >=51%)
    function test_worker_majority() public {
        bytes32[] memory agents = new bytes32[](0);
        // Two workers first.
        sbt.mint(alice, MembershipSBT.MemberClass.Worker, agents);
        sbt.mint(bob, MembershipSBT.MemberClass.Worker, agents);
        // One investor: 2 workers / 3 total = 66% >= 51% → ok.
        address carol = address(0xCA401);
        address dave = address(0xDA4E);
        kyc.set(carol, true, keccak256("identity:carol"));
        kyc.set(dave, true, keccak256("identity:dave"));
        sbt.mint(carol, MembershipSBT.MemberClass.Investor, agents);
        assertEq(sbt.workerCount(), 2);
        assertEq(sbt.memberCount(), 3);
        // Second investor: 2 workers / 4 total = 50% < 51% → revert.
        vm.expectRevert(MembershipSBT.WorkerMajorityViolated.selector);
        sbt.mint(dave, MembershipSBT.MemberClass.Investor, agents);
    }

    // coop_membership: "a revoked-KYC member cannot act"
    function test_revoked_kyc_fail_closed() public {
        kyc.set(alice, false, keccak256("identity:alice")); // revoked
        bytes32[] memory agents = new bytes32[](0);
        vm.expectRevert();
        sbt.mint(alice, MembershipSBT.MemberClass.Worker, agents);
    }

    // --- adversarial (FEATURE step 6) ---

    function test_only_registrar_can_mint() public {
        bytes32[] memory agents = new bytes32[](0);
        vm.prank(address(0xBEEF));
        vm.expectRevert();
        sbt.mint(alice, MembershipSBT.MemberClass.Worker, agents);
    }

    function test_expel_frees_seat_and_identity() public {
        bytes32[] memory agents = new bytes32[](0);
        sbt.mint(alice, MembershipSBT.MemberClass.Worker, agents);
        assertEq(sbt.memberCount(), 1);
        sbt.expel(alice);
        assertFalse(sbt.isMember(alice));
        assertEq(sbt.memberCount(), 0);
        // identity freed → a fresh address on the same identity can be admitted
        sbt.mint(alice2, MembershipSBT.MemberClass.Worker, agents); // alice2 shares alice's identity
        assertTrue(sbt.isMember(alice2));
    }

    function test_agentids_recorded() public {
        bytes32[] memory agents = new bytes32[](2);
        agents[0] = keccak256("agent:1");
        agents[1] = keccak256("agent:2");
        sbt.mint(alice, MembershipSBT.MemberClass.Worker, agents);
        bytes32[] memory got = sbt.agentIdsOf(alice);
        assertEq(got.length, 2);
        assertEq(got[1], keccak256("agent:2"));
    }

    // Property: admitting only workers always keeps worker share at 100%.
    function testFuzz_all_workers_keep_majority(uint8 n) public {
        n = uint8(bound(n, 1, 20));
        bytes32[] memory agents = new bytes32[](0);
        for (uint256 i = 0; i < n; i++) {
            address a = address(uint160(0x1000 + i));
            kyc.set(a, true, keccak256(abi.encode("id", i)));
            sbt.mint(a, MembershipSBT.MemberClass.Worker, agents);
        }
        assertEq(sbt.workerCount(), n);
        assertEq(sbt.memberCount(), n);
        assertTrue(sbt.workerCount() * 100 >= 51 * sbt.memberCount());
    }
}
