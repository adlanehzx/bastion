// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Ownable, Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";

import {IPancakeRouterV2} from "./interfaces/IPancakeRouterV2.sol";
import {IAggregatorV3} from "./interfaces/IAggregatorV3.sol";
import {IWrappedNative} from "./interfaces/IWrappedNative.sol";

/// @title Bastion Vault
/// @author Adlane Hamzaoui
/// @notice Personal vault that executes the owner's trading orders automatically:
///         DCA (time-based), limit orders, stop-loss and take-profit (price-based).
/// @dev Trust model:
///      - The owner deposits, withdraws and manages orders.
///      - The keeper (an off-chain bot) can only call `execute`, and only when the order's
///        condition holds. It can never move funds anywhere but into a swap whose minimum
///        output is derived from Chainlink prices, so a compromised keeper or a manipulated
///        pool cannot drain the vault beyond the slippage chosen by the owner.
contract Vault is Ownable2Step, Pausable, ReentrancyGuard {
    using SafeERC20 for IERC20;
    using SafeCast for uint256;

    enum Trigger {
        Time, // DCA: every `interval` seconds
        PriceAbove, // take-profit / limit sell: price of `priceAsset` >= triggerPrice
        PriceBelow // stop-loss / limit buy: price of `priceAsset` <= triggerPrice
    }

    struct Order {
        address tokenIn;
        address tokenOut;
        address priceAsset; // token whose USD price is compared (price triggers only)
        uint128 amountIn; // spent at each execution
        uint128 triggerPrice; // USD, 18 decimals (price triggers only)
        uint32 interval; // seconds between executions (Time trigger only)
        uint32 nextExecution; // earliest timestamp of the next execution
        uint32 remaining; // executions left
        uint16 slippageBps; // max loss versus the oracle quote
        Trigger trigger;
        bool active;
    }

    struct Feed {
        IAggregatorV3 aggregator;
        uint32 maxAge; // seconds after which a price is considered stale
    }

    uint16 public constant MAX_SLIPPAGE_BPS = 1_000; // 10 %
    uint256 private constant BPS = 10_000;

    IPancakeRouterV2 public immutable router;
    IWrappedNative public immutable wrappedNative;

    address public keeper;
    mapping(address token => Feed) public feeds;
    Order[] private _orders;

    event KeeperUpdated(address indexed keeper);
    event FeedUpdated(address indexed token, address indexed aggregator, uint32 maxAge);
    event NativeDeposited(address indexed from, uint256 amount);
    event Withdrawn(address indexed token, address indexed to, uint256 amount);
    event OrderCreated(
        uint256 indexed id, Trigger trigger, address tokenIn, address tokenOut, uint256 amountIn
    );
    event OrderCancelled(uint256 indexed id);
    event OrderExecuted(uint256 indexed id, uint256 amountIn, uint256 amountOut, uint256 minAmountOut);

    error NotExecutor();
    error InvalidOrder(string reason);
    error UnknownOrder(uint256 id);
    error OrderInactive(uint256 id);
    error ConditionNotMet(uint256 id);
    error InsufficientBalance(address token, uint256 needed, uint256 available);
    error MissingFeed(address token);
    error StalePrice(address token, uint256 updatedAt);
    error InvalidPrice(address token, int256 answer);
    error SlippageExceeded(uint256 received, uint256 minimum);
    error ZeroAddress();
    error NativeTransferFailed();

    modifier onlyExecutor() {
        _checkExecutor();
        _;
    }

    constructor(address owner_, IPancakeRouterV2 router_, IWrappedNative wrappedNative_, address keeper_)
        Ownable(owner_)
    {
        if (address(router_) == address(0) || address(wrappedNative_) == address(0)) revert ZeroAddress();
        router = router_;
        wrappedNative = wrappedNative_;
        keeper = keeper_;
        emit KeeperUpdated(keeper_);
    }

    // ---------------------------------------------------------------------------------------------
    // Funds
    // ---------------------------------------------------------------------------------------------

    /// @notice Native BNB is wrapped on arrival so the vault only ever holds ERC-20 tokens.
    receive() external payable {
        if (msg.sender != address(wrappedNative)) depositNative();
    }

    function depositNative() public payable {
        wrappedNative.deposit{value: msg.value}();
        emit NativeDeposited(msg.sender, msg.value);
    }

    /// @notice ERC-20 deposits are plain transfers to the vault address.
    function withdraw(IERC20 token, uint256 amount, address to) external onlyOwner nonReentrant {
        if (to == address(0)) revert ZeroAddress();
        token.safeTransfer(to, amount);
        emit Withdrawn(address(token), to, amount);
    }

    function withdrawNative(uint256 amount, address payable to) external onlyOwner nonReentrant {
        if (to == address(0)) revert ZeroAddress();
        wrappedNative.withdraw(amount);
        (bool ok,) = to.call{value: amount}("");
        if (!ok) revert NativeTransferFailed();
        emit Withdrawn(address(0), to, amount);
    }

    // ---------------------------------------------------------------------------------------------
    // Configuration
    // ---------------------------------------------------------------------------------------------

    function setKeeper(address keeper_) external onlyOwner {
        keeper = keeper_;
        emit KeeperUpdated(keeper_);
    }

    /// @param maxAge Maximum age of a price, typically the feed heartbeat plus a margin.
    function setFeed(address token, IAggregatorV3 aggregator, uint32 maxAge) external onlyOwner {
        if (token == address(0)) revert ZeroAddress();
        feeds[token] = Feed({aggregator: aggregator, maxAge: maxAge});
        emit FeedUpdated(token, address(aggregator), maxAge);
    }

    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }

    // ---------------------------------------------------------------------------------------------
    // Orders
    // ---------------------------------------------------------------------------------------------

    /// @notice Buys `amountIn` of `tokenIn` worth of `tokenOut` every `interval` seconds.
    function createDca(
        address tokenIn,
        address tokenOut,
        uint128 amountIn,
        uint32 interval,
        uint32 executions,
        uint16 slippageBps
    ) external onlyOwner returns (uint256 id) {
        if (interval == 0) revert InvalidOrder("interval is zero");
        Order memory o = _baseOrder(tokenIn, tokenOut, amountIn, executions, slippageBps);
        o.trigger = Trigger.Time;
        o.interval = interval;
        o.nextExecution = block.timestamp.toUint32();
        id = _store(o);
    }

    /// @notice Swaps once the USD price of `priceAsset` crosses `triggerPrice`.
    ///         Limit buy / stop-loss use `PriceBelow`, take-profit / limit sell use `PriceAbove`.
    function createPriceOrder(
        address tokenIn,
        address tokenOut,
        uint128 amountIn,
        Trigger trigger,
        address priceAsset,
        uint128 triggerPrice,
        uint16 slippageBps
    ) external onlyOwner returns (uint256 id) {
        if (trigger == Trigger.Time) revert InvalidOrder("use createDca for time orders");
        if (priceAsset != tokenIn && priceAsset != tokenOut) revert InvalidOrder("price asset not in pair");
        if (triggerPrice == 0) revert InvalidOrder("trigger price is zero");
        Order memory o = _baseOrder(tokenIn, tokenOut, amountIn, 1, slippageBps);
        o.trigger = trigger;
        o.priceAsset = priceAsset;
        o.triggerPrice = triggerPrice;
        id = _store(o);
    }

    function cancelOrder(uint256 id) external onlyOwner {
        Order storage o = _order(id);
        if (!o.active) revert OrderInactive(id);
        o.active = false;
        emit OrderCancelled(id);
    }

    /// @notice Executes an order whose condition holds. Callable by the keeper or the owner.
    function execute(uint256 id)
        external
        onlyExecutor
        whenNotPaused
        nonReentrant
        returns (uint256 amountOut)
    {
        Order storage o = _order(id);
        if (!o.active) revert OrderInactive(id);
        if (!_conditionMet(o)) revert ConditionNotMet(id);

        uint256 amountIn = o.amountIn;
        uint256 available = IERC20(o.tokenIn).balanceOf(address(this));
        if (available < amountIn) revert InsufficientBalance(o.tokenIn, amountIn, available);

        // Effects before the external swap (checks-effects-interactions).
        o.remaining -= 1;
        if (o.remaining == 0) o.active = false;
        if (o.trigger == Trigger.Time) o.nextExecution = (block.timestamp + o.interval).toUint32();

        uint256 minOut = minAmountOut(o.tokenIn, o.tokenOut, amountIn, o.slippageBps);
        amountOut = _swap(o.tokenIn, o.tokenOut, amountIn, minOut);
        emit OrderExecuted(id, amountIn, amountOut, minOut);
    }

    // ---------------------------------------------------------------------------------------------
    // Views
    // ---------------------------------------------------------------------------------------------

    function orderCount() external view returns (uint256) {
        return _orders.length;
    }

    function getOrder(uint256 id) external view returns (Order memory) {
        return _order(id);
    }

    /// @notice True when `execute(id)` would pass its checks (the swap itself may still fail).
    function canExecute(uint256 id) public view returns (bool) {
        if (paused() || id >= _orders.length) return false;
        Order storage o = _orders[id];
        if (!o.active) return false;
        if (IERC20(o.tokenIn).balanceOf(address(this)) < o.amountIn) return false;
        try this.conditionMet(id) returns (bool met) {
            return met;
        } catch {
            return false; // stale or invalid price
        }
    }

    /// @notice Ids of the orders the keeper should execute now.
    function executableOrders() external view returns (uint256[] memory ids) {
        uint256 count;
        uint256[] memory buffer = new uint256[](_orders.length);
        for (uint256 i; i < _orders.length; ++i) {
            if (canExecute(i)) buffer[count++] = i;
        }
        ids = new uint256[](count);
        for (uint256 i; i < count; ++i) {
            ids[i] = buffer[i];
        }
    }

    function conditionMet(uint256 id) external view returns (bool) {
        return _conditionMet(_order(id));
    }

    /// @notice Chainlink price of `token` in USD, scaled to 18 decimals. Reverts when stale.
    function price(address token) public view returns (uint256) {
        Feed memory feed = feeds[token];
        if (address(feed.aggregator) == address(0)) revert MissingFeed(token);
        (, int256 answer,, uint256 updatedAt,) = feed.aggregator.latestRoundData();
        if (answer <= 0) revert InvalidPrice(token, answer);
        if (updatedAt == 0 || updatedAt > block.timestamp || block.timestamp - updatedAt > feed.maxAge) {
            revert StalePrice(token, updatedAt);
        }
        uint8 decimals = feed.aggregator.decimals();
        // casting to 'uint256' is safe because `answer` was checked to be strictly positive above
        // forge-lint: disable-next-line(unsafe-typecast)
        uint256 value = uint256(answer);
        return decimals <= 18 ? value * 10 ** (18 - decimals) : value / 10 ** (decimals - 18);
    }

    /// @notice Minimum output accepted for a swap: oracle value of `amountIn`, minus slippage.
    function minAmountOut(address tokenIn, address tokenOut, uint256 amountIn, uint16 slippageBps)
        public
        view
        returns (uint256)
    {
        uint256 decIn = IERC20Metadata(tokenIn).decimals();
        uint256 decOut = IERC20Metadata(tokenOut).decimals();
        // USD value of amountIn (18 decimals), then converted to tokenOut units.
        uint256 usd = Math.mulDiv(amountIn, price(tokenIn), 10 ** decIn);
        uint256 expectedOut = Math.mulDiv(usd, 10 ** decOut, price(tokenOut));
        return Math.mulDiv(expectedOut, BPS - slippageBps, BPS);
    }

    // ---------------------------------------------------------------------------------------------
    // Internals
    // ---------------------------------------------------------------------------------------------

    function _checkExecutor() private view {
        if (msg.sender != keeper && msg.sender != owner()) revert NotExecutor();
    }

    function _baseOrder(
        address tokenIn,
        address tokenOut,
        uint128 amountIn,
        uint32 executions,
        uint16 slippageBps
    ) private view returns (Order memory o) {
        if (tokenIn == address(0) || tokenOut == address(0)) revert ZeroAddress();
        if (tokenIn == tokenOut) revert InvalidOrder("same token");
        if (amountIn == 0) revert InvalidOrder("amount is zero");
        if (executions == 0) revert InvalidOrder("no execution");
        if (slippageBps > MAX_SLIPPAGE_BPS) revert InvalidOrder("slippage above 10%");
        if (address(feeds[tokenIn].aggregator) == address(0)) revert MissingFeed(tokenIn);
        if (address(feeds[tokenOut].aggregator) == address(0)) revert MissingFeed(tokenOut);
        o.tokenIn = tokenIn;
        o.tokenOut = tokenOut;
        o.amountIn = amountIn;
        o.remaining = executions;
        o.slippageBps = slippageBps;
        o.active = true;
    }

    function _store(Order memory o) private returns (uint256 id) {
        id = _orders.length;
        _orders.push(o);
        emit OrderCreated(id, o.trigger, o.tokenIn, o.tokenOut, o.amountIn);
    }

    function _order(uint256 id) private view returns (Order storage) {
        if (id >= _orders.length) revert UnknownOrder(id);
        return _orders[id];
    }

    function _conditionMet(Order storage o) private view returns (bool) {
        if (o.trigger == Trigger.Time) return block.timestamp >= o.nextExecution;
        uint256 current = price(o.priceAsset);
        return o.trigger == Trigger.PriceAbove ? current >= o.triggerPrice : current <= o.triggerPrice;
    }

    function _path(address tokenIn, address tokenOut) private view returns (address[] memory path) {
        address hub = address(wrappedNative);
        if (tokenIn == hub || tokenOut == hub) {
            path = new address[](2);
            path[0] = tokenIn;
            path[1] = tokenOut;
        } else {
            path = new address[](3);
            path[0] = tokenIn;
            path[1] = hub;
            path[2] = tokenOut;
        }
    }

    function _swap(address tokenIn, address tokenOut, uint256 amountIn, uint256 minOut)
        private
        returns (uint256 received)
    {
        IERC20(tokenIn).forceApprove(address(router), amountIn);
        uint256 before = IERC20(tokenOut).balanceOf(address(this));
        router.swapExactTokensForTokens(
            amountIn, minOut, _path(tokenIn, tokenOut), address(this), block.timestamp
        );
        IERC20(tokenIn).forceApprove(address(router), 0);
        // Measured, not trusted from the router's return value.
        received = IERC20(tokenOut).balanceOf(address(this)) - before;
        if (received < minOut) revert SlippageExceeded(received, minOut);
    }
}
