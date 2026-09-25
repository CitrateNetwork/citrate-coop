// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.26;

import "./PbaR2Base.sol";

/// PBA-L2-038 (MEDIUM): the factory granted the pool's YEAR_KEEPER_ROLE to the GOVERNOR, but the
/// governor only ever acts through ModelCooperative.execute (msg.sender == coop at the pool). So a
/// fully passed proposal to close a CRP cohort or forfeit a grant always reverted ExecFailed.
contract PbaR2YearKeeperTest is PbaR2Base {
    function setUp() public {
        _deploy(3, 0);
        salt.mint(address(pool), pool.TOTAL()); // the 50M CRP funding (a separate treasury action)
    }

    function _passAndExecute(address tgt, bytes memory data) internal returns (bool ok) {
        uint256 id = _propose(workers[0], tgt, data, CooperativeGovernor.Kind.Standard);
        _voteWorkers(id, 3, 0);
        assertTrue(gov.passed(id));
        (ok,) = address(gov).call(abi.encodeWithSelector(CooperativeGovernor.execute.selector, id));
    }

    /// The audit PoC (test_PBA_governance_cannot_close_crp_year), inverted.
    function test_PBA_L2_038_governance_closes_crp_year() public {
        assertTrue(_passAndExecute(address(pool), abi.encodeWithSelector(ContributionRewardPool.closeCurrentYear.selector)), "close via governance must succeed");
        assertTrue(pool.yearClosedAt(0) != 0);
        assertEq(ledger.currentYear(), 1);
        assertEq(salt.balanceOf(reserveTreasury), (pool.ANNUAL() * pool.reserveBps()) / 10_000);
    }

    function test_PBA_L2_038_governance_forfeits_grant() public {
        assertTrue(_passAndExecute(address(pool), abi.encodeWithSelector(ContributionRewardPool.forfeit.selector, workers[2])), "forfeit via governance must succeed");
        assertTrue(pool.forfeitedAt(workers[2]) != 0);
    }

    /// TRIPWIRE (the audit's generic factory check): the governor's only outbound call is
    /// coop.execute, so the factory must grant the governor NO role anywhere; every role meant for
    /// governance sits on the co-op, which is the actual msg.sender on the execute path.
    function test_PBA_L2_038_tripwire_governance_roles_on_the_caller() public view {
        bytes32[6] memory roles = [
            pool.YEAR_KEEPER_ROLE(), pool.DEFAULT_ADMIN_ROLE(), ledger.COOP_ROLE(), ledger.SETTLER_ROLE(),
            ledger.YEAR_KEEPER_ROLE(), sbt.REGISTRAR_ROLE()
        ];
        address[4] memory surfaces = [address(pool), address(ledger), address(sbt), address(coop)];
        for (uint256 s = 0; s < surfaces.length; s++) {
            for (uint256 r = 0; r < roles.length; r++) {
                assertFalse(Auth(surfaces[s]).hasRole(roles[r], address(gov)), "role granted to the governor is unreachable");
            }
        }
        assertTrue(pool.hasRole(pool.YEAR_KEEPER_ROLE(), address(coop)));
    }
}
