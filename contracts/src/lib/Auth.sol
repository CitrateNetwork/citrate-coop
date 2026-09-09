// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

/// @title Auth — minimal role-based access control (RFC-CIT-COOP-0001)
/// @notice Tiny, dependency-free AccessControl. Deployer gets DEFAULT_ADMIN_ROLE.
abstract contract Auth {
    bytes32 public constant DEFAULT_ADMIN_ROLE = 0x00;

    mapping(bytes32 => mapping(address => bool)) private _roles;

    event RoleGranted(bytes32 indexed role, address indexed account, address indexed sender);
    event RoleRevoked(bytes32 indexed role, address indexed account, address indexed sender);

    error Unauthorized(bytes32 role, address account);

    constructor() {
        _grant(DEFAULT_ADMIN_ROLE, msg.sender);
    }

    modifier onlyRole(bytes32 role) {
        if (!_roles[role][msg.sender]) revert Unauthorized(role, msg.sender);
        _;
    }

    function hasRole(bytes32 role, address account) public view returns (bool) {
        return _roles[role][account];
    }

    function grantRole(bytes32 role, address account) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _grant(role, account);
    }

    function revokeRole(bytes32 role, address account) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (_roles[role][account]) {
            _roles[role][account] = false;
            emit RoleRevoked(role, account, msg.sender);
        }
    }

    function _grant(bytes32 role, address account) internal {
        if (!_roles[role][account]) {
            _roles[role][account] = true;
            emit RoleGranted(role, account, msg.sender);
        }
    }
}

/// @notice Minimal reentrancy guard.
abstract contract ReentrancyGuard {
    uint256 private _status = 1;
    error Reentrancy();

    modifier nonReentrant() {
        if (_status == 2) revert Reentrancy();
        _status = 2;
        _;
        _status = 1;
    }
}
