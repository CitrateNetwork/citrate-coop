// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.26;

import "forge-std/Test.sol";
import "../src/ModelCooperative.sol";
import "../src/PatronageLedger.sol";
import "../src/MembershipSBT.sol";
import "./mocks/MockERC20.sol";

contract MockKYC is IKYCRegistry {
    mapping(address => bool) public ok;
    mapping(address => bytes32) public id;
    function set(address a, bool v, bytes32 ident) external { ok[a] = v; id[a] = ident; }
    function isVerified(address a) external view returns (bool) { return ok[a]; }
    function identityOf(address a) external view returns (bytes32) { return id[a]; }
}

/// @notice Mock ModelRegistry — pays the model owner the full value (native→wSALT modeled as
///         a direct wSALT transfer to the owner). Mirrors ModelRegistry.requestInference.
contract MockModelRegistry {
    MockERC20 public salt;
    address public owner;
    constructor(MockERC20 s, address o) { salt = s; owner = o; }
    function requestInference(uint256 price) external { salt.transfer(owner, price); }
}

/// @notice Mock ModelMarketplace — pays owner price minus 2.5% fee (to a marketplace treasury).
contract MockMarketplace {
    MockERC20 public salt;
    address public owner;
    address public treasury;
    uint256 constant FEE_BPS = 250;
    constructor(MockERC20 s, address o, address t) { salt = s; owner = o; treasury = t; }
    function purchaseAccess(uint256 total) external {
        uint256 fee = (total * FEE_BPS) / 10000;
        salt.transfer(treasury, fee);
        salt.transfer(owner, total - fee);
    }
}

/// @notice Mock X402Facilitator — EIP-3009-style split: net→provider(co-op), fee→facilitator.
contract MockX402 {
    MockERC20 public salt;
    address public facilitatorTreasury;
    constructor(MockERC20 s, address t) { salt = s; facilitatorTreasury = t; }
    function settle(address payer, address provider, uint256 value, uint256 fee) external {
        salt.transferFrom(payer, provider, value - fee);
        salt.transferFrom(payer, facilitatorTreasury, fee);
    }
}

/// @notice Tests for revenue routing rails A + B (COOP-S1 WP-4).
///         Maps to features/coop_revenue_routing.feature.
contract RevenueRoutingTest is Test {
    MockERC20 salt;
    MockKYC kyc;
    MembershipSBT sbt;
    PatronageLedger ledger;
    ModelCooperative coop;
    address alice = address(0xA11CE);

    function setUp() public {
        salt = new MockERC20();
        kyc = new MockKYC();
        bytes32[] memory models = new bytes32[](0);
        sbt = new MembershipSBT(address(kyc), models);
        ledger = new PatronageLedger(address(kyc), address(sbt));
        coop = new ModelCooperative(address(salt), address(kyc), address(ledger), keccak256("model"));
        ledger.grantRole(ledger.SETTLER_ROLE(), address(this));
        ledger.grantRole(ledger.COOP_ROLE(), address(coop));
        coop.setGovernor(address(this));

        kyc.set(alice, true, keccak256("id:alice"));
        bytes32[] memory agents = new bytes32[](0);
        sbt.mint(alice, MembershipSBT.MemberClass.Worker, agents);
        bytes32 r = keccak256("r");
        ledger.commitRound(r, keccak256("mh"));
        ledger.recordContribution(r, alice, 1000, 10000); // alice = 100% of patronage
        coop.activate();
    }

    // coop_revenue_routing: "direct inference revenue lands in the co-op" (Rail A)
    function test_rail_a_inference() public {
        MockModelRegistry reg = new MockModelRegistry(salt, address(coop));
        salt.mint(address(reg), 1000);
        reg.requestInference(1000);                 // pays the owner (co-op) directly
        assertEq(salt.balanceOf(address(coop)), 1000);
        coop.syncDirectRevenue();                   // credit the unaccounted inflow
        assertEq(coop.pendingDividendOf(alice), 1000);
    }

    // coop_revenue_routing: "marketplace sale revenue lands in the co-op minus 2.5%" (Rail A)
    function test_rail_a_marketplace() public {
        address mTreasury = address(0x6A33);
        MockMarketplace mkt = new MockMarketplace(salt, address(coop), mTreasury);
        salt.mint(address(mkt), 1000);
        mkt.purchaseAccess(1000);
        assertEq(salt.balanceOf(mTreasury), 25);    // 2.5%
        assertEq(salt.balanceOf(address(coop)), 975);
        coop.syncDirectRevenue();
        assertEq(coop.pendingDividendOf(alice), 975);
    }

    // coop_revenue_routing: "x402 micropayment routes to the co-op" (Rail B)
    function test_rail_b_x402() public {
        address payer = address(0x9A1E5);
        address facTreasury = address(0xFAC);
        MockX402 x402 = new MockX402(salt, facTreasury);
        salt.mint(payer, 1000);
        vm.prank(payer);
        salt.approve(address(x402), 1000);
        x402.settle(payer, address(coop), 1000, 30); // 30 fee to facilitator, 970 net to co-op
        assertEq(salt.balanceOf(facTreasury), 30);
        coop.syncDirectRevenue();
        assertEq(coop.pendingDividendOf(alice), 970);
        // alice claims her residual
        vm.prank(alice);
        coop.claimDividend();
        assertEq(salt.balanceOf(alice), 970);
    }

    // adversarial: sync before Active reverts (no revenue before product)
    function test_sync_before_active_reverts() public {
        ModelCooperative fresh = new ModelCooperative(address(salt), address(kyc), address(ledger), keccak256("m2"));
        fresh.setGovernor(address(this));
        salt.mint(address(fresh), 100);
        vm.expectRevert(ModelCooperative.WrongState.selector);
        fresh.syncDirectRevenue();
    }
}
