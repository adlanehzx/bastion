// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IPancakeRouterV2} from "../../src/interfaces/IPancakeRouterV2.sol";
import {MockERC20} from "./MockERC20.sol";
import {MockFeed} from "./MockFeed.sol";

/// Router that fills swaps at the mock oracle price times `qualityBps`, so tests can model a
/// fair pool (10_000), slippage (< 10_000) or a manipulated pool (very low quality).
contract MockRouter is IPancakeRouterV2 {
    mapping(address token => MockFeed) public feedOf;
    uint256 public qualityBps = 10_000;
    /// When false, the router ignores `amountOutMin` like a malicious or buggy router would.
    bool public enforceMinOut = true;
    address[] public lastPath;

    function setFeed(address token, MockFeed feed) external {
        feedOf[token] = feed;
    }

    function setQuality(uint256 qualityBps_) external {
        qualityBps = qualityBps_;
    }

    function setEnforceMinOut(bool enforce) external {
        enforceMinOut = enforce;
    }

    function lastPathLength() external view returns (uint256) {
        return lastPath.length;
    }

    function _quote(uint256 amountIn, address tokenIn, address tokenOut) internal view returns (uint256) {
        uint256 pIn = uint256(feedOf[tokenIn].answer());
        uint256 pOut = uint256(feedOf[tokenOut].answer());
        uint256 decIn = MockERC20(tokenIn).decimals();
        uint256 decOut = MockERC20(tokenOut).decimals();
        return (amountIn * pIn * 10 ** decOut) / (pOut * 10 ** decIn);
    }

    function getAmountsOut(uint256 amountIn, address[] calldata path)
        public
        view
        override
        returns (uint256[] memory amounts)
    {
        amounts = new uint256[](path.length);
        amounts[0] = amountIn;
        for (uint256 i = 1; i < path.length; ++i) {
            amounts[i] = _quote(amounts[i - 1], path[i - 1], path[i]);
        }
        amounts[path.length - 1] = (amounts[path.length - 1] * qualityBps) / 10_000;
    }

    function swapExactTokensForTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external override returns (uint256[] memory amounts) {
        require(block.timestamp <= deadline, "EXPIRED");
        amounts = getAmountsOut(amountIn, path);
        uint256 out = amounts[path.length - 1];
        require(!enforceMinOut || out >= amountOutMin, "INSUFFICIENT_OUTPUT_AMOUNT");
        lastPath = path;
        require(MockERC20(path[0]).transferFrom(msg.sender, address(this), amountIn), "TRANSFER_FAILED");
        MockERC20(path[path.length - 1]).mint(to, out);
    }
}
