// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {AggregatorV3Interface} from "@chainlink/contracts/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";

/// @notice Finds the implementation storage slot holding the Chainlink `answer` and optionally
/// writes a new price. Used by setup-fork.sh and fork oracle nudging from the frontend.
///   NEW_ANSWER=170000000000 forge script script/NudgeOracle.s.sol --rpc-url http://127.0.0.1:8545
///   DELTA_BPS=100 forge script script/NudgeOracle.s.sol --rpc-url http://127.0.0.1:8545
contract NudgeOracle is Script {
    address internal constant FEED = 0x71041dddad3595F9CEd3DcCFBe3D1F4b0a16Bb70;

    function run() external {
        (, int256 answer,, uint256 updatedAt,) = AggregatorV3Interface(FEED).latestRoundData();

        int256 newAnswer = answer;
        if (vm.envOr("NEW_ANSWER", int256(0)) != 0) {
            newAnswer = vm.envInt("NEW_ANSWER");
        } else if (vm.envOr("DELTA_BPS", int256(0)) != 0) {
            int256 delta = vm.envInt("DELTA_BPS");
            newAnswer = answer * (10_000 + delta) / 10_000;
        }

        address impl = address(uint160(uint256(vm.load(FEED, bytes32(uint256(0))))));

        uint256 answerSlot = type(uint256).max;
        for (uint256 s = 0; s < 128; s++) {
            bytes32 v = vm.load(impl, bytes32(s));
            if (int256(uint256(v)) == answer) {
                answerSlot = s;
                break;
            }
        }
        require(answerSlot != type(uint256).max, "NudgeOracle: answer slot not found");

        vm.store(impl, bytes32(answerSlot), bytes32(uint256(newAnswer)));

        // Keep updatedAt fresh so the hook does not revert StaleOraclePrice.
        for (uint256 s = 0; s < 128; s++) {
            bytes32 v = vm.load(impl, bytes32(s));
            if (uint256(v) == updatedAt) {
                vm.store(impl, bytes32(s), bytes32(block.timestamp));
                break;
            }
        }

        console2.log("Oracle answer slot:", answerSlot);
        console2.log("New answer (1e8):", uint256(newAnswer));
        console2.log("New price USD:", uint256(newAnswer) / 1e8);
    }
}
