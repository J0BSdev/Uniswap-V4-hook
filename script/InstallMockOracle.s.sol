// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {AggregatorV3Interface} from "@chainlink/contracts/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";
import {MockChainlinkAggregator} from "../test/mocks/MockChainlinkAggregator.sol";

/// @notice Replaces the Base ETH/USD Chainlink feed with a controllable mock on the fork.
/// The hook still reads the same address, but we can nudge the price from the frontend.
contract InstallMockOracle is Script {
    address internal constant FEED = 0x71041dddad3595F9CEd3DcCFBe3D1F4b0a16Bb70;

    function run() external {
        (, int256 answer,,,) = AggregatorV3Interface(FEED).latestRoundData();

        MockChainlinkAggregator template = new MockChainlinkAggregator();
        vm.etch(FEED, address(template).code);

        uint256 now = block.timestamp;
        MockChainlinkAggregator(FEED).setRound(answer, now - 120, now - 60);

        console2.log("Mock oracle installed at:", FEED);
        console2.log("Initial answer (1e8):", uint256(answer));
        console2.log("Initial price USD:", uint256(answer) / 1e8);
    }
}
