// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts@5.4.0/token/ERC20/IERC20.sol";
import {Ownable} from "@openzeppelin/contracts@5.4.0/access/Ownable.sol";
import {Pausable} from "@openzeppelin/contracts@5.4.0/utils/Pausable.sol";
import {SafeERC20} from "@openzeppelin/contracts@5.4.0/token/ERC20/utils/SafeERC20.sol";

/**
 * @title GFPriceOracle
 * @dev Provides manually managed asset prices (USD, 6 decimals) with admins/owner roles and pause control.
 */
contract GFPriceOracle is Ownable, Pausable {

    using SafeERC20 for IERC20;

    // ==================== Constants ====================

    string public constant VERSION = "1.0.0";

    uint256 public constant PRICE_PRECISION = 1e6;           // Price precision (USD, 6 decimals)
    uint256 public constant MAX_PRICE = 1e12 * 1e6;          // Max price: 1 trillion USD (6 decimals)
    uint256 public constant MIN_PRICE = 1e3;                 // Min price: 0.001 USD (6 decimals)

    // ==================== State Variables ====================

    mapping(address => bool) private admins;
    address[] private adminList;

    struct PricedMeta {
        uint256 price;        // USD, 6 decimals
        uint256 lastUpdated;  // block.timestamp when last set/cleared
    }

    // asset => PricedMeta
    mapping(address => PricedMeta) public meta;

    // Indexing for enumeration
    address[] private priceAssets;              // list of assets that have been priced at least once
    mapping(address => bool) private isTracked; // whether asset is already added to priceAssets

    // Total number of successful price updates (including batch and clear)
    uint256 public totalPriceUpdates;

    // ==================== Events ====================

    event PriceUpdated(address indexed asset, uint256 oldPrice, uint256 newPrice);

    event AdminAdded(address indexed account);
    event AdminRemoved(address indexed account);

    event ERC20Rescued(address indexed token, address indexed to, uint256 amount);
    event NativeRescued(address indexed to, uint256 amount);

    // ==================== Errors ====================

    error OnlyAdminOrOwner();
    error InvalidAddress();
    error InvalidAmount();
    error InvalidPrice();
    error PriceNotSet();
    error LengthMismatch();
    error EmptyArray();
    error NativeTransferFailed();

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

    modifier validPrice(uint256 price) {
        if (price < MIN_PRICE || price > MAX_PRICE) revert InvalidPrice();
        _;
    }

    // ==================== Constructor & Views ====================

    constructor() Ownable(msg.sender) {
        _addAdminInternal(msg.sender);
    }

    struct Overview {
        // Basic meta
        string  version;            // contract version
        uint256 pricePrecision;     // PRICE_PRECISION (USD, 6 decimals)
        uint256 minPrice;           // MIN_PRICE
        uint256 maxPrice;           // MAX_PRICE

        // Roles
        address owner;

        // Runtime state
        bool    paused;

        // Stats
        uint256 totalPriceUpdates;  // number of successful updates (set/batch/clear)
        uint256 pricedCount;        // number of assets currently having non-zero price
        uint256 trackedCount;       // total assets ever tracked (priceAssets length)
    }

    function getOverview() external view returns (Overview memory s) {
        s.version         = VERSION;
        s.pricePrecision  = PRICE_PRECISION;
        s.minPrice        = MIN_PRICE;
        s.maxPrice        = MAX_PRICE;

        s.owner           = owner();

        s.paused          = paused();

        s.totalPriceUpdates = totalPriceUpdates;

        // Count currently priced (non-zero) assets
        uint256 count = 0;
        for (uint256 i = 0; i < priceAssets.length; ) {
            if (meta[priceAssets[i]].price != 0) {
                unchecked { ++count; }
            }
            unchecked { ++i; }
        }
        s.pricedCount   = count;
        s.trackedCount  = priceAssets.length;
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

    // ==================== Price Management ====================

    function setPrice(address asset, uint256 price)
    public
    onlyAdminOrOwner
    whenNotPaused
    validAddress(asset)
    validPrice(price)
    {
        uint256 oldPrice = meta[asset].price;

        // Track first-time priced assets (oldPrice == 0 and not tracked yet)
        if (oldPrice == 0 && !isTracked[asset]) {
            isTracked[asset] = true;
            priceAssets.push(asset);
        }

        meta[asset].price = price;
        meta[asset].lastUpdated = block.timestamp;

        unchecked { ++totalPriceUpdates; }
        emit PriceUpdated(asset, oldPrice, price);
    }

    function setPrices(address[] calldata assets, uint256[] calldata prices_)
    external
    onlyAdminOrOwner
    whenNotPaused
    {
        uint256 len = assets.length;
        if (len != prices_.length) revert LengthMismatch();
        if (len == 0) revert EmptyArray();

        for (uint256 i = 0; i < len; ) {
            address a = assets[i];
            uint256 p = prices_[i];

            if (a == address(0)) revert InvalidAddress();
            if (p < MIN_PRICE || p > MAX_PRICE) revert InvalidPrice();

            uint256 oldPrice = meta[a].price;

            if (oldPrice == 0 && !isTracked[a]) {
                isTracked[a] = true;
                priceAssets.push(a);
            }

            meta[a].price = p;
            meta[a].lastUpdated = block.timestamp;

            unchecked { ++totalPriceUpdates; }
            emit PriceUpdated(a, oldPrice, p);

            unchecked { ++i; }
        }
    }

    /**
     * @notice Clears the price of an asset (sets to 0) and updates lastUpdated.
     * @dev Asset remains tracked for historical enumeration but will be filtered out by views that require non-zero price.
     */
    function clearPrice(address asset)
    external
    onlyAdminOrOwner
    whenNotPaused
    validAddress(asset)
    {
        uint256 oldPrice = meta[asset].price;
        if (oldPrice == 0) revert PriceNotSet(); // nothing to clear

        meta[asset].price = 0;
        meta[asset].lastUpdated = block.timestamp;

        unchecked { ++totalPriceUpdates; }
        emit PriceUpdated(asset, oldPrice, 0);
    }

    // ==================== Views ====================

    function getPrice(address asset) external view returns (uint256) {
        uint256 price = meta[asset].price;
        if (price == 0) revert PriceNotSet();
        return price;
    }

    function getLastUpdated(address asset) external view returns (uint256) {
        uint256 ts = meta[asset].lastUpdated;
        if (meta[asset].price == 0) revert PriceNotSet(); // consistent with getPrice requirement
        return ts;
    }

    function getAllPricedAssets() external view returns (address[] memory) {
        // Count assets with non-zero price
        uint256 count = 0;
        for (uint256 i = 0; i < priceAssets.length; ) {
            if (meta[priceAssets[i]].price != 0) {
                unchecked { ++count; }
            }
            unchecked { ++i; }
        }

        // Collect
        address[] memory result = new address[](count);
        uint256 idx = 0;
        for (uint256 i = 0; i < priceAssets.length; ) {
            address a = priceAssets[i];
            if (meta[a].price != 0) {
                result[idx] = a;
                unchecked { ++idx; }
            }
            unchecked { ++i; }
        }
        return result;
    }

    struct PricedAsset {
        address asset;
        uint256 price;
        uint256 lastUpdated;
    }

    /**
     * @notice Returns structured list of assets with non-zero price.
     */
    function getAllPrices() external view returns (PricedAsset[] memory list) {
        // Count
        uint256 count = 0;
        for (uint256 i = 0; i < priceAssets.length; ) {
            if (meta[priceAssets[i]].price != 0) {
                unchecked { ++count; }
            }
            unchecked { ++i; }
        }

        // Build
        list = new PricedAsset[](count);
        uint256 idx = 0;
        for (uint256 i = 0; i < priceAssets.length; ) {
            address a = priceAssets[i];
            PricedMeta memory m = meta[a];
            if (m.price != 0) {
                list[idx] = PricedAsset({
                    asset: a,
                    price: m.price,
                    lastUpdated: m.lastUpdated
                });
                unchecked { ++idx; }
            }
            unchecked { ++i; }
        }
    }

    function getPricedCount() external view returns (uint256) {
        uint256 count = 0;
        for (uint256 i = 0; i < priceAssets.length; ) {
            if (meta[priceAssets[i]].price != 0) {
                unchecked { ++count; }
            }
            unchecked { ++i; }
        }
        return count;
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
}