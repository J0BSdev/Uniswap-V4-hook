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

import {DynamicLPFeesHook} from "../src/LPFees/DynamicLPFeesHook.sol";
import {MockChainlinkAggregator} from "../test/mocks/MockChainlinkAggregator.sol";
import {NetworkConfig} from "./NetworkConfig.sol";

/// @notice Full Base Sepolia deploy: mock Chainlink feeds + hook + pool init.
///
///   export PRIVATE_KEY=0x...
///   forge script script/DeployBaseSepolia.s.sol \
///     --rpc-url https://sepolia.base.org --broadcast --private-key $PRIVATE_KEY
///
/// Then seed liquidity (needs WETH + USDC on deployer):
///   HOOK_ADDR=0x... POOL_MANAGER=0x05E7... forge script script/SeedLiquidity.s.sol \
///     --rpc-url https://sepolia.base.org --broadcast --private-key $PRIVATE_KEY
contract DeployBaseSepolia is Script {
    using PoolIdLibrary for PoolKey;

    address internal constant CREATE2_DEPLOYER = 0x4e59b44847b379578588920cA78FbF26c0B4956C;
    int24 internal constant TICK_SPACING = 60;

    function run()
        external
        returns (address hookAddress, bytes32 poolId, address priceFeed, address sequencerFeed)
    {
        NetworkConfig.Config memory cfg = NetworkConfig.baseSepolia();
        int256 oraclePrice8 = vm.envOr("ORACLE_PRICE8", cfg.defaultOraclePrice8);

        vm.startBroadcast();
        (priceFeed, sequencerFeed) = _deployMocks(oraclePrice8);
        hookAddress = _deployHook(cfg, priceFeed, sequencerFeed);
        poolId = _initPool(cfg, hookAddress, oraclePrice8);
        vm.stopBroadcast();

        _logResults(cfg, hookAddress, poolId, priceFeed, sequencerFeed);
    }

    function _deployMocks(int256 oraclePrice8)
        internal
        returns (address priceFeed, address sequencerFeed)
    {
        MockChainlinkAggregator priceMock = new MockChainlinkAggregator();
        MockChainlinkAggregator sequencerMock = new MockChainlinkAggregator();
        priceFeed = address(priceMock);
        sequencerFeed = address(sequencerMock);

        uint256 now = block.timestamp;
        priceMock.setRound(oraclePrice8, now - 5000, now);
        sequencerMock.setRound(0, now - 5000, now);
    }

    function _deployHook(NetworkConfig.Config memory cfg, address priceFeed, address sequencerFeed)
        internal
        returns (address hookAddress)
    {
        IPoolManager manager = IPoolManager(cfg.poolManager);
        uint160 flags = uint160(Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG);
        bytes memory constructorArgs =
            abi.encode(manager, cfg.weth, cfg.usdc, priceFeed, sequencerFeed);

        (address mined, bytes32 salt) =
            HookMiner.find(CREATE2_DEPLOYER, flags, type(DynamicLPFeesHook).creationCode, constructorArgs);
        console2.log("Mined hook address:", mined);

        DynamicLPFeesHook hook = new DynamicLPFeesHook{salt: salt}(
            manager, cfg.weth, cfg.usdc, priceFeed, sequencerFeed
        );
        require(address(hook) == mined, "DeployScript: hook address mismatch");
        hookAddress = address(hook);
    }

    function _initPool(NetworkConfig.Config memory cfg, address hookAddress, int256 oraclePrice8)
        internal
        returns (bytes32 poolId)
    {
        IPoolManager manager = IPoolManager(cfg.poolManager);
        bool wethToken0 = NetworkConfig.wethIsCurrency0(cfg.weth, cfg.usdc);
        uint160 sqrtPriceX96 = NetworkConfig.sqrtPriceFromOracle(oraclePrice8, wethToken0);
        console2.log("Init oracle USD (1e8):", uint256(oraclePrice8));
        console2.log("Init sqrtPriceX96:", uint256(sqrtPriceX96));

        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(NetworkConfig.currency0(cfg.weth, cfg.usdc)),
            currency1: Currency.wrap(NetworkConfig.currency1(cfg.weth, cfg.usdc)),
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(hookAddress)
        });

        manager.initialize(key, sqrtPriceX96);
        poolId = PoolId.unwrap(key.toId());
    }

    function _logResults(
        NetworkConfig.Config memory cfg,
        address hookAddress,
        bytes32 poolId,
        address priceFeed,
        address sequencerFeed
    ) internal view {
        console2.log("==========================================================");
        console2.log("Base Sepolia deployment complete");
        console2.log("Mock ETH/USD feed:", priceFeed);
        console2.log("Mock sequencer feed:", sequencerFeed);
        console2.log("DynamicLPFeesHook:", hookAddress);
        console2.log("POOL_ID:", vm.toString(poolId));
        console2.log("PoolManager:", cfg.poolManager);
        console2.log("WETH:", cfg.weth);
        console2.log("USDC:", cfg.usdc);
        console2.log("Frontend env:");
        console2.log("  VITE_CHAIN_ID = 84532");
        console2.log("  VITE_HOOK_ADDRESS =", hookAddress);
        console2.logBytes32(poolId);
        console2.log("  VITE_POOL_ID (bytes32 above)");
        console2.log("  VITE_BASE_RPC_URL = https://sepolia.base.org");
        console2.log("  VITE_ETH_USD_FEED =", priceFeed);
        console2.log("  VITE_POOL_MANAGER =", cfg.poolManager);
        console2.log("==========================================================");
    }

}
