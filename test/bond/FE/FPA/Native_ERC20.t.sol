// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {IBondFPA} from "../../../../src/interfaces/IBondFPA.sol";
import {MarketTestBase} from "./base.t.sol";

import {ERC20} from "@openzeppelin-contracts/token/ERC20/ERC20.sol";
import {console} from "forge-std/console.sol";

contract ERC20_Native_MarketTest is MarketTestBase {

    function setUp() public override {
        super.setUp();
        quoteToken = ERC20(address(0));
        uint256 capacity = 1000 * 10 ** payoutToken.decimals();
        params = IBondFPA.MarketParams(
            payoutToken, // Payout token
            quoteToken, // Quote token
            capacity, // Capacity
            1e36, // Price
            1 minutes, // Deposit interval
            10 minutes, // Vesting
            0, // Start time
            20 minutes, // Duration
            0 // Scale adjustment
        );
    }

    receive() external payable {}

    function testCreate() public {
        _testCreate();
    }

    function testPurchase() public {
        _testPurchase();
    }

    function testClose() public {
        _testClose();
    }

}
