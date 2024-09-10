// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity 0.8.20;

import "../src/BondAggregator.sol";

import {RolesAuthority} from "../src/RolesAuthority.sol";
import "../src/interfaces/IBondAuctioneer.sol";
import "../src/interfaces/IBondTeller.sol";
import {MockAuctioneerDummy} from "./utils/mocks/MockAuctioneers.sol";

import {MockERC20} from "./utils/mocks/MockERC20.sol";
import "@openzeppelin-contracts/token/ERC20/ERC20.sol";
import "forge-std/Test.sol";

contract BondAggregatorTest is Test {

    BondAggregator public aggregator;
    RolesAuthority public authority;
    MockAuctioneerDummy public auctioneer;
    ERC20 public payoutToken;
    ERC20 public quoteToken;

    address public guardian = address(1);

    function deployToken(string memory name, string memory symbol, uint8 decimals) internal returns (ERC20 token) {
        MockERC20 mockedToken = new MockERC20(name, symbol, decimals);
        return ERC20(address(mockedToken));
    }

    function setUp() public {
        /// @dev RolesAuthority tested in RolesAuthority.t.sol
        authority = new RolesAuthority(guardian, IAuthority(address(0)));
        aggregator = new BondAggregator(guardian, authority);
        auctioneer = new MockAuctioneerDummy(IBondTeller(address(0)), aggregator, guardian, authority);
        payoutToken = deployToken("Payout", "PAY", 18);
        quoteToken = deployToken("Quote", "QUO", 18);
    }

    function testRegisterAuctioneer() public {
        vm.prank(guardian);
        aggregator.registerAuctioneer(auctioneer);

        // Check if auctioneer is registered
        assertEq(address(aggregator.auctioneers(0)), address(auctioneer));
    }

    function testRegisterAuctioneerOnlyGuardian() public {
        vm.expectRevert("UNAUTHORIZED");
        aggregator.registerAuctioneer(auctioneer);
    }

    function testRegisterMarket() public {
        vm.prank(guardian);
        aggregator.registerAuctioneer(auctioneer);

        vm.prank(address(auctioneer));
        uint256 marketId = aggregator.registerMarket(payoutToken, quoteToken);

        assertEq(marketId, 0);
        assertEq(address(aggregator.marketsToAuctioneers(marketId)), address(auctioneer));
    }

    function testRegisterMarketOnlyAuctioneer() public {
        vm.expectRevert(BondAggregator.Aggregator_OnlyAuctioneer.selector);
        aggregator.registerMarket(payoutToken, quoteToken);
    }

    function testGetAuctioneer() public {
        vm.prank(guardian);
        aggregator.registerAuctioneer(auctioneer);

        vm.prank(address(auctioneer));
        uint256 marketId = aggregator.registerMarket(payoutToken, quoteToken);

        assertEq(address(aggregator.getAuctioneer(marketId)), address(auctioneer));
    }

}
