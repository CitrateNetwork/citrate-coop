// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.26;

import "./lib/Auth.sol";
import "./lib/IERC20.sol";
import "./MembershipSBT.sol"; // IKYCRegistry
import "./PatronageLedger.sol";

/// @title ModelCooperative — lifecycle, treasury, revenue intake (RFC-CIT-COOP-0001)
/// @notice The core. Owns the model in ModelRegistry, holds the SALT treasury, routes
///         revenue into the patronage-dividend accumulator, and gates claims on KYC.
///         Drives the lifecycle state machine (CoopLifecycle.tla). Governance (the
///         CooperativeGovernor) is the only privileged caller for lifecycle + execution.
/// @dev Formal: specs/tla/coop/CoopLifecycle.tla, PatronageDividend.tla.
///      Feature: coop_revenue_dividend.feature, coop_revenue_routing.feature.
contract ModelCooperative is Auth, ReentrancyGuard {
    enum CoopState { Forming, Active, WindingDown, Dissolved }

    IERC20 public immutable salt;
    IKYCRegistry public immutable kyc;
    PatronageLedger public immutable ledger;

    CoopState public state;
    address public governor;          // CooperativeGovernor (privileged)
    bytes32 public modelHash;         // the model this co-op owns (ModelRegistry)

    event Activated();
    event WindDownBegun();
    event Dissolved(address residualTreasury, uint256 swept);
    event RevenueReceived(uint256 amount);
    event DividendClaimed(address indexed member, uint256 amount); // for Subchapter T / 1099-PATR
    event GovernorSet(address governor);
    event Executed(address indexed target, uint256 value, bytes data);

    error NotGovernor();
    error WrongState();
    error NotKyc();
    error Nothing();
    error ExecFailed();
    error ExecForbidden(); // SETL-C2: execute() may not target the ledger or the SALT treasury
    error GovernorAlreadySet(); // PBA-L2-019: setGovernor is one-shot
    error ZeroGovernor();

    modifier onlyGovernor() {
        if (msg.sender != governor) revert NotGovernor();
        _;
    }

    /// @dev Governance acts uniformly through `execute`. A proposal whose target is this
    ///      contract calls back in with msg.sender == address(this); a direct governor call
    ///      has msg.sender == governor. Both are governance.
    modifier onlyGovernance() {
        if (msg.sender != governor && msg.sender != address(this)) revert NotGovernor();
        _;
    }

    constructor(address salt_, address kyc_, address ledger_, bytes32 modelHash_) {
        salt = IERC20(salt_);
        kyc = IKYCRegistry(kyc_);
        ledger = PatronageLedger(ledger_);
        modelHash = modelHash_;
        state = CoopState.Forming;
    }

    /// @dev Set once by the deployer/factory (admin), then governance owns lifecycle.
    ///      PBA-L2-019: enforced one-shot. Without the guard DEFAULT_ADMIN could re-point the
    ///      governor at will and drive lifecycle / admission / expulsion around the members.
    function setGovernor(address g) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (governor != address(0)) revert GovernorAlreadySet();
        if (g == address(0)) revert ZeroGovernor();
        governor = g;
        emit GovernorSet(g);
    }

    // --- lifecycle (governor) ---

    function activate() external onlyGovernance {
        if (state != CoopState.Forming) revert WrongState();
        state = CoopState.Active;
        emit Activated();
    }

    function beginWindDown() external onlyGovernance {
        if (state != CoopState.Active) revert WrongState();
        state = CoopState.WindingDown;
        ledger.closeContributionWindow(); // contributions close permanently
        emit WindDownBegun();
    }

    // No nonReentrant: state is set terminal BEFORE the single transfer (CEI), and a reentrant
    // dissolve hits state != WindingDown → WrongState. Omitting the guard also lets governance
    // route a self-targeted dissolve through execute() (which holds the guard) without clashing.
    function dissolve(address residualTreasury) external onlyGovernance {
        if (state != CoopState.WindingDown) revert WrongState();
        state = CoopState.Dissolved;
        // SETL-C1 fix: sweep ONLY the surplus ABOVE the on-chain owed floor. The floor is the SALT
        // still owed to members as unclaimed dividends (credited − claimed); it MUST remain in the
        // contract so every member's claimDividend() can still pay out after dissolution. Sweeping
        // the whole balance (the prior behaviour) stole unclaimed dividends and made later claims
        // revert. This is the `accountedNet` quantity syncDirectRevenue already trusts.
        uint256 owedFloor = ledger.totalRevenueCredited() - ledger.totalDividendClaimed();
        uint256 bal = salt.balanceOf(address(this));
        uint256 sweepable = bal > owedFloor ? bal - owedFloor : 0;
        if (sweepable > 0 && residualTreasury != address(0)) {
            salt.transfer(residualTreasury, sweepable);
        }
        emit Dissolved(residualTreasury, sweepable);
    }

    // NOTE: there is deliberately NO advanceYear() here. SETL-H1 fix: the ContributionRewardPool is
    // the SOLE year-keeper (it stamps the cohort vest-start + skims the reserve BEFORE advancing the
    // ledger year). A second path that advanced the ledger year without that bookkeeping permanently
    // stranded a whole cohort's grant, so it was removed. Governance advances the year via
    // ContributionRewardPool.closeCurrentYear().

    // --- revenue intake → patronage dividend ---

    /// @notice Pull-based revenue intake (x402 / fiat rail / any payer). Credits the dividend.
    ///         Legal only when Active or WindingDown (CoopLifecycle Inv_NoRevenueBeforeActive).
    function depositRevenue(uint256 amount) external nonReentrant {
        if (state != CoopState.Active && state != CoopState.WindingDown) revert WrongState();
        require(salt.transferFrom(msg.sender, address(this), amount), "transferFrom");
        ledger.creditRevenue(amount);
        emit RevenueReceived(amount);
    }

    /// @notice Rail A: ModelRegistry/ModelMarketplace pay the owner (this co-op) directly with
    ///         no callback. This credits any unaccounted SALT inflow into the dividend. The
    ///         co-op's entire SALT balance is dividend-bearing (the CRP reserve goes to a
    ///         separate treasury), so balance above (credited - claimed) is fresh revenue.
    function syncDirectRevenue() external nonReentrant returns (uint256 credited) {
        if (state != CoopState.Active && state != CoopState.WindingDown) revert WrongState();
        uint256 bal = salt.balanceOf(address(this));
        uint256 accountedNet = ledger.totalRevenueCredited() - ledger.totalDividendClaimed();
        if (bal > accountedNet) {
            credited = bal - accountedNet;
            ledger.creditRevenue(credited);
            emit RevenueReceived(credited);
        }
    }

    // --- residual claim ---

    /// @notice Claim earned patronage dividends. SETL-M2 policy (explicit, matches CRP.forfeit +
    ///         COOP_OWNERSHIP_CONTRACT_SPEC and Subchapter T): earned dividends are VESTED patronage
    ///         property. Claiming re-checks KYC (compliance/AML at payout) but does NOT require
    ///         continued membership — expulsion stops FUTURE earning (recordContribution is
    ///         membership-gated) but never confiscates ALREADY-EARNED dividends, exactly as
    ///         ContributionRewardPool.forfeit keeps already-vested CRP claimable. A member who loses
    ///         KYC is blocked here but not confiscated: the owed balance stays booked (and, post
    ///         SETL-C1, backed even through dissolve), and becomes claimable again once KYC is
    ///         restored. So the divergence from recordContribution's membership gate is intentional,
    ///         not an oversight.
    function claimDividend() external nonReentrant {
        if (!kyc.isVerified(msg.sender)) revert NotKyc(); // revocation re-checked at claim (compliance)
        uint256 owed = ledger.recordClaim(msg.sender);
        if (owed == 0) revert Nothing();
        require(salt.transfer(msg.sender, owed), "transfer");
        emit DividendClaimed(msg.sender, owed);
    }

    function pendingDividendOf(address m) external view returns (uint256) {
        return ledger.pendingDividendOf(m);
    }

    // --- governance execution (co-op acts as model owner) ---

    /// @notice Execute an arbitrary call as the cooperative (e.g. ModelRegistry.setInferencePrice).
    /// @dev SETL-C2 fix: the ledger and the SALT treasury are OFF-LIMITS to execute(). The coop holds
    ///      COOP_ROLE on the ledger, so an unconstrained execute() let the governor mint unbacked
    ///      dividends (creditRevenue), zero a member's dividend (recordClaim), or drain the treasury
    ///      (salt.transfer) — all bypassing the solvency backing the rest of the contract enforces.
    ///      Legitimate ledger/treasury mutations go through the purpose-built, invariant-checked
    ///      functions (depositRevenue/claimDividend/beginWindDown/dissolve), never a raw call.
    function execute(address target, uint256 value, bytes calldata data)
        external
        onlyGovernor
        nonReentrant
        returns (bytes memory)
    {
        if (target == address(ledger) || target == address(salt)) revert ExecForbidden();
        (bool ok, bytes memory ret) = target.call{value: value}(data);
        if (!ok) revert ExecFailed();
        emit Executed(target, value, data);
        return ret;
    }
}
