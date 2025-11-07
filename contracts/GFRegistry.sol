// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts@5.4.0/token/ERC20/IERC20.sol";
import {Ownable} from "@openzeppelin/contracts@5.4.0/access/Ownable.sol";
import {Pausable} from "@openzeppelin/contracts@5.4.0/utils/Pausable.sol";
import {SafeERC20} from "@openzeppelin/contracts@5.4.0/token/ERC20/utils/SafeERC20.sol";

/**
 * @title GFRegistry
 * @notice Minimal identity registry for KYC approval and human-readable names.
 *         - Read-only queries are always available.
 *         - Writes (set/clear/batch) can be paused.
 *         - Separate admin role from owner.
 *         - Names are unique (case-insensitive).
 */
contract GFRegistry is Ownable, Pausable {

    using SafeERC20 for IERC20;

    // ==================== Constants ====================

    string public constant VERSION = "1.0.0";

    uint256 public constant MAX_BATCH = 100;

    // Name constraints
    uint256 public constant NAME_MIN_LEN = 1;
    uint256 public constant NAME_MAX_LEN = 64;

    // ==================== Storage ====================

    mapping(address => bool) private admins;
    address[] private adminList;

    mapping(address => bool) private kycApproved;

    // Name registry (normalized lowercase)
    mapping(address => string) private addressName;   // address -> display name (original casing)
    mapping(string => address) private nameOwner;     // normalized lowercase name -> address

    // ==================== Events ====================

    event AdminAdded(address indexed account);
    event AdminRemoved(address indexed account);

    event KycStatusUpdated(address indexed account, bool approved);

    event ERC20Rescued(address indexed token, address indexed to, uint256 amount);
    event NativeRescued(address indexed to, uint256 amount);

    event NameSet(address indexed account, string name);
    event NameCleared(address indexed account, string oldName);

    // ==================== Errors ====================

    error OnlyAdminOrOwner();
    error InvalidAddress();
    error InvalidAmount();
    error EmptyArray();
    error TooManyAccounts();
    error NativeTransferFailed();

    error InvalidName();
    error NameAlreadyTaken();
    error NotNameOwner();

    // ==================== Modifiers ====================

    modifier onlyAdminOrOwner() {
        if (msg.sender != owner() && !admins[msg.sender]) revert OnlyAdminOrOwner();
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

    constructor() Ownable(msg.sender) {
        _addAdminInternal(msg.sender);
    }

    function getOverview()
    external
    view
    returns (
        string memory version,
        address owner_,
        bool paused_,
        uint256 maxBatch
    )
    {
        return (VERSION, owner(), paused(), MAX_BATCH);
    }

    function isKycApproved(address account) external view returns (bool) {
        return kycApproved[account];
    }

    /**
     * @notice Batch read: get KYC status for multiple accounts.
     */
    function getKycStatusBatch(address[] calldata accounts) external view returns (bool[] memory statuses) {
        uint256 len = accounts.length;
        if (len > MAX_BATCH) revert TooManyAccounts();
        statuses = new bool[](len);
        for (uint256 i = 0; i < len; ) {
            statuses[i] = kycApproved[accounts[i]];
            unchecked { ++i; }
        }
    }

    /**
     * @notice Get the display name (original casing) of an address. Returns empty string if unset.
     */
    function nameOf(address account) external view returns (string memory) {
        return addressName[account];
    }

    /**
     * @notice Batch read: get display names (original casing) for multiple accounts.
     *         Unset names return empty string.
     */
    function getNamesBatch(address[] calldata accounts) external view returns (string[] memory names) {
        uint256 len = accounts.length;
        if (len > MAX_BATCH) revert TooManyAccounts();
        names = new string[](len);
        for (uint256 i = 0; i < len; ) {
            names[i] = addressName[accounts[i]];
            unchecked { ++i; }
        }
    }

    /**
     * @notice Get the owner address of a normalized (lowercase) name. Returns address(0) if unregistered.
     * @dev Input will be normalized to lowercase before lookup to ensure consistent behavior.
     */
    function ownerOfName(string calldata name) external view returns (address) {
        string memory norm = _normalize(name);
        return nameOwner[norm];
    }

    // ==================== Admin Management ====================

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

    function isAdmin(address account) external view returns (bool) {
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
            unchecked {
                ++i;
            }
        }
        return true;
    }

    // ==================== KYC Writes ====================

    /**
     * @notice Set KYC status for a single account.
     * @dev Writing operations are blocked when paused. Reads remain available.
     */
    function setKycStatus(address account, bool approved) external onlyAdminOrOwner validAddress(account) whenNotPaused
    {
        if (kycApproved[account] == approved) return;
        kycApproved[account] = approved;
        emit KycStatusUpdated(account, approved);
    }

    /**
     * @notice Batch set KYC status for multiple accounts.
     * @dev Hard-capped by MAX_BATCH to bound runtime.
     */
    function setKycStatusBatch(address[] calldata accounts, bool approved) external onlyAdminOrOwner whenNotPaused {
        uint256 len = accounts.length;
        if (len == 0) revert EmptyArray();
        if (len > MAX_BATCH) revert TooManyAccounts();

        for (uint256 i = 0; i < len; ) {
            address a = accounts[i];
            if (a != address(0) && kycApproved[a] != approved) {
                kycApproved[a] = approved;
                emit KycStatusUpdated(a, approved);
            }
            unchecked { ++i; }
        }
    }

    // ==================== Names: Writes ====================

    /**
     * @notice Set your own name. Name must be unique (case-insensitive).
     * @dev Writing operations are blocked when paused.
     */
    function setMyName(string calldata name) external whenNotPaused {
        _setName(msg.sender, name);
    }

    /**
     * @notice Admin/Owner set name for any account (overrides existing name binding).
     * @dev Useful for ops corrections or migration. Writing operations are blocked when paused.
     */
    function setNameFor(address account, string calldata name) external onlyAdminOrOwner validAddress(account) whenNotPaused
    {
        _setName(account, name);
    }

    /**
     * @notice Clear your own name.
     */
    function clearMyName() external whenNotPaused {
        _clearName(msg.sender);
    }

    /**
     * @notice Admin/Owner clears name of any account.
     */
    function clearNameFor(address account) external onlyAdminOrOwner validAddress(account) whenNotPaused {
        _clearName(account);
    }

    // Internal name logic
    function _setName(address account, string calldata rawName) internal {
        // Normalize and validate
        string memory norm = _normalize(rawName);
        _validateName(norm);

        // If account already has a name, free it first if different
        string memory old = addressName[account];
        if (bytes(old).length != 0) {
            if (_equals(_normalize(old), norm)) {
                if (!_equals(old, rawName)) {
                    addressName[account] = rawName;
                    emit NameSet(account, rawName);
                }
                return;
            }
            // free old -> address mapping
            nameOwner[_normalize(old)] = address(0);
        }

        // Ensure the new name is free or already owned by the same account
        address currentOwner = nameOwner[norm];
        if (currentOwner != address(0) && currentOwner != account) {
            revert NameAlreadyTaken();
        }

        // Bind
        addressName[account] = rawName;
        nameOwner[norm] = account;

        emit NameSet(account, rawName);
    }

    function _clearName(address account) internal {
        string memory oldDisplay = addressName[account];
        if (bytes(oldDisplay).length == 0) {
            return; // nothing to clear
        }

        // Clear both sides
        delete addressName[account];
        string memory oldNorm = _normalize(oldDisplay);
        nameOwner[oldNorm] = address(0);

        emit NameCleared(account, oldDisplay);
    }

    // ==================== Emergency ====================

    function pause() external onlyAdminOrOwner { _pause(); }

    function unpause() external onlyOwner { _unpause(); }

    function rescueERC20(address token, address to, uint256 amount) external onlyOwner validAddress(token) validAddress(to) validAmount(amount) {
        IERC20(token).safeTransfer(to, amount);
        emit ERC20Rescued(token, to, amount);
    }

    function rescueNative(address to, uint256 amount) external onlyOwner validAddress(to) validAmount(amount) {
        (bool ok, ) = to.call{value: amount}("");
        if (!ok) revert NativeTransferFailed();
        emit NativeRescued(to, amount);
    }

    // ==================== Internal utils ====================

    function _validateName(string memory norm) internal pure {
        bytes memory b = bytes(norm);
        uint256 len = b.length;
        if (len < NAME_MIN_LEN || len > NAME_MAX_LEN) revert InvalidName();

        // Allowed: 'a'-'z', '0'-'9', '.', '-', '_'
        for (uint256 i = 0; i < len; ) {
            bytes1 c = b[i];
            bool ok =
                (c >= 0x61 && c <= 0x7A) || // a-z
                (c >= 0x30 && c <= 0x39) || // 0-9
                c == 0x2E ||                // '.'
                c == 0x2D ||                // '-'
                c == 0x5F;                  // '_'
            if (!ok) revert InvalidName();
            unchecked { ++i; }
        }
    }

    // Normalize to lowercase. Reverts if non-ASCII letter passed that would violate allowed-set after lowering.
    function _normalize(string memory input) internal pure returns (string memory) {
        bytes memory src = bytes(input);
        uint256 len = src.length;
        bytes memory out = new bytes(len);
        for (uint256 i = 0; i < len; ) {
            bytes1 c = src[i];
            // Uppercase A-Z -> lowercase a-z
            if (c >= 0x41 && c <= 0x5A) {
                out[i] = bytes1(uint8(c) + 32);
            } else {
                out[i] = c;
            }
            unchecked { ++i; }
        }
        return string(out);
    }

    function _equals(string memory a, string memory b) internal pure returns (bool) {
        return keccak256(bytes(a)) == keccak256(bytes(b));
    }
}