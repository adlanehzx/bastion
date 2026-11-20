// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";

import {Vault} from "../src/Vault.sol";
import {MockFeed} from "./mocks/MockFeed.sol";
import {MockRouter} from "./mocks/MockRouter.sol";
import {VaultFixture} from "./Vault.t.sol";

/// Drives the vault with random keeper actions, market moves and hostile pool behaviour.
contract KeeperHandler is Test {
    Vault internal vault;
    MockRouter internal router;
    MockFeed internal bnbFeed;
    MockFeed[] internal feeds;
    address internal keeper;

    uint256[] public orderIds;
    mapping(uint256 id => uint256) public executions;
    uint256 public slippageViolations;
    uint256 public successfulExecutions;

    constructor(
        Vault vault_,
        MockRouter router_,
        MockFeed bnbFeed_,
        MockFeed[] memory feeds_,
        address keeper_,
        uint256[] memory ids
    ) {
        vault = vault_;
        router = router_;
        bnbFeed = bnbFeed_;
        feeds = feeds_;
        keeper = keeper_;
        orderIds = ids;
    }

    function execute(uint256 seed) external {
        uint256 id = orderIds[seed % orderIds.length];
        Vault.Order memory o = vault.getOrder(id);
        uint256 fair;
        try vault.minAmountOut(o.tokenIn, o.tokenOut, o.amountIn, 0) returns (uint256 f) {
            fair = f;
        } catch {}

        vm.prank(keeper);
        try vault.execute(id) returns (uint256 out) {
            executions[id] += 1;
            successfulExecutions += 1;
            // Received amount must respect the owner's slippage against the oracle value.
            if (out * 10_000 + 10_000 < fair * (10_000 - o.slippageBps)) slippageViolations += 1;
        } catch {}
    }

    function passTime(uint256 seconds_) external {
        vm.warp(block.timestamp + bound(seconds_, 1 minutes, 3 days));
        for (uint256 i; i < feeds.length; ++i) {
            feeds[i].set(feeds[i].answer()); // feeds keep publishing
        }
    }

    function moveBnbPrice(uint256 price) external {
        bnbFeed.set(int256(bound(price, 300e8, 900e8)));
    }

    function degradePool(uint256 quality, bool honest) external {
        router.setQuality(bound(quality, 1, 10_000));
        router.setEnforceMinOut(honest);
    }

    function orderCount() external view returns (uint256) {
        return orderIds.length;
    }
}

contract VaultInvariantTest is VaultFixture {
    KeeperHandler internal handler;
    uint256[] internal ids;
    mapping(uint256 => uint32) internal initialExecutions;

    function setUp() public override {
        super.setUp();
        wbnb.mint(address(vault), 20e18);

        vm.startPrank(owner);
        ids.push(vault.createDca(address(usdt), address(wbnb), 200e18, 1 days, 10, 100));
        ids.push(vault.createDca(address(usdt), address(cake), 100e18, 12 hours, 10, 300));
        ids.push(
            vault.createPriceOrder(
                address(usdt), address(wbnb), 1_000e18, Vault.Trigger.PriceBelow, address(wbnb), 450e18, 100
            )
        );
        ids.push(
            vault.createPriceOrder(
                address(wbnb), address(usdt), 5e18, Vault.Trigger.PriceBelow, address(wbnb), 400e18, 200
            )
        );
        ids.push(
            vault.createPriceOrder(
                address(wbnb), address(usdt), 5e18, Vault.Trigger.PriceAbove, address(wbnb), 800e18, 200
            )
        );
        vm.stopPrank();
        for (uint256 i; i < ids.length; ++i) {
            initialExecutions[ids[i]] = vault.getOrder(ids[i]).remaining;
        }

        MockFeed[] memory all = new MockFeed[](3);
        all[0] = bnbFeed;
        all[1] = usdtFeed;
        all[2] = cakeFeed;
        handler = new KeeperHandler(vault, router, bnbFeed, all, keeper, ids);
        targetContract(address(handler));
    }

    /// Guards against a vacuous invariant suite: the handler really executes orders.
    function test_handlerExecutesOrders() public {
        handler.execute(0); // DCA, due immediately
        handler.moveBnbPrice(0); // 300 $: limit buy and stop-loss become due
        handler.execute(2);
        handler.execute(3);
        assertEq(handler.successfulExecutions(), 3);
    }

    /// The keeper never ends up holding any of the vault's tokens.
    function invariant_keeperNeverReceivesFunds() public view {
        assertEq(usdt.balanceOf(keeper), 0);
        assertEq(wbnb.balanceOf(keeper), 0);
        assertEq(cake.balanceOf(keeper), 0);
    }

    /// No successful execution is ever worse than the owner's slippage, even with a lying router.
    function invariant_noSlippageViolation() public view {
        assertEq(handler.slippageViolations(), 0);
    }

    /// Orders never run more times than the owner allowed, and `remaining` tracks executions.
    function invariant_executionsAreBounded() public view {
        for (uint256 i; i < ids.length; ++i) {
            Vault.Order memory o = vault.getOrder(ids[i]);
            assertEq(handler.executions(ids[i]) + o.remaining, initialExecutions[ids[i]]);
            if (o.remaining == 0) assertFalse(o.active);
        }
    }

    /// The vault never leaves an allowance to the router behind.
    function invariant_noDanglingApproval() public view {
        assertEq(usdt.allowance(address(vault), address(router)), 0);
        assertEq(wbnb.allowance(address(vault), address(router)), 0);
    }
}
