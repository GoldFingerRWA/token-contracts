// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC20} from "@openzeppelin/contracts@5.4.0/token/ERC20/ERC20.sol";
import {ERC20Burnable} from "@openzeppelin/contracts@5.4.0/token/ERC20/extensions/ERC20Burnable.sol";
import {ERC20Permit} from "@openzeppelin/contracts@5.4.0/token/ERC20/extensions/ERC20Permit.sol";
import {ERC20Votes} from "@openzeppelin/contracts@5.4.0/token/ERC20/extensions/ERC20Votes.sol";
import {IERC20} from "@openzeppelin/contracts@5.4.0/token/ERC20/IERC20.sol";
import {IERC6372} from "@openzeppelin/contracts@5.4.0/interfaces/IERC6372.sol";
import {Nonces} from "@openzeppelin/contracts@5.4.0/utils/Nonces.sol";
import {Ownable} from "@openzeppelin/contracts@5.4.0/access/Ownable.sol";
import {Pausable} from "@openzeppelin/contracts@5.4.0/utils/Pausable.sol";
import {SafeERC20} from "@openzeppelin/contracts@5.4.0/token/ERC20/utils/SafeERC20.sol";

/**
 * @title GFToken
 * @notice GoldFinger Governance Token (GF) — the governance and ecosystem incentive token.
 *
 * Key features:
 * - ERC20 with 6 decimals and capped total supply (100B GF with 6 decimals).
 * - ERC20Permit (EIP-2612) and ERC20Votes (delegation and snapshots for governance).
 * - Timestamp-based governance clock (ERC-6372) for intuitive time units in governor parameters.
 * - Role model: Owner + Admin set + Minter set.
 * - Compliance: blacklist controls, pausable transfers, and admin burn for blacklisted balances.
 * - Transparency: tracks total minted and burned.
 * - Safety: supply cap enforced on mint; rescue functions for stale assets.
 */
contract GFToken is ERC20, ERC20Burnable, ERC20Permit, ERC20Votes, Ownable, Pausable {

    using SafeERC20 for IERC20;

    // ==================== Constants ====================

    string public constant VERSION = "1.0.0";

    uint256 public constant TOTAL_SUPPLY = 100_000_000_000 * 10**6;
    uint256 public constant MAX_BATCH = 100;               // admin batch ops

    // ==================== State ====================

    mapping(address => bool) private admins;
    address[] private adminList;

    mapping(address => bool) private minters;
    address[] private minterList;

    // Compliance
    mapping(address => bool) public blacklisted;

    // Transparency stats
    uint256 public totalMinted;
    uint256 public totalBurned;

    // ==================== Events ====================

    event AdminAdded(address indexed account);
    event AdminRemoved(address indexed account);

    event MinterAdded(address indexed account);
    event MinterRemoved(address indexed account);

    event BlacklistedUpdated(address indexed account, bool isBlacklisted);
    event BlacklistedBurned(address indexed account, uint256 amount);

    event ERC20Rescued(address indexed token, address indexed to, uint256 amount);
    event NativeRescued(address indexed to, uint256 amount);

    // ==================== Errors ====================

    error OnlyAdminOrOwner();
    error OnlyMinter();
    error InvalidAddress();
    error InvalidAmount();
    error ExceedsMaxSupply();
    error UserBlacklisted(address user);
    error NotBlacklisted(address user);
    error EmptyArray();
    error TooManyUsers();
    error NativeTransferFailed();
    error ContractPaused();

    // ==================== Modifiers ====================

    modifier onlyAdminOrOwner() {
        if (msg.sender != owner() && !admins[msg.sender]) revert OnlyAdminOrOwner();
        _;
    }

    modifier onlyMinter() {
        if (!minters[msg.sender]) revert OnlyMinter();
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
    ERC20("GoldFinger Token", "GF")
    ERC20Permit("GoldFinger Token")
    Ownable(msg.sender)
    {
        _addAdminInternal(msg.sender);
        _addMinterInternal(msg.sender);
    }

    function decimals() public pure virtual override returns (uint8) { return 6; }

    function getSupplyStats() external view returns (uint256 currentSupply, uint256 mintedTotal, uint256 burnedTotal, uint256 maxSupply) {
        return (totalSupply(), totalMinted, totalBurned, TOTAL_SUPPLY);
    }

    struct Overview {
        // Version and basic token meta
        string  version;
        string  name;
        string  symbol;
        uint8   decimalsValue;
        uint256 maxSupply;
        uint256 maxBatch;

        // Roles
        address owner;

        // State
        bool    paused;

        // Supply
        uint256 totalSupplyNow;   // current total supply
        uint256 totalMinted;      // cumulative minted
        uint256 totalBurned;      // cumulative burned
    }

    function getOverview() external view returns (Overview memory s) {
        // Basic metadata and limits
        s.version         = VERSION;
        s.name            = name();
        s.symbol          = symbol();
        s.decimalsValue   = decimals();
        s.maxSupply       = TOTAL_SUPPLY;
        s.maxBatch        = MAX_BATCH;

        // Roles
        s.owner           = owner();

        // Runtime state
        s.paused          = paused();

        s.totalSupplyNow  = totalSupply();
        s.totalMinted     = totalMinted;
        s.totalBurned     = totalBurned;
    }
    // ---------- ERC-6372 (Timestamp clock) ----------

    /**
     * @notice Timestamp-based governance clock for ERC-6372 compatibility.
     * Governor will use seconds for votingDelay/votingPeriod.
     */
    function clock() public view virtual override returns (uint48) {
        return uint48(block.timestamp);
    }

    /**
     * @notice ERC-6372 CLOCK_MODE string indicating timestamp mode.
     */
    function CLOCK_MODE() public pure virtual override returns (string memory) {
        return "mode=timestamp";
    }

    // ==================== Role Management ====================

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

    function addMinter(address account) external onlyOwner validAddress(account) {
        if (_addMinterInternal(account)) {
            emit MinterAdded(account);
        }
    }

    function removeMinter(address account) external onlyOwner validAddress(account) {
        if (_removeMinterInternal(account)) {
            emit MinterRemoved(account);
        }
    }

    function isMinter(address account) external view returns (bool) {
        return minters[account];
    }

    function getMinters() external view onlyAdminOrOwner returns (address[] memory) {
        return minterList;
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

    function _addMinterInternal(address account) internal returns (bool) {
        if (minters[account]) return false;
        minters[account] = true;
        minterList.push(account);
        return true;
    }

    function _removeMinterInternal(address account) internal returns (bool) {
        if (!minters[account]) return false;
        minters[account] = false;

        uint256 len = minterList.length;
        for (uint256 i = 0; i < len; ) {
            if (minterList[i] == account) {
                uint256 last = len - 1;
                if (i != last) {
                    minterList[i] = minterList[last];
                }
                minterList.pop();
                break;
            }
            unchecked { ++i; }
        }
        return true;
    }

    // ==================== Token Management ====================

    function mint(address to, uint256 amount) external onlyMinter validAddress(to) validAmount(amount) {
        _enforceSupply(amount);
        _mint(to, amount);
    }

    // ==================== Internal Helpers ====================

    function _enforceSupply(uint256 mintAmount) internal view {
        uint256 newSupply = totalSupply() + mintAmount;
        if (newSupply > TOTAL_SUPPLY) revert ExceedsMaxSupply();
    }

    /**
     * @dev Centralized transfer hook integrating:
     *  - Pause check (reverts if paused).
     *  - Blacklist checks on sender and recipient.
     *  - Vote checkpointing (ERC20Votes).
     *  - Mint/burn statistics accounting.
     */
    function _update(address from, address to, uint256 value) internal override(ERC20, ERC20Votes) {
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

    /**
     * @dev Required override to disambiguate Nonces for ERC20Permit.
     */
    function nonces(address owner) public view virtual override(ERC20Permit, Nonces) returns (uint256) {
        return super.nonces(owner);
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