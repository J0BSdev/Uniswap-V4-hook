import {Test} from "forge-std/Test.sol";
import {console} from "forge-std/console.sol";
import {Deployers} from "../lib/v4-hooks-public/test/Deployers.sol";
import {MockERC20} from "solmate/test/utils/mocks/MockERC20.sol";
import {PoolManager} from "../lib/v4-core/src/test/PoolManager.sol";
import {Currency, CurrencyLibrary} from "../lib/v4-core/src/test/Currency.sol";
import {PoolId, PoolIdLibrary} from "../lib/v4-core/src/test/PoolId.sol";
import {PoolSwapTest} from "../lib/v4-core/src/test/PoolSwapTest.sol";
import {GasPriceFeesHook} from "../src/GasPriceFeesHook.sol";
import {TickMath} from "../lib/v4-core/src/libraries/TickMath.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";

contract GasPriceFeesHookTest is Test {
    GasPriceFeesHook public gasPriceFeesHook;
}