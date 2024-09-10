// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {IBondSDA} from "../../../../src/interfaces/IBondSDA.sol";
import {MarketTestBase} from "./base.t.sol";

import {ERC20} from "@openzeppelin-contracts/token/ERC20/ERC20.sol";
import {console} from "forge-std/console.sol";

contract ERC20_Native_MarketTest is MarketTestBase {

    function setUp() public override {
        super.setUp();
        payoutToken = ERC20(address(0));
        uint256 capacity = 1000 ether;
        params = IBondSDA.MarketParams(
            payoutToken, // Payout token
            quoteToken, // Quote token
            capacity, // Capacity
            1e36, // init Price
            1e35, // min Price
            1000, // debt buffer
            10 minutes, // Vesting
            0, // Start time
            20 minutes, // Duration
            1 minutes, // Deposit interval
            0 // Scale adjustment
        );
    }

    receive() external payable {}

    /**
     * @notice Test create, a public state-modifying contract function.
     * @custom:signature testCreate()
     * @custom:selector 0xd62d3115
     */
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
