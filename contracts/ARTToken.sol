// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC20} from "@openzeppelin/contracts@5.4.0/token/ERC20/ERC20.sol";
import {ERC20Burnable} from "@openzeppelin/contracts@5.4.0/token/ERC20/extensions/ERC20Burnable.sol";
import {ERC20Permit} from "@openzeppelin/contracts@5.4.0/token/ERC20/extensions/ERC20Permit.sol";
import {IERC20} from "@openzeppelin/contracts@5.4.0/token/ERC20/IERC20.sol";
import {Ownable} from "@openzeppelin/contracts@5.4.0/access/Ownable.sol";
import {Pausable} from "@openzeppelin/contracts@5.4.0/utils/Pausable.sol";
import {SafeERC20} from "@openzeppelin/contracts@5.4.0/token/ERC20/utils/SafeERC20.sol";

/**
 * @title ARTToken
 * @dev Aurum Reserve Token - gold-backed digital asset token
 */
contract ARTToken is ERC20, ERC20Burnable, ERC20Permit, Ownable, Pausable {

    using SafeERC20 for IERC20;

    // ==================== Constants ====================

    string public constant VERSION = "1.0.0";

    uint256 public constant MAX_BATCH = 100;               // admin batch ops

    // ==================== State ====================

    mapping(address => bool) private admins;
    address[] private adminList;

    address public vault;

    // Bridges allowlist
    mapping(address => bool) public bridges;

    // Bridge accounting
    uint256 public totalBridgedOut;
    uint256 public totalBridgedIn;

    // Minimal replay protection for bridgeIn (per-bridge nonce)
    mapping(address => mapping(uint256 => bool)) public bridgeInNonceUsed;

    // Compliance
    mapping(address => bool) public blacklisted;

    // Transparency stats
    uint256 public totalMinted;
    uint256 public totalBurned;

    // ==================== Events ====================

    event VaultUpdated(address indexed oldVault, address indexed newVault);

    event AdminAdded(address indexed account);
    event AdminRemoved(address indexed account);

    event BlacklistedUpdated(address indexed account, bool isBlacklisted);
    event BlacklistedBurned(address indexed account, uint256 amount);

    event SupplyMinted(address indexed to, uint256 amount);
    event SupplyBurned(address indexed from, uint256 amount);

    event BridgeUpdated(address indexed bridge, bool allowed);
    event BridgeOut(address indexed account, uint256 amount, string targetChain);
    event BridgeIn(address indexed account, uint256 amount, string sourceChain, uint256 nonce);

    event ERC20Rescued(address indexed token, address indexed to, uint256 amount);
    event NativeRescued(address indexed to, uint256 amount);

    // ==================== Errors ====================

    error OnlyAdminOrOwner();
    error OnlyVault();
    error OnlyBridge();
    error InvalidAddress();
    error InvalidAmount();
    error UserBlacklisted(address user);
    error NotBlacklisted(address user);
    error EmptyArray();
    error TooManyUsers();
    error NonceAlreadyUsed();
    error NativeTransferFailed();
    error ContractPaused();

    // ==================== Modifiers ====================

    modifier onlyAdminOrOwner() {
        if (msg.sender != owner() && !admins[msg.sender]) revert OnlyAdminOrOwner();
        _;
    }

    modifier onlyVault() {
        if (msg.sender != vault) revert OnlyVault();
        _;
    }

    modifier onlyBridge() {
        if (!bridges[msg.sender]) revert OnlyBridge();
        _;
    }

    modifier validAddress(address addr) {
        if (addr == address(0)) revert InvalidAddress();
        _;
    }

    modifier validAmount(uint256 amount) {
        if (amount == 0) revert InvalidAmount();
        _;
    }

    // ==================== Constructor & Views ====================

    constructor()
    ERC20("Aurum Reserve Token", "ART")
    ERC20Permit("Aurum Reserve Token")
    Ownable(msg.sender)
    {
        _addAdminInternal(msg.sender);
    }

    function decimals() public pure virtual override returns (uint8) { return 6; }

    function getSupplyStats() external view returns (uint256 currentSupply, uint256 mintedTotal, uint256 burnedTotal) {
        return (totalSupply(), totalMinted, totalBurned);
    }

    struct Overview {
        // Version and basic token meta
        string  version;
        string  name;
        string  symbol;
        uint8   decimalsValue;
        uint256 maxBatch;

        // Roles
        address owner;
        address vault;

        // State
        bool    paused;

        // Bridge
        uint256 totalBridgedIn;
        uint256 totalBridgedOut;

        // Supply
        uint256 totalSupplyNow;
        uint256 totalMinted;
        uint256 totalBurned;
    }

    function getOverview() external view returns (Overview memory s) {
        s.version         = VERSION;
        s.name            = name();
        s.symbol          = symbol();
        s.decimalsValue   = decimals();
        s.maxBatch        = MAX_BATCH;

        s.owner           = owner();
        s.vault           = vault;

        s.paused          = paused();

        s.totalBridgedIn  = totalBridgedIn;
        s.totalBridgedOut = totalBridgedOut;

        s.totalSupplyNow  = totalSupply();
        s.totalMinted     = totalMinted;
        s.totalBurned     = totalBurned;
    }

    // ==================== Role Management ====================

    function setVault(address newVault) external onlyOwner validAddress(newVault) {
        if (newVault == vault) return;
        address old = vault;
        vault = newVault;
        emit VaultUpdated(old, newVault);
    }

    function setBridge(address bridge, bool allowed) external onlyOwner validAddress(bridge) {
        if (bridges[bridge] == allowed) return;
        bridges[bridge] = allowed;
        emit BridgeUpdated(bridge, allowed);
    }

    function addAdmin(address account) external onlyOwner validAddress(account) {
        if (_addAdminInternal(account)) {
            emit AdminAdded(account);
        }
    }

    function removeAdmin(address account) external onlyOwner validAddress(account) {
        if (_removeAdminInternal(account)) {
            emit AdminRemoved(account);
        }
    }

    function isAdmin(address account) public view returns (bool) {
        return admins[account];
    }

    function getAdmins() external view onlyAdminOrOwner returns (address[] memory) {
        return adminList;
    }

    function _addAdminInternal(address account) internal returns (bool) {
        if (admins[account]) return false;
        admins[account] = true;
        adminList.push(account);
        return true;
    }

    function _removeAdminInternal(address account) internal returns (bool) {
        if (!admins[account]) return false;
        admins[account] = false;

        uint256 len = adminList.length;
        for (uint256 i = 0; i < len; ) {
            if (adminList[i] == account) {
                uint256 last = len - 1;
                if (i != last) {
                    adminList[i] = adminList[last];
                }
                adminList.pop();
                break;
            }
            unchecked { ++i; }
        }
        return true;
    }

    // ==================== Token Management ====================

    function mint(address to, uint256 amount) external onlyAdminOrOwner validAddress(to) validAmount(amount) {
        _mint(to, amount);
    }

    function mintFromVault(address to, uint256 amount) external onlyVault validAddress(to) validAmount(amount) {
        _mint(to, amount);
        emit SupplyMinted(to, amount);
    }

    function burnFromVault(address from, uint256 amount) external onlyVault validAddress(from) validAmount(amount) {
        _burn(from, amount);
        emit SupplyBurned(from, amount);
    }

    // ==================== Bridging ====================

    /**
     * @notice Bridge out: burn tokens from account for bridging to targetChain.
     */
    function bridgeOut(address account, uint256 amount, string calldata targetChain)
    external
    onlyBridge
    validAddress(account)
    validAmount(amount)
    {
        _burn(account, amount);
        totalBridgedOut += amount;

        emit BridgeOut(account, amount, targetChain);
    }

    /**
     * @notice Bridge in: mint tokens to account after receiving proof from source chain.
     */
    function bridgeIn(address account, uint256 amount, string calldata sourceChain, uint256 nonce)
    external
    onlyBridge
    validAddress(account)
    validAmount(amount)
    {
        if (bridgeInNonceUsed[msg.sender][nonce]) revert NonceAlreadyUsed();
        bridgeInNonceUsed[msg.sender][nonce] = true;

        _mint(account, amount);
        totalBridgedIn += amount;

        emit BridgeIn(account, amount, sourceChain, nonce);
    }

    // ==================== Internal ====================

    /**
     * @dev Enforce pause/blacklist and unify mint/burn statistics.
     */
    function _update(address from, address to, uint256 value) internal override {
        if (paused()) revert ContractPaused();

        if (from != address(0) && blacklisted[from]) revert UserBlacklisted(from);
        if (to   != address(0) && blacklisted[to])   revert UserBlacklisted(to);

        bool isMint = (from == address(0));
        bool isBurn = (to   == address(0));

        super._update(from, to, value);

        if (isMint) {
            totalMinted += value;
        } else if (isBurn) {
            totalBurned += value;
        }
    }

    // ==================== Compliance ====================

    function setBlacklisted(address account, bool status) external onlyAdminOrOwner validAddress(account) {
        if (blacklisted[account] == status) return;
        blacklisted[account] = status;
        emit BlacklistedUpdated(account, status);
    }

    function setBlacklistedBatch(address[] calldata accounts, bool status) external onlyAdminOrOwner {
        uint256 len = accounts.length;
        if (len == 0) revert EmptyArray();
        if (len > MAX_BATCH) revert TooManyUsers();

        for (uint256 i = 0; i < len; ) {
            address a = accounts[i];
            if (a != address(0) && blacklisted[a] != status) {
                blacklisted[a] = status;
                emit BlacklistedUpdated(a, status);
            }
            unchecked { ++i; }
        }
    }

    function burnBlacklisted(address account, uint256 amount) external onlyAdminOrOwner validAddress(account) validAmount(amount) {
        if (!blacklisted[account]) revert NotBlacklisted(account);
        _burn(account, amount);
        emit BlacklistedBurned(account, amount);
    }

    function isBlacklisted(address account) external view returns (bool) {
        return blacklisted[account];
    }

    // ==================== Emergency ====================

    function pause() external onlyAdminOrOwner { _pause(); }

    function unpause() external onlyOwner { _unpause(); }

    function rescueERC20(address token, address to, uint256 amount) external onlyOwner validAddress(token) validAddress(to) validAmount(amount) {
        if (token == address(this)) {
            _transfer(address(this), to, amount);
        } else {
            IERC20(token).safeTransfer(to, amount);
        }
        emit ERC20Rescued(token, to, amount);
    }

    function rescueNative(address to, uint256 amount) external onlyOwner validAddress(to) validAmount(amount) {
        (bool ok, ) = to.call{value: amount}("");
        if (!ok) revert NativeTransferFailed();
        emit NativeRescued(to, amount);
    }
}