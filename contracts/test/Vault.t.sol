// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {Vault} from "../src/Vault.sol";
import {IPancakeRouterV2} from "../src/interfaces/IPancakeRouterV2.sol";
import {IWrappedNative} from "../src/interfaces/IWrappedNative.sol";
import {MockERC20, MockWrappedNative} from "./mocks/MockERC20.sol";
import {MockFeed} from "./mocks/MockFeed.sol";
import {MockRouter} from "./mocks/MockRouter.sol";

/// Shared setup: WBNB at 600 $, USDT at 1 $ (18 decimals, as on BSC), CAKE at 2 $.
abstract contract VaultFixture is Test {
    address internal owner = makeAddr("owner");
    address internal keeper = makeAddr("keeper");
    address internal stranger = makeAddr("stranger");

    MockWrappedNative internal wbnb;
    MockERC20 internal usdt;
    MockERC20 internal cake;
    MockFeed internal bnbFeed;
    MockFeed internal usdtFeed;
    MockFeed internal cakeFeed;
    MockRouter internal router;
    Vault internal vault;

    uint32 internal constant MAX_AGE = 1 hours;

    function setUp() public virtual {
        vm.warp(1_700_000_000);
        wbnb = new MockWrappedNative();
        usdt = new MockERC20("Tether USD", "USDT", 18);
        cake = new MockERC20("PancakeSwap", "CAKE", 18);
        bnbFeed = new MockFeed(8, 600e8);
        usdtFeed = new MockFeed(8, 1e8);
        cakeFeed = new MockFeed(8, 2e8);

        router = new MockRouter();
        router.setFeed(address(wbnb), bnbFeed);
        router.setFeed(address(usdt), usdtFeed);
        router.setFeed(address(cake), cakeFeed);

        vault = new Vault(owner, IPancakeRouterV2(address(router)), IWrappedNative(address(wbnb)), keeper);
        vm.startPrank(owner);
        vault.setFeed(address(wbnb), bnbFeed, MAX_AGE);
        vault.setFeed(address(usdt), usdtFeed, MAX_AGE);
        vault.setFeed(address(cake), cakeFeed, MAX_AGE);
        vm.stopPrank();

        usdt.mint(address(vault), 10_000e18);
    }

    function _dca(uint128 amount, uint32 interval, uint32 executions) internal returns (uint256) {
        vm.prank(owner);
        return vault.createDca(address(usdt), address(wbnb), amount, interval, executions, 100);
    }
}

contract VaultTest is VaultFixture {
    // ---------------------------------------------------------------- funds

    function test_depositNative_wrapsBnb() public {
        vm.deal(stranger, 2 ether);
        vm.prank(stranger);
        (bool ok,) = address(vault).call{value: 2 ether}("");
        assertTrue(ok);
        assertEq(wbnb.balanceOf(address(vault)), 2 ether);
    }

    function test_withdraw_onlyOwner() public {
        vm.prank(keeper);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, keeper));
        vault.withdraw(IERC20(address(usdt)), 1e18, keeper);

        vm.prank(owner);
        vault.withdraw(IERC20(address(usdt)), 1_000e18, owner);
        assertEq(usdt.balanceOf(owner), 1_000e18);
    }

    function test_withdrawNative_unwrapsToOwner() public {
        vm.deal(owner, 1 ether);
        vm.startPrank(owner);
        vault.depositNative{value: 1 ether}();
        vault.withdrawNative(0.4 ether, payable(owner));
        vm.stopPrank();
        assertEq(owner.balance, 0.4 ether);
        assertEq(wbnb.balanceOf(address(vault)), 0.6 ether);
    }

    // ---------------------------------------------------------------- access control

    function test_keeperCannotManageVault() public {
        vm.startPrank(keeper);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, keeper));
        vault.setKeeper(keeper);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, keeper));
        vault.createDca(address(usdt), address(wbnb), 1e18, 1 days, 1, 100);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, keeper));
        vault.setFeed(address(usdt), usdtFeed, 1);
        vm.stopPrank();
    }

    function test_onlyKeeperOrOwnerCanExecute() public {
        uint256 id = _dca(100e18, 1 days, 3);
        vm.prank(stranger);
        vm.expectRevert(Vault.NotExecutor.selector);
        vault.execute(id);

        vm.prank(owner);
        vault.execute(id);
    }

    function test_ownershipTransferIsTwoStep() public {
        vm.prank(owner);
        vault.transferOwnership(stranger);
        assertEq(vault.owner(), owner);
        vm.prank(stranger);
        vault.acceptOwnership();
        assertEq(vault.owner(), stranger);
    }

    // ---------------------------------------------------------------- order validation

    function test_createOrder_rejectsInvalidParameters() public {
        vm.startPrank(owner);
        vm.expectRevert(abi.encodeWithSelector(Vault.InvalidOrder.selector, "same token"));
        vault.createDca(address(usdt), address(usdt), 1e18, 1 days, 1, 100);
        vm.expectRevert(abi.encodeWithSelector(Vault.InvalidOrder.selector, "amount is zero"));
        vault.createDca(address(usdt), address(wbnb), 0, 1 days, 1, 100);
        vm.expectRevert(abi.encodeWithSelector(Vault.InvalidOrder.selector, "interval is zero"));
        vault.createDca(address(usdt), address(wbnb), 1e18, 0, 1, 100);
        vm.expectRevert(abi.encodeWithSelector(Vault.InvalidOrder.selector, "slippage above 10%"));
        vault.createDca(address(usdt), address(wbnb), 1e18, 1 days, 1, 1_001);

        MockERC20 unknown = new MockERC20("Unknown", "UNK", 18);
        vm.expectRevert(abi.encodeWithSelector(Vault.MissingFeed.selector, address(unknown)));
        vault.createDca(address(usdt), address(unknown), 1e18, 1 days, 1, 100);

        vm.expectRevert(abi.encodeWithSelector(Vault.InvalidOrder.selector, "price asset not in pair"));
        vault.createPriceOrder(
            address(usdt), address(wbnb), 1e18, Vault.Trigger.PriceBelow, address(cake), 500e18, 100
        );
        vm.expectRevert(abi.encodeWithSelector(Vault.InvalidOrder.selector, "use createDca for time orders"));
        vault.createPriceOrder(address(usdt), address(wbnb), 1e18, Vault.Trigger.Time, address(wbnb), 1, 100);
        vm.stopPrank();
    }

    // ---------------------------------------------------------------- DCA

    function test_dca_executesOncePerInterval() public {
        uint256 id = _dca(100e18, 1 days, 3);

        vm.prank(keeper);
        uint256 out = vault.execute(id);
        assertEq(out, uint256(100e18) * 1e8 / 600e8, "100 USDT at 600 $/BNB");
        assertEq(usdt.balanceOf(address(vault)), 9_900e18);

        vm.prank(keeper);
        vm.expectRevert(abi.encodeWithSelector(Vault.ConditionNotMet.selector, id));
        vault.execute(id);

        vm.warp(block.timestamp + 1 days);
        _refreshFeeds();
        vm.prank(keeper);
        vault.execute(id);
        assertEq(vault.getOrder(id).remaining, 1);
    }

    function test_dca_deactivatesAfterLastExecution() public {
        uint256 id = _dca(100e18, 1 hours, 2);
        vm.startPrank(keeper);
        vault.execute(id);
        vm.warp(block.timestamp + 1 hours);
        _refreshFeeds();
        vault.execute(id);
        assertFalse(vault.getOrder(id).active);
        vm.expectRevert(abi.encodeWithSelector(Vault.OrderInactive.selector, id));
        vault.execute(id);
        vm.stopPrank();
    }

    function test_insufficientBalance_reverts() public {
        uint256 id = _dca(20_000e18, 1 days, 1);
        assertFalse(vault.canExecute(id));
        vm.prank(keeper);
        vm.expectRevert(
            abi.encodeWithSelector(Vault.InsufficientBalance.selector, address(usdt), 20_000e18, 10_000e18)
        );
        vault.execute(id);
    }

    // ---------------------------------------------------------------- price orders

    function test_limitBuy_triggersOnlyBelowPrice() public {
        vm.prank(owner);
        uint256 id = vault.createPriceOrder(
            address(usdt), address(wbnb), 1_000e18, Vault.Trigger.PriceBelow, address(wbnb), 550e18, 100
        );
        assertFalse(vault.canExecute(id));
        vm.prank(keeper);
        vm.expectRevert(abi.encodeWithSelector(Vault.ConditionNotMet.selector, id));
        vault.execute(id);

        bnbFeed.set(540e8);
        assertTrue(vault.canExecute(id));
        vm.prank(keeper);
        uint256 out = vault.execute(id);
        assertEq(out, uint256(1_000e18) * 1e8 / 540e8);
        assertFalse(vault.getOrder(id).active, "price orders run once");
    }

    function test_stopLossAndTakeProfit() public {
        wbnb.mint(address(vault), 2e18);
        vm.startPrank(owner);
        uint256 stopLoss = vault.createPriceOrder(
            address(wbnb), address(usdt), 1e18, Vault.Trigger.PriceBelow, address(wbnb), 500e18, 200
        );
        uint256 takeProfit = vault.createPriceOrder(
            address(wbnb), address(usdt), 1e18, Vault.Trigger.PriceAbove, address(wbnb), 800e18, 200
        );
        vm.stopPrank();
        assertFalse(vault.canExecute(stopLoss));
        assertFalse(vault.canExecute(takeProfit));

        bnbFeed.set(850e8);
        assertFalse(vault.canExecute(stopLoss));
        vm.prank(keeper);
        assertEq(vault.execute(takeProfit), 850e18);

        bnbFeed.set(480e8);
        vm.prank(keeper);
        assertEq(vault.execute(stopLoss), 480e18);
    }

    function test_cancelledOrderCannotRun() public {
        uint256 id = _dca(100e18, 1 days, 5);
        vm.prank(owner);
        vault.cancelOrder(id);
        assertFalse(vault.canExecute(id));
        vm.prank(keeper);
        vm.expectRevert(abi.encodeWithSelector(Vault.OrderInactive.selector, id));
        vault.execute(id);
    }

    // ---------------------------------------------------------------- oracle safety

    function test_stalePrice_blocksExecution() public {
        vm.prank(owner);
        uint256 id = vault.createPriceOrder(
            address(usdt), address(wbnb), 100e18, Vault.Trigger.PriceBelow, address(wbnb), 700e18, 100
        );
        vm.warp(block.timestamp + MAX_AGE + 1);
        assertFalse(vault.canExecute(id));
        vm.prank(keeper);
        vm.expectRevert();
        vault.execute(id);
    }

    function test_invalidPrice_reverts() public {
        bnbFeed.set(0);
        vm.expectRevert(abi.encodeWithSelector(Vault.InvalidPrice.selector, address(wbnb), int256(0)));
        vault.price(address(wbnb));
    }

    function test_priceIsScaledTo18Decimals() public view {
        assertEq(vault.price(address(wbnb)), 600e18);
        assertEq(vault.price(address(usdt)), 1e18);
    }

    // ---------------------------------------------------------------- swap safety

    function test_manipulatedPool_revertsInsteadOfLosingFunds() public {
        uint256 id = _dca(1_000e18, 1 days, 1); // 1 % slippage allowed
        router.setQuality(9_800); // pool 2 % worse than the oracle (e.g. sandwich attack)
        vm.prank(keeper);
        vm.expectRevert("INSUFFICIENT_OUTPUT_AMOUNT");
        vault.execute(id);
        assertEq(usdt.balanceOf(address(vault)), 10_000e18, "nothing spent");
    }

    function test_vaultChecksReceivedAmountItself() public {
        uint256 id = _dca(1_000e18, 1 days, 1);
        router.setQuality(5_000);
        router.setEnforceMinOut(false); // router lies about enforcing amountOutMin
        vm.prank(keeper);
        vm.expectPartialRevert(Vault.SlippageExceeded.selector);
        vault.execute(id);
    }

    function test_withinSlippage_succeeds() public {
        uint256 id = _dca(1_000e18, 1 days, 1);
        router.setQuality(9_950); // 0.5 % worse, under the 1 % limit
        vm.prank(keeper);
        vault.execute(id);
        assertEq(usdt.allowance(address(vault), address(router)), 0, "approval reset");
    }

    function test_tokenToToken_routesThroughWbnb() public {
        vm.prank(owner);
        uint256 id = vault.createDca(address(usdt), address(cake), 100e18, 1 days, 1, 100);
        vm.prank(keeper);
        uint256 out = vault.execute(id);
        assertEq(router.lastPathLength(), 3);
        assertApproxEqRel(out, 50e18, 1e10, "100 USDT = 50 CAKE at 2 $ (two-hop rounding)");
    }

    function test_pause_blocksExecution() public {
        uint256 id = _dca(100e18, 1 days, 1);
        vm.prank(owner);
        vault.pause();
        assertFalse(vault.canExecute(id));
        vm.prank(keeper);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        vault.execute(id);
    }

    // ---------------------------------------------------------------- views

    function test_executableOrders_listsReadyOrders() public {
        uint256 a = _dca(100e18, 1 days, 2);
        vm.prank(owner);
        vault.createPriceOrder(
            address(usdt), address(wbnb), 100e18, Vault.Trigger.PriceBelow, address(wbnb), 500e18, 100
        );
        uint256 c = _dca(100e18, 1 days, 2);

        uint256[] memory ids = vault.executableOrders();
        assertEq(ids.length, 2);
        assertEq(ids[0], a);
        assertEq(ids[1], c);
    }

    // ---------------------------------------------------------------- fuzzing

    /// The minimum output always equals the oracle value of the input, minus slippage.
    function testFuzz_minAmountOut_matchesOracleValue(uint96 amountIn, uint64 bnbPrice, uint16 slippage)
        public
    {
        bnbPrice = uint64(bound(bnbPrice, 1e6, 1e14)); // 0.01 $ to 1 000 000 $
        slippage = uint16(bound(slippage, 0, vault.MAX_SLIPPAGE_BPS()));
        bnbFeed.set(int256(uint256(bnbPrice)));

        uint256 minOut = vault.minAmountOut(address(usdt), address(wbnb), amountIn, slippage);
        uint256 expected = uint256(amountIn) * 1e8 / bnbPrice;
        uint256 floor = expected * (10_000 - slippage) / 10_000;
        assertApproxEqAbs(minOut, floor, 1);
        assertLe(minOut, expected);
    }

    /// Whatever the pool quality, an execution either reverts or respects the slippage bound.
    function testFuzz_execution_neverWorseThanSlippage(uint16 quality, uint16 slippage) public {
        quality = uint16(bound(quality, 1, 10_000));
        slippage = uint16(bound(slippage, 0, vault.MAX_SLIPPAGE_BPS()));
        router.setQuality(quality);
        router.setEnforceMinOut(false);

        vm.prank(owner);
        uint256 id = vault.createDca(address(usdt), address(wbnb), 1_000e18, 1 days, 1, slippage);
        uint256 fair = uint256(1_000e18) * 1e8 / 600e8;

        vm.prank(keeper);
        try vault.execute(id) returns (uint256 out) {
            assertGe(out * 10_000, fair * (10_000 - slippage) - 10_000);
        } catch {
            assertEq(usdt.balanceOf(address(vault)), 10_000e18, "failed execution spends nothing");
        }
    }

    function _refreshFeeds() internal {
        bnbFeed.set(bnbFeed.answer());
        usdtFeed.set(usdtFeed.answer());
        cakeFeed.set(cakeFeed.answer());
    }
}
