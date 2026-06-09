// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console2} from "forge-std/Script.sol";

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {HookMiner} from "@uniswap/v4-periphery/src/utils/HookMiner.sol";
import {AggregatorV3Interface} from "@chainlink/contracts/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";

import {DynamicLPFeesHook} from "../src/LPFees/DynamicLPFeesHook.sol";
import {NetworkConfig} from "./NetworkConfig.sol";

/// @notice Mines a valid hook address, deploys DynamicLPFeesHook via CREATE2, and
/// initializes the WETH/USDC dynamic-fee pool at the current Chainlink ETH/USD price.
///
/// Run against a Base mainnet fork first (free):
///   anvil --fork-url $BASE_RPC_URL
///   forge script script/DeployDynamicLPFeesHook.s.sol \
///     --rpc-url http://127.0.0.1:8545 --broadcast \
///     --private-key 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80
///
/// Then mainnet (real ETH):
///   forge script script/DeployDynamicLPFeesHook.s.sol \
///     --rpc-url $BASE_RPC_URL --broadcast --private-key $PRIVATE_KEY --verify
contract DeployDynamicLPFeesHook is Script {
    using PoolIdLibrary for PoolKey;

    // CREATE2 Deployer Proxy (same address on every chain)
    address internal constant CREATE2_DEPLOYER = 0x4e59b44847b379578588920cA78FbF26c0B4956C;

    int24 internal constant TICK_SPACING = 60;

    function run() external returns (address hookAddress, bytes32 poolId) {
        NetworkConfig.Config memory cfg = NetworkConfig.baseMainnet();
        IPoolManager manager = IPoolManager(cfg.poolManager);

        // The deployed address must encode beforeInitialize + beforeSwap in its low bits.
        uint160 flags = uint160(Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG);
        bytes memory constructorArgs = abi.encode(
            manager, cfg.weth, cfg.usdc, cfg.ethUsdFeed, cfg.sequencerFeed
        );

        (address mined, bytes32 salt) =
            HookMiner.find(CREATE2_DEPLOYER, flags, type(DynamicLPFeesHook).creationCode, constructorArgs);
        console2.log("Mined hook address:", mined);

        bool wethToken0 = NetworkConfig.wethIsCurrency0(cfg.weth, cfg.usdc);
        uint160 sqrtPriceX96 = _sqrtPriceFromOracle(cfg.ethUsdFeed, wethToken0);
        console2.log("Init sqrtPriceX96:", uint256(sqrtPriceX96));

        vm.startBroadcast();

        DynamicLPFeesHook hook = new DynamicLPFeesHook{salt: salt}(
            manager, cfg.weth, cfg.usdc, cfg.ethUsdFeed, cfg.sequencerFeed
        );
        require(address(hook) == mined, "DeployScript: hook address mismatch");

        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(NetworkConfig.currency0(cfg.weth, cfg.usdc)),
            currency1: Currency.wrap(NetworkConfig.currency1(cfg.weth, cfg.usdc)),
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(address(hook))
        });

        manager.initialize(key, sqrtPriceX96);

        vm.stopBroadcast();

        hookAddress = address(hook);
        poolId = PoolId.unwrap(key.toId());

        console2.log("==========================================================");
        console2.log("DynamicLPFeesHook deployed:", hookAddress);
        console2.log("Pool initialized. Frontend env values:");
        console2.log("  VITE_HOOK_ADDRESS =", hookAddress);
        console2.log("  VITE_POOL_ID (bytes32):");
        console2.logBytes32(poolId);
        console2.log("==========================================================");
    }

    /// @dev Inverse of the hook's _getPoolPriceFromSqrtPriceX96 so the pool launches at
    /// (approximately) zero deviation from the oracle: sqrtP = sqrt(price8 * 2^192 / 1e20).
    function _sqrtPriceFromOracle(address feed, bool wethToken0) internal view returns (uint160) {
        (, int256 answer,,,) = AggregatorV3Interface(feed).latestRoundData();
        return NetworkConfig.sqrtPriceFromOracle(answer, wethToken0);
    }
}
