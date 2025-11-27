// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {IERC20} from "@openzeppelin/contracts@5.4.0/token/ERC20/IERC20.sol";
import {Ownable} from "@openzeppelin/contracts@5.4.0/access/Ownable.sol";
import {Pausable} from "@openzeppelin/contracts@5.4.0/utils/Pausable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts@5.4.0/utils/ReentrancyGuard.sol";
import {SafeERC20} from "@openzeppelin/contracts@5.4.0/token/ERC20/utils/SafeERC20.sol";

interface IGFToken is IERC20 {
    function mint(address to, uint256 amount) external;
}

/**
 * @title GFDistributor
 * @dev GF token distribution and vesting manager + Lock Pool.
 * @notice Amounts use 6 decimals. This contract must be an authorized minter in GFToken (for mint paths).
 *         Lock pool uses ERC20 transfers from category allocation wallets (requires allowance).
 */
contract GFDistributor is Ownable, ReentrancyGuard, Pausable {

    using SafeERC20 for IERC20;
    using SafeERC20 for IGFToken;

    // ==================== Constants ====================

    string public constant VERSION = "1.0.3";

    // Reference total supply (for documentation, actual cap enforced by GFToken)
    uint256 public constant TOTAL_SUPPLY = 100_000_000_000 * 1e6; // 100B

    // Global category allocation percentages (basis points)
    // 20% is used by GFStaking
    uint256 public constant TEAM_ALLOCATION_BPS       = 2600; // 26%
    uint256 public constant PRIVATE_ALLOCATION_BPS    = 400;  // 4%
    uint256 public constant PUBLIC_ALLOCATION_BPS     = 1000; // 10%
    uint256 public constant COMMUNITY_ALLOCATION_BPS  = 1000; // 10%
    uint256 public constant ECOSYSTEM_ALLOCATION_BPS  = 2000; // 20%
    uint256 public constant RESERVE_ALLOCATION_BPS    = 500;  // 5%
    uint256 public constant LIQUIDITY_ALLOCATION_BPS  = 500;  // 5%

    // Global initial unlock percentages (basis points)
    uint256 public constant TEAM_INITIAL_BPS       = 0;    // 0%
    uint256 public constant PRIVATE_INITIAL_BPS    = 0;    // 0%
    uint256 public constant PUBLIC_INITIAL_BPS     = 500;  // 5%
    uint256 public constant COMMUNITY_INITIAL_BPS  = 750;  // 7.5%
    uint256 public constant ECOSYSTEM_INITIAL_BPS  = 500;  // 5%
    uint256 public constant RESERVE_INITIAL_BPS    = 0;    // 0%
    uint256 public constant LIQUIDITY_INITIAL_BPS  = 500;  // 5%

    // Category total allocations (compile-time constants)
    uint256 public constant TEAM_TOTAL_ALLOCATION       = (TOTAL_SUPPLY * TEAM_ALLOCATION_BPS) / 10000;
    uint256 public constant PRIVATE_TOTAL_ALLOCATION    = (TOTAL_SUPPLY * PRIVATE_ALLOCATION_BPS) / 10000;
    uint256 public constant PUBLIC_TOTAL_ALLOCATION     = (TOTAL_SUPPLY * PUBLIC_ALLOCATION_BPS) / 10000;
    uint256 public constant COMMUNITY_TOTAL_ALLOCATION  = (TOTAL_SUPPLY * COMMUNITY_ALLOCATION_BPS) / 10000;
    uint256 public constant ECOSYSTEM_TOTAL_ALLOCATION  = (TOTAL_SUPPLY * ECOSYSTEM_ALLOCATION_BPS) / 10000;
    uint256 public constant RESERVE_TOTAL_ALLOCATION    = (TOTAL_SUPPLY * RESERVE_ALLOCATION_BPS) / 10000;
    uint256 public constant LIQUIDITY_TOTAL_ALLOCATION  = (TOTAL_SUPPLY * LIQUIDITY_ALLOCATION_BPS) / 10000;

    // Initial unlock amounts (compile-time constants)
    uint256 public constant TEAM_INITIAL_UNLOCK       = (TOTAL_SUPPLY * TEAM_INITIAL_BPS) / 10000;
    uint256 public constant PRIVATE_INITIAL_UNLOCK    = (TOTAL_SUPPLY * PRIVATE_INITIAL_BPS) / 10000;
    uint256 public constant PUBLIC_INITIAL_UNLOCK     = (TOTAL_SUPPLY * PUBLIC_INITIAL_BPS) / 10000;
    uint256 public constant COMMUNITY_INITIAL_UNLOCK  = (TOTAL_SUPPLY * COMMUNITY_INITIAL_BPS) / 10000;
    uint256 public constant ECOSYSTEM_INITIAL_UNLOCK  = (TOTAL_SUPPLY * ECOSYSTEM_INITIAL_BPS) / 10000;
    uint256 public constant RESERVE_INITIAL_UNLOCK    = (TOTAL_SUPPLY * RESERVE_INITIAL_BPS) / 10000;
    uint256 public constant LIQUIDITY_INITIAL_UNLOCK  = (TOTAL_SUPPLY * LIQUIDITY_INITIAL_BPS) / 10000;

    uint256 public constant TOTAL_INITIAL_UNLOCK =
    TEAM_INITIAL_UNLOCK +
    PRIVATE_INITIAL_UNLOCK +
    PUBLIC_INITIAL_UNLOCK +
    COMMUNITY_INITIAL_UNLOCK +
    ECOSYSTEM_INITIAL_UNLOCK +
    RESERVE_INITIAL_UNLOCK +
    LIQUIDITY_INITIAL_UNLOCK;

    // Vesting parameters per category

    // TEAM: 1y cliff + 9y linear
    uint256 public constant TEAM_DURATION = 9 * 365 days;
    uint256 public constant TEAM_CLIFF    = 365 days;

    // PRIVATE: 1y cliff + 4y linear (1% per year) -> total 4 years linear after cliff
    uint256 public constant PRIVATE_DURATION = 4 * 365 days;
    uint256 public constant PRIVATE_CLIFF    = 365 days;

    // PUBLIC: 190 days cliff, instant unlock at cliff (TGE 5% is initial; this path can be used if needed)
    uint256 public constant PUBLIC_DURATION = 1 days;  // ignored
    uint256 public constant PUBLIC_CLIFF    = 190 days;

    // COMMUNITY: TGE 7.5%, then 10y linear
    uint256 public constant COMMUNITY_DURATION = 10 * 365 days;
    uint256 public constant COMMUNITY_CLIFF    = 0;

    // ECOSYSTEM: TGE 5%, then 10y linear
    uint256 public constant ECOSYSTEM_DURATION = 10 * 365 days; // 10y linear
    uint256 public constant ECOSYSTEM_CLIFF    = 0;

    // RESERVE: 5y cliff, instant unlock after cliff
    uint256 public constant RESERVE_DURATION = 1 days;  // ignored
    uint256 public constant RESERVE_CLIFF    = 5 * 365 days;

    // LIQUIDITY: TGE 5% immediate (no cliff). Vesting path is cliff=0, instant; but we keep ignored duration.
    uint256 public constant LIQUIDITY_DURATION = 1 days; // ignored
    uint256 public constant LIQUIDITY_CLIFF    = 0;

    // Reason codes
    uint8 public constant REASON_INITIAL_UNLOCK   = 1;
    uint8 public constant REASON_VESTING_RELEASE  = 2;
    uint8 public constant REASON_BATCH            = 4;
    uint8 public constant REASON_CUSTOM           = 5;

    // ==================== State ====================

    IGFToken public immutable gfToken;

    mapping(address => bool) private admins;
    address[] private adminList;

    bool public initialDistributionExecuted;

    enum Category { TEAM, PRIVATE, PUBLIC, COMMUNITY, ECOSYSTEM, RESERVE, LIQUIDITY }

    mapping(Category => address) public allocationAddress;
    mapping(Category => uint256) public initialAllocated;     // minted at TGE
    mapping(Category => uint256) public totalCategoryMinted;  // all minted amounts for category

    struct VestingSchedule {
        address beneficiary;
        uint256 totalAmount;
        uint256 releasedAmount;
        uint256 startTime;
        Category category;
        bool revoked;
    }

    struct UserLockSummary {
        uint256 totalCount;
        uint256 activeCount;
        uint256 maturedCount;
        uint256 releasedCount;
        uint256 totalAmount;
        uint256 activeAmount;
        uint256 maturedAmount;
        uint256 releasedAmount;
    }

    mapping(uint256 => VestingSchedule) public vestingSchedules;
    mapping(address => uint256[]) public userVestingIds;
    uint256 public nextVestingId = 1;

    uint256 public totalVestingAllocated;
    uint256 public totalVestingReleased;

    // ==================== Lock Pool ====================

    struct LockRecord {
        address user;
        Category category;
        uint256 amount;        // locked amount
        uint256 startTime;     // lock start timestamp
        uint256 lockDuration;  // lock duration in seconds
        bool    released;      // marked after user/admin withdrawal
    }

    uint256 public nextLockId = 1;
    mapping(uint256 => LockRecord) public locks;
    mapping(address => uint256[]) public userLockIds;
    uint256 public totalLocked;       // sum of active (not released) locks
    uint256 public totalLockReleased; // cumulative amount released from locks

    // ==================== Events ====================

    event InitialDistributionExecuted(uint256 totalAmount);
    event AllocationAddressSet(Category indexed category, address indexed oldAddress, address indexed newAddress);
    event VestingCreated(uint256 indexed vestingId, address indexed beneficiary, uint256 amount, Category category, uint256 startTime);
    event TokensReleased(uint256 indexed vestingId, address indexed beneficiary, uint256 amount, uint256 totalReleased);

    event TokensDistributed(address indexed recipient, uint256 amount, Category indexed category, uint8 indexed reasonCode);

    event AdminAdded(address indexed account);
    event AdminRemoved(address indexed account);

    event ERC20Rescued(address indexed token, address indexed to, uint256 amount);
    event NativeRescued(address indexed to, uint256 amount);

    // Lock pool events
    event Locked(uint256 indexed lockId, address indexed user, Category indexed category, uint256 amount, uint256 startTime, uint256 duration);
    event LockWithdrawn(uint256 indexed lockId, address indexed user, uint256 amount, bool byAdmin);
    event LockCancelled(uint256 indexed lockId, address indexed to, uint256 amount, address cancelledBy);

    // ==================== Errors ====================

    error OnlyAdminOrOwner();
    error InvalidAddress();
    error InvalidAmount();
    error InvalidVestingId();
    error InvalidLockId();
    error VestingAlreadyRevoked();
    error NotAuthorized();
    error NoTokensToRelease();
    error AlreadyRevoked();
    error LengthMismatch();
    error EmptyArrays();
    error InvalidCategory();
    error InitialDistributionAlreadyExecuted();
    error CategoryCapExceeded(uint8 category);
    error NativeTransferFailed();
    error LockNotMatured();
    error LockAlreadyReleased();

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

    modifier validVestingId(uint256 vestingId) {
        if (vestingSchedules[vestingId].beneficiary == address(0)) revert InvalidVestingId();
        _;
    }

    modifier validLockId(uint256 lockId) {
        if (locks[lockId].user == address(0)) revert InvalidLockId();
        _;
    }

    // ==================== Constructor & Views ====================

    constructor(address _gfToken) Ownable(msg.sender) {
        if (_gfToken == address(0)) revert InvalidAddress();
        gfToken = IGFToken(_gfToken);

        _addAdminInternal(msg.sender);
    }

    struct Overview {
        // Version & constants
        string  version;
        uint256 totalSupplyRef;
        uint256 maxInitialUnlock;

        // Roles
        address owner;

        // Switches
        bool paused;

        // Allocation wallets
        address teamAddress;
        address privateAddress;
        address publicAddress;
        address communityAddress;
        address ecosystemAddress;
        address reserveAddress;
        address liquidityAddress;

        // Flags
        bool initialDistributionExecuted;

        // Totals
        uint256 totalVestingAllocated;
        uint256 totalVestingReleased;

        // Category minted so far
        uint256 teamMinted;
        uint256 privateMinted;
        uint256 publicMinted;
        uint256 communityMinted;
        uint256 ecosystemMinted;
        uint256 reserveMinted;
        uint256 liquidityMinted;

        // Vesting meta
        uint256 nextVestingId;

        // Lock pool meta
        uint256 nextLockId;
        uint256 totalLocked;
        uint256 totalLockReleased;
    }

    function getOverview() external view returns (Overview memory s) {
        s.version            = VERSION;
        s.totalSupplyRef     = TOTAL_SUPPLY;
        s.maxInitialUnlock   = TOTAL_INITIAL_UNLOCK;

        s.owner  = owner();
        s.paused = paused();

        s.teamAddress      = allocationAddress[Category.TEAM];
        s.privateAddress   = allocationAddress[Category.PRIVATE];
        s.publicAddress    = allocationAddress[Category.PUBLIC];
        s.communityAddress = allocationAddress[Category.COMMUNITY];
        s.ecosystemAddress = allocationAddress[Category.ECOSYSTEM];
        s.reserveAddress   = allocationAddress[Category.RESERVE];
        s.liquidityAddress = allocationAddress[Category.LIQUIDITY];

        s.initialDistributionExecuted = initialDistributionExecuted;

        s.totalVestingAllocated   = totalVestingAllocated;
        s.totalVestingReleased    = totalVestingReleased;

        s.teamMinted      = totalCategoryMinted[Category.TEAM];
        s.privateMinted   = totalCategoryMinted[Category.PRIVATE];
        s.publicMinted    = totalCategoryMinted[Category.PUBLIC];
        s.communityMinted = totalCategoryMinted[Category.COMMUNITY];
        s.ecosystemMinted = totalCategoryMinted[Category.ECOSYSTEM];
        s.reserveMinted   = totalCategoryMinted[Category.RESERVE];
        s.liquidityMinted = totalCategoryMinted[Category.LIQUIDITY];

        s.nextVestingId = nextVestingId;

        s.nextLockId = nextLockId;
        s.totalLocked = totalLocked;
        s.totalLockReleased = totalLockReleased;
    }

    // ==================== Roles ====================

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

    // ==================== Allocation Management ====================

    function setAllocationAddresses(
        address teamAddress,
        address privateAddress,
        address publicAddress,
        address communityAddress,
        address ecosystemAddress,
        address reserveAddress,
        address liquidityAddress
    ) external onlyAdminOrOwner {
        _setAllocationAddress(Category.TEAM, teamAddress);
        _setAllocationAddress(Category.PRIVATE, privateAddress);
        _setAllocationAddress(Category.PUBLIC, publicAddress);
        _setAllocationAddress(Category.COMMUNITY, communityAddress);
        _setAllocationAddress(Category.ECOSYSTEM, ecosystemAddress);
        _setAllocationAddress(Category.RESERVE, reserveAddress);
        _setAllocationAddress(Category.LIQUIDITY, liquidityAddress);
    }

    function setAllocationAddress(Category category, address addr) external onlyAdminOrOwner {
        _setAllocationAddress(category, addr);
    }

    function _setAllocationAddress(Category category, address addr) internal validAddress(addr) {
        address old = allocationAddress[category];
        if (old == addr) return;
        allocationAddress[category] = addr;
        emit AllocationAddressSet(category, old, addr);
    }

    // ==================== Caps ====================

    function _capOf(Category c) internal pure returns (uint256) {
        if (c == Category.TEAM) return TEAM_TOTAL_ALLOCATION;
        if (c == Category.PRIVATE) return PRIVATE_TOTAL_ALLOCATION;
        if (c == Category.PUBLIC) return PUBLIC_TOTAL_ALLOCATION;
        if (c == Category.COMMUNITY) return COMMUNITY_TOTAL_ALLOCATION;
        if (c == Category.ECOSYSTEM) return ECOSYSTEM_TOTAL_ALLOCATION;
        if (c == Category.RESERVE) return RESERVE_TOTAL_ALLOCATION;
        if (c == Category.LIQUIDITY) return LIQUIDITY_TOTAL_ALLOCATION;
        return 0;
    }

    function _checkCategoryCap(Category c, uint256 toMint) internal view {
        uint256 cap = _capOf(c);
        if (cap > 0 && totalCategoryMinted[c] + toMint > cap) {
            revert CategoryCapExceeded(uint8(c));
        }
    }

    // ==================== Initial Distribution (mint) ====================

    function executeInitialDistribution() external onlyAdminOrOwner nonReentrant {
        if (initialDistributionExecuted) revert InitialDistributionAlreadyExecuted();

        if (PRIVATE_INITIAL_UNLOCK > 0 && allocationAddress[Category.PRIVATE] == address(0)) revert InvalidAddress();
        if (PUBLIC_INITIAL_UNLOCK > 0 && allocationAddress[Category.PUBLIC] == address(0)) revert InvalidAddress();
        if (COMMUNITY_INITIAL_UNLOCK > 0 && allocationAddress[Category.COMMUNITY] == address(0)) revert InvalidAddress();
        if (ECOSYSTEM_INITIAL_UNLOCK > 0 && allocationAddress[Category.ECOSYSTEM] == address(0)) revert InvalidAddress();
        if (LIQUIDITY_INITIAL_UNLOCK > 0 && allocationAddress[Category.LIQUIDITY] == address(0)) revert InvalidAddress();

        _distributeInitial(Category.TEAM, TEAM_INITIAL_UNLOCK);
        _distributeInitial(Category.PRIVATE, PRIVATE_INITIAL_UNLOCK);
        _distributeInitial(Category.PUBLIC, PUBLIC_INITIAL_UNLOCK);
        _distributeInitial(Category.COMMUNITY, COMMUNITY_INITIAL_UNLOCK);
        _distributeInitial(Category.ECOSYSTEM, ECOSYSTEM_INITIAL_UNLOCK);
        _distributeInitial(Category.RESERVE, RESERVE_INITIAL_UNLOCK);
        _distributeInitial(Category.LIQUIDITY, LIQUIDITY_INITIAL_UNLOCK);

        initialDistributionExecuted = true;
        emit InitialDistributionExecuted(TOTAL_INITIAL_UNLOCK);
    }

    function _distributeInitial(Category category, uint256 amount) internal {
        address recipient = allocationAddress[category];
        if (recipient != address(0) && amount > 0) {
            _checkCategoryCap(category, amount);
            gfToken.mint(recipient, amount);
            initialAllocated[category] = amount;
            totalCategoryMinted[category] += amount;
            emit TokensDistributed(recipient, amount, category, REASON_INITIAL_UNLOCK);
        }
    }

    // ==================== Vesting (mint) ====================

    function createVestingSchedule(
        address beneficiary,
        uint256 amount,
        Category category,
        uint256 startTime
    ) external onlyAdminOrOwner whenNotPaused validAddress(beneficiary) validAmount(amount) returns (uint256) {
        uint256 vestingId = nextVestingId++;
        vestingSchedules[vestingId] = VestingSchedule({
            beneficiary: beneficiary,
            totalAmount: amount,
            releasedAmount: 0,
            startTime: startTime,
            category: category,
            revoked: false
        });

        userVestingIds[beneficiary].push(vestingId);
        totalVestingAllocated += amount;

        emit VestingCreated(vestingId, beneficiary, amount, category, startTime);
        return vestingId;
    }

    function releaseVestedTokens(uint256 vestingId) public nonReentrant whenNotPaused validVestingId(vestingId) {
        VestingSchedule storage s = vestingSchedules[vestingId];
        if (s.revoked) revert VestingAlreadyRevoked();

        if (msg.sender != s.beneficiary && msg.sender != owner() && !admins[msg.sender]) {
            revert NotAuthorized();
        }

        uint256 releasable = _calculateReleasableAmount(s);
        if (releasable == 0) revert NoTokensToRelease();

        _checkCategoryCap(s.category, releasable);
        s.releasedAmount += releasable;
        totalVestingReleased += releasable;
        totalCategoryMinted[s.category] += releasable;

        gfToken.mint(s.beneficiary, releasable);
        emit TokensReleased(vestingId, s.beneficiary, releasable, s.releasedAmount);
    }

    function releaseAllVestedTokens(address beneficiary) external nonReentrant whenNotPaused validAddress(beneficiary) {
        uint256[] memory ids = userVestingIds[beneficiary];
        for (uint256 i = 0; i < ids.length; ) {
            uint256 id = ids[i];
            VestingSchedule storage s = vestingSchedules[id];
            if (!s.revoked) {
                if (msg.sender == beneficiary || msg.sender == owner() || admins[msg.sender]) {
                    uint256 releasable = _calculateReleasableAmount(s);
                    if (releasable > 0) {
                        _checkCategoryCap(s.category, releasable);
                        s.releasedAmount += releasable;
                        totalVestingReleased += releasable;
                        totalCategoryMinted[s.category] += releasable;

                        gfToken.mint(s.beneficiary, releasable);
                        emit TokensReleased(id, s.beneficiary, releasable, s.releasedAmount);
                    }
                }
            }
            unchecked { ++i; }
        }
    }

    function releaseVestedTokensBatch(uint256[] calldata vestingIds) external nonReentrant whenNotPaused {
        for (uint256 i = 0; i < vestingIds.length; ) {
            uint256 id = vestingIds[i];
            VestingSchedule storage s = vestingSchedules[id];
            if (s.beneficiary != address(0) && !s.revoked) {
                if (msg.sender == s.beneficiary || msg.sender == owner() || admins[msg.sender]) {
                    uint256 releasable = _calculateReleasableAmount(s);
                    if (releasable > 0) {
                        _checkCategoryCap(s.category, releasable);
                        s.releasedAmount += releasable;
                        totalVestingReleased += releasable;
                        totalCategoryMinted[s.category] += releasable;

                        gfToken.mint(s.beneficiary, releasable);
                        emit TokensReleased(id, s.beneficiary, releasable, s.releasedAmount);
                    }
                }
            }
            unchecked { ++i; }
        }
    }

    function revokeVesting(uint256 vestingId) external onlyAdminOrOwner validVestingId(vestingId) {
        VestingSchedule storage s = vestingSchedules[vestingId];
        if (s.revoked) revert AlreadyRevoked();
        uint256 revokedAmount = s.totalAmount - s.releasedAmount;
        s.revoked = true;
        totalVestingAllocated -= revokedAmount;
        emit TokensReleased(vestingId, s.beneficiary, 0, s.releasedAmount);
    }

    function _calculateReleasableAmount(VestingSchedule memory s) internal view returns (uint256) {
        (uint256 duration, uint256 cliff) = _getVestingConfig(s.category);
        if (block.timestamp < s.startTime + cliff) return 0;

        // Cliff-only categories: instant unlock at/after cliff
        if (s.category == Category.PUBLIC || s.category == Category.RESERVE || s.category == Category.LIQUIDITY) {
            return s.totalAmount - s.releasedAmount;
        }

        uint256 elapsed = block.timestamp - s.startTime;
        if (elapsed >= duration) {
            return s.totalAmount - s.releasedAmount;
        }

        uint256 vested = (s.totalAmount * elapsed) / duration;
        return vested > s.releasedAmount ? (vested - s.releasedAmount) : 0;
    }

    function _getVestingConfig(Category c) internal pure returns (uint256 duration, uint256 cliff) {
        if (c == Category.TEAM) return (TEAM_DURATION, TEAM_CLIFF);
        if (c == Category.PRIVATE) return (PRIVATE_DURATION, PRIVATE_CLIFF);
        if (c == Category.PUBLIC) return (PUBLIC_DURATION, PUBLIC_CLIFF);
        if (c == Category.COMMUNITY) return (COMMUNITY_DURATION, COMMUNITY_CLIFF);
        if (c == Category.ECOSYSTEM) return (ECOSYSTEM_DURATION, ECOSYSTEM_CLIFF);
        if (c == Category.RESERVE) return (RESERVE_DURATION, RESERVE_CLIFF);
        if (c == Category.LIQUIDITY) return (LIQUIDITY_DURATION, LIQUIDITY_CLIFF);
        revert InvalidCategory();
    }

    // ==================== Distributions (mint) ====================

    function customDistribution(address recipient, uint256 amount, Category category)
    external
    onlyAdminOrOwner
    nonReentrant
    whenNotPaused
    validAddress(recipient)
    validAmount(amount)
    {
        _checkCategoryCap(category, amount);
        gfToken.mint(recipient, amount);
        totalCategoryMinted[category] += amount;
        emit TokensDistributed(recipient, amount, category, REASON_CUSTOM);
    }

    function batchDistribution(address[] calldata recipients, uint256[] calldata amounts, Category category)
    external
    onlyAdminOrOwner
    nonReentrant
    whenNotPaused
    {
        if (recipients.length != amounts.length) revert LengthMismatch();
        if (recipients.length == 0) revert EmptyArrays();

        for (uint256 i = 0; i < recipients.length; ) {
            address r = recipients[i];
            uint256 a = amounts[i];
            if (r == address(0)) revert InvalidAddress();
            if (a == 0) revert InvalidAmount();

            _checkCategoryCap(category, a);
            gfToken.mint(r, a);
            totalCategoryMinted[category] += a;
            emit TokensDistributed(r, a, category, REASON_BATCH);

            unchecked { ++i; }
        }
    }

    // ==================== Lock Pool (transfer from allocation wallets) ====================

    /**
     * @notice Allocate budget from a category wallet and lock it for a user.
     *         Pulls tokens via transferFrom from allocationAddress[category] (requires allowance).
     *         Lock startTime is set to the current block timestamp.
     * @param user The beneficiary entitled to withdraw after maturity
     * @param category Source category; tokens are pulled from allocationAddress[category]
     * @param amount Lock amount
     * @param lockDuration Lock duration in seconds
     * @return lockId Newly created lock id
     */
    function allocateAndLockForUser(
        address user,
        Category category,
        uint256 amount,
        uint256 lockDuration
    ) external onlyAdminOrOwner nonReentrant whenNotPaused validAddress(user) validAmount(amount) returns (uint256 lockId) {
        address src = allocationAddress[category];
        if (src == address(0)) revert InvalidAddress();

        // Pull tokens into contract custody (requires allowance by the category wallet)
        gfToken.safeTransferFrom(src, address(this), amount);

        uint256 start = block.timestamp;

        lockId = nextLockId++;
        locks[lockId] = LockRecord({
            user: user,
            category: category,
            amount: amount,
            startTime: start,
            lockDuration: lockDuration,
            released: false
        });
        userLockIds[user].push(lockId);

        totalLocked += amount;
        emit Locked(lockId, user, category, amount, start, lockDuration);
    }

    /**
     * @notice User withdraws their matured lock (self-service).
     */
    function withdrawLock(uint256 lockId) external nonReentrant whenNotPaused validLockId(lockId) {
        LockRecord storage l = locks[lockId];
        if (l.released) revert LockAlreadyReleased();
        if (msg.sender != l.user) revert NotAuthorized();

        if (!_isMatured(l)) revert LockNotMatured();

        l.released = true;
        totalLocked -= l.amount;
        totalLockReleased += l.amount;

        gfToken.safeTransfer(l.user, l.amount);
        emit LockWithdrawn(lockId, l.user, l.amount, false);
    }

    /**
     * @notice Admin releases a lock to the user (optionally before maturity if policy allows).
     */
    function adminReleaseLock(uint256 lockId) external onlyAdminOrOwner nonReentrant validLockId(lockId) {
        LockRecord storage l = locks[lockId];
        if (l.released) revert LockAlreadyReleased();

        // Optional: enforce maturity if desired
        // if (!_isMatured(l)) revert LockNotMatured();

        l.released = true;
        totalLocked -= l.amount;
        totalLockReleased += l.amount;

        gfToken.safeTransfer(l.user, l.amount);
        emit LockWithdrawn(lockId, l.user, l.amount, true);
    }

    /**
     * @notice Admin cancels a lock and returns funds back to the category allocation address.
     */
    function adminCancelLock(uint256 lockId) external onlyAdminOrOwner nonReentrant validLockId(lockId) {
        LockRecord storage l = locks[lockId];
        if (l.released) revert LockAlreadyReleased();

        address to = allocationAddress[l.category];
        if (to == address(0)) revert InvalidAddress();

        uint256 amt = l.amount;
        l.released = true;
        totalLocked -= amt;
        totalLockReleased += amt;

        gfToken.safeTransfer(to, amt);
        emit LockCancelled(lockId, to, amt, msg.sender);
    }

    function _isMatured(LockRecord memory l) internal view returns (bool) {
        return block.timestamp >= l.startTime + l.lockDuration;
    }

    // ======== Lock Pool Views ========

    function getUserLocks(address user) external view returns (uint256[] memory) {
        return userLockIds[user];
    }

    function getLock(uint256 lockId) external view validLockId(lockId) returns (
        address user,
        Category category,
        uint256 amount,
        uint256 startTime,
        uint256 lockDuration,
        bool released
    ) {
        LockRecord memory l = locks[lockId];
        return (l.user, l.category, l.amount, l.startTime, l.lockDuration, l.released);
    }

    function getUserLockSummary(address user) external view returns (UserLockSummary memory s) {
        uint256[] memory ids = userLockIds[user];
        s.totalCount = ids.length;

        for (uint256 i = 0; i < ids.length; ) {
            LockRecord memory l = locks[ids[i]];
            s.totalAmount += l.amount;

            if (l.released) {
                s.releasedCount += 1;
                s.releasedAmount += l.amount;
            } else {
                bool matured = block.timestamp >= l.startTime + l.lockDuration;
                if (matured) {
                    s.maturedCount += 1;
                    s.maturedAmount += l.amount;
                } else {
                    s.activeCount += 1;
                    s.activeAmount += l.amount;
                }
            }

            unchecked { ++i; }
        }
    }

    // ==================== Views ====================

    function getAllocationAddresses() external view returns (
        address teamAddress,
        address privateAddress,
        address publicAddress,
        address communityAddress,
        address ecosystemAddress,
        address reserveAddress,
        address liquidityAddress
    ) {
        return (
            allocationAddress[Category.TEAM],
            allocationAddress[Category.PRIVATE],
            allocationAddress[Category.PUBLIC],
            allocationAddress[Category.COMMUNITY],
            allocationAddress[Category.ECOSYSTEM],
            allocationAddress[Category.RESERVE],
            allocationAddress[Category.LIQUIDITY]
        );
    }

    function getPoolAllocations() external pure returns (
        uint256 teamTotal,
        uint256 privateTotal,
        uint256 publicTotal,
        uint256 communityTotal,
        uint256 ecosystemTotal,
        uint256 reserveTotal,
        uint256 liquidityTotal
    ) {
        return (
            TEAM_TOTAL_ALLOCATION,
            PRIVATE_TOTAL_ALLOCATION,
            PUBLIC_TOTAL_ALLOCATION,
            COMMUNITY_TOTAL_ALLOCATION,
            ECOSYSTEM_TOTAL_ALLOCATION,
            RESERVE_TOTAL_ALLOCATION,
            LIQUIDITY_TOTAL_ALLOCATION
        );
    }

    function getInitialUnlockAmounts() external pure returns (
        uint256 teamInitial,
        uint256 privateInitial,
        uint256 publicInitial,
        uint256 communityInitial,
        uint256 ecosystemInitial,
        uint256 reserveInitial,
        uint256 liquidityInitial,
        uint256 totalInitial
    ) {
        return (
            TEAM_INITIAL_UNLOCK,
            PRIVATE_INITIAL_UNLOCK,
            PUBLIC_INITIAL_UNLOCK,
            COMMUNITY_INITIAL_UNLOCK,
            ECOSYSTEM_INITIAL_UNLOCK,
            RESERVE_INITIAL_UNLOCK,
            LIQUIDITY_INITIAL_UNLOCK,
            TOTAL_INITIAL_UNLOCK
        );
    }

    function getInitialAllocationInfo() external view returns (
        bool executed,
        uint256 teamInitialAmount,
        uint256 privateInitialAmount,
        uint256 publicInitialAmount,
        uint256 communityInitialAmount,
        uint256 ecosystemInitialAmount,
        uint256 reserveInitialAmount,
        uint256 liquidityInitialAmount,
        uint256 totalInitialMinted
    ) {
        uint256 totalInit = initialAllocated[Category.TEAM]
            + initialAllocated[Category.PRIVATE]
            + initialAllocated[Category.PUBLIC]
            + initialAllocated[Category.COMMUNITY]
            + initialAllocated[Category.ECOSYSTEM]
            + initialAllocated[Category.RESERVE]
            + initialAllocated[Category.LIQUIDITY];

        return (
            initialDistributionExecuted,
            initialAllocated[Category.TEAM],
            initialAllocated[Category.PRIVATE],
            initialAllocated[Category.PUBLIC],
            initialAllocated[Category.COMMUNITY],
            initialAllocated[Category.ECOSYSTEM],
            initialAllocated[Category.RESERVE],
            initialAllocated[Category.LIQUIDITY],
            totalInit
        );
    }

    function getVestingSchedule(uint256 vestingId) external view validVestingId(vestingId) returns (
        address beneficiary,
        uint256 totalAmount,
        uint256 releasedAmount,
        uint256 startTime,
        Category category,
        bool revoked
    ) {
        VestingSchedule memory s = vestingSchedules[vestingId];
        return (s.beneficiary, s.totalAmount, s.releasedAmount, s.startTime, s.category, s.revoked);
    }

    function getUserVestingSchedules(address beneficiary) external view returns (uint256[] memory) {
        return userVestingIds[beneficiary];
    }

    function getUserVestingSummary(address beneficiary) external view returns (
        uint256 totalAllocatedAmount,
        uint256 totalReleasedAmount,
        uint256 totalReleasableAmount,
        uint256 vestingCount
    ) {
        uint256[] memory ids = userVestingIds[beneficiary];
        vestingCount = ids.length;

        for (uint256 i = 0; i < ids.length; ) {
            VestingSchedule memory s = vestingSchedules[ids[i]];
            if (!s.revoked) {
                totalAllocatedAmount += s.totalAmount;
                totalReleasedAmount += s.releasedAmount;
                totalReleasableAmount += _calculateReleasableAmount(s);
            }
            unchecked { ++i; }
        }
    }

    function getReleasableAmount(uint256 vestingId) external view validVestingId(vestingId) returns (uint256) {
        VestingSchedule memory s = vestingSchedules[vestingId];
        if (s.revoked) return 0;
        return _calculateReleasableAmount(s);
    }

    function getVestingStats() external view returns (
        uint256 _totalAllocated,
        uint256 _totalReleased,
        uint256 _totalPending,
        uint256 _scheduleCount
    ) {
        return (
            totalVestingAllocated,
            totalVestingReleased,
            totalVestingAllocated - totalVestingReleased,
            nextVestingId - 1
        );
    }

    function getCategoryMinted() external view returns (
        uint256 teamMinted,
        uint256 privateMinted,
        uint256 publicMinted,
        uint256 communityMinted,
        uint256 ecosystemMinted,
        uint256 reserveMinted,
        uint256 liquidityMinted
    ) {
        return (
            totalCategoryMinted[Category.TEAM],
            totalCategoryMinted[Category.PRIVATE],
            totalCategoryMinted[Category.PUBLIC],
            totalCategoryMinted[Category.COMMUNITY],
            totalCategoryMinted[Category.ECOSYSTEM],
            totalCategoryMinted[Category.RESERVE],
            totalCategoryMinted[Category.LIQUIDITY]
        );
    }

    function getNextVestingId() external view returns (uint256) {
        return nextVestingId;
    }

    function getNextLockId() external view returns (uint256) {
        return nextLockId;
    }

    // ==================== Emergency ====================

    function pause() external onlyAdminOrOwner { _pause(); }

    function unpause() external onlyOwner { _unpause(); }

    /**
     * @dev Rescue tokens accidentally sent to this contract. GF token is blocked to protect locked funds.
     */
    function rescueERC20(address token, address to, uint256 amount) external onlyOwner validAddress(token) validAddress(to) validAmount(amount) {
        if (token == address(gfToken)) revert NotAuthorized();
        IERC20(token).safeTransfer(to, amount);
        emit ERC20Rescued(token, to, amount);
    }

    function rescueNative(address to, uint256 amount) external onlyOwner validAddress(to) validAmount(amount) {
        (bool ok, ) = to.call{value: amount}("");
        if (!ok) revert NativeTransferFailed();
        emit NativeRescued(to, amount);
    }
}
