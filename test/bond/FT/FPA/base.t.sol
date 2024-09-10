// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {BondFixedTermFPA} from "../../../../src/BondFixedTermFPA.sol";
import {IBondFPA} from "../../../../src/interfaces/IBondFPA.sol";
import {UnsafeUpgrades, Upgrades} from "../../../utils/LegacyUpgradesPlus.sol";
import {BondFixedTermTestBase} from "../Teller.t.sol";

import {ERC20} from "@openzeppelin-contracts/token/ERC20/ERC20.sol";
import {console} from "forge-std/console.sol";

abstract contract MarketTestBase is BondFixedTermTestBase {

    BondFixedTermFPA public fpaAuctioneer;
    IBondFPA.MarketParams public params;

    function createMarket(
        IBondFPA.MarketParams memory params
    ) internal returns (uint256) {
        return auctioneer.createMarket{value: address(params.payoutToken) == address(0) ? params.capacity : 0}(
            abi.encode(params)
        );
    }

    function getMarketTyped(
        uint256 _marketId
    ) internal view returns (IBondFPA.BondMarket memory market) {
        (
            address owner,
            ERC20 payoutToken,
            ERC20 quoteToken,
            uint256 capacity, // capacity remaining in payout token
            uint256 maxPayout, // max payout tokens out in one order
            uint256 price, // fixed price of the market (see MarketParams struct)
            uint256 scale, // scaling factor for the market (see MarketParams struct)
            uint256 sold, // payout tokens out
            uint256 purchased
        ) = fpaAuctioneer.markets(_marketId);
        return IBondFPA.BondMarket(owner, payoutToken, quoteToken, capacity, maxPayout, price, scale, sold, purchased);
    }

    function setUp() public virtual override {
        super.setUp();
        fpaAuctioneer = new BondFixedTermFPA(teller, aggregator, owner, rolesAuthority);
        auctioneer = fpaAuctioneer;
        aggregator.registerAuctioneer(fpaAuctioneer);
    }

    function getTokenBalance(ERC20 token, address account) internal view returns (uint256 balance) {
        balance = address(token) == address(0) ? account.balance : token.balanceOf(account);
        return balance;
    }

    function _testCreate() internal {
        if (address(payoutToken) != address(0)) payoutToken.approve(address(auctioneer), params.capacity);
        // Simulate creating a market
        marketId = createMarket(params);
        // Assertions to verify the state after creating the market
        assertEq(getTokenBalance(payoutToken, address(teller)), params.capacity, "Teller should have all the tokens");
    }

    function _testPurchase() internal {
        _testCreate();
        // Assuming market has been created in a previous test or setup
        IBondFPA.BondMarket memory market = getMarketTyped(marketId);
        uint256 amountToBuy = (market.maxPayout * market.price) / market.scale; // Example amount to buy
        address receiver = address(0x123); // Example receiver address
        if (address(quoteToken) != address(0)) quoteToken.approve(address(teller), amountToBuy);
        // Simulate purchasing tokens
        (uint256 payout, uint48 expiration) = teller.purchase{
            value: address(quoteToken) != address(0) ? 0 : amountToBuy
        }(receiver, owner, marketId, amountToBuy, 0);
        uint256 tokenId = teller.getTokenId(payoutToken, expiration);
        assertEq(teller.balanceOf(receiver, tokenId), payout, "Receiver should have the Bonded tokens");
        vm.warp(block.timestamp + expiration);
        vm.prank(receiver);
        teller.redeem(tokenId, payout);
        // Assertions to verify the state after purchasing
        assertEq(getTokenBalance(payoutToken, receiver), payout, "Receiver should have the purchased tokens");
    }

    function _testClose() internal {
        _testCreate();
        // Assuming market has been created in a previous test or setup
        uint256 balanceTellerBefore = getTokenBalance(payoutToken, address(teller));
        uint256 balanceOwnerBefore = getTokenBalance(payoutToken, owner);
        IBondFPA.BondMarket memory marketBefore = getMarketTyped(marketId);
        // Simulate closing the market
        teller.closeMarket(marketId);
        // Assertions to verify the state after closing the market
        IBondFPA.BondMarket memory market = getMarketTyped(marketId);
        assertEq(market.capacity, 0, "Market capacity should be 0");
        assertEq(
            getTokenBalance(payoutToken, address(teller)),
            balanceTellerBefore - marketBefore.capacity,
            "Teller should withdraw the remaining tokens"
        );
        assertEq(
            getTokenBalance(payoutToken, owner),
            balanceOwnerBefore + marketBefore.capacity,
            "Owner should receive the remaining tokens"
        );
    }

}
