// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts@5.4.0/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts@5.4.0/token/ERC20/extensions/IERC20Metadata.sol";
import {Ownable} from "@openzeppelin/contracts@5.4.0/access/Ownable.sol";
import {Pausable} from "@openzeppelin/contracts@5.4.0/utils/Pausable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts@5.4.0/utils/ReentrancyGuard.sol";
import {SafeERC20} from "@openzeppelin/contracts@5.4.0/token/ERC20/utils/SafeERC20.sol";

/**
 * @dev ART token vault interface (vault must be authorized within ART token contract).
 */
interface IARTToken {
    function mintFromVault(address to, uint256 amount) external;
    function burnFromVault(address from, uint256 amount) external;
}

/**
 * @dev Oracle interface used as the single source of truth for NAV (USD, 6 decimals).
 */
interface IPriceOracle {
    function getPrice(address asset) external view returns (uint256);
}

/**
 * @dev External KYC registry interface.
 */
interface IRegistry {
    function isKycApproved(address account) external view returns (bool);
}

/**
 * @title ARTVault
 * @dev Mint/redeem application center for ART with external KYC registry, fees, and oracle-driven NAV (USD, 6 decimals).
 * @notice Stablecoin transfers are scaled according to token decimals dynamically.
 */
contract ARTVault is Ownable, ReentrancyGuard, Pausable {
    using SafeERC20 for IERC20;

    // ==================== Constants ====================

    string public constant VERSION = "1.0.0";

    uint8   public constant USD_DECIMALS = 6;
    uint256 public constant ONE_USD      = 10 ** USD_DECIMALS;

    uint256 public constant MAX_FEE_BPS     = 200;    // Max 2%
    uint256 public constant BPS_DENOMINATOR = 10000;  // 100%

    uint256 public constant MAX_BATCH = 100;

    // Pagination page-size hard cap
    uint256 private constant MAX_REQUEST_LIMIT = 100;

    enum RedeemStatus { Pending, Completed, Cancelled }

    // ==================== State ====================

    mapping(address => bool) private admins;
    address[] private adminList;

    IARTToken public immutable artToken;
    IERC20 public immutable usdt;
    IERC20 public immutable usdc;

    IPriceOracle public priceOracle;
    IRegistry public registry;

    uint8 public immutable usdtDecimals;
    uint8 public immutable usdcDecimals;

    // Stablecoin receiving address for minting
    address public recipient;

    // Fees (basis points)
    uint256 public mintFeeBps   = 50; // 0.5%
    uint256 public redeemFeeBps = 50; // 0.5%

    // Limits (USD 6 decimals)
    uint256 public minimumAmount = 100 * ONE_USD; // $100 min per tx

    // Global KYC switch: when true (default), KYC is enforced via external registry; owner can disable to bypass checks
    bool public kycEnforced = true;

    /**
     * @dev Redeem request record.
     * - usdGross/usdFee: stored in USD 6 decimals.
     * - tokenNetOut: stored in the stablecoin's native decimals selected by the user.
     * - stableToken holds the token address (USDT or USDC) used for payout.
     */
    struct RedeemRequest {
        uint256 id;
        address account;
        address stableToken;   // USDT or USDC
        uint256 artAmount;     // burned at request time
        uint64  createdAt;
        uint64  completedAt;   // 0 if not completed
        RedeemStatus status;

        // Settlement snapshot at request time
        uint256 usdGross;      // USD gross amount (6 decimals)
        uint256 usdFee;        // USD fee amount (6 decimals)
        uint256 tokenNetOut;   // Net stablecoin out (stablecoin decimals)
    }

    // Redeem request storage by id
    mapping(uint256 => RedeemRequest) public redeemRequests;

    // Ordered list of all request IDs for enumeration
    uint256[] public allRedeemRequestIds;

    // Per-user request IDs
    mapping(address => uint256[]) public userRedeemRequestIds;

    // Operational switches
    bool public isMintOpen;    // controls mintWithUSDT/USDC
    bool public isRedeemOpen;  // controls redeemToUSDT/USDC and completeRedeem

    // Off-chain payout transaction hash per request
    mapping(uint256 => string) public redeemTxHash;

    // Global de-duplication for transaction digests
    mapping(bytes32 => bool) public usedTxDigests;

    // ==================== Events ====================

    event AdminAdded(address indexed account);
    event AdminRemoved(address indexed account);

    event PriceOracleUpdated(address indexed oldOracle, address indexed newOracle);
    event RegistryUpdated(address indexed oldRegistry, address indexed newRegistry);
    event RecipientUpdated(address indexed oldRecipient, address indexed newRecipient);
    event KycEnforcedUpdated(bool enforced);

    event FeesUpdated(uint256 oldMintFeeBps, uint256 newMintFeeBps, uint256 oldRedeemFeeBps, uint256 newRedeemFeeBps);
    event MintOpenUpdated(bool open);
    event RedeemOpenUpdated(bool open);

    event ARTMinted(
        address indexed account,
        address indexed stableToken,
        uint256 usdAmount,
        uint256 tokenIn,
        uint256 grossArt,
        uint256 feeArt,
        uint256 netArt
    );

    event RedeemRequested(
        uint256 indexed id,
        address indexed account,
        address indexed stableToken,
        uint256 artAmount,
        uint256 usdGross,
        uint256 feeUsd,
        uint256 usdNet,
        uint256 grossTokenOut,
        uint256 feeTokenOut,
        uint256 netTokenOut
    );
    event RedeemCompleted(uint256 indexed id, address indexed account, address indexed stableToken, uint256 artAmount);
    event RedeemCancelled(uint256 indexed id, address indexed account, address indexed stableToken);

    event ERC20Rescued(address indexed token, address indexed to, uint256 amount);
    event NativeRescued(address indexed to, uint256 amount);

    event RedeemTxHashRecorded(uint256 indexed id, string txHash);

    // ==================== Errors ====================

    error OnlyAdminOrOwner();
    error OnlyKYCApproved();
    error InvalidAddress();
    error InvalidAmount();
    error InvalidFee();
    error BelowMinimumAmount();
    error InvalidStablecoinDecimals();
    error EmptyArray();
    error TooManyAccounts();
    error InvalidRedeemId();
    error InvalidStatus();
    error MintClosed();
    error RedeemClosed();
    error NativeTransferFailed();
    error DuplicateRequestId(uint256 requestId);
    error InvalidNAV();
    error EmptyTransactionHash();
    error TransactionHashAlreadyUsed(string transactionHash);

    // ==================== Modifiers ====================

    modifier onlyAdminOrOwner() {
        if (msg.sender != owner() && !admins[msg.sender]) revert OnlyAdminOrOwner();
        _;
    }

    modifier onlyKYCApproved() {
        // Enforce KYC only when the global switch is on, querying external registry
        if (kycEnforced && !registry.isKycApproved(msg.sender)) revert OnlyKYCApproved();
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

    modifier whenMintOpen() {
        if (!isMintOpen) revert MintClosed();
        _;
    }

    modifier whenRedeemOpen() {
        if (!isRedeemOpen) revert RedeemClosed();
        _;
    }

    // ==================== Constructor & Views ====================

    /**
     * @param artToken_ ART token contract address (vault-authorized).
     * @param usdt_ USDT token address.
     * @param usdc_ USDC token address.
     * @param priceOracle_ Oracle returning NAV in USD 6 decimals for ART.
     * @param registry_ External registry for KYC checks.
     */
    constructor(
        address artToken_,
        address usdt_,
        address usdc_,
        address priceOracle_,
        address registry_
    ) Ownable(msg.sender) {
        if (
            artToken_ == address(0) ||
            usdt_ == address(0) ||
            usdc_ == address(0) ||
            priceOracle_ == address(0) ||
            registry_ == address(0)
        ) {
            revert InvalidAddress();
        }

        artToken = IARTToken(artToken_);
        usdt = IERC20(usdt_);
        usdc = IERC20(usdc_);
        priceOracle = IPriceOracle(priceOracle_);
        registry = IRegistry(registry_);

        // Cache decimals (must be >= 6)
        usdtDecimals = IERC20Metadata(usdt_).decimals();
        usdcDecimals = IERC20Metadata(usdc_).decimals();
        if (usdtDecimals < USD_DECIMALS || usdcDecimals < USD_DECIMALS) revert InvalidStablecoinDecimals();

        _addAdminInternal(msg.sender);

        // Default recipient is this contract; operations may set to a treasury later
        recipient = address(this);

        isMintOpen = true;
        isRedeemOpen = true;
    }

    function getConfig() external view returns (
        uint256 mintFeeBpsValue,
        uint256 redeemFeeBpsValue,
        uint256 minimumAmountValue,
        bool isMintOpenValue,
        bool isRedeemOpenValue
    ) {
        return (
            mintFeeBps,
            redeemFeeBps,
            minimumAmount,
            isMintOpen,
            isRedeemOpen
        );
    }

    struct Overview {
        // Version & constants
        string  version;
        uint256 maxBatch;        // 100

        // Addresses
        address owner;
        address recipient;
        address priceOracle;
        address registry;
        address artToken;
        address usdt;
        address usdc;

        // Decimals
        uint8 usdDecimals;     // constant = 6
        uint8 usdtDecimals;
        uint8 usdcDecimals;

        // Fees & limits (USD 6 decimals for minimumAmount)
        uint256 mintFeeBps;
        uint256 redeemFeeBps;
        uint256 maxFeeBps;       // 200
        uint256 bpsDenominator;  // 10000

        uint256 minimumAmount;

        // Switches
        bool kycEnforced;
        bool isMintOpen;
        bool isRedeemOpen;
        bool paused;

        // Aggregated counts
        uint256 totalRedeemRequests;

        // Current NAV (USD 6 decimals)
        uint256 nav;
    }

    function getOverview() external view returns (Overview memory s) {
        s.version         = VERSION;
        s.maxBatch        = MAX_BATCH;

        s.owner           = owner();
        s.recipient       = recipient;
        s.priceOracle     = address(priceOracle);
        s.registry        = address(registry);
        s.artToken        = address(artToken);
        s.usdt            = address(usdt);
        s.usdc            = address(usdc);

        s.usdDecimals     = USD_DECIMALS;
        s.usdtDecimals    = usdtDecimals;
        s.usdcDecimals    = usdcDecimals;

        s.mintFeeBps      = mintFeeBps;
        s.redeemFeeBps    = redeemFeeBps;
        s.maxFeeBps       = MAX_FEE_BPS;
        s.bpsDenominator  = BPS_DENOMINATOR;

        s.minimumAmount   = minimumAmount;

        s.kycEnforced     = kycEnforced;
        s.isMintOpen      = isMintOpen;
        s.isRedeemOpen    = isRedeemOpen;
        s.paused          = paused();

        s.totalRedeemRequests = allRedeemRequestIds.length;

        // Safe NAV read with try/catch. If oracle reverts (e.g., price not set), return 0.
        try priceOracle.getPrice(address(artToken)) returns (uint256 nav_) {
            s.nav = nav_;
        } catch {
            s.nav = 0;
        }
    }

    // ==================== Role & Config ====================

    function setPriceOracle(address newOracle) external onlyOwner validAddress(newOracle) {
        if (newOracle == address(priceOracle)) return;
        address old = address(priceOracle);
        priceOracle = IPriceOracle(newOracle);
        emit PriceOracleUpdated(old, newOracle);
    }

    function setRegistry(address newRegistry) external onlyOwner validAddress(newRegistry) {
        if (newRegistry == address(registry)) return;
        address old = address(registry);
        registry = IRegistry(newRegistry);
        emit RegistryUpdated(old, newRegistry);
    }

    function setRecipient(address newRecipient) external onlyOwner validAddress(newRecipient) {
        if (newRecipient == recipient) return;
        address old = recipient;
        recipient = newRecipient;
        emit RecipientUpdated(old, newRecipient);
    }

    function setKycEnforced(bool enforced) external onlyOwner {
        if (kycEnforced == enforced) return;
        kycEnforced = enforced;
        emit KycEnforcedUpdated(enforced);
    }

    function setMintOpen(bool open) external onlyAdminOrOwner {
        if (isMintOpen == open) return;
        isMintOpen = open;
        emit MintOpenUpdated(open);
    }

    function setRedeemOpen(bool open) external onlyAdminOrOwner {
        if (isRedeemOpen == open) return;
        isRedeemOpen = open;
        emit RedeemOpenUpdated(open);
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

    // ==================== Internal: Shared Mint ====================

    function _mintWith(IERC20 stablecoin, uint8 dec, uint256 usdAmount) private {
        if (usdAmount < minimumAmount) revert BelowMinimumAmount();

        uint256 nav = _nav();
        if (nav == 0) revert InvalidNAV();

        (uint256 grossArt, uint256 feeArt, uint256 netArt) = _previewMintWithNAV(usdAmount, nav);

        // Transfer stablecoin in to recipient
        uint256 payAmount = _scaleFromUsd6(usdAmount, dec);
        stablecoin.safeTransferFrom(msg.sender, recipient, payAmount);

        // Mint ART to account via ART token vault permission
        artToken.mintFromVault(msg.sender, netArt);

        emit ARTMinted(msg.sender, address(stablecoin), usdAmount, payAmount, grossArt, feeArt, netArt);
    }

    // ==================== Minting & Redeeming (applications) ====================

    /**
     * @notice Mint ART with USDT amount specified in USD 6 decimals.
     */
    function mintWithUSDT(uint256 usdAmount)
    external
    onlyKYCApproved
    nonReentrant
    whenNotPaused
    whenMintOpen
    validAmount(usdAmount)
    {
        _mintWith(usdt, usdtDecimals, usdAmount);
    }

    /**
     * @notice Mint ART with USDC amount specified in USD 6 decimals.
     */
    function mintWithUSDC(uint256 usdAmount)
    external
    onlyKYCApproved
    nonReentrant
    whenNotPaused
    whenMintOpen
    validAmount(usdAmount)
    {
        _mintWith(usdc, usdcDecimals, usdAmount);
    }

    /**
     * @dev Generate unique request ID without storage operations
     */
    function generateRequestId(address user, uint256 amount) internal view returns (uint256) {
        return uint256(keccak256(abi.encodePacked(
            user,
            amount,
            block.number,
            msg.sender
        )));
    }

    /**
     * @notice Submit redeem request to receive USDT based on NAV.
     */
    function redeemToUSDT(uint256 artAmount)
    external
    onlyKYCApproved
    nonReentrant
    whenNotPaused
    whenRedeemOpen
    validAmount(artAmount)
    {
        _submitRedeem(usdt, usdtDecimals, artAmount);
    }

    /**
     * @notice Submit redeem request to receive USDC based on NAV.
     */
    function redeemToUSDC(uint256 artAmount)
    external
    onlyKYCApproved
    nonReentrant
    whenNotPaused
    whenRedeemOpen
    validAmount(artAmount)
    {
        _submitRedeem(usdc, usdcDecimals, artAmount);
    }

    /**
     * @dev Submit redeem request; burns ART now and records payout snapshot for off-chain settlement.
     */
    function _submitRedeem(IERC20 stable, uint8 dec, uint256 artAmount) internal {
        uint256 nav = _nav();
        if (nav == 0) revert InvalidNAV();

        (uint256 usdGross, uint256 feeUsd, uint256 usdNet) = _previewRedeemWithNAV(artAmount, nav);
        if (usdGross < minimumAmount) revert BelowMinimumAmount();

        // Burn ART from caller; accounting is handled in ART token
        artToken.burnFromVault(msg.sender, artAmount);

        // Informational token-out values (not transferred on-chain here)
        uint256 grossTokenOut = _scaleFromUsd6(usdGross, dec);
        uint256 feeTokenOut   = (grossTokenOut * redeemFeeBps) / BPS_DENOMINATOR;
        uint256 netTokenOut   = grossTokenOut - feeTokenOut;

        // Generate unique ID; revert if collision is detected (extremely unlikely)
        uint256 id = generateRequestId(msg.sender, artAmount);
        if (redeemRequests[id].id != 0) revert DuplicateRequestId(id);

        // Store request with settlement snapshot
        redeemRequests[id] = RedeemRequest({
            id: id,
            account: msg.sender,
            stableToken: address(stable),
            artAmount: artAmount,
            createdAt: uint64(block.timestamp),
            completedAt: 0,
            status: RedeemStatus.Pending,
            usdGross: usdGross,
            usdFee: feeUsd,
            tokenNetOut: netTokenOut
        });

        unchecked {
            allRedeemRequestIds.push(id);
            userRedeemRequestIds[msg.sender].push(id);
        }

        // Emit rich event for off-chain reconciliation
        emit RedeemRequested(
            id,
            msg.sender,
            address(stable),
            artAmount,
            usdGross,
            feeUsd,
            usdNet,
            grossTokenOut,
            feeTokenOut,
            netTokenOut
        );
    }

    /**
     * @dev Validate and record an off-chain transaction hash (string).
     *      Stores only the digest globally to prevent re-use across requests.
     */
    function _validateAndRecordTxHash(string calldata txHash) internal {
        if (bytes(txHash).length == 0) revert EmptyTransactionHash();
        bytes32 digest = keccak256(abi.encodePacked(txHash));
        if (usedTxDigests[digest]) {
            revert TransactionHashAlreadyUsed(txHash);
        }
        usedTxDigests[digest] = true;
    }

    /**
     * @dev Admin marks completion AFTER off-chain payout, and records the transfer tx hash.
     */
    function completeRedeem(uint256 redeemId, string calldata txHash)
    external
    onlyAdminOrOwner
    nonReentrant
    whenNotPaused
    whenRedeemOpen
    {
        RedeemRequest storage r = redeemRequests[redeemId];
        if (r.id == 0) revert InvalidRedeemId();
        if (r.status != RedeemStatus.Pending) revert InvalidStatus();
        if (kycEnforced && !registry.isKycApproved(r.account)) revert OnlyKYCApproved();

        // Validate and record off-chain transaction hash
        _validateAndRecordTxHash(txHash);
        redeemTxHash[redeemId] = txHash;
        emit RedeemTxHashRecorded(redeemId, txHash);

        // Mark completion
        r.status = RedeemStatus.Completed;
        r.completedAt = uint64(block.timestamp);

        emit RedeemCompleted(redeemId, r.account, r.stableToken, r.artAmount);
    }

    /**
     * @dev Admin may cancel a pending redeem: mint ART back to user (reverse previous burn).
     */
    function cancelRedeem(uint256 redeemId) external onlyAdminOrOwner nonReentrant {
        RedeemRequest storage r = redeemRequests[redeemId];
        if (r.id == 0) revert InvalidRedeemId();
        if (r.status != RedeemStatus.Pending) revert InvalidStatus();

        r.status = RedeemStatus.Cancelled;

        artToken.mintFromVault(r.account, r.artAmount);

        emit RedeemCancelled(redeemId, r.account, r.stableToken);
    }

    // ==================== Views (USD 6 decimals) ====================

    /**
     * @notice Preview ART amounts for a given USD deposit.
     */
    function previewMintART(uint256 usdAmount) public view returns (uint256 grossArt, uint256 feeArt, uint256 netArt) {
        uint256 nav = _nav();
        return _previewMintWithNAV(usdAmount, nav);
    }

    /**
     * @notice Preview USD amounts (USD 6 decimals) for a given ART redemption.
     */
    function previewRedeemUSD(uint256 artAmount) public view returns (uint256 usdGross, uint256 feeUsd, uint256 usdNet) {
        uint256 nav = _nav();
        return _previewRedeemWithNAV(artAmount, nav);
    }

    function previewMintARTTokenAmount(uint256 usdAmount, bool useUSDT) external view returns (uint256 tokenIn) {
        uint8 dec = useUSDT ? usdtDecimals : usdcDecimals;
        tokenIn = _scaleFromUsd6(usdAmount, dec);
    }

    function previewRedeemTokenAmount(uint256 artAmount, bool useUSDT)
    external
    view
    returns (uint256 grossTokenOut, uint256 feeTokenOut, uint256 netTokenOut)
    {
        (uint256 usdGross,,) = previewRedeemUSD(artAmount);
        uint8 dec = useUSDT ? usdtDecimals : usdcDecimals;
        grossTokenOut = _scaleFromUsd6(usdGross, dec);
        feeTokenOut   = (grossTokenOut * redeemFeeBps) / BPS_DENOMINATOR;
        netTokenOut   = grossTokenOut - feeTokenOut;
    }

    // ==================== Limits & Fees ====================

    function setMinimumAmount(uint256 newMinimum) external onlyAdminOrOwner validAmount(newMinimum) {
        minimumAmount = newMinimum;
    }

    function setFees(uint256 newMintFeeBps, uint256 newRedeemFeeBps) external onlyAdminOrOwner {
        if (newMintFeeBps > MAX_FEE_BPS || newRedeemFeeBps > MAX_FEE_BPS) revert InvalidFee();
        if (mintFeeBps == newMintFeeBps && redeemFeeBps == newRedeemFeeBps) return;
        uint256 oldMint = mintFeeBps;
        uint256 oldRedeem = redeemFeeBps;
        mintFeeBps = newMintFeeBps;
        redeemFeeBps = newRedeemFeeBps;
        emit FeesUpdated(oldMint, newMintFeeBps, oldRedeem, newRedeemFeeBps);
    }

    // ==================== Internal Helpers ====================

    function _scaleFromUsd6(uint256 usd6, uint8 tokenDec) internal pure returns (uint256) {
        if (tokenDec == USD_DECIMALS) return usd6;
        if (tokenDec > USD_DECIMALS) return usd6 * (10 ** (tokenDec - USD_DECIMALS));
        // tokenDec < 6 is forbidden by constructor; branch kept for completeness
        return usd6 / (10 ** (USD_DECIMALS - tokenDec));
    }

    function _nav() internal view returns (uint256) {
        // Read NAV (USD 6 decimals) from oracle; must be set beforehand
        return priceOracle.getPrice(address(artToken));
    }

    function _previewMintWithNAV(uint256 usdAmount, uint256 nav)
    internal
    view
    returns (uint256 grossArt, uint256 feeArt, uint256 netArt)
    {
        grossArt = (usdAmount * ONE_USD) / nav;
        feeArt = (grossArt * mintFeeBps) / BPS_DENOMINATOR;
        netArt = grossArt - feeArt;
    }

    function _previewRedeemWithNAV(uint256 artAmount, uint256 nav)
    internal
    view
    returns (uint256 usdGross, uint256 feeUsd, uint256 usdNet)
    {
        usdGross = (artAmount * nav) / ONE_USD;
        feeUsd = (usdGross * redeemFeeBps) / BPS_DENOMINATOR;
        usdNet = usdGross - feeUsd;
    }

    // ==================== Queries ====================

    /**
     * @dev Get a range of redeem request IDs with optional pending-only filter.
     * @param start Zero-based start index in allRedeemRequestIds.
     * @param limit Max number of IDs to return (capped by MAX_REQUEST_LIMIT).
     * @param onlyPending If true, only returns IDs currently in Pending status.
     */
    function getRedeemRequestIds(uint256 start, uint256 limit, bool onlyPending) external view returns (uint256[] memory) {
        uint256 totalRequests = allRedeemRequestIds.length;
        uint256[] memory result;

        if (limit > MAX_REQUEST_LIMIT) {
            limit = MAX_REQUEST_LIMIT;
        }
        if (start >= totalRequests || limit == 0) return new uint256[](0);

        uint256 availableItems;
        unchecked { availableItems = totalRequests - start; }
        uint256 maxItems = availableItems < limit ? availableItems : limit;

        // No filtering path
        if (!onlyPending) {
            result = new uint256[](maxItems);
            unchecked {
                for (uint256 i = 0; i < maxItems; i++) {
                    result[i] = allRedeemRequestIds[start + i];
                }
            }
            return result;
        }

        // Filtering path
        uint256 validCount = 0;
        uint256 endIndex = start + maxItems < totalRequests ? start + maxItems : totalRequests;
        unchecked {
            for (uint256 i = start; i < endIndex; i++) {
                uint256 id = allRedeemRequestIds[i];
                if (redeemRequests[id].status == RedeemStatus.Pending) {
                    validCount++;
                }
            }
        }

        result = new uint256[](validCount);
        if (validCount > 0) {
            uint256 out = 0;
            unchecked {
                for (uint256 i = start; i < endIndex && out < validCount; i++) {
                    uint256 id = allRedeemRequestIds[i];
                    if (redeemRequests[id].status == RedeemStatus.Pending) {
                        result[out++] = id;
                    }
                }
            }
        }
        return result;
    }

    /**
     * @dev Get total number of requests
     */
    function getRedeemRequestCount() external view returns (uint256) {
        return allRedeemRequestIds.length;
    }

    /**
     * @dev Get user's request list
     */
    function getUserRedeemRequestIds(address user, uint256 start, uint256 limit) external view returns (uint256[] memory) {
        if (limit > MAX_REQUEST_LIMIT) {
            limit = MAX_REQUEST_LIMIT;
        }
        uint256[] memory userRequests = userRedeemRequestIds[user];
        uint256 total = userRequests.length;
        if (start >= total || limit == 0) return new uint256[](0);

        uint256 availableItems;
        unchecked { availableItems = total - start; }
        uint256 maxItems = availableItems < limit ? availableItems : limit;

        uint256[] memory result = new uint256[](maxItems);
        unchecked {
            for (uint256 i = 0; i < maxItems; i++) {
                result[i] = userRequests[start + i];
            }
        }
        return result;
    }

    /**
     * @dev Get user request count
     */
    function getUserRedeemRequestCount(address user) external view returns (uint256) {
        return userRedeemRequestIds[user].length;
    }

    /**
     * @dev Get request details
     */
    function getRedeemRequest(uint256 redeemId) external view returns (RedeemRequest memory r) {
        r = redeemRequests[redeemId];
        if (r.id == 0) revert InvalidRedeemId();
    }

    // ==================== Emergency Control ====================

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