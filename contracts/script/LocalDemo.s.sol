// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script, console} from "forge-std/Script.sol";

import {Vault} from "../src/Vault.sol";
import {IPancakeRouterV2} from "../src/interfaces/IPancakeRouterV2.sol";
import {IWrappedNative} from "../src/interfaces/IWrappedNative.sol";
import {MockERC20, MockWrappedNative} from "../test/mocks/MockERC20.sol";
import {MockFeed} from "../test/mocks/MockFeed.sol";
import {MockRouter} from "../test/mocks/MockRouter.sol";

/// Local demo for anvil: mock market + vault with a DCA order (due now) and a limit buy
/// (not triggered). Used by `scripts/e2e.sh`; never deploy this on a real network.
contract LocalDemo is Script {
    function run() external {
        address keeper = vm.envAddress("KEEPER");

        vm.startBroadcast();
        MockWrappedNative wbnb = new MockWrappedNative();
        MockERC20 usdt = new MockERC20("Tether USD", "USDT", 18);
        MockFeed bnbFeed = new MockFeed(8, 600e8);
        MockFeed usdtFeed = new MockFeed(8, 1e8);
        MockRouter router = new MockRouter();
        router.setFeed(address(wbnb), bnbFeed);
        router.setFeed(address(usdt), usdtFeed);

        Vault vault =
            new Vault(msg.sender, IPancakeRouterV2(address(router)), IWrappedNative(address(wbnb)), keeper);
        vault.setFeed(address(wbnb), bnbFeed, 1 days);
        vault.setFeed(address(usdt), usdtFeed, 1 days);
        usdt.mint(address(vault), 1_000e18);

        vault.createDca(address(usdt), address(wbnb), 100e18, 1 days, 5, 100);
        vault.createPriceOrder(
            address(usdt), address(wbnb), 300e18, Vault.Trigger.PriceBelow, address(wbnb), 500e18, 100
        );
        vm.stopBroadcast();

        console.log("VAULT=%s", address(vault));
    }
}
