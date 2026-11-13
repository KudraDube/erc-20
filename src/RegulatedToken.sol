// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

// ============ Borrowed from OpenZeppelin ============
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC20Pausable} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Pausable.sol";
import {ERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";

contract RegulatedToken is ERC20, ERC20Pausable, ERC20Permit, AccessControl {

    // ============ Custom logic ============

    bytes32 public constant MINTER_ROLE = keccak256("MINTER_ROLE");
    bytes32 public constant PAUSER_ROLE = keccak256("PAUSER_ROLE");
    bytes32 public constant COMPLIANCE_ROLE = keccak256("COMPLIANCE_ROLE");

    uint256 public immutable cap;

    mapping(address => bool) public isBlacklisted;

    event Blacklisted(address indexed account);
    event Unblacklisted(address indexed account);

    error CapExceeded(uint256 requested, uint256 cap);
    error AccountBlacklisted(address account);

    constructor(
        string memory name_,
        string memory symbol_,
        uint256 cap_,
        address admin
    ) ERC20(name_, symbol_) ERC20Permit(name_) {
        cap = cap_;
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(MINTER_ROLE, admin);
        _grantRole(PAUSER_ROLE, admin);
        _grantRole(COMPLIANCE_ROLE, admin);
    }

    function mint(address to, uint256 amount) external onlyRole(MINTER_ROLE) {
        _mint(to, amount); // the cap is enforced in _update, so it holds on every mint path
    }

    function pause() external onlyRole(PAUSER_ROLE) {
        _pause();
    }

    function unpause() external onlyRole(PAUSER_ROLE) {
        _unpause();
    }

    function blacklist(address account) external onlyRole(COMPLIANCE_ROLE) {
        isBlacklisted[account] = true;
        emit Blacklisted(account);
    }

    function unblacklist(address account) external onlyRole(COMPLIANCE_ROLE) {
        isBlacklisted[account] = false;
        emit Unblacklisted(account);
    }

    // The single choke point every transfer, mint and burn passes through
    function _update(address from, address to, uint256 value)
        internal
        override(ERC20, ERC20Pausable)
    {
        if (isBlacklisted[from]) revert AccountBlacklisted(from);
        if (isBlacklisted[to]) revert AccountBlacklisted(to);

        super._update(from, to, value); // runs ERC20Pausable's paused check, then ERC20's actual balance update

        // from == address(0) means this was a mint. The supply has already grown, so compare it to the cap.
        if (from == address(0) && totalSupply() > cap) {
            revert CapExceeded(totalSupply(), cap);
        }
    }
}
