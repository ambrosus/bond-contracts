// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity 0.8.20;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {FullMath} from "../lib/FullMath.sol";
import {IAuthority} from "../interfaces/IAuthority.sol";
import {IBondAuctioneer} from "../interfaces/IBondAuctioneer.sol";
import {IBondOSDA} from "../interfaces/IBondOSDA.sol";
import {IBondTeller} from "../interfaces/IBondTeller.sol";
import {IBondAggregator} from "../interfaces/IBondAggregator.sol";
import {IBondOracle} from "../interfaces/IBondOracle.sol";
import {BondBaseOracleAuctioneer, BondBaseAuctioneer} from "./BondBaseOracleAuctioneer.sol";


/// @title Bond Oracle-based Sequential Dutch Auctioneer (OSDA)
/// @notice Bond Oracle-based Sequential Dutch Auctioneer Base Contract
/// @dev Bond Protocol is a system to create bond markets for any token pair.
///      The markets do not require maintenance and will manage bond prices
///      based on activity. Bond issuers create BondMarkets that pay out
///      a Payout Token in exchange for deposited Quote Tokens. Users can purchase
///      future-dated Payout Tokens with Quote Tokens at the current market price and
///      receive Bond Tokens to represent their position while their bond vests.
///      Once the Bond Tokens vest, they can redeem it for the Quote Tokens.
///
/// @dev The Oracle-based Sequential Dutch Auctioneer contract allows users to create
///      and manage bond markets. All bond market data is stored in the Auctioneer.
///      The market price is based on an outside Oracle and varies based on whether the
///      market is under- or oversold with the goal of selling a target amount of
///      payout tokens or buying a target amount of quote tokens over the duration of
///      a market. An Auctioneer is dependent on a Teller to serve external users and
///      an Aggregator to register new markets.
///
/// @author Oighty
abstract contract BondBaseOSDA is IBondOSDA, BondBaseOracleAuctioneer {
    using SafeERC20 for ERC20;
    using FullMath for uint256;

    error Auctioneer_InitialPriceLessThanMin();


    /* ========== EVENTS ========== */

    event MarketCreated(
        uint256 indexed id, 
        address indexed payoutToken, 
        address indexed quoteToken, 
        uint48 vesting
    );
    event MarketClosed(uint256 indexed id);
    event Tuned(uint256 indexed id, uint256 oldControlVariable, uint256 newControlVariable);

    /* ========== STATE VARIABLES ========== */

    /// @notice Main information pertaining to bond market
    mapping(uint256 => BondMarket) public markets;

    /// @notice Information used to control how a bond market changes
    mapping(uint256 => BondTerms) public terms;

    /// @notice New address to designate as market owner. They must accept ownership to transfer permissions.
    mapping(uint256 => address) public newOwners;

    // Minimum time parameter values. Can be updated by admin.
    /// @notice Minimum deposit interval for a market
    uint48 public minDepositInterval;

    /// @notice Minimum duration for a market
    uint48 public minMarketDuration;

    /// @notice Whether or not the market creator is authorized to use a callback address
    mapping(address => bool) public callbackAuthorized;

    constructor(
        IBondTeller teller_,
        IBondAggregator aggregator_,
        address guardian_,
        IAuthority authority_
    ) BondBaseOracleAuctioneer( teller_, aggregator_,guardian_, authority_){
        minDepositInterval = 1 minutes;
        minMarketDuration = 10 minutes;
    }

    /* ========== MARKET FUNCTIONS ========== */

    /// @inheritdoc IBondAuctioneer
    function createMarket(bytes calldata params_) external payable virtual returns (uint256);

    /// @notice core market creation logic, see IBondOSDA.MarketParams documentation
    function _createMarket(MarketParams memory params_) internal whenNotPaused returns (uint256) {
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

        // Check that the base discount is in bounds (cannot be 100% or greater)
        BondTerms storage term = terms[marketId];
        if (params_.baseDiscount >= ONE_HUNDRED_PERCENT || params_.baseDiscount > params_.maxDiscountFromCurrent)
            revert Auctioneer_InvalidParams();
        term.baseDiscount = params_.baseDiscount;

        // Validate oracle and get price variables
        (uint256 price, uint256 oracleConversion, uint256 scale) = _validateOracle(
            marketId,
            params_.oracle,
            params_.quoteToken,
            params_.payoutToken,
            params_.baseDiscount
        );
        term.oracle = params_.oracle;
        term.oracleConversion = oracleConversion;
        term.scale = scale;

        // Check that the max discount from current price is in bounds (cannot be greater than 100%)
        if (params_.maxDiscountFromCurrent > ONE_HUNDRED_PERCENT) revert Auctioneer_InvalidParams();

        // Calculate the minimum price for the market
        term.minPrice = price.mulDivUp(
            uint256(ONE_HUNDRED_PERCENT - params_.maxDiscountFromCurrent),
            uint256(ONE_HUNDRED_PERCENT)
        );

        // Check time bounds
        if (
            params_.duration < minMarketDuration ||
            params_.depositInterval < minDepositInterval ||
            params_.depositInterval > params_.duration
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
            if (params_.payoutToken.balanceOf(address(_teller)) < payoutBalance + params_.capacity)
                revert Auctioneer_UnsupportedToken();
        }

        // Calculate the maximum payout amount for this market, determined by deposit interval
        market.maxPayout = params_.capacity.mulDiv(uint256(params_.depositInterval), uint256(params_.duration));

        // Check target interval discount in bounds
        if (params_.targetIntervalDiscount > ONE_HUNDRED_PERCENT) revert Auctioneer_InvalidParams();

        // Calculate decay speed
        term.decaySpeed = (params_.duration * params_.targetIntervalDiscount) / params_.depositInterval;

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
    function pullOwnership(uint256 id_) external override whenNotPaused {
        if (msg.sender != newOwners[id_]) revert Auctioneer_NotAuthorized();
        markets[id_].owner = newOwners[id_];
    }

    /// @inheritdoc IBondOSDA
    function setMinMarketDuration(uint48 duration_) external override requiresAuth {
        // Restricted to authorized addresses

        // Require duration to be greater than minimum deposit interval and at least 10 minutes
        if (duration_ < minDepositInterval || duration_ < 10 minutes) revert Auctioneer_InvalidParams();

        minMarketDuration = duration_;
    }

    /// @inheritdoc IBondOSDA
    function setMinDepositInterval(uint48 depositInterval_) external override requiresAuth {
        // Restricted to authorized addresses

        // Require min deposit interval to be less than minimum market duration and at least 1 minute
        if (depositInterval_ > minMarketDuration || depositInterval_ < 1 minutes) revert Auctioneer_InvalidParams();

        minDepositInterval = depositInterval_;
    }

    // Unused, but required by interface
    function setIntervals(uint256 id_, uint32[3] calldata intervals_) external override onlyMarketOwner(id_) {}

    // Unused, but required by interface
    function setDefaults(uint32[6] memory defaults_) external override requiresAuth {}

    /// @inheritdoc IBondAuctioneer
    function setAllowNewMarkets(bool status_) external override(IBondAuctioneer, BondBaseAuctioneer) requiresAuth {
        _setAllowNewMarkets(status_);
    }

    /// @inheritdoc IBondAuctioneer
    function closeMarket(uint256 id_) external override onlyTeller whenNotPaused {
        
        // If market closed early, set conclusion to current timestamp
        if (terms[id_].conclusion > uint48(block.timestamp)) {
            terms[id_].conclusion = uint48(block.timestamp);
        }

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

        // Retrieve price and calculate payout
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

        // Markets have a max payout amount, capping size because deposits
        // do not experience slippage. max payout is recalculated upon tuning
        if (payout > market.maxPayout) revert Auctioneer_MaxPayoutExceeded();

        // Update Capacity

        // Capacity is either the number of payout tokens that the market can sell
        // (if capacity in quote is false),
        //
        // or the number of quote tokens that the market can buy
        // (if capacity in quote is true)

        // If payout is greater than capacity remaining, revert
        if (payout > market.capacity) revert Auctioneer_NotEnoughCapacity();
        unchecked {
            // Capacity is decreased by the deposited or paid amount
            market.capacity -= payout;

            // Markets keep track of how many quote tokens have been
            // purchased, and how many payout tokens have been sold
            market.purchased += amount_;
            market.sold += payout;
        }
    }

    /* ========== INTERNAL VIEW FUNCTIONS ========== */

    /// @notice             Calculate current market price of payout token in quote tokens
    /// @dev                See marketPrice() in IBondOSDA for explanation of price computation
    /// @param id_          Market ID
    /// @return             Price for market as a ratio of quote tokens to payout tokens with 36 decimals
    function _currentMarketPrice(uint256 id_) internal view returns (uint256) {
        BondMarket memory market = markets[id_];
        BondTerms memory term = terms[id_];

        // Get price from oracle, apply oracle conversion factor, and apply target discount
        uint256 price = (term.oracle.currentPrice(id_) * term.oracleConversion).mulDivUp(
            (ONE_HUNDRED_PERCENT - term.baseDiscount),
            ONE_HUNDRED_PERCENT
        );

        // Revert if price is 0
        if (price == 0) revert Auctioneer_OraclePriceZero();

        // Calculate initial capacity based on remaining capacity and amount sold/purchased up to this point
        uint256 initialCapacity = market.capacity + (market.sold);

        // Compute seconds remaining until market will conclude
        uint256 conclusion = uint256(term.conclusion);
        uint256 timeRemaining = conclusion - block.timestamp;

        // Calculate expectedCapacity as the capacity expected to be bought or sold up to this point
        // Higher than current capacity means the market is undersold, lower than current capacity means the market is oversold
        uint256 expectedCapacity = initialCapacity.mulDiv(timeRemaining, conclusion - uint256(term.start));

        // Price is increased or decreased based on how far the market is ahead or behind
        // Intuition:
        // If the time neutral capacity is higher than the initial capacity, then the market is undersold and price should be discounted
        // If the time neutral capacity is lower than the initial capacity, then the market is oversold and price should be increased
        //
        // This implementation uses a linear price decay
        // P(t) = P(0) * (1 + k * (X(t) - C(t) / C(0)))
        // P(t): price at time t
        // P(0): initial/target price of the market provided by oracle + base discount (see IOSDA.MarketParams)
        // k: decay speed of the market
        // k = L / I * d, where L is the duration/length of the market, I is the deposit interval, and d is the target interval discount.
        // X(t): expected capacity of the market at time t.
        // X(t) = C(0) * t / L.
        // C(t): actual capacity of the market at time t.
        // C(0): initial capacity of the market provided by the user (see IOSDA.MarketParams).
        uint256 adjustment;
        if (expectedCapacity > market.capacity) {
            adjustment =
                ONE_HUNDRED_PERCENT +
                (term.decaySpeed * (expectedCapacity - market.capacity)) /
                initialCapacity;
        } else {
            // If actual capacity is greater than expected capacity, we need to check for underflows
            // The adjustment has a minimum value of 0 since that will reduce the price to 0 as well.
            uint256 factor = (term.decaySpeed * (market.capacity - expectedCapacity)) / initialCapacity;
            adjustment = ONE_HUNDRED_PERCENT > factor ? ONE_HUNDRED_PERCENT - factor : 0;
        }

        return price.mulDivUp(adjustment, ONE_HUNDRED_PERCENT);
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

    /// @inheritdoc IBondOSDA
    function marketPrice(uint256 id_) public view override(IBondAuctioneer, IBondOSDA) returns (uint256) {
        uint256 price = _currentMarketPrice(id_);

        return (price > terms[id_].minPrice) ? price : terms[id_].minPrice;
    }

    /// @inheritdoc IBondAuctioneer
    function marketScale(uint256 id_) external view override returns (uint256) {
        return terms[id_].scale;
    }

    /// @inheritdoc IBondAuctioneer
    function payoutFor(uint256 amount_, uint256 id_, address referrer_) public view override returns (uint256) {
        /// Calculate the payout for the given amount of tokens
        uint256 fee = amount_.mulDiv(_teller.getFee(referrer_), 1e5);
        uint256 payout = (amount_ - fee).mulDiv(terms[id_].scale, marketPrice(id_));

        /// Check that the payout is less than or equal to the maximum payout,
        /// Revert if not, otherwise return the payout
        if (payout > maxPayout(id_)) {
            revert Auctioneer_MaxPayoutExceeded();
        } else {
            return payout;
        }
    }

    /// @inheritdoc IBondOSDA
    function maxPayout(uint256 id_) public view override returns (uint256) {
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
    function isInstantSwap(uint256 id_) public view returns (bool) {
        uint256 vesting = terms[id_].vesting;
        return (vesting <= MAX_FIXED_TERM) ? vesting == 0 : vesting <= block.timestamp;
    }

    /// @inheritdoc IBondAuctioneer
    function isLive(uint256 id_) public view override returns (bool) {
        return (markets[id_].capacity != 0 &&
            terms[id_].conclusion > uint48(block.timestamp) &&
            terms[id_].start <= uint48(block.timestamp));
    }

    /// @inheritdoc IBondAuctioneer
    function isClosing(uint256 id_) public view override returns (bool) {
        return (markets[id_].capacity != 0 && terms[id_].conclusion < uint48(block.timestamp));
    }

    /// @inheritdoc IBondAuctioneer
    function ownerOf(uint256 id_) external view override returns (address) {
        return markets[id_].owner;
    }

    /// @inheritdoc IBondAuctioneer
    function currentCapacity(uint256 id_) external view override returns (uint256) {
        return markets[id_].capacity;
    }

    /// @inheritdoc IBondAuctioneer
    function getConclusion(uint256 id_) external view override returns (uint48) {
        return terms[id_].conclusion;
    }
}
