// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.26;

/// @title CitrateAdminSafe — M-of-N multisig + timelock for DEFAULT_ADMIN custody (SETL-M4)
/// @notice Holds DEFAULT_ADMIN_ROLE of the co-op money surface (PatronageLedger, ModelCooperative,
///         ContributionRewardPool, MembershipSBT) so NO single EOA can rotate roles, set patronage
///         weights, or set the governor. Every admin action needs `threshold` signer confirmations
///         AND then a `delay` timelock — the reaction window that starts AFTER approval, so a bad
///         (but approved) action can still be cancelled before it lands. Signer-set / threshold /
///         delay changes are themselves gated by the same flow (self-call through execute only), so
///         the safe can never be re-keyed without M-of-N + the timelock.
/// @dev Dependency-free, matching the repo style (lib/Auth.sol, CooperativeGovernor.sol). Deployed
///      SEPARATELY with the chosen signer set, then passed as `Params.admin` to
///      CitrateCooperativeFactory.createCooperative — the factory already hands DEFAULT_ADMIN to
///      `admin` and renounces its own, so no factory change is needed for the custody move.
contract CitrateAdminSafe {
    // --- config (mutable only via a timelocked self-call) ---
    address[] private _signers;
    mapping(address => bool) public isSigner;
    uint256 public threshold;
    uint256 public delay; // seconds
    /// PBA-L2-039: bumped on every signer-set change. An action records the config it was proposed
    /// under; once the signer set changes, every older action is void (no confirm/execute/cancel) and
    /// must be re-proposed, so confirmations from removed signers can never count toward a quorum.
    uint64 public configNonce;

    // --- proposals ---
    struct Action {
        address target;
        uint256 value;
        bytes data;
        uint64 eta; // 0 until queued (threshold reached); the execute-after timestamp
        uint32 confirmations;
        bool executed;
        bool canceled;
        uint64 configNonce; // PBA-L2-039: the signer-set generation this action belongs to
    }

    Action[] private _actions;
    mapping(uint256 => mapping(address => bool)) public confirmedBy;
    mapping(uint256 => uint32) public cancelConfirmations;
    mapping(uint256 => mapping(address => bool)) public cancelConfirmedBy;

    // reentrancy guard (hand-rolled, matching lib/Auth.sol::ReentrancyGuard)
    uint256 private _lock = 1;

    event Proposed(uint256 indexed id, address indexed proposer, address indexed target, uint256 value, bytes data);
    event Confirmed(uint256 indexed id, address indexed signer, uint32 confirmations);
    event Queued(uint256 indexed id, uint64 eta);
    event Executed(uint256 indexed id, bytes ret);
    event CancelConfirmed(uint256 indexed id, address indexed signer, uint32 confirmations);
    event Canceled(uint256 indexed id);
    event SignersChanged(address[] signers, uint256 threshold);
    event DelayChanged(uint256 delay);

    error NotSigner();
    error OnlySelf();
    error BadConfig();
    error UnknownAction();
    error AlreadyConfirmed();
    error AlreadyExecuted();
    error IsCanceled();
    error NotQueued();
    error Timelocked();
    error CallFailed();
    error Reentrancy();
    error StaleConfig(); // PBA-L2-039: the signer set changed after this action was proposed

    modifier onlySigner() {
        if (!isSigner[msg.sender]) revert NotSigner();
        _;
    }

    modifier onlySelf() {
        // Only the safe itself — i.e. a proposed, M-of-N-confirmed, timelocked execute() that targets
        // this contract. There is no external admin over the signer set.
        if (msg.sender != address(this)) revert OnlySelf();
        _;
    }

    modifier nonReentrant() {
        if (_lock == 2) revert Reentrancy();
        _lock = 2;
        _;
        _lock = 1;
    }

    constructor(address[] memory signers_, uint256 threshold_, uint256 delay_) {
        _setSigners(signers_, threshold_);
        delay = delay_;
        emit DelayChanged(delay_);
    }

    // --- views ---

    function signers() external view returns (address[] memory) {
        return _signers;
    }

    function signerCount() external view returns (uint256) {
        return _signers.length;
    }

    function actionCount() external view returns (uint256) {
        return _actions.length;
    }

    function actionOf(uint256 id) external view returns (Action memory) {
        if (id >= _actions.length) revert UnknownAction();
        return _actions[id];
    }

    // --- propose / confirm / execute / cancel ---

    /// @notice Propose an admin action; the proposer's confirmation is counted immediately.
    function propose(address target, uint256 value, bytes calldata data)
        external
        onlySigner
        returns (uint256 id)
    {
        id = _actions.length;
        _actions.push(
            Action({
                target: target,
                value: value,
                data: data,
                eta: 0,
                confirmations: 0,
                executed: false,
                canceled: false,
                configNonce: configNonce
            })
        );
        emit Proposed(id, msg.sender, target, value, data);
        _confirm(id); // the proposer auto-confirms
    }

    function confirm(uint256 id) external onlySigner {
        _confirm(id);
    }

    function _confirm(uint256 id) internal {
        if (id >= _actions.length) revert UnknownAction();
        Action storage a = _actions[id];
        if (a.executed) revert AlreadyExecuted();
        if (a.canceled) revert IsCanceled();
        if (a.configNonce != configNonce) revert StaleConfig();
        if (confirmedBy[id][msg.sender]) revert AlreadyConfirmed();
        confirmedBy[id][msg.sender] = true;
        a.confirmations += 1;
        emit Confirmed(id, msg.sender, a.confirmations);
        // Queue when the threshold is FIRST reached: the timelock (reaction window) begins now, after
        // approval — not at propose time — so the full delay always applies to an approved action.
        if (a.eta == 0 && a.confirmations >= threshold) {
            a.eta = uint64(block.timestamp + delay);
            emit Queued(id, a.eta);
        }
    }

    /// @notice Execute a queued action once its timelock has elapsed. Any signer may fire it.
    function execute(uint256 id) external onlySigner nonReentrant returns (bytes memory) {
        if (id >= _actions.length) revert UnknownAction();
        Action storage a = _actions[id];
        if (a.executed) revert AlreadyExecuted();
        if (a.canceled) revert IsCanceled();
        if (a.configNonce != configNonce) revert StaleConfig(); // signer set rotated since proposal
        if (a.eta == 0) revert NotQueued(); // threshold never reached
        if (block.timestamp < a.eta) revert Timelocked(); // delay not elapsed
        a.executed = true; // effects before interaction (CEI)
        (bool ok, bytes memory r) = a.target.call{value: a.value}(a.data);
        if (!ok) revert CallFailed();
        emit Executed(id, r);
        return r;
    }

    /// @notice Cancel a not-yet-executed action. Threshold-gated (like execute) so a single rogue
    ///         signer can neither veto everything nor block their own removal — cancelling needs the
    ///         same M-of-N the action itself did.
    function cancel(uint256 id) external onlySigner {
        if (id >= _actions.length) revert UnknownAction();
        Action storage a = _actions[id];
        if (a.executed) revert AlreadyExecuted();
        if (a.canceled) revert IsCanceled();
        if (a.configNonce != configNonce) revert StaleConfig(); // already void, nothing to cancel
        if (cancelConfirmedBy[id][msg.sender]) revert AlreadyConfirmed();
        cancelConfirmedBy[id][msg.sender] = true;
        uint32 c = cancelConfirmations[id] + 1;
        cancelConfirmations[id] = c;
        emit CancelConfirmed(id, msg.sender, c);
        if (c >= threshold) {
            a.canceled = true;
            emit Canceled(id);
        }
    }

    // --- self-administration (only via a timelocked self-call routed through execute) ---

    function setSigners(address[] calldata newSigners, uint256 newThreshold) external onlySelf {
        _setSigners(newSigners, newThreshold);
    }

    function setDelay(uint256 newDelay) external onlySelf {
        delay = newDelay;
        emit DelayChanged(newDelay);
    }

    function _setSigners(address[] memory s, uint256 t) internal {
        for (uint256 i = 0; i < _signers.length; i++) {
            isSigner[_signers[i]] = false;
        }
        delete _signers;
        if (s.length == 0 || t == 0 || t > s.length) revert BadConfig();
        for (uint256 i = 0; i < s.length; i++) {
            address a = s[i];
            if (a == address(0) || isSigner[a]) revert BadConfig(); // no zero address, no duplicates
            isSigner[a] = true;
            _signers.push(a);
        }
        threshold = t;
        configNonce += 1; // PBA-L2-039: void every action proposed under the previous signer set
        emit SignersChanged(s, t);
    }

    receive() external payable {}
}
