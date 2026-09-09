// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import "forge-std/Test.sol";
import "../src/PatronageLedger.sol";
import "../src/MembershipSBT.sol";

contract MockKYC is IKYCRegistry {
    mapping(address => bool) public ok;
    mapping(address => bytes32) public id;
    function set(address a, bool v, bytes32 ident) external { ok[a] = v; id[a] = ident; }
    function isVerified(address a) external view returns (bool) { return ok[a]; }
    function identityOf(address a) external view returns (bytes32) { return id[a]; }
}

/// @notice WP-8 — the on-chain SETTLEMENT SEAM the nat-federated coordinator calls.
///         The Rust `Settlement` impl (in the nat repo, gated on NAT Gate-4) will, after
///         committing a round's merged_hash on Citrate, call commitRound + recordContribution
///         here per node, with reward_weight = compute_metered x data_quality. This test
///         simulates that coordinator so the on-chain half is proven independent of the Rust side.
///         See SETTLEMENT_SEAM.md.
contract FederatedSettlementTest is Test {
    PatronageLedger ledger;
    MembershipSBT sbt;
    MockKYC kyc;

    address coordinator = address(0xC007D); // holds SETTLER_ROLE
    address nodeA = address(0xA1);
    address nodeB = address(0xB2);
    address nodeC = address(0xC3);

    function setUp() public {
        kyc = new MockKYC();
        bytes32[] memory models = new bytes32[](0);
        sbt = new MembershipSBT(address(kyc), models);
        ledger = new PatronageLedger(address(kyc), address(sbt));
        ledger.grantRole(ledger.SETTLER_ROLE(), coordinator);

        address[3] memory ns = [nodeA, nodeB, nodeC];
        for (uint256 i = 0; i < 3; i++) {
            kyc.set(ns[i], true, keccak256(abi.encode("id", ns[i])));
            bytes32[] memory agents = new bytes32[](0);
            sbt.mint(ns[i], MembershipSBT.MemberClass.Worker, agents);
        }
    }

    /// A federated round settles: coordinator commits the merged_hash, then records each node's
    /// reward_weight (compute x quality) as patronage. Mirrors nat-federated::finalize_round.
    function test_coordinator_settles_round() public {
        bytes32 roundId = keccak256("nat-round-42");
        bytes32 mergedHash = keccak256("merge_trace_hashes(sorted accepted trace hashes)");

        vm.startPrank(coordinator);
        ledger.commitRound(roundId, mergedHash);
        // node A: heavy compute, top quality; B: medium; C: light
        ledger.recordContribution(roundId, nodeA, 4000, 10000); // 4000 units
        ledger.recordContribution(roundId, nodeB, 2000, 9000);  // 1800 units
        ledger.recordContribution(roundId, nodeC, 1000, 5000);  // 500 units
        vm.stopPrank();

        assertEq(ledger.units(nodeA), 4000);
        assertEq(ledger.units(nodeB), 1800);
        assertEq(ledger.units(nodeC), 500);
        assertEq(ledger.totalUnits(), 6300);
        // provenance binding: the round's merged_hash is anchored on-chain
        assertEq(ledger.roundMergedHash(roundId), mergedHash);
    }

    /// The seam refuses to mint patronage for a round whose merged_hash was never committed —
    /// equity is anchored to the verified federated aggregation (ADR-0003).
    function test_unverified_round_rejected() public {
        vm.prank(coordinator);
        vm.expectRevert(PatronageLedger.RoundNotCommitted.selector);
        ledger.recordContribution(keccak256("ghost"), nodeA, 1000, 10000);
    }

    /// Only the federation coordinator (SETTLER_ROLE) can settle — a random node cannot mint itself patronage.
    function test_only_coordinator_settles() public {
        bytes32 roundId = keccak256("r");
        vm.prank(coordinator);
        ledger.commitRound(roundId, keccak256("mh"));
        vm.prank(nodeA);
        vm.expectRevert();
        ledger.recordContribution(roundId, nodeA, 999999, 10000);
    }
}
