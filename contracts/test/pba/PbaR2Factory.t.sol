// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.26;

import "./PbaR2Base.sol";

/// PBA-L2-018 (MEDIUM, COOP-B-004): createCooperative was permissionless AND overwrote
/// cooperativeOf[modelHash], so anyone could re-point the canonical registry entry for an existing
/// model at a co-op they control (their own settler, registrar and admin).
contract PbaR2FactoryRegistryTest is PbaR2Base {
    bytes4 constant ALREADY = bytes4(keccak256("ModelAlreadyHasCooperative(bytes32)"));

    function setUp() public {
        _deploy(0, 0);
    }

    function _tryCreate(address caller, CitrateCooperativeFactory.Params memory p) internal returns (bool ok, bytes4 err) {
        vm.prank(caller);
        bytes memory ret;
        (ok, ret) = address(factory).call(abi.encodeWithSelector(CitrateCooperativeFactory.createCooperative.selector, p));
        if (!ok && ret.length >= 4) err = bytes4(ret);
    }

    /// The audit PoC (test_PBA_factory_registry_hijack_still_open), inverted.
    function test_PBA_L2_018_registry_hijack_refused() public {
        address attacker = address(0xBAD);
        (bool ok, bytes4 err) = _tryCreate(attacker, _params(MODEL, attacker, attacker, attacker));
        assertFalse(ok, "an existing model's co-op must not be overwritable");
        assertEq(err, ALREADY);
        assertEq(factory.cooperativeOf(MODEL), c.cooperative);
        assertEq(factory.count(), 1);
    }

    /// A different model still gets its own co-op (the factory stays usable).
    function test_PBA_L2_018_new_model_still_created() public {
        (bool ok,) = _tryCreate(address(this), _params(keccak256("other"), registrar, settler, admin));
        assertTrue(ok);
        assertTrue(factory.cooperativeOf(keccak256("other")) != address(0));
        assertEq(factory.cooperativeOf(MODEL), c.cooperative);
    }

    /// TRIPWIRE: the canonical registry is first-writer-wins for every caller and every parameter set.
    function testFuzz_PBA_L2_018_registry_is_write_once(address caller, address reg, address set_, address adm) public {
        vm.assume(caller != address(0));
        (bool ok,) = _tryCreate(caller, _params(MODEL, reg, set_, adm));
        assertFalse(ok);
        assertEq(factory.cooperativeOf(MODEL), c.cooperative);
    }
}
