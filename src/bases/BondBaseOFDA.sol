/// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.20;

import {IAuthority} from "../../lib/interfaces/IAuthority.sol";

import {FullMath} from "../../lib/FullMath.sol";
import {IBondAggregator} from "../interfaces/IBondAggregator.sol";
import {IBondAuctioneer} from "../interfaces/IBondAuctioneer.sol";
import {IBondOFDA} from "../interfaces/IBondOFDA.sol";
import {IBondOracle} from "../interfaces/IBondOracle.sol";
import {IBondTeller} from "../interfaces/IBondTeller.sol";

import {BondBaseAuctioneer, BondBaseOracleAuctioneer} from "./BondBaseOracleAuctioneer.sol";
import {ERC20} from "@openzeppelin-contracts/token/ERC20/ERC20.sol";
import {SafeERC20} from "@openzeppelin-contracts/token/ERC20/utils/SafeERC20.sol";

/// @title Bond Oracle-based Fixed Discount Auctioneer
/// @notice Bond Oracle-based Fixed Discount Auctioneer Base Contract
/// @dev Bond Protocol is a system to create markets for any token pair.
///      Bond issuers create BondMarkets that pay out a Payout Token in exchange
///      for deposited Quote Tokens. Users can purchase future-dated Payout Tokens
///      with Quote Tokens at the current market price and receive Bond Tokens to
///      represent their position while their bond vests. Once the Bond Tokens vest,
///      they can redeem it for the Quote Tokens. Alternatively, markets can be
///      instant swap and payouts are made immediately to the user.
///
/// @dev An Auctioneer contract allows users to create and manage bond markets.
///      All bond pricing logic and market data is stored in the Auctioneer.
///      An Auctioneer is dependent on a Teller to serve external users and
///      an Aggregator to register new markets. The Fixed Discount Auctioneer
///      lets issuers set a fixed discount from an oracle price to buy a target
///      amount of quote tokens or sell a target amount of payout tokens over
///      the duration of a market.
///
/// @author Oighty
abstract contract BondBaseOFDA is IBondOFDA, BondBaseOracleAuctioneer {

    using SafeERC20 for ERC20;
    using FullMath for uint256;

    /* ========== EVENTS ========== */

    event MarketCreated(uint256 indexed id, address indexed payoutToken, address indexed quoteToken, uint48 vesting);

    /* ========== STATE VARIABLES ========== */

    /// @notice Information pertaining to bond markets
    mapping(uint256 => BondMarket) public markets;

    /// @notice Information pertaining to market vesting and duration
    mapping(uint256 => BondTerms) public terms;

    /// @notice New address to designate as market owner. They must accept ownership to transfer permissions.
    mapping(uint256 => address) public newOwners;

    // Minimum time parameter values. Can be updated by admin.
    /// @notice Minimum deposit interval for a market
    uint48 public minDepositInterval;

    /// @notice Minimum market duration in seconds
    uint48 public minMarketDuration;

    /// @notice Whether or not the market creator is authorized to use a callback address
    mapping(address => bool) public callbackAuthorized;

    constructor(
        IBondTeller teller_,
        IBondAggregator aggregator_,
        address guardian_,
        IAuthority authority_
    ) BondBaseOracleAuctioneer(teller_, aggregator_, guardian_, authority_) {
        minDepositInterval = 1 minutes;
        minMarketDuration = 10 minutes;
    }

    /* ========== MARKET FUNCTIONS ========== */

    /// @inheritdoc IBondAuctioneer
    function createMarket(
        bytes calldata params_
    ) external payable virtual returns (uint256);

    /// @notice core market creation logic, see IBondOFDA.MarketParams documentation
    function _createMarket(
        MarketParams memory params_
    ) internal whenNotPaused returns (uint256) {
        // Upfront permission and timing checks
        {
            // Check that the auctioneer is allowing new markets to be created
            if (!allowNewMarkets) revert Auctioneer_NewMarketsNotAllowed();
            // Start time must be zero or in the future
            if (params_.start > 0 && params_.start < block.timestamp) revert Auctioneer_InvalidParams();
        }
        // Register new market on aggregator and get marketId
        uint256 marketId = _aggregator.registerMarket(params_.payoutToken, params_.quoteToken);

        // Set basic market data
        BondMarket storage market = markets[marketId];
        market.owner = msg.sender;
        market.quoteToken = params_.quoteToken;
        market.payoutToken = params_.payoutToken;
        market.capacity = params_.capacity;

        // Check that the fixed discount is in bounds (cannot be greater than or equal to 100%)
        BondTerms storage term = terms[marketId];
        if (params_.fixedDiscount >= ONE_HUNDRED_PERCENT || params_.fixedDiscount > params_.maxDiscountFromCurrent) {
            revert Auctioneer_InvalidParams();
        }
        term.fixedDiscount = params_.fixedDiscount;

        // Validate oracle and get price variables
        (uint256 price, uint256 oracleConversion, uint256 scale) =
            _validateOracle(marketId, params_.oracle, params_.quoteToken, params_.payoutToken, params_.fixedDiscount);
        term.oracle = params_.oracle;
        term.oracleConversion = oracleConversion;
        term.scale = scale;

        // Check that the max discount from current price is in bounds (cannot be greater than 100%)
        if (params_.maxDiscountFromCurrent > ONE_HUNDRED_PERCENT) revert Auctioneer_InvalidParams();

        // Calculate the minimum price for the market
        term.minPrice =
            price.mulDivUp(uint256(ONE_HUNDRED_PERCENT - params_.maxDiscountFromCurrent), uint256(ONE_HUNDRED_PERCENT));

        // Check time bounds
        if (
            params_.duration < minMarketDuration || params_.depositInterval < minDepositInterval
                || params_.depositInterval > params_.duration
        ) revert Auctioneer_InvalidParams();

        // If payout is native token
        if (address(params_.payoutToken) == address(0)) {
            // Ensure capacity is equal to the value sent
            if (params_.capacity != msg.value) revert Auctioneer_InvalidParams();
            // Send tokens to teller as it operates over purchase
            (bool sent,) = payable(address(_teller)).call{value: msg.value}("");
            require(sent, "Failed to send tokens to teller");
        } else {
            // Check balance before and after to ensure full amount received, revert if not
            // Handles edge cases like fee-on-transfer tokens (which are not supported)
            uint256 payoutBalance = params_.payoutToken.balanceOf(address(_teller));
            params_.payoutToken.safeTransferFrom(msg.sender, address(_teller), params_.capacity);
            if (params_.payoutToken.balanceOf(address(_teller)) < payoutBalance + params_.capacity) {
                revert Auctioneer_UnsupportedToken();
            }
        }

        // Calculate the maximum payout amount for this market
        market.maxPayout = params_.capacity.mulDiv(uint256(params_.depositInterval), uint256(params_.duration));

        // Store bond time terms
        term.vesting = params_.vesting;
        uint48 start = params_.start == 0 ? uint48(block.timestamp) : params_.start;
        term.start = start;
        term.conclusion = start + params_.duration;

        // Emit market created event
        emit MarketCreated(marketId, address(params_.payoutToken), address(params_.quoteToken), params_.vesting);

        return marketId;
    }

    /// @inheritdoc IBondAuctioneer
    function pushOwnership(uint256 id_, address newOwner_) external override onlyMarketOwner(id_) whenNotPaused {
        if (msg.sender != markets[id_].owner) revert Auctioneer_OnlyMarketOwner();
        newOwners[id_] = newOwner_;
    }

    /// @inheritdoc IBondAuctioneer
    function pullOwnership(
        uint256 id_
    ) external override whenNotPaused {
        if (msg.sender != newOwners[id_]) revert Auctioneer_NotAuthorized();
        markets[id_].owner = newOwners[id_];
    }

    /// @inheritdoc IBondOFDA
    function setMinMarketDuration(
        uint48 duration_
    ) external override requiresAuth {
        // Restricted to authorized addresses

        // Require duration to be greater than minimum deposit interval and at least 10 minutes
        if (duration_ < minDepositInterval || duration_ < 10 minutes) revert Auctioneer_InvalidParams();

        minMarketDuration = duration_;
    }

    /// @inheritdoc IBondOFDA
    function setMinDepositInterval(
        uint48 depositInterval_
    ) external override requiresAuth {
        // Restricted to authorized addresses

        // Require min deposit interval to be less than minimum market duration and at least 1 minute
        if (depositInterval_ > minMarketDuration || depositInterval_ < 1 minutes) revert Auctioneer_InvalidParams();

        minDepositInterval = depositInterval_;
    }

    // Unused, but required by interface
    function setIntervals(uint256 id_, uint32[3] calldata intervals_) external override onlyMarketOwner(id_) {}

    // Unused, but required by interface
    function setDefaults(
        uint32[6] memory defaults_
    ) external override requiresAuth {}

    /// @inheritdoc IBondAuctioneer
    function setAllowNewMarkets(
        bool status_
    ) external override (IBondAuctioneer, BondBaseAuctioneer) requiresAuth {
        _setAllowNewMarkets(status_);
    }

    /// @inheritdoc IBondAuctioneer
    function closeMarket(
        uint256 id_
    ) external override onlyTeller whenNotPaused {
        // If market closed early, set conclusion to current timestamp
        if (terms[id_].conclusion > uint48(block.timestamp)) terms[id_].conclusion = uint48(block.timestamp);

        markets[id_].capacity = 0;

        emit MarketClosed(id_);
    }

    /* ========== TELLER FUNCTIONS ========== */

    /// @inheritdoc IBondAuctioneer
    function purchaseBond(
        uint256 id_,
        uint256 amount_,
        uint256 minAmountOut_
    ) external override onlyTeller whenNotPaused returns (uint256 payout) {
        BondMarket storage market = markets[id_];
        BondTerms memory term = terms[id_];

        // Check if market is live, if not revert
        if (!isLive(id_)) revert Auctioneer_MarketNotActive();

        // Get current price with fixed discount
        uint256 price = marketPrice(id_);

        // Payout for the deposit = amount / price
        //
        // where:
        // payout = payout tokens out
        // amount = quote tokens in
        // price = quote tokens : payout token (i.e. 200 QUOTE : BASE), adjusted for scaling
        payout = amount_.mulDiv(term.scale, price);

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

    /* ========== EXTERNAL VIEW FUNCTIONS ========== */

    /// @inheritdoc IBondAuctioneer
    function getMarketInfoForPurchase(
        uint256 id_
    )
        external
        view
        override
        returns (address owner, ERC20 payoutToken, ERC20 quoteToken, uint48 vesting, uint256 maxPayout_)
    {
        BondMarket memory market = markets[id_];
        return (market.owner, market.payoutToken, market.quoteToken, terms[id_].vesting, maxPayout(id_));
    }

    /// @inheritdoc IBondAuctioneer
    function marketPrice(
        uint256 id_
    ) public view override (IBondAuctioneer, IBondOFDA) returns (uint256) {
        // Get the current price from the oracle
        BondTerms memory term = terms[id_];
        uint256 oraclePrice = term.oracle.currentPrice(id_);

        // Revert if price is 0
        if (oraclePrice == 0) revert Auctioneer_OraclePriceZero();

        // Convert the oracle price to market price decimals using the oracleConversion
        uint256 price = oraclePrice * term.oracleConversion;

        // Apply the fixed discount
        uint256 discountedPrice = price.mulDivUp(ONE_HUNDRED_PERCENT - term.fixedDiscount, ONE_HUNDRED_PERCENT);

        // Check if price is less than the minimum price and return
        return discountedPrice < term.minPrice ? term.minPrice : discountedPrice;
    }

    /// @inheritdoc IBondAuctioneer
    function marketScale(
        uint256 id_
    ) external view override returns (uint256) {
        return terms[id_].scale;
    }

    /// @inheritdoc IBondAuctioneer
    function payoutFor(uint256 amount_, uint256 id_, address referrer_) public view override returns (uint256) {
        // Calculate the payout for the given amount of tokens
        uint256 fee = amount_.mulDiv(_teller.getFee(referrer_), ONE_HUNDRED_PERCENT);
        uint256 payout = (amount_ - fee).mulDiv(terms[id_].scale, marketPrice(id_));

        // Check that the payout is less than or equal to the maximum payout,
        // Revert if not, otherwise return the payout
        if (payout > maxPayout(id_)) revert Auctioneer_MaxPayoutExceeded();
        else return payout;
    }

    /// @inheritdoc IBondOFDA
    function maxPayout(
        uint256 id_
    ) public view override returns (uint256) {
        BondMarket memory market = markets[id_];

        // Cap max payout at the remaining capacity
        return market.maxPayout > market.capacity ? market.capacity : market.maxPayout;
    }

    /// @inheritdoc IBondAuctioneer
    function maxAmountAccepted(uint256 id_, address referrer_) external view returns (uint256) {
        // Calculate maximum amount of quote tokens that correspond to max bond size
        // Maximum of the maxPayout and the remaining capacity converted to quote tokens
        BondMarket memory market = markets[id_];
        BondTerms memory term = terms[id_];
        uint256 price = marketPrice(id_);
        uint256 quoteCapacity = market.capacity.mulDiv(price, term.scale);
        uint256 maxQuote = market.maxPayout.mulDiv(price, term.scale);
        uint256 amountAccepted = quoteCapacity < maxQuote ? quoteCapacity : maxQuote;

        // Take into account teller fees and return
        // Estimate fee based on amountAccepted. Fee taken will be slightly larger than
        // this given it will be taken off the larger amount, but this avoids rounding
        // errors with trying to calculate the exact amount.
        // Therefore, the maxAmountAccepted is slightly conservative.
        uint256 estimatedFee = amountAccepted.mulDiv(_teller.getFee(referrer_), ONE_HUNDRED_PERCENT);

        return amountAccepted + estimatedFee;
    }

    /// @inheritdoc IBondAuctioneer
    function isInstantSwap(
        uint256 id_
    ) public view returns (bool) {
        uint256 vesting = terms[id_].vesting;
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

    /// @inheritdoc IBondAuctioneer
    function isClosing(
        uint256 id_
    ) public view override returns (bool) {
        return (markets[id_].capacity != 0 && terms[id_].conclusion < uint48(block.timestamp));
    }

    /// @inheritdoc IBondAuctioneer
    function ownerOf(
        uint256 id_
    ) external view override returns (address) {
        return markets[id_].owner;
    }

    /// @inheritdoc IBondAuctioneer
    function currentCapacity(
        uint256 id_
    ) external view override returns (uint256) {
        return markets[id_].capacity;
    }

    /// @inheritdoc IBondAuctioneer
    function getConclusion(
        uint256 id_
    ) external view override returns (uint48) {
        return terms[id_].conclusion;
    }

}
