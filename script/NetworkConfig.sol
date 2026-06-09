// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";

/// @notice Chain-specific addresses for DynamicLPFeesHook deployment.
library NetworkConfig {
    struct Config {
        address poolManager;
        address weth;
        address usdc;
        /// @dev address(0) means "deploy a MockChainlinkAggregator at runtime"
        address ethUsdFeed;
        /// @dev address(0) means "deploy a mock sequencer feed (always up)"
        address sequencerFeed;
        /// @dev Used when deploying mock price feed (1e8 scale)
        int256 defaultOraclePrice8;
    }

    function baseMainnet() internal pure returns (Config memory) {
        return Config({
            poolManager: 0x498581fF718922c3f8e6A244956aF099B2652b2b,
            weth: 0x4200000000000000000000000000000000000006,
            usdc: 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913,
            ethUsdFeed: 0x71041dddad3595F9CEd3DcCFBe3D1F4b0a16Bb70,
            sequencerFeed: 0xBCF85224fc0756B9Fa45aA7892530B47e10b6433,
            defaultOraclePrice8: 0
        });
    }

    function baseSepolia() internal pure returns (Config memory) {
        return Config({
            poolManager: 0x05E73354cFDd6745C338b50BcFDfA3Aa6fA03408,
            weth: 0x4200000000000000000000000000000000000006,
            usdc: 0x036CbD53842c5426634e7929541eC2318f3dCF7e,
            ethUsdFeed: address(0),
            sequencerFeed: address(0),
            defaultOraclePrice8: 3500e8
        });
    }

    function wethIsCurrency0(address weth, address usdc) internal pure returns (bool) {
        return weth < usdc;
    }

    function currency0(address weth, address usdc) internal pure returns (address) {
        return weth < usdc ? weth : usdc;
    }

    function currency1(address weth, address usdc) internal pure returns (address) {
        return weth < usdc ? usdc : weth;
    }

    /// @dev sqrtPriceX96 so pool ETH/USD (1e8) matches `oraclePrice8` for the sorted pair order.
    function sqrtPriceFromOracle(int256 oraclePrice8, bool wethToken0) internal pure returns (uint160) {
        require(oraclePrice8 > 0, "NetworkConfig: bad oracle");
        uint256 target;
        if (wethToken0) {
            target = FullMath.mulDiv(uint256(oraclePrice8), 1 << 192, 1e20);
        } else {
            target = FullMath.mulDiv(1e26, 1 << 192, uint256(oraclePrice8) * 1e6);
        }
        uint256 root = _sqrt(target);
        require(root <= type(uint160).max, "NetworkConfig: sqrt overflow");
        return uint160(root);
    }

    function _sqrt(uint256 x) private pure returns (uint256 z) {
        if (x == 0) return 0;
        z = (x + 1) / 2;
        uint256 y = x;
        while (z < y) {
            y = z;
            z = (x / z + z) / 2;
        }
        return y;
    }
}
