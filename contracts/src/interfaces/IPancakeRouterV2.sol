// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @notice Subset of the PancakeSwap V2 (Uniswap V2 fork) router used by the vault.
interface IPancakeRouterV2 {
    function getAmountsOut(uint256 amountIn, address[] calldata path)
        external
        view
        returns (uint256[] memory amounts);

    function swapExactTokensForTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external returns (uint256[] memory amounts);
}
