// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.26;

import "./PbaR2Base.sol";
import "../../src/CooperativeFiatRamp.sol";

/// Regression pins for guards that no existing test exercised at its real entry point.
/// Each test drives a factory-deployed co-op (PbaR2Base) and fails on an assertion if the
/// guard it names is removed.
contract GuardPinsTest is PbaR2Base {
    function setUp() public {
        _deploy(4, 0);
    }

    // Delegation stays flat: a member may not delegate to a member who has themselves delegated.
    // Without the check, weight parked on a delegated (non-voting) rep is silently lost.
    function test_delegate_to_an_already_delegated_member_is_refused() public {
        vm.prank(workers[0]);
        gov.delegate(workers[1]);
        assertEq(gov.delegatorCount(workers[1]), 1);

        vm.prank(workers[2]);
        vm.expectRevert(CooperativeGovernor.HasDelegated.selector);
        gov.delegate(workers[0]);

        assertEq(gov.delegatorCount(workers[0]), 0, "weight parked on a delegated member");
        assertEq(gov.delegateOf(workers[2]), address(0));
    }

    // The flat-delegation refusal keeps every delegated vote reachable: the chained delegator's
    // vote is still castable directly, and the rep's weight is exactly 1 + direct delegators.
    function test_flat_delegation_keeps_weight_on_the_voting_rep() public {
        vm.prank(workers[0]);
        gov.delegate(workers[1]);
        vm.prank(workers[2]);
        try gov.delegate(workers[0]) {} catch {}

        uint256 id = _propose(workers[1], address(target), _setValueCall(7), CooperativeGovernor.Kind.Standard);
        _commit(id, workers[1], CooperativeGovernor.Choice.Yes);
        _commit(id, workers[2], CooperativeGovernor.Choice.Yes);
        vm.warp(_commitDeadline(id) + 1);
        _reveal(id, workers[1], CooperativeGovernor.Choice.Yes);
        _reveal(id, workers[2], CooperativeGovernor.Choice.Yes);
        // yes = rep (1 + 1 delegator) + direct voter (1) = 3: no vote lost to a chain
        CooperativeGovernor.Proposal memory p = gov.getProposal(id);
        assertEq(p.yes, 3, "a delegated vote was lost");
    }

    // The patronage formula's truncation order: the data weight is folded into quality bps
    // first, then applied to weighted compute. Pinned with non-default weights, where the two
    // possible orderings disagree.
    function test_patronage_units_follow_the_ledger_truncation_order() public {
        vm.prank(admin);
        ledger.setWeights(10_000, 5_000);
        vm.prank(settler);
        ledger.commitRound(keccak256("r"), keccak256("mh"));
        vm.prank(settler);
        ledger.recordContribution(keccak256("r"), workers[0], 1e8, 3);
        // wq = 3 * 5000 / 10000 = 1 ; p = (1e8 * 10000 / 10000) * 1 / 10000 = 10_000
        // (quality applied first, then wData, would give 15_000)
        assertEq(ledger.units(workers[0]), 10_000);
    }

    function testFuzz_patronage_units_match_the_normative_formula(uint64 compute, uint16 q, uint16 wc, uint16 wd)
        public
    {
        q = uint16(bound(q, 0, 10_000));
        wc = uint16(bound(wc, 1, 10_000));
        wd = uint16(bound(wd, 1, 10_000));
        vm.prank(admin);
        ledger.setWeights(wc, wd);
        vm.prank(settler);
        ledger.commitRound(keccak256("r"), keccak256("mh"));
        vm.prank(settler);
        ledger.recordContribution(keccak256("r"), workers[0], compute, q);
        uint256 expected = ((uint256(compute) * wc) / 10_000) * ((uint256(q) * wd) / 10_000) / 10_000;
        assertEq(ledger.units(workers[0]), expected);
    }

    // The co-op is ERC-20 (wSALT) end to end and has no payable entry point: a plain native-value
    // transfer must fail rather than strand value in a contract with no way to account for it.
    function test_cooperative_refuses_native_value() public {
        vm.deal(address(this), 1 ether);
        (bool ok,) = address(coop).call{value: 1 ether}("");
        assertFalse(ok, "co-op accepted native value");
        assertEq(address(coop).balance, 0);
    }

    // withdrawRampFunds refuses the zero address, so a mistyped refund can never burn the
    // charged-back reserve.
    function test_ramp_withdraw_to_zero_address_is_refused() public {
        CooperativeFiatRamp ramp = new CooperativeFiatRamp(address(salt), address(coop), 5 days, address(this));
        address attestor = address(0xA77E);
        ramp.grantRole(ramp.ATTESTOR_ROLE(), attestor);
        salt.mint(address(ramp), 1_000);
        vm.prank(attestor);
        ramp.creditFromFiat(keccak256("ref"), 1_000, 100);
        vm.prank(attestor);
        ramp.chargeback(keccak256("ref"));

        vm.expectRevert(CooperativeFiatRamp.ZeroRecipient.selector);
        ramp.withdrawRampFunds(address(0), 1_000);
        assertEq(ramp.rampReserve(), 1_000);
        assertEq(salt.balanceOf(address(ramp)), 1_000);
    }
}
