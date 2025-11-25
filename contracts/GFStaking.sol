// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {IERC20} from "@openzeppelin/contracts@5.4.0/token/ERC20/IERC20.sol";
import {Ownable} from "@openzeppelin/contracts@5.4.0/access/Ownable.sol";
import {Pausable} from "@openzeppelin/contracts@5.4.0/utils/Pausable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts@5.4.0/utils/ReentrancyGuard.sol";
import {SafeERC20} from "@openzeppelin/contracts@5.4.0/token/ERC20/utils/SafeERC20.sol";

/**
 * @dev Minimal EIP-2612 permit interface (OpenZeppelin ERC20Permit-compatible).
 */
interface IERC20Permit {
    function permit(
        address owner,
        address spender,
        uint256 value,
        uint256 deadline,
        uint8 v, bytes32 r, bytes32 s
    ) external;
}

/**
 * @dev GF token interface with TOTAL_SUPPLY view and mint capability.
 */
interface IGFToken is IERC20 {
    function TOTAL_SUPPLY() external view returns (uint256);
    function mint(address to, uint256 amount) external;
}

/**
 * @title GFStaking
 * @notice
 * - Two pools: ART / GF.
 * - Terms: Flexible (1.0), 30d (1.8), 90d (3.8).
 * - After maturity, weight STAYS at boosted level until withdrawn.
 * - Multi-position model: each user can hold multiple 30d/90d positions (amount, unlockAt).
 * - Early withdraw for locked (not matured) positions with a configurable penalty (bps) sent to feeRecipient.
 * - Incentives: 10-year linear emission; ART pool 0.5%/year, GF pool 1.5%/year based on INITIAL_GF_SUPPLY.
 * - Private sale: 5% ART immediate transfer, 95% locked for 90 days; optional immediate GF rewards mint.
 */
contract GFStaking is Ownable, ReentrancyGuard, Pausable {

    using SafeERC20 for IERC20;
    using SafeERC20 for IGFToken;

    // ==================== Constants ====================

    string public constant VERSION = "1.1.0";

    uint256 public constant BPS_DENOMINATOR       = 10_000;   // 100%
    uint256 public constant ART_POOL_ANNUAL_BPS   = 50;       // 0.5% of GF total supply per year
    uint256 public constant GF_POOL_ANNUAL_BPS    = 150;      // 1.5% of GF total supply per year
    uint256 public constant INCENTIVE_PERIOD      = 10 * 365 days; // 10 years
    uint256 public constant REWARD_PRECISION      = 1e12;

    // Boosts
    uint256 public constant BOOST_PRECISION       = 1e12;
    uint256 public constant BOOST_FLEX            = 1e12;          // 1.0
    uint256 public constant BOOST_30D             = 18e11;         // 1.8
    uint256 public constant BOOST_90D             = 38e11;         // 3.8

    uint256 public constant TERM_30D              = 30 days;
    uint256 public constant TERM_90D              = 90 days;

    // Private sale parameters
    uint256 public constant PRIVATE_LOCK_PERIOD   = 90 days;       // 3 months
    uint256 public constant PRIVATE_IMMEDIATE_BPS = 500;           // 5% immediate ART release

    // Pool IDs
    uint8 public constant ART_POOL_ID = 0;
    uint8 public constant GF_POOL_ID  = 1;
    uint8 public constant POOL_COUNT  = 2;

    // Term IDs
    uint8 public constant TERM_FLEX = 0;
    uint8 public constant TERM_30   = 1;
    uint8 public constant TERM_90   = 2;
    uint8 public constant TERM_COUNT = 3;

    // Safety Limits
    // Max positions per term per user to prevent gas limit issues during iteration
    uint256 public constant MAX_POSITIONS = 200;

    // ==================== Roles, Tokens & Recipients ====================

    mapping(address => bool) private admins;
    address[] private adminList;

    IERC20 public immutable artToken;   // ART token (6 decimals)
    IGFToken public immutable gfToken;  // GF token (6 decimals, mintable here)

    uint256 public immutable deploymentTime;
    uint256 public immutable INITIAL_GF_SUPPLY; // emission base (snapshot at deployment)

    // Fee recipient for penalties and rescues
    address public feeRecipient;

    // ==================== Configurables ====================

    // Early unlock penalty (bps on amount)
    uint256 public earlyPenaltyBps; // default 500 (5%)

    // Per-term staking toggles
    bool public flexibleEnabled; // controls TERM_FLEX stake
    bool public lock30Enabled;   // controls TERM_30 stake
    bool public lock90Enabled;   // controls TERM_90 stake

    // ==================== Pool & User State ====================

    struct Pool {
        // weights
        uint256 weightedFlex;             // sum(amount * 1.0)
        uint256 weighted30;               // sum(amount * 1.8) for active 30d locks
        uint256 weighted90;               // sum(amount * 3.8) for active 90d locks
        uint256 weightedTotal;            // sum of the above

        // token totals
        uint256 totalStaked;              // overall total (flex + 30d + 90d)
        uint256 totalStakedFlex;          // flexible term total
        uint256 totalStaked30;            // 30d term total
        uint256 totalStaked90;            // 90d term total

        // rewards
        uint256 rewardPerWeightStored;    // accumulated reward per unit weight (scaled by REWARD_PRECISION)
        uint256 lastUpdateTime;           // last timestamp rewards were updated
        uint256 annualRateBps;            // annual rate in BPS of INITIAL_GF_SUPPLY distributed to this pool
    }

    struct Position {
        uint256 amount;
        uint256 unlockAt;
    }

    struct UserPositions {
        // flexible bucket
        uint256 flexAmount;

        // arrays of lock positions
        Position[] lock30;
        Position[] lock90;

        // rewards accounting
        uint256 userRewardPerWeightPaid;
        uint256 pendingRewards;
    }

    mapping(uint8 => Pool) public pools;                            // poolId => Pool
    mapping(uint8 => mapping(address => UserPositions)) public users;// poolId => user => UserPositions

    // ==================== Stats ====================

    uint256 public totalRewardsDistributed;
    uint256 public totalStakedArt;
    uint256 public totalStakedGf;

    // ==================== Events ====================

    event AdminAdded(address indexed account);
    event AdminRemoved(address indexed account);
    event FeeRecipientUpdated(address indexed oldRecipient, address indexed newRecipient);
    event EarlyPenaltyUpdated(uint256 oldBps, uint256 newBps);
    event StakingTogglesUpdated(bool flexibleEnabled, bool lock30Enabled, bool lock90Enabled);

    event Staked(uint8 indexed poolId, address indexed user, uint8 termId, uint256 amount, uint256 unlockAtOrZero, uint256 positionIndexOrMax);

    event Withdrawn(uint8 indexed poolId, address indexed user, uint8 termId, uint256 amount, uint32 positionIndex);

    event EarlyWithdrawn(uint8 indexed poolId, address indexed user, uint8 termId, uint256 positionIndex, uint256 amount, uint256 penalty);
    event RewardClaimed(address indexed user, uint256 amount);

    event PrivateAllocated(
        address indexed investor,
        uint256 artAmount,
        uint256 gfRewards,
        uint256 immediateRelease,
        uint256 stakedAmount,
        uint256 lockEndTime,
        uint256 positionIndex
    );

    event ERC20Rescued(address indexed token, address indexed to, uint256 amount);
    event NativeRescued(address indexed to, uint256 amount);

    // ==================== Errors ====================

    error OnlyAdminOrOwner();
    error InvalidAddress();
    error InvalidAmount();
    error InvalidPoolId();
    error InvalidTerm();
    error InvalidPosition();
    error NotActive();
    error InsufficientBalance();
    error NotLocked();
    error NotMatured();
    error AlreadyMatured();
    error NothingToClaim();
    error NativeTransferFailed();
    error DeductInsufficientFlexible();
    error Disabled();
    error MaxPositionsExceeded();

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

    modifier validPool(uint8 poolId) {
        if (poolId >= POOL_COUNT) revert InvalidPoolId();
        _;
    }

    modifier validTerm(uint8 termId) {
        if (termId >= TERM_COUNT) revert InvalidTerm();
        _;
    }

    modifier whenActive() {
        if (block.timestamp > deploymentTime + INCENTIVE_PERIOD) revert NotActive();
        _;
    }

    // ==================== Constructor & Views ====================

    constructor(address _artToken, address _gfToken) Ownable(msg.sender) {
        if (_artToken == address(0) || _gfToken == address(0)) revert InvalidAddress();

        artToken = IERC20(_artToken);
        gfToken = IGFToken(_gfToken);

        deploymentTime = block.timestamp;
        INITIAL_GF_SUPPLY = gfToken.TOTAL_SUPPLY();

        feeRecipient = msg.sender;
        _addAdminInternal(msg.sender);

        uint256 nowTs = block.timestamp;
        pools[ART_POOL_ID] = Pool(0, 0, 0, 0, 0, 0, 0, 0, 0, nowTs, ART_POOL_ANNUAL_BPS);
        pools[GF_POOL_ID]  = Pool(0, 0, 0, 0, 0, 0, 0, 0, 0, nowTs, GF_POOL_ANNUAL_BPS);

        // defaults
        earlyPenaltyBps = 500; // 5%
        flexibleEnabled = true;
        lock30Enabled   = true;
        lock90Enabled   = true;
    }

    struct Overview {
        // Constants
        string  version;
        uint256 bpsDenominator;
        uint256 artPoolAnnualBps;
        uint256 gfPoolAnnualBps;
        uint256 incentivePeriod;
        uint256 rewardPrecision;
        uint256 boostPrecision;
        uint256 boostFlex;
        uint256 boost30d;
        uint256 boost90d;
        uint256 privateLockPeriod;
        uint256 privateImmediateBps;
        uint256 earlyPenaltyBps;
        uint256 maxPositions;

        // Addresses & roles
        address owner;
        address artToken;
        address gfToken;
        address feeRecipient;

        // Global status
        bool    paused;
        bool    active;
        uint256 deploymentTime;
        uint256 timeRemaining;

        // Emission base
        uint256 gfInitialSupplyRef;
        uint256 gfCurrentSupplyRef;

        // ART pool snapshot
        uint256 artTotalStaked;
        uint256 artTotalStakedFlex;
        uint256 artTotalStaked30;
        uint256 artTotalStaked90;
        uint256 artWeightedFlex;
        uint256 artWeighted30;
        uint256 artWeighted90;
        uint256 artWeightedTotal;
        uint256 artRewardPerWeightStored;
        uint256 artLastUpdateTime;
        uint256 artAnnualRateBps;
        uint256 artCurrentAnnualReward;

        // GF pool snapshot
        uint256 gfTotalStaked;
        uint256 gfTotalStakedFlex;
        uint256 gfTotalStaked30;
        uint256 gfTotalStaked90;
        uint256 gfWeightedFlex;
        uint256 gfWeighted30;
        uint256 gfWeighted90;
        uint256 gfWeightedTotal;
        uint256 gfRewardPerWeightStored;
        uint256 gfLastUpdateTime;
        uint256 gfAnnualRateBps;
        uint256 gfCurrentAnnualReward;

        // Toggles
        bool flexibleEnabled;
        bool lock30Enabled;
        bool lock90Enabled;

        // APRs (1e18 precision)
        uint256 artAprFlex;
        uint256 artApr30;
        uint256 artApr90;
        uint256 gfAprFlex;
        uint256 gfApr30;
        uint256 gfApr90;
    }

    function getOverview() external view returns (Overview memory s) {
        s.version              = VERSION;
        s.bpsDenominator       = BPS_DENOMINATOR;
        s.artPoolAnnualBps     = ART_POOL_ANNUAL_BPS;
        s.gfPoolAnnualBps      = GF_POOL_ANNUAL_BPS;
        s.incentivePeriod      = INCENTIVE_PERIOD;
        s.rewardPrecision      = REWARD_PRECISION;
        s.boostPrecision       = BOOST_PRECISION;
        s.boostFlex            = BOOST_FLEX;
        s.boost30d             = BOOST_30D;
        s.boost90d             = BOOST_90D;
        s.privateLockPeriod    = PRIVATE_LOCK_PERIOD;
        s.privateImmediateBps  = PRIVATE_IMMEDIATE_BPS;
        s.earlyPenaltyBps      = earlyPenaltyBps;
        s.maxPositions         = MAX_POSITIONS;

        s.owner        = owner();
        s.artToken     = address(artToken);
        s.gfToken      = address(gfToken);
        s.feeRecipient = feeRecipient;

        s.paused         = paused();
        s.active         = block.timestamp <= deploymentTime + INCENTIVE_PERIOD;
        s.deploymentTime = deploymentTime;
        if (s.active) {
            uint256 endTs = deploymentTime + INCENTIVE_PERIOD;
            s.timeRemaining = endTs > block.timestamp ? endTs - block.timestamp : 0;
        }

        s.gfInitialSupplyRef = INITIAL_GF_SUPPLY;
        s.gfCurrentSupplyRef = gfToken.TOTAL_SUPPLY();

        // read both pools once
        Pool memory pa = pools[ART_POOL_ID];
        Pool memory pg = pools[GF_POOL_ID];

        // ART pool snapshot
        s.artTotalStaked            = pa.totalStaked;
        s.artTotalStakedFlex        = pa.totalStakedFlex;
        s.artTotalStaked30          = pa.totalStaked30;
        s.artTotalStaked90          = pa.totalStaked90;
        s.artWeightedFlex           = pa.weightedFlex;
        s.artWeighted30             = pa.weighted30;
        s.artWeighted90             = pa.weighted90;
        s.artWeightedTotal          = pa.weightedTotal;
        s.artRewardPerWeightStored  = pa.rewardPerWeightStored;
        s.artLastUpdateTime         = pa.lastUpdateTime;
        s.artAnnualRateBps          = pa.annualRateBps;
        s.artCurrentAnnualReward    = (INITIAL_GF_SUPPLY * pa.annualRateBps) / BPS_DENOMINATOR;

        // GF pool snapshot
        s.gfTotalStaked            = pg.totalStaked;
        s.gfTotalStakedFlex        = pg.totalStakedFlex;
        s.gfTotalStaked30          = pg.totalStaked30;
        s.gfTotalStaked90          = pg.totalStaked90;
        s.gfWeightedFlex           = pg.weightedFlex;
        s.gfWeighted30             = pg.weighted30;
        s.gfWeighted90             = pg.weighted90;
        s.gfWeightedTotal          = pg.weightedTotal;
        s.gfRewardPerWeightStored  = pg.rewardPerWeightStored;
        s.gfLastUpdateTime         = pg.lastUpdateTime;
        s.gfAnnualRateBps          = pg.annualRateBps;
        s.gfCurrentAnnualReward    = (INITIAL_GF_SUPPLY * pg.annualRateBps) / BPS_DENOMINATOR;

        // toggles
        s.flexibleEnabled = flexibleEnabled;
        s.lock30Enabled   = lock30Enabled;
        s.lock90Enabled   = lock90Enabled;

        // APRs using the helper on the same snapshots
        (s.artAprFlex, s.artApr30, s.artApr90) = _poolAprs(pa, s.artCurrentAnnualReward);
        (s.gfAprFlex,  s.gfApr30,  s.gfApr90)  = _poolAprs(pg, s.gfCurrentAnnualReward);
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

    function setFeeRecipient(address newRecipient) external onlyOwner validAddress(newRecipient) {
        if (newRecipient == feeRecipient) return;
        address old = feeRecipient;
        feeRecipient = newRecipient;
        emit FeeRecipientUpdated(old, newRecipient);
    }

    /**
     * @dev Update early penalty bps. Range: [0, 10000].
     */
    function setEarlyPenaltyBps(uint256 newBps) external onlyOwner {
        if (newBps > BPS_DENOMINATOR) revert InvalidAmount();
        uint256 old = earlyPenaltyBps;
        if (newBps == old) return;
        earlyPenaltyBps = newBps;
        emit EarlyPenaltyUpdated(old, newBps);
    }

    /**
     * @dev Update term toggles for staking availability by term.
     */
    function setStakingToggles(bool flex, bool lock30, bool lock90) external onlyOwner {
        flexibleEnabled = flex;
        lock30Enabled   = lock30;
        lock90Enabled   = lock90;
        emit StakingTogglesUpdated(flex, lock30, lock90);
    }

    // ==================== Private Allocation ====================

    /**
     * @dev Admin funds ART, 5% sent to investor, 95% staked as one 90d lock, optional GF rewards.
     */
    function allocatePrivateSale(
        address investor,
        uint256 artAmount,
        uint256 gfRewards
    ) external nonReentrant onlyAdminOrOwner validAddress(investor) validAmount(artAmount) {
        artToken.safeTransferFrom(msg.sender, address(this), artAmount);

        _syncAndSettle(ART_POOL_ID, investor);

        _allocatePrivateCommon(investor, artAmount, gfRewards);
    }

    /**
     * @dev Same as allocatePrivateSale but uses EIP-2612 permit for ART pull.
     */
    function allocatePrivateSaleWithPermit(
        address investor,
        uint256 artAmount,
        uint256 gfRewards,
        uint256 deadline,
        uint8 v, bytes32 r, bytes32 s
    )
    external
    nonReentrant
    onlyAdminOrOwner
    validAddress(investor)
    validAmount(artAmount)
    {
        _safePermit(address(artToken), msg.sender, address(this), artAmount, deadline, v, r, s);
        artToken.safeTransferFrom(msg.sender, address(this), artAmount);

        _syncAndSettle(ART_POOL_ID, investor);

        _allocatePrivateCommon(investor, artAmount, gfRewards);
    }

    // ==================== Core: Staking ====================

    /**
     * @dev Stake tokens into a pool with selected term.
     */
    function stake(uint8 poolId, uint8 termId, uint256 amount)
    external
    nonReentrant
    whenNotPaused
    whenActive
    validPool(poolId)
    validTerm(termId)
    validAmount(amount)
    {
        if (termId == TERM_FLEX && !flexibleEnabled) revert Disabled();
        if (termId == TERM_30   && !lock30Enabled)   revert Disabled();
        if (termId == TERM_90   && !lock90Enabled)   revert Disabled();

        _syncAndSettle(poolId, msg.sender);

        IERC20 token = _tokenOf(poolId);
        token.safeTransferFrom(msg.sender, address(this), amount);

        uint256 posIndex = _stakeAdd(poolId, msg.sender, termId, amount);

        uint256 unlockAtOrZero = _termUnlockAt(termId);
        emit Staked(poolId, msg.sender, termId, amount, unlockAtOrZero, posIndex);
    }

    /**
     * @dev Stake with EIP-2612 permit.
     */
    function stakeWithPermit(
        uint8 poolId,
        uint8 termId,
        uint256 amount,
        uint256 deadline,
        uint8 v, bytes32 r, bytes32 s
    )
    external
    nonReentrant
    whenNotPaused
    whenActive
    validPool(poolId)
    validTerm(termId)
    validAmount(amount)
    {
        if (termId == TERM_FLEX && !flexibleEnabled) revert Disabled();
        if (termId == TERM_30   && !lock30Enabled)   revert Disabled();
        if (termId == TERM_90   && !lock90Enabled)   revert Disabled();

        _syncAndSettle(poolId, msg.sender);

        IERC20 token = _tokenOf(poolId);
        _safePermit(address(token), msg.sender, address(this), amount, deadline, v, r, s);
        token.safeTransferFrom(msg.sender, address(this), amount);

        uint256 posIndex = _stakeAdd(poolId, msg.sender, termId, amount);

        uint256 unlockAtOrZero = _termUnlockAt(termId);
        emit Staked(poolId, msg.sender, termId, amount, unlockAtOrZero, posIndex);
    }

    /**
     * @dev Withdraw flexible balance and matured locks.
     * Tries flexible first, then matured 30d, then matured 90d.
     */
    function withdraw(uint8 poolId, uint256 amount)
    external
    nonReentrant
    whenNotPaused
    validPool(poolId)
    validAmount(amount)
    {
        _syncAndSettle(poolId, msg.sender);

        uint256 available = _getWithdrawable(poolId, msg.sender);
        if (amount > available) revert InsufficientBalance();

        _deductFromAvailable(poolId, msg.sender, amount);

        if (poolId == ART_POOL_ID) {
            artToken.safeTransfer(msg.sender, amount);
        } else {
            gfToken.safeTransfer(msg.sender, amount);
        }
    }

    /**
     * @dev Withdraw a specific matured lock position by index.
     */
    function withdrawSpecific(uint8 poolId, uint8 termId, uint256 posIndex)
    external
    nonReentrant
    whenNotPaused
    validPool(poolId)
    {
        // 1. Validate term (must be a lock term)
        if (termId != TERM_30 && termId != TERM_90) revert InvalidTerm();

        // 2. Sync rewards before modifying state
        _syncAndSettle(poolId, msg.sender);

        // 3. Get position info
        (uint256 amount, uint256 unlockAt) = _getLockedPosition(poolId, msg.sender, termId, posIndex);

        // 4. Validate position state
        if (amount == 0) revert InvalidAmount();
        if (block.timestamp < unlockAt) revert NotMatured();

        // 5. Reduce locked position (updates weights, removes from array, updates term totals)
        _reduceLocked(poolId, msg.sender, termId, posIndex, amount);

        // 6. Update Global Pool Totals
        pools[poolId].totalStaked -= amount;
        if (poolId == ART_POOL_ID) totalStakedArt -= amount; else totalStakedGf -= amount;

        // 7. Transfer tokens
        IERC20 token = _tokenOf(poolId);
        token.safeTransfer(msg.sender, amount);

        emit Withdrawn(poolId, msg.sender, termId, amount, uint32(posIndex));
    }

    /**
     * @dev Early withdraw from a locked (not matured) position with penalty.
     */
    function earlyWithdraw(uint8 poolId, uint8 termId, uint256 posIndex, uint256 amount)
    external
    nonReentrant
    whenNotPaused
    validPool(poolId)
    validAmount(amount)
    {
        if (termId == TERM_FLEX) revert NotLocked();

        _syncAndSettle(poolId, msg.sender);

        (uint256 lockedAmt, uint256 unlockAt) = _getLockedPosition(poolId, msg.sender, termId, posIndex);
        if (lockedAmt == 0) revert NotLocked();
        if (block.timestamp >= unlockAt) revert AlreadyMatured();
        if (amount > lockedAmt) revert InsufficientBalance();

        uint256 penalty = (amount * earlyPenaltyBps) / BPS_DENOMINATOR;
        uint256 sendToUser = amount - penalty;

        _reduceLocked(poolId, msg.sender, termId, posIndex, amount);

        pools[poolId].totalStaked -= amount;
        if (poolId == ART_POOL_ID) totalStakedArt -= amount; else totalStakedGf -= amount;

        if (poolId == ART_POOL_ID) {
            if (sendToUser > 0) artToken.safeTransfer(msg.sender, sendToUser);
            if (penalty > 0) artToken.safeTransfer(feeRecipient, penalty);
        } else {
            if (sendToUser > 0) gfToken.safeTransfer(msg.sender, sendToUser);
            if (penalty > 0) gfToken.safeTransfer(feeRecipient, penalty);
        }

        emit EarlyWithdrawn(poolId, msg.sender, termId, posIndex, amount, penalty);
    }

    /**
     * @dev Claim accumulated GF rewards across both pools (mint).
     */
    function claimRewards() external nonReentrant whenNotPaused {
        uint256 totalToMint = 0;

        for (uint8 i = 0; i < POOL_COUNT; i++) {
            _syncAndSettle(i, msg.sender);

            uint256 claimable = users[i][msg.sender].pendingRewards;
            if (claimable > 0) {
                users[i][msg.sender].pendingRewards = 0;
                totalToMint += claimable;
            }
        }

        if (totalToMint == 0) revert NothingToClaim();

        gfToken.mint(msg.sender, totalToMint);
        totalRewardsDistributed += totalToMint;
        emit RewardClaimed(msg.sender, totalToMint);
    }

    // ==================== Internal: stake/withdraw helpers ====================

    /**
     * @dev Add stake for a user. For locked terms, create a new position.
     * @return posIndex Index of created position (flex returns type(uint256).max).
     */
    function _stakeAdd(uint8 poolId, address user, uint8 termId, uint256 amount) internal returns (uint256 posIndex) {
        Pool storage p = pools[poolId];
        UserPositions storage up = users[poolId][user];

        if (termId == TERM_FLEX) {
            up.flexAmount += amount;
            uint256 w = (amount * BOOST_FLEX) / BOOST_PRECISION;
            p.weightedFlex += w;

            p.totalStakedFlex += amount;
            posIndex = type(uint256).max;
        } else if (termId == TERM_30) {
            if (up.lock30.length >= MAX_POSITIONS) revert MaxPositionsExceeded();

            uint256 endTs = block.timestamp + TERM_30D;
            up.lock30.push(Position({amount: amount, unlockAt: endTs}));

            uint256 w = (amount * BOOST_30D) / BOOST_PRECISION;
            p.weighted30 += w;

            p.totalStaked30 += amount;
            posIndex = up.lock30.length - 1;
        } else if (termId == TERM_90) {
            if (up.lock90.length >= MAX_POSITIONS) revert MaxPositionsExceeded();

            uint256 endTs = block.timestamp + TERM_90D;
            up.lock90.push(Position({amount: amount, unlockAt: endTs}));

            uint256 w = (amount * BOOST_90D) / BOOST_PRECISION;
            p.weighted90 += w;

            p.totalStaked90 += amount;
            posIndex = up.lock90.length - 1;
        } else {
            revert InvalidTerm();
        }

        p.weightedTotal = p.weightedFlex + p.weighted30 + p.weighted90;
        p.totalStaked += amount;

        if (poolId == ART_POOL_ID) totalStakedArt += amount; else totalStakedGf += amount;
    }

    /**
     * @dev Compute withdrawable (flex + matured locks) without storage mutation.
     */
    function _getWithdrawable(uint8 poolId, address user) internal view returns (uint256) {
        UserPositions storage up = users[poolId][user];

        uint256 available = up.flexAmount;
        uint256 nowTs = block.timestamp;

        // matured 30d
        Position[] storage arr30 = up.lock30;
        for (uint256 i = 0; i < arr30.length; i++) {
            if (arr30[i].amount > 0 && arr30[i].unlockAt > 0 && nowTs >= arr30[i].unlockAt) {
                available += arr30[i].amount;
            }
        }
        // matured 90d
        Position[] storage arr90 = up.lock90;
        for (uint256 i = 0; i < arr90.length; i++) {
            if (arr90[i].amount > 0 && arr90[i].unlockAt > 0 && nowTs >= arr90[i].unlockAt) {
                available += arr90[i].amount;
            }
        }
        return available;
    }

    /**
     * @dev Deduct amount from available sources in order: Flex -> Matured 30d -> Matured 90d.
     */
    function _deductFromAvailable(uint8 poolId, address user, uint256 amount) internal {
        Pool storage p = pools[poolId];
        UserPositions storage up = users[poolId][user];

        uint256 remaining = amount;
        uint256 nowTs = block.timestamp;

        // 1. Try Flexible
        if (up.flexAmount > 0) {
            uint256 take = up.flexAmount < remaining ? up.flexAmount : remaining;
            up.flexAmount -= take;

            uint256 w = (take * BOOST_FLEX) / BOOST_PRECISION;
            if (p.weightedFlex >= w) p.weightedFlex -= w; else p.weightedFlex = 0;
            if (p.totalStakedFlex >= take) p.totalStakedFlex -= take; else p.totalStakedFlex = 0;

            remaining -= take;

            emit Withdrawn(poolId, user, TERM_FLEX, take, 0);
        }

        if (remaining == 0) {
            _finalizeDeduct(poolId, amount);
            return;
        }

        // 2. Try Matured 30d
        uint256 i = 0;
        while (remaining > 0 && i < up.lock30.length) {
            Position storage pos = up.lock30[i];
            // Check if matured
            if (pos.amount > 0 && pos.unlockAt > 0 && nowTs >= pos.unlockAt) {
                if (pos.amount > remaining) {
                    // Partial take
                    pos.amount -= remaining;

                    // Update weights (30d weight)
                    uint256 w = (remaining * BOOST_30D) / BOOST_PRECISION;
                    if (p.weighted30 >= w) p.weighted30 -= w; else p.weighted30 = 0;
                    if (p.totalStaked30 >= remaining) p.totalStaked30 -= remaining; else p.totalStaked30 = 0;

                    // Emit event for this partial take
                    emit Withdrawn(poolId, user, TERM_30, remaining, uint32(i));

                    remaining = 0;
                } else {
                    // Full take of this position
                    uint256 take = pos.amount;
                    remaining -= take;

                    uint256 w = (take * BOOST_30D) / BOOST_PRECISION;
                    if (p.weighted30 >= w) p.weighted30 -= w; else p.weighted30 = 0;
                    if (p.totalStaked30 >= take) p.totalStaked30 -= take; else p.totalStaked30 = 0;

                    // Emit event for this full take BEFORE removing index
                    emit Withdrawn(poolId, user, TERM_30, take, uint32(i));

                    // Remove position
                    _removePosition(up.lock30, i);
                    continue;
                }
            }
            i++;
        }

        if (remaining == 0) {
            _finalizeDeduct(poolId, amount);
            return;
        }

        // 3. Try Matured 90d
        i = 0;
        while (remaining > 0 && i < up.lock90.length) {
            Position storage pos = up.lock90[i];
            if (pos.amount > 0 && pos.unlockAt > 0 && nowTs >= pos.unlockAt) {
                if (pos.amount > remaining) {
                    pos.amount -= remaining;

                    uint256 w = (remaining * BOOST_90D) / BOOST_PRECISION;
                    if (p.weighted90 >= w) p.weighted90 -= w; else p.weighted90 = 0;
                    if (p.totalStaked90 >= remaining) p.totalStaked90 -= remaining; else p.totalStaked90 = 0;

                    // Emit event
                    emit Withdrawn(poolId, user, TERM_90, remaining, uint32(i));

                    remaining = 0;
                } else {
                    uint256 take = pos.amount;
                    remaining -= take;

                    uint256 w = (take * BOOST_90D) / BOOST_PRECISION;
                    if (p.weighted90 >= w) p.weighted90 -= w; else p.weighted90 = 0;
                    if (p.totalStaked90 >= take) p.totalStaked90 -= take; else p.totalStaked90 = 0;

                    // Emit event
                    emit Withdrawn(poolId, user, TERM_90, take, uint32(i));

                    _removePosition(up.lock90, i);
                    continue;
                }
            }
            i++;
        }

        if (remaining != 0) revert DeductInsufficientFlexible();

        _finalizeDeduct(poolId, amount);
    }

    function _finalizeDeduct(uint8 poolId, uint256 amount) internal {
        Pool storage p = pools[poolId];
        p.weightedTotal = p.weightedFlex + p.weighted30 + p.weighted90;
        p.totalStaked -= amount;
        if (poolId == ART_POOL_ID) totalStakedArt -= amount; else totalStakedGf -= amount;
    }

    /**
     * @dev Get a specific lock position.
     */
    function _getLockedPosition(uint8 poolId, address user, uint8 termId, uint256 posIndex)
    internal
    view
    returns (uint256 amount, uint256 unlockAt)
    {
        UserPositions storage up = users[poolId][user];
        if (termId == TERM_30) {
            if (posIndex >= up.lock30.length) revert InvalidPosition();
            Position storage p30 = up.lock30[posIndex];
            return (p30.amount, p30.unlockAt);
        } else if (termId == TERM_90) {
            if (posIndex >= up.lock90.length) revert InvalidPosition();
            Position storage p90 = up.lock90[posIndex];
            return (p90.amount, p90.unlockAt);
        }
        revert InvalidTerm();
    }

    /**
     * @dev Reduce a specific lock position by amount; remove if zero; update weights.
     */
    function _reduceLocked(uint8 poolId, address user, uint8 termId, uint256 posIndex, uint256 amount) internal {
        Pool storage p = pools[poolId];
        UserPositions storage up = users[poolId][user];

        if (termId == TERM_30) {
            if (posIndex >= up.lock30.length) revert InvalidPosition();
            Position storage pos = up.lock30[posIndex];
            if (pos.amount < amount) revert InsufficientBalance();
            pos.amount -= amount;

            uint256 w = (amount * BOOST_30D) / BOOST_PRECISION;
            if (p.weighted30 >= w) p.weighted30 -= w; else p.weighted30 = 0;

            if (p.totalStaked30 >= amount) p.totalStaked30 -= amount; else p.totalStaked30 = 0;

            if (pos.amount == 0) {
                _removePosition(up.lock30, posIndex);
            }
        } else if (termId == TERM_90) {
            if (posIndex >= up.lock90.length) revert InvalidPosition();
            Position storage pos = up.lock90[posIndex];
            if (pos.amount < amount) revert InsufficientBalance();
            pos.amount -= amount;

            uint256 w = (amount * BOOST_90D) / BOOST_PRECISION;
            if (p.weighted90 >= w) p.weighted90 -= w; else p.weighted90 = 0;

            if (p.totalStaked90 >= amount) p.totalStaked90 -= amount; else p.totalStaked90 = 0;

            if (pos.amount == 0) {
                _removePosition(up.lock90, posIndex);
            }
        } else {
            revert InvalidTerm();
        }

        p.weightedTotal = p.weightedFlex + p.weighted30 + p.weighted90;
    }

    /**
     * @dev O(1) remove by swap&pop; position order is not preserved.
     */
    function _removePosition(Position[] storage arr, uint256 index) internal {
        uint256 last = arr.length - 1;
        if (index != last) {
            arr[index] = arr[last];
        }
        arr.pop();
    }


    // ==================== Rewards & Settlement ====================

    /**
     * @dev Consolidated settlement: update pool reward, update user reward.
     */
    function _syncAndSettle(uint8 poolId, address user) internal {
        _updatePoolReward(poolId);
        _updateUserReward(poolId, user);
    }

    /**
     * @dev Update pool's rewardPerWeightStored by linear per-second emission.
     */
    function _updatePoolReward(uint8 poolId) internal {
        Pool storage p = pools[poolId];
        uint256 lastTime = p.lastUpdateTime;
        uint256 endTime = deploymentTime + INCENTIVE_PERIOD;

        uint256 current = block.timestamp;
        if (current > endTime) current = endTime;
        if (current <= lastTime) return;

        uint256 annualReward = (INITIAL_GF_SUPPLY * p.annualRateBps) / BPS_DENOMINATOR;
        uint256 elapsed = current - lastTime;

        if (p.weightedTotal > 0) {
            uint256 numerator = annualReward * elapsed * REWARD_PRECISION;
            uint256 denominator = 365 days * p.weightedTotal;
            p.rewardPerWeightStored += numerator / denominator;
        }
        p.lastUpdateTime = current;
    }

    /**
     * @dev Update user's pending rewards using rewardPerWeight.
     */
    function _updateUserReward(uint8 poolId, address user) internal {
        Pool storage p = pools[poolId];
        UserPositions storage up = users[poolId][user];

        uint256 rpt = p.rewardPerWeightStored;
        if (rpt == up.userRewardPerWeightPaid) return;

        uint256 userWeight = _userEffectiveWeight(poolId, user);
        if (userWeight > 0) {
            uint256 diff = rpt - up.userRewardPerWeightPaid;
            uint256 newly = (userWeight * diff) / REWARD_PRECISION;
            up.pendingRewards += newly;
        }
        up.userRewardPerWeightPaid = rpt;
    }

    /**
     * @dev Effective weight for a user at current timestamp (read-only).
     * Locked positions provide boosted weight regardless of expiry, as long as they are in the array.
     */
    function _userEffectiveWeight(uint8 poolId, address user) internal view returns (uint256) {
        UserPositions storage up = users[poolId][user];

        uint256 weight = (up.flexAmount * BOOST_FLEX) / BOOST_PRECISION;

        // 30d positions
        Position[] storage arr30 = up.lock30;
        for (uint256 i = 0; i < arr30.length; i++) {
            Position storage pos = arr30[i];
            if (pos.amount == 0) continue;
            weight += (pos.amount * BOOST_30D) / BOOST_PRECISION;
        }
        // 90d positions
        Position[] storage arr90 = up.lock90;
        for (uint256 i = 0; i < arr90.length; i++) {
            Position storage pos = arr90[i];
            if (pos.amount == 0) continue;
            weight += (pos.amount * BOOST_90D) / BOOST_PRECISION;
        }
        return weight;
    }

    // ==================== Views ====================

    function getStats() external view returns (uint256 _totalRewardsDistributed, uint256 _totalStakedArt, uint256 _totalStakedGf) {
        return (totalRewardsDistributed, totalStakedArt, totalStakedGf);
    }

    function getStatus() external view returns (bool active, uint256 deploymentTime_, uint256 timeRemaining) {
        bool act = block.timestamp <= deploymentTime + INCENTIVE_PERIOD;
        uint256 remaining = 0;
        if (act) {
            uint256 endTs = deploymentTime + INCENTIVE_PERIOD;
            remaining = endTs > block.timestamp ? endTs - block.timestamp : 0;
        }
        return (act, deploymentTime, remaining);
    }

    struct PoolInfo {
        uint256 totalStaked;
        uint256 totalStakedFlex;
        uint256 totalStaked30;
        uint256 totalStaked90;
        uint256 currentAnnualReward;
        uint256 rewardPerWeightStored;
        uint256 lastUpdateTime;
        uint256 annualRateBps;
        uint256 weightedFlex;
        uint256 weighted30;
        uint256 weighted90;
        uint256 weightedTotal;
        uint256 aprFlex;
        uint256 apr30;
        uint256 apr90;
    }

    function getPoolInfo(uint8 poolId) external view validPool(poolId) returns (PoolInfo memory info) {
        // Inline reads to avoid stack pressure
        uint256 annualRate = pools[poolId].annualRateBps;

        info.totalStaked           = pools[poolId].totalStaked;
        info.totalStakedFlex       = pools[poolId].totalStakedFlex;
        info.totalStaked30         = pools[poolId].totalStaked30;
        info.totalStaked90         = pools[poolId].totalStaked90;
        info.annualRateBps         = annualRate;
        info.currentAnnualReward   = (INITIAL_GF_SUPPLY * annualRate) / BPS_DENOMINATOR;
        info.rewardPerWeightStored = pools[poolId].rewardPerWeightStored;
        info.lastUpdateTime        = pools[poolId].lastUpdateTime;
        info.weightedFlex          = pools[poolId].weightedFlex;
        info.weighted30            = pools[poolId].weighted30;
        info.weighted90            = pools[poolId].weighted90;
        info.weightedTotal         = pools[poolId].weightedTotal;

        // Inline APR computation (1e18 precision)
        uint256 wTotal = info.weightedTotal;
        uint256 annualReward = info.currentAnnualReward;

        if (wTotal == 0 || annualReward == 0) {
            // aprs remain zero
            return info;
        }

        uint256 rewardFlex = (annualReward * info.weightedFlex) / wTotal;
        uint256 reward30   = (annualReward * info.weighted30)  / wTotal;
        uint256 reward90   = (annualReward * info.weighted90)  / wTotal;

        info.aprFlex = (info.totalStakedFlex > 0) ? (rewardFlex * 1e18) / info.totalStakedFlex : 0;
        info.apr30   = (info.totalStaked30  > 0) ? (reward30   * 1e18) / info.totalStaked30   : 0;
        info.apr90   = (info.totalStaked90  > 0) ? (reward90   * 1e18) / info.totalStaked90   : 0;
    }

    /**
     * @dev Returns user summary; for positions use getUserPositions.
     */
    function getUserInfo(uint8 poolId, address user) external view validPool(poolId) returns (
        uint256 flexAmount,
        uint256 lock30Count,
        uint256 lock90Count,
        uint256 pending,
        uint256 effectiveWeight
    ) {
        UserPositions storage up = users[poolId][user];

        flexAmount       = up.flexAmount;
        lock30Count      = up.lock30.length;
        lock90Count      = up.lock90.length;

        pending          = viewPending(poolId, user);
        effectiveWeight  = _userEffectiveWeight(poolId, user);
    }

    /**
     * @dev Paged positions for 30d or 90d.
     */
    function getUserPositions(
        uint8 poolId,
        address user,
        uint8 termId,
        uint256 offset,
        uint256 limit
    ) external view validPool(poolId) validTerm(termId) returns (Position[] memory out) {
        UserPositions storage up = users[poolId][user];
        Position[] storage src;
        if (termId == TERM_30) {
            src = up.lock30;
        } else if (termId == TERM_90) {
            src = up.lock90;
        } else {
            revert InvalidTerm();
        }

        uint256 n = src.length;
        if (offset >= n) return new Position[](0);
        uint256 end = offset + limit;
        if (end > n) end = n;

        uint256 size = end - offset;
        out = new Position[](size);
        for (uint256 i = 0; i < size; i++) {
            out[i] = src[offset + i];
        }
    }

    /**
     * @dev View pending rewards for a user in a pool (approximate until next interaction).
     */
    function viewPending(uint8 poolId, address user) public view returns (uint256) {
        Pool memory p = pools[poolId];
        UserPositions memory up = users[poolId][user];

        uint256 lastTime = p.lastUpdateTime;
        uint256 endTime = deploymentTime + INCENTIVE_PERIOD;

        uint256 current = block.timestamp;
        if (current > endTime) current = endTime;

        uint256 rpt = p.rewardPerWeightStored;

        if (current > lastTime) {
            uint256 annualReward = (INITIAL_GF_SUPPLY * p.annualRateBps) / BPS_DENOMINATOR;
            uint256 elapsed = current - lastTime;

            uint256 wTotal = p.weightedTotal;
            if (wTotal > 0) {
                uint256 numerator = annualReward * elapsed * REWARD_PRECISION;
                uint256 denominator = 365 days * wTotal;
                rpt = rpt + (numerator / denominator);
            }
        }

        uint256 userWeight = _userEffectiveWeight(poolId, user);
        uint256 pending = up.pendingRewards;

        if (rpt > up.userRewardPerWeightPaid && userWeight > 0) {
            uint256 diff = rpt - up.userRewardPerWeightPaid;
            pending += (userWeight * diff) / REWARD_PRECISION;
        }
        return pending;
    }

    // ==================== Internal utils ====================

    function _poolAprs(Pool memory p, uint256 annualReward) internal pure returns (uint256 aprFlex, uint256 apr30, uint256 apr90) {
        uint256 wTotal = p.weightedTotal;
        if (wTotal == 0 || annualReward == 0) {
            return (0, 0, 0);
        }
        uint256 rewardFlex = (annualReward * p.weightedFlex) / wTotal;
        uint256 reward30   = (annualReward * p.weighted30)  / wTotal;
        uint256 reward90   = (annualReward * p.weighted90)  / wTotal;

        aprFlex = (p.totalStakedFlex > 0) ? (rewardFlex * 1e18) / p.totalStakedFlex : 0;
        apr30   = (p.totalStaked30  > 0) ? (reward30   * 1e18) / p.totalStaked30  : 0;
        apr90   = (p.totalStaked90  > 0) ? (reward90   * 1e18) / p.totalStaked90  : 0;
    }

    function _tokenOf(uint8 poolId) internal view returns (IERC20) {
        return poolId == ART_POOL_ID ? artToken : IERC20(address(gfToken));
    }

    function _safePermit(
        address token,
        address owner_,
        address spender,
        uint256 amount,
        uint256 deadline,
        uint8 v, bytes32 r, bytes32 s
    ) internal {
        IERC20Permit(token).permit(owner_, spender, amount, deadline, v, r, s);
    }

    function _termUnlockAt(uint8 termId) internal view returns (uint256) {
        if (termId == TERM_FLEX) return 0;
        if (termId == TERM_30)   return block.timestamp + TERM_30D;
        if (termId == TERM_90)   return block.timestamp + TERM_90D;
        revert InvalidTerm();
    }

    function _allocatePrivateCommon(address investor, uint256 artAmount, uint256 gfRewards) internal {
        uint256 immediate = (artAmount * PRIVATE_IMMEDIATE_BPS) / BPS_DENOMINATOR;
        uint256 stakeAmt = artAmount - immediate;

        // 5% immediate ART to investor
        artToken.safeTransfer(investor, immediate);

        // Optional immediate GF rewards
        if (gfRewards > 0) {
            gfToken.mint(investor, gfRewards);
            totalRewardsDistributed += gfRewards;
        }

        Pool storage p = pools[ART_POOL_ID];
        UserPositions storage up = users[ART_POOL_ID][investor];

        uint256 endTs = block.timestamp + PRIVATE_LOCK_PERIOD;
        // create one 90d position for private allocation
        up.lock90.push(Position({amount: stakeAmt, unlockAt: endTs}));

        uint256 w = (stakeAmt * BOOST_90D) / BOOST_PRECISION;
        p.weighted90 += w;

        p.totalStaked90 += stakeAmt;

        p.weightedTotal = p.weightedFlex + p.weighted30 + p.weighted90;
        p.totalStaked += stakeAmt;
        totalStakedArt += stakeAmt;

        uint256 posIndex = up.lock90.length - 1;

        emit PrivateAllocated(investor, artAmount, gfRewards, immediate, stakeAmt, endTs, posIndex);
        emit Staked(ART_POOL_ID, investor, TERM_90, stakeAmt, endTs, posIndex);
    }

    // ==================== Emergency ====================

    function pause() external onlyAdminOrOwner { _pause(); }

    function unpause() external onlyOwner { _unpause(); }

    function rescueERC20(address token, address to, uint256 amount) external onlyOwner validAddress(token) validAddress(to) validAmount(amount) {
        // Prevent rescuing staked tokens (pool assets): ART and GF.
        // This ensures owner cannot accidentally or maliciously withdraw funds that belong to staking participants.
        if (token == address(artToken) || token == address(gfToken)) revert InvalidAddress();
        IERC20(token).safeTransfer(to, amount);
        emit ERC20Rescued(token, to, amount);
    }

    function rescueNative(address to, uint256 amount) external onlyOwner validAddress(to) validAmount(amount) {
        (bool ok, ) = to.call{value: amount}("");
        if (!ok) revert NativeTransferFailed();
        emit NativeRescued(to, amount);
    }
}
