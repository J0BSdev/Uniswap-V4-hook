import {ERC1155} from "@openzeppelin/contracts/token/ERC1155/ERC1155.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";

import {PoolId,PoolIdLibrary} from "@uniswap/v4-core/src/libraries/PoolIdLibrary.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/libraries/CurrencyLibrary.sol";


import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";

import {FixedPointsMathLib} from "@uniswap/v4-core/src/libraries/FixedPointsMathLib.sol";
 

contract TakeProfitsHook is BaseHook, ERC1155 {

    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;
    using BalanceDeltaLibrary for BalanceDelta;

    error InsufficientBalance();


    mapping(PoolId poolId => mapping(int24 tickToExecuteAt => mapping(bool zeroForOne
     => uint256 inputAmount)))))) public pendingOrders;


     mapping(uint256 positionId => uint256 claimSupply) public claimTokenSupply;

     mapping(uint256 positionId => uint256 outputClaimable) public claimableOutputTokens;

 
 constructor(
    IpoolManager _manager,
    string memory _uri
 ) BaseHook(_manager) ERC1155(_uri){}



function getHookPermissions() public pure override returns (Hooks.Permissions memory) {

    returns Hooks.Permissions({
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

    function afterInitialize(
        address,
        PoolKey calldata,
        uint160,
        int24
    ) external override returns (bytes4) {

       return this.afterInitialize.selector;


    }




    function afterSwap(
        address sender,
        PoolKey calldata key,
        IPoolManager.SwapParams calldata params,
        BalanceDelta,
        bytes calldata external override onlyPoolManager returns (bytes4, int128) {
            //TODO
            return (this,afterSwap.selector);

            }



            // STEP ONE: PLACING ORDERS




            function placeOrder(PoolKey calldata key, int24 tickToSellaat, bool zeroForOne,uint256 inputAmount)external returns(int24){
                //round down their tick to the nearest "usable tick"
                int24 tickToExecuteAt = getLowerUsableTick(tickToSellaat, key.tickSpacing);


                //save their order in mapping
                pendingOrders[key.toId()][tickToExecuteAt][zeroForOne] += inputAmount;

                //mint claim token to user
                uint256 positionId = getPositionId(key, tickToExecuteAt, zeroForOne);
                claimTokenSupply[positionId] += inputAmount;
                _mint(msg.sender, positionId, inputAmount, "");

                //actually transfer the input token from user -> hook contract
                address sellToken = zeroForOne ? Currency.unwrap(key.currency0) : Currency.unwrap(key.currency1);
                IERC20(sellToken).transferFrom(msg.sender, address(this), inputAmount);

                return tickToExecuteAt;


            }






            //STEP TWO :CANCELING ORDERS


            function cancelOrder(PoolKey calldata key, int24 tick, 
            bool zeroForOne,uint256 amountToCancel )external{
                int24 tickToExecuteAt = getLowerUsableTick(tick, key.tickSpacing);
                uint256 positionId = getPositionId(key, tickToExecuteAt, zeroForOne);

                uint256 positionTokens = balanceOf(msg.sender, positionId);
                if (positionTokens < amountToCancel) revert InsufficientBalance();



                //update  pendinf order mapping
                pendingOrders[key.toId()][tickToExecuteAt][zeroForOne] -= amountToCancel;
                claimTokenSupply[positionId] -= amountToCancel;
                _burn(msg.sender, positionId, amountToCancel);

                //send them back their underliying actual ERC-20 token

                Currency token = zeroForOne ? key.currency0 : key.currency1;
                token.transfer(msg.sender, amountToCancel);


            }



//STEP THREE : REDEMPTION


function redeem(PoolKey calldata key, int24 tick, bool zeroForOne,uint256 inputAmountToClaimFor)external{
int24 tickToExecuteAt = getLowerUsableTick(tick, key.tickSpacing);
uint256 positionId = getPositionId(key, tickToExecuteAt, zeroForOne);


//there must to be something to redeem in the first place

if(claimableOutputTokens[positionId] == 0 ) revert InsufficientBalance();

// they must have claim tokens >= input to claim for
uint256 positionTokens = balanceOf(msg.sender, positionId);
if(positionTokens < inputAmountToClaimFor) revert InsufficientBalance();

//calculate how much output tokens are actually theirs
uint256 totaolClaimableForPositon = claimableOutputTokens[positionId];
uint256 totalInputAmountForPositon = claimTokenSupply[positionId];

//outputAmountForUser = (inputAmountToClaimFor * totalClaimableForPositon) / totalInputaAmountForPosition
uint256 outputAmountForUser = (inputAmountToClaimFor * totalClaimableForPositon) / totalInputAmountForPositon;
  

  //reduce claimable output tokens 
  //reduce claim tokens total supply
  //burn claim tokens
  //transfer output tokens
  claimableOutputTokens[positionId] -= outputAmountForUser;
  claimTokenSupply[positionId] -= inputAmountToClaimFor;
  _burn(msg.sender, positionId, inputAmountToClaimFor);

  Currency token = zeroForOne ? key.currency1 : key.currency0;
  token.transfer(msg.sender, outputAmountForUser);

}




function executeOrder(PoolKey calldata key, int24 tick, bool zeroForOne,uint256 inputAmount)internal{
    //actually do the swap
    //settle balances for the swap against the pool manager

    BalanceDelta delta = swapAndSettleBalances(
        key, 
        IPoolManager.SwapParams({
            zeroForOne: zeroForOne,
            amountSpecified: -int256(inputAmount),
            sqrtPriceLimitX96: zeroForOne 
            ? TickMath.MIN_SQRT_PRICE + 1 
            :TickMath.MAX_SQRT_PRICE - 1,
            
        }),

    );



    //update our mappings properly
    pendingOrders[key.toId()][tick][zeroForOne] -= inputAmount;
    uint256 positionId = getPositionId(key, tick, zeroForOne);
    uint256 outputAmount = zeroForOne ?
    uint256 (int256(delta.amount1())) :
    uint256 (int256(delta.amount0()));

    claimableOutputTokens[positionId] += outputAmount;

    

}


function swapAndSettleBalances(PoolKey calldata key, 
IPoolManager.SwapParams memory params)
internal returns (BalanceDelta) {

//we dont need tro unlock pool manager in this case
//because hook is already operating INSIDE of an unlocked pool

BalanceDelta delta = IPoolManager.swap(key,params,"");

//setle balances
if (params.zeroForOne) {


    //amount0 will be negative 


    _settle(key.currency0,uint128(-delta.amount0()));
    _take(key.currency1,uint128(delta.amount1()));

} else {

    _settle(key.currency1,uint128(-delta.amount1()));
    _take(key.currency0,uint128(delta.amount0()));


}


//settle
  //sending money from swapper -> PM
  //take
    //taking money form PM -> swapper


    
}


            //HELPERS 

            function getLowerUsableTick( int24 tick,int24 tickSpacing) private pure returns
             (int24) {

                //e.g tickSpacing =60
                // tick = 100
                // round down to 60 


                //tick = -120
                // round down to -120



//100 /60 = 1 (integer division)
    int24 intervals = tick / tickSpacing;


    if (tick< 0 && tick % tickSpacing != 0) intervals -- {


    // - 60
    return intervals * tickSpacing;


    



    }



    function getPositionId(PoolKey calldata key, int24 tick, bool zeroForOne)public pure returns (uint256) {
        return uint256(keccak256(abi.encode(key.toId(), tick, zeroForOne)));

    }







}





  
