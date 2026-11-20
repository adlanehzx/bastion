// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script, console} from "forge-std/Script.sol";

import {Vault} from "../src/Vault.sol";
import {IAggregatorV3} from "../src/interfaces/IAggregatorV3.sol";
import {IPancakeRouterV2} from "../src/interfaces/IPancakeRouterV2.sol";
import {IWrappedNative} from "../src/interfaces/IWrappedNative.sol";

/// Deploys a vault owned by the broadcasting wallet and registers its Chainlink feeds.
///
/// Required env: ROUTER, WRAPPED_NATIVE, KEEPER.
/// Optional env: FEED_TOKENS and FEED_AGGREGATORS (comma-separated, same order),
///               FEED_MAX_AGE (seconds, default 86400).
///
///   forge script script/Deploy.s.sol --rpc-url $RPC_URL --account deployer --broadcast
contract Deploy is Script {
    function run() external returns (Vault vault) {
        address router = vm.envAddress("ROUTER");
        address wrappedNative = vm.envAddress("WRAPPED_NATIVE");
        address keeper = vm.envAddress("KEEPER");
        address[] memory tokens = vm.envOr("FEED_TOKENS", ",", new address[](0));
        address[] memory aggregators = vm.envOr("FEED_AGGREGATORS", ",", new address[](0));
        uint32 maxAge = uint32(vm.envOr("FEED_MAX_AGE", uint256(1 days)));
        require(tokens.length == aggregators.length, "FEED_TOKENS and FEED_AGGREGATORS differ in length");

        vm.startBroadcast();
        vault = new Vault(msg.sender, IPancakeRouterV2(router), IWrappedNative(wrappedNative), keeper);
        for (uint256 i; i < tokens.length; ++i) {
            vault.setFeed(tokens[i], IAggregatorV3(aggregators[i]), maxAge);
        }
        vm.stopBroadcast();

        console.log("Vault deployed at", address(vault));
        console.log("Owner", msg.sender, "keeper", keeper);
    }
}
