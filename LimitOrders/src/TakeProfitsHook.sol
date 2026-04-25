// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {BaseHook} from "@uniswap/v4-periphery/src/utils/BaseHook.sol";

import {ERC1155} from "@openzeppelin/contracts/token/ERC1155/ERC1155.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";

import {CurrencySettler} from "@uniswap/v4-core/test/utils/CurrencySettler.sol";

/// @title TakeProfitsHook
/// @notice Take-profit limit orders for a Uniswap V4 pool, executed when the
///         tick crosses the user-specified threshold during a swap.
contract TakeProfitsHook is BaseHook, ERC1155 {
    using StateLibrary for IPoolManager;
    using CurrencyLibrary for Currency;
    using CurrencySettler for Currency;

    // ─── Errors ──────────────────────────────────────────────────────────────
    error InsufficientBalance();
    error NothingToClaim();

    // ─── State ───────────────────────────────────────────────────────────────

    // poolId => tickToExecuteAt => zeroForOne => unfilled input amount
    mapping(PoolId poolId => mapping(int24 tickToExecuteAt => mapping(bool zeroForOne => uint256 inputAmount)))
        public pendingOrders;

    // positionId => total claim-token supply (== sum of inputs placed at that position)
    mapping(uint256 positionId => uint256 claimSupply) public claimTokenSupply;

    // positionId => total output tokens claimable across all holders of that position
    mapping(uint256 positionId => uint256 outputClaimable) public claimableOutputTokens;

    // poolId => last observed tick after a swap (used to detect crossings)
    mapping(PoolId poolId => int24 lastTick) public lastKnownTick;

    // ─── Constructor ─────────────────────────────────────────────────────────

    constructor(IPoolManager _manager, string memory _uri) BaseHook(_manager) ERC1155(_uri) {}

    // ─── Hook permissions ────────────────────────────────────────────────────

    function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: false,
            afterInitialize: true,
            beforeAddLiquidity: false,
            beforeRemoveLiquidity: false,
            afterAddLiquidity: false,
            afterRemoveLiquidity: false,
            beforeSwap: false,
            afterSwap: true,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: false,
            afterSwapReturnDelta: false,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    // ─── Hook callbacks ──────────────────────────────────────────────────────

    function _afterInitialize(address, PoolKey calldata key, uint160, int24 tick)
        internal
        override
        returns (bytes4)
    {
        lastKnownTick[key.toId()] = tick;
        return this.afterInitialize.selector;
    }

/**

so we're gonna go top-down
we'll create a black-box magic funstion that font exist





 */


    function afterSwap(
        address sender,
        PoolKey calldata key,
        SwapParams calldata,
        BalanceDelta,
        bytes calldata
    ) external override onlyPoolManager returns (bytes4, int128) {

        if (sender == address(this)) {
            return (this.afterSwap.selector, 0);
        }

        PoolId poolId = key.toId();
        int24 lastTick = lastKnownTick[poolId];
        (, int24 currentTick,,) = poolManager.getSlot0(poolId);

        // Try to fill any orders crossed by this swap. Each fill changes the price,
        // so loop until no more orders are crossable in the current tick range.
        bool tryMore = true;
        while (tryMore) {
            (tryMore, currentTick) = _tryExecutingOrders(key, currentTick, lastTick);
            lastTick = currentTick;
        }

        lastKnownTick[poolId] = currentTick;
        return (this.afterSwap.selector, 0);
    }

    // ─── Order placement ─────────────────────────────────────────────────────

    /// @notice Place a take-profit (limit) order.
    /// @param key            The pool key.
    /// @param tickToSellAt   The tick at which the user wants the order to fire.
    /// @param zeroForOne     True if selling currency0 for currency1.
    /// @param inputAmount    Amount of the input currency to sell.
    /// @return tickToExecuteAt The tick the order is actually pinned to (rounded down to a usable tick).
    function placeOrder(PoolKey calldata key, int24 tickToSellAt, bool zeroForOne, uint256 inputAmount)
        external
        returns (int24 tickToExecuteAt)
    {
        tickToExecuteAt = getLowerUsableTick(tickToSellAt, key.tickSpacing);

        pendingOrders[key.toId()][tickToExecuteAt][zeroForOne] += inputAmount;

        uint256 positionId = getPositionId(key, tickToExecuteAt, zeroForOne);
        claimTokenSupply[positionId] += inputAmount;
        _mint(msg.sender, positionId, inputAmount, "");

        address sellToken = zeroForOne ? Currency.unwrap(key.currency0) : Currency.unwrap(key.currency1);
        IERC20(sellToken).transferFrom(msg.sender, address(this), inputAmount);
    }

    // ─── Order cancellation ──────────────────────────────────────────────────

    function cancelOrder(PoolKey calldata key, int24 tick, bool zeroForOne, uint256 amountToCancel) external {
        int24 tickToExecuteAt = getLowerUsableTick(tick, key.tickSpacing);
        uint256 positionId = getPositionId(key, tickToExecuteAt, zeroForOne);

        uint256 positionTokens = balanceOf(msg.sender, positionId);
        if (positionTokens < amountToCancel) revert InsufficientBalance();

        pendingOrders[key.toId()][tickToExecuteAt][zeroForOne] -= amountToCancel;
        claimTokenSupply[positionId] -= amountToCancel;
        _burn(msg.sender, positionId, amountToCancel);

        Currency token = zeroForOne ? key.currency0 : key.currency1;
        token.transfer(msg.sender, amountToCancel);
    }

    // ─── Redemption ──────────────────────────────────────────────────────────

    function redeem(PoolKey calldata key, int24 tick, bool zeroForOne, uint256 inputAmountToClaimFor) external {
        int24 tickToExecuteAt = getLowerUsableTick(tick, key.tickSpacing);
        uint256 positionId = getPositionId(key, tickToExecuteAt, zeroForOne);

        if (claimableOutputTokens[positionId] == 0) revert NothingToClaim();

        uint256 positionTokens = balanceOf(msg.sender, positionId);
        if (positionTokens < inputAmountToClaimFor) revert InsufficientBalance();

        uint256 totalClaimableForPosition = claimableOutputTokens[positionId];
        uint256 totalInputAmountForPosition = claimTokenSupply[positionId];

        // outputAmountForUser = (inputAmountToClaimFor * totalClaimable) / totalInput
        uint256 outputAmountForUser = (inputAmountToClaimFor * totalClaimableForPosition) / totalInputAmountForPosition;

        claimableOutputTokens[positionId] -= outputAmountForUser;
        claimTokenSupply[positionId] -= inputAmountToClaimFor;
        _burn(msg.sender, positionId, inputAmountToClaimFor);

        Currency token = zeroForOne ? key.currency1 : key.currency0;
        token.transfer(msg.sender, outputAmountForUser);
    }

    // ─── Internal: order execution ───────────────────────────────────────────

    /// @dev Tries to execute one batch of pending orders that the latest swap crossed.
    ///      Returns (tryMore, newCurrentTick).
    function _tryExecutingOrders(PoolKey calldata key, int24 currentTick, int24 lastTick)
        internal
        returns (bool tryMore, int24 newTick)
    {
        PoolId poolId = key.toId();

        if (lastTick < currentTick) {
            // Price went up => we can fill zeroForOne orders sitting between lastTick and currentTick.
            for (int24 tick = lastTick; tick < currentTick; tick += key.tickSpacing) {
                uint256 inputAmount = pendingOrders[poolId][tick][true];
                if (inputAmount > 0) {
                    _executeOrder(key, tick, true, inputAmount);
                    (, int24 t,,) = poolManager.getSlot0(poolId);
                    return (true, t);
                }
            }
        } else if (lastTick > currentTick) {
            // Price went down => we can fill !zeroForOne orders sitting between currentTick and lastTick.
            for (int24 tick = lastTick; tick > currentTick; tick -= key.tickSpacing) {
                uint256 inputAmount = pendingOrders[poolId][tick][false];
                if (inputAmount > 0) {
                    _executeOrder(key, tick, false, inputAmount);
                    (, int24 t,,) = poolManager.getSlot0(poolId);
                    return (true, t);
                }
            }
        }

        return (false, currentTick);
    }

    function _executeOrder(PoolKey calldata key, int24 tick, bool zeroForOne, uint256 inputAmount) internal {
        BalanceDelta delta = _swapAndSettleBalances(
            key,
            SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: -int256(inputAmount),
                sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            })
        );

        pendingOrders[key.toId()][tick][zeroForOne] -= inputAmount;
        uint256 positionId = getPositionId(key, tick, zeroForOne);
        uint256 outputAmount =
            zeroForOne ? uint256(int256(delta.amount1())) : uint256(int256(delta.amount0()));

        claimableOutputTokens[positionId] += outputAmount;
    }

    function _swapAndSettleBalances(PoolKey calldata key, SwapParams memory params)
        internal
        returns (BalanceDelta delta)
    {
        // We are inside an unlocked PoolManager (called from afterSwap), so we can swap directly.
        delta = poolManager.swap(key, params, "");

        if (params.zeroForOne) {
            // amount0 is negative (we owe), amount1 is positive (we receive)
            key.currency0.settle(poolManager, address(this), uint256(uint128(-delta.amount0())), false);
            key.currency1.take(poolManager, address(this), uint256(uint128(delta.amount1())), false);
        } else {
            key.currency1.settle(poolManager, address(this), uint256(uint128(-delta.amount1())), false);
            key.currency0.take(poolManager, address(this), uint256(uint128(delta.amount0())), false);
        }
    }

    // ─── Helpers ─────────────────────────────────────────────────────────────

    /// @notice Round `tick` DOWN to the nearest multiple of `tickSpacing`.
    function getLowerUsableTick(int24 tick, int24 tickSpacing) public pure returns (int24) {
        int24 intervals = tick / tickSpacing;
        // Solidity truncates toward zero; for negative non-multiples we need to step one further down.
        if (tick < 0 && tick % tickSpacing != 0) {
            intervals--;
        }
        return intervals * tickSpacing;
    }

    function getPositionId(PoolKey calldata key, int24 tick, bool zeroForOne) public pure returns (uint256) {
        return uint256(keccak256(abi.encode(key.toId(), tick, zeroForOne)));
    }
}
