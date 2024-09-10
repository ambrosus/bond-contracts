// SPDX-License-Identifier: AGPL-3.0
pragma solidity >=0.8.0;

import {FullMath} from "../../../lib/FullMath.sol";
import "../../../src/bases/BondBaseAuctioneer.sol";
import {Pausable} from "@openzeppelin-contracts/security/Pausable.sol";

import {ERC20} from "@openzeppelin-contracts/token/ERC20/ERC20.sol";
import {SafeCast} from "@openzeppelin-contracts/utils/math/SafeCast.sol";
import {console} from "forge-std/console.sol";

contract MockAuctioneerDummy is BondBaseAuctioneer {

    using SafeCast for uint256;
    using FullMath for uint256;

    constructor(
        IBondTeller teller_,
        IBondAggregator aggregator_,
        address guardian_,
        IAuthority authority_
    ) BondBaseAuctioneer(teller_, aggregator_, guardian_, authority_) {}

    /// @notice Information pertaining to bond market
    struct Market {
        address owner; // market owner. sends payout tokens, receives quote tokens (defaults to creator)
        ERC20 payoutToken; // token to pay depositors with
        ERC20 quoteToken; // token to accept as payment
        uint256 capacity; // capacity remaining in payout token
        uint256 maxPayout; // max payout tokens out in one order
        uint256 price; // fixed price of the market (see MarketParams struct)
        uint256 scale; // scaling factor for the market (see MarketParams struct)
        uint256 sold; // payout tokens out
        uint256 purchased; // quote tokens in
    }

    /// @notice Information pertaining to market duration and vesting
    struct Terms {
        uint48 start; // timestamp when market starts
        uint48 conclusion; // timestamp when market no longer offered
        uint48 vesting; // length of time from deposit to expiry if fixed-term, vesting timestamp if fixed-expiry
    }

    struct MarketPrms {
        address owner; // market owner. sends payout tokens, receives quote tokens (defaults to creator)
        ERC20 payoutToken; // token to pay depositors with
        ERC20 quoteToken; // token to accept as payment
        uint256 capacity; // capacity remaining in payout token
        uint256 maxPayout; // max payout tokens out in one order
        uint256 price; // fixed price of the market (see MarketParams struct)
        uint256 scale; // scaling factor for the market (see MarketParams struct)
        uint48 vesting; // length of time from deposit to expiry if fixed-term, vesting timestamp if fixed-expiry
        uint48 duration; // when market ends
    }

    /// @notice New address to designate as market owner. They must accept ownership to transfer permissions.
    mapping(uint256 => address) public newOwners;

    mapping(uint256 => Market) public markets;
    mapping(uint256 => Terms) public terms;

    function createMarket(
        bytes memory params
    ) external payable override returns (uint256) {
        MarketPrms memory market = abi.decode(params, (MarketPrms));
        uint256 marketId = _aggregator.registerMarket(market.payoutToken, market.quoteToken);
        markets[marketId] = Market(
            market.owner,
            market.payoutToken,
            market.quoteToken,
            market.capacity,
            market.maxPayout,
            market.price,
            market.scale,
            0,
            0
        );
        terms[marketId] =
            Terms((block.timestamp).toUint48(), (block.timestamp + market.duration).toUint48(), market.vesting);
        return marketId;
    }

    function closeMarket(
        uint256 id_
    ) external override onlyTeller whenNotPaused {
        // If market closed early, set conclusion to current timestamp
        if (terms[id_].conclusion > uint48(block.timestamp)) terms[id_].conclusion = uint48(block.timestamp);

        markets[id_].capacity = 0;

        emit MarketClosed(id_);
    }

    function purchaseBond(
        uint256 id_,
        uint256 amount_,
        uint256 minAmountOut_
    ) external override onlyTeller whenNotPaused returns (uint256 payout) {
        Market storage market = markets[id_];

        // Check if market is live, if not revert
        if (!isLive(id_)) revert Auctioneer_MarketNotActive();

        // Calculate payout amount from fixed price
        payout = amount_.mulDiv(market.scale, market.price);

        // Payout and amount must be greater than zero
        if (payout == 0 || amount_ == 0) revert Auctioneer_AmountLessThanMinimum();

        // Payout must be greater than user inputted minimum
        if (payout < minAmountOut_) revert Auctioneer_AmountLessThanMinimum();

        // Markets have a max payout amount per transaction
        if (payout > market.maxPayout) revert Auctioneer_MaxPayoutExceeded();

        // Update Capacity

        // Capacity is either the number of payout tokens that the market can sell
        // (if capacity in quote is false),
        //
        // or the number of quote tokens that the market can buy
        // (if capacity in quote is true)

        // If payout is greater than capacity remaining, revert
        if (payout > market.capacity) revert Auctioneer_NotEnoughCapacity();
        // Capacity is decreased by the deposited or paid amount
        market.capacity -= payout;

        // Markets keep track of how many quote tokens have been
        // purchased, and how many payout tokens have been sold
        market.purchased += amount_;
        market.sold += payout;
    }

    function setIntervals(uint256, uint32[3] calldata) external override {}

    /// @inheritdoc IBondAuctioneer
    function pushOwnership(uint256 id_, address newOwner_) external override onlyMarketOwner(id_) whenNotPaused {
        newOwners[id_] = newOwner_;
    }

    /// @inheritdoc IBondAuctioneer
    function pullOwnership(
        uint256 id_
    ) external override whenNotPaused {
        if (msg.sender != newOwners[id_]) revert Auctioneer_NotAuthorized();
        markets[id_].owner = newOwners[id_];
    }

    function maxPayout(
        uint256 id_
    ) public view returns (uint256) {
        Market memory market = markets[id_];

        // Cap max payout at the remaining capacity
        return market.maxPayout > market.capacity ? market.capacity : market.maxPayout;
    }

    function setDefaults(
        uint32[6] memory
    ) external override {}

    function getMarketInfoForPurchase(
        uint256 marketId
    ) external view override returns (address, ERC20, ERC20, uint48, uint256) {
        Market memory market = markets[marketId];
        return (
            market.owner,
            ERC20(market.payoutToken),
            ERC20(market.quoteToken),
            terms[marketId].vesting,
            maxPayout(marketId)
        );
    }

    function marketPrice(
        uint256 id_
    ) public view override returns (uint256) {
        return markets[id_].price;
    }

    /// @inheritdoc IBondAuctioneer
    function marketScale(
        uint256 id_
    ) external view override returns (uint256) {
        return markets[id_].scale;
    }

    function payoutFor(uint256 marketId, uint256 amount, address referrer) external view override returns (uint256) {
        return amount;
    }

    function maxAmountAccepted(uint256 id_, address referrer_) external view returns (uint256) {
        // Calculate maximum amount of quote tokens that correspond to max bond size
        // Maximum of the maxPayout and the remaining capacity converted to quote tokens
        Market memory market = markets[id_];
        uint256 price = marketPrice(id_);
        uint256 quoteCapacity = market.capacity.mulDiv(price, market.scale);
        uint256 maxQuote = market.maxPayout.mulDiv(price, market.scale);
        uint256 amountAccepted = quoteCapacity < maxQuote ? quoteCapacity : maxQuote;

        return amountAccepted;
    }

    function isInstantSwap(
        uint256 marketId
    ) public view returns (bool) {
        uint256 vesting = terms[marketId].vesting;
        return (vesting <= MAX_FIXED_TERM) ? vesting == 0 : vesting <= block.timestamp;
    }

    /// @inheritdoc IBondAuctioneer
    function isLive(
        uint256 id_
    ) public view override returns (bool) {
        return (
            markets[id_].capacity != 0 && terms[id_].conclusion > uint48(block.timestamp)
                && terms[id_].start <= uint48(block.timestamp)
        );
    }

    function isClosing(
        uint256 id_
    ) public view override returns (bool) {
        return (markets[id_].capacity != 0 && terms[id_].conclusion < uint48(block.timestamp));
    }

    function ownerOf(
        uint256 marketId
    ) external view override returns (address) {
        return markets[marketId].owner;
    }

    function currentCapacity(
        uint256 marketId
    ) external view override returns (uint256) {
        return markets[marketId].capacity;
    }

    function getConclusion(
        uint256 id_
    ) external view override returns (uint48) {
        return terms[id_].conclusion;
    }

}
