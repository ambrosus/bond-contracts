/// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.15;

import {ERC20} from "solmate/src/tokens/ERC20.sol";
import {Auth, Authority} from "solmate/src/auth/Auth.sol";

import {IBondOFDA, IBondAuctioneer} from "../interfaces/IBondOFDA.sol";
import {IBondTeller} from "../interfaces/IBondTeller.sol";
import {IBondCallback} from "../interfaces/IBondCallback.sol";
import {IBondAggregator} from "../interfaces/IBondAggregator.sol";
import {IBondOracle} from "../interfaces/IBondOracle.sol";

import {TransferHelper} from "../lib/TransferHelper.sol";
import {FullMath} from "../lib/FullMath.sol";

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
abstract contract BondBaseOFDA is IBondOFDA, Auth {
    using TransferHelper for ERC20;
    using FullMath for uint256;

    /* ========== ERRORS ========== */

    error Auctioneer_OnlyMarketOwner();
    error Auctioneer_MarketNotActive();
    error Auctioneer_MaxPayoutExceeded();
    error Auctioneer_AmountLessThanMinimum();
    error Auctioneer_NotEnoughCapacity();
    error Auctioneer_InvalidCallback();
    error Auctioneer_BadExpiry();
    error Auctioneer_InvalidParams();
    error Auctioneer_NotAuthorized();
    error Auctioneer_NewMarketsNotAllowed();
    error Auctioneer_OraclePriceZero();

    /* ========== EVENTS ========== */

    event MarketCreated(
        uint256 indexed id,
        address[] indexed payoutToken,
        address indexed quoteToken,
        uint48 vesting
    );
    event MarketClosed(uint256 indexed id);

    /* ========== STATE VARIABLES ========== */

    /// @notice Information pertaining to bond markets
    mapping(uint256 => BondMarket) public markets;

    /// @notice Information pertaining to market vesting and duration
    mapping(uint256 => BondTerms) public terms;

    /// @notice New address to designate as market owner. They must accept ownership to transfer permissions.
    mapping(uint256 => address) public newOwners;

    /// @notice Whether or not the auctioneer allows new markets to be created
    /// @dev    Changing to false will sunset the auctioneer after all active markets end
    bool public allowNewMarkets;

    // Minimum time parameter values. Can be updated by admin.
    /// @notice Minimum deposit interval for a market
    uint48 public minDepositInterval;

    /// @notice Minimum market duration in seconds
    uint48 public minMarketDuration;

    /// @notice Whether or not the market creator is authorized to use a callback address
    mapping(address => bool) public callbackAuthorized;

    // A 'vesting' param longer than 50 years is considered a timestamp for fixed expiry.
    uint48 internal constant MAX_FIXED_TERM = 52 weeks * 50;
    uint48 internal constant ONE_HUNDRED_PERCENT = 1e5; // one percent equals 1000.

    // BondAggregator contract with utility functions
    IBondAggregator internal immutable _aggregator;

    // BondTeller contract that handles interactions with users and issues tokens
    IBondTeller internal immutable _teller;

    constructor(
        IBondTeller teller_,
        IBondAggregator aggregator_,
        address guardian_,
        Authority authority_
    ) Auth(guardian_, authority_) {
        _aggregator = aggregator_;
        _teller = teller_;

        minDepositInterval = 1 hours;
        minMarketDuration = 1 days;

        allowNewMarkets = true;
    }

    /* ========== MARKET FUNCTIONS ========== */

    /// @inheritdoc IBondAuctioneer
    function createMarket(bytes calldata params_) external virtual returns (uint256);

    /// @notice core market creation logic, see IBondOFDA.MarketParams documentation
    function _createMarket(MarketParams memory params_) internal returns (uint256) {
        // Upfront permission and timing checks
        {
            // Check that the auctioneer is allowing new markets to be created
            if (!allowNewMarkets) revert Auctioneer_NewMarketsNotAllowed();
            // Restrict the use of a callback address unless allowed
            if (!callbackAuthorized[msg.sender] && params_.callbackAddr != address(0))
                revert Auctioneer_NotAuthorized();
            // Start time must be zero or in the future
            if (params_.start > 0 && params_.start < block.timestamp)
                revert Auctioneer_InvalidParams();
        }
        // Register new market on aggregator and get marketId
        uint256 marketId = _aggregator.registerMarket(params_.payoutToken, params_.quoteToken);

        // Set basic market data
        BondMarket storage market = markets[marketId];
        market.owner = msg.sender;
        market.quoteToken = params_.quoteToken;
        market.payoutToken = params_.payoutToken;
        market.callbackAddr = params_.callbackAddr;
        market.capacity = params_.capacity;

        // Check that the fixed discount is in bounds (cannot be greater than or equal to 100%)
        BondTerms storage term = terms[marketId];
        for (uint8 i = 0; i < params_.fixedDiscount.length; i++) {
            if (
                params_.fixedDiscount[i] >= ONE_HUNDRED_PERCENT ||
                params_.fixedDiscount[i] > params_.maxDiscountFromCurrent[i]
            ) revert Auctioneer_InvalidParams();
        }
        term.fixedDiscount = params_.fixedDiscount;

        // Validate oracle and get price variables
        (uint256[] memory price, uint256[] memory oracleConversion, uint256[] memory scale) = _validateOracle(
            marketId,
            params_.oracle,
            params_.quoteToken,
            params_.payoutToken,
            params_.fixedDiscount
        );
        term.oracle = params_.oracle;
        term.oracleConversion = oracleConversion;
        term.scale = scale;

        for (uint8 i = 0; i < params_.maxDiscountFromCurrent.length; i++) {
            // Check that the max discount from current price is in bounds (cannot be greater than 100%)
            if (params_.maxDiscountFromCurrent[i] >= ONE_HUNDRED_PERCENT)
                revert Auctioneer_InvalidParams();

            // Calculate the minimum price for the market
            term.minPrice[i] = price[i].mulDivUp(
                uint256(ONE_HUNDRED_PERCENT - params_.maxDiscountFromCurrent[i]),
                uint256(ONE_HUNDRED_PERCENT)
            );
        }

        // Check time bounds
        if (
            params_.duration < minMarketDuration ||
            params_.depositInterval < minDepositInterval ||
            params_.depositInterval > params_.duration
        ) revert Auctioneer_InvalidParams();

        // Calculate the maximum payout amount for this market
        for (uint8 i = 0; i < market.maxPayout.length; i++) {
            market.maxPayout[i] = params_.capacity[i].mulDiv(
                uint256(params_.depositInterval),
                uint256(params_.duration)
            );
        }

        // Store bond time terms
        term.vesting = params_.vesting;
        uint48 start = params_.start == 0 ? uint48(block.timestamp) : params_.start;
        term.start = start;
        term.conclusion = start + params_.duration;

        address[] memory payoutTokensAddresses = new address[](params_.payoutToken.length);
        for (uint8 i = 0; i < params_.payoutToken.length; i++) {
            payoutTokensAddresses[i] = address(params_.payoutToken[i]);
        }

        // Emit market created event
        emit MarketCreated(
            marketId,
            payoutTokensAddresses,
            address(params_.quoteToken),
            params_.vesting
        );

        return marketId;
    }

    function _validateOracle(
        uint256 id_,
        IBondOracle[] memory oracle_,
        ERC20 quoteToken_,
        ERC20[] memory payoutToken_,
        uint48[] memory fixedDiscount_
    )
        internal
        returns (
            uint256[] memory,
            uint256[] memory,
            uint256[] memory
        )
    {
        // Ensure token decimals are in bounds
        uint8 quoteTokenDecimals = quoteToken_.decimals();
        if (quoteTokenDecimals < 6 || quoteTokenDecimals > 18) revert Auctioneer_InvalidParams();

        uint256[] memory currentPrice = new uint256[](oracle_.length);
        uint256[] memory oracleConversion = new uint256[](oracle_.length);
        uint256[] memory scale = new uint256[](oracle_.length);        

        for (uint8 i = 0; i < oracle_.length; i++) {
            // Ensure token decimals are in bounds
            uint8 payoutTokenDecimals = payoutToken_[i].decimals();
            if (payoutTokenDecimals < 6 || payoutTokenDecimals > 18) revert Auctioneer_InvalidParams();

            // Check that oracle is valid. It should:
            // 1. Be a contract
            if (address(oracle_[i]) == address(0) || address(oracle_[i]).code.length == 0)
                revert Auctioneer_InvalidParams();

            // 2. Allow registering markets
            oracle_[i].registerMarket(id_, quoteToken_, payoutToken_[i]);

            // 3. Return a valid price for the quote token : payout token pair
            currentPrice[i] = oracle_[i].currentPrice(id_);
            if (currentPrice[i] == 0) revert Auctioneer_OraclePriceZero();

            // 4. Return a valid decimal value for the quote token : payout token pair price
            uint8 oracleDecimals = oracle_[i].decimals(id_);
            if (oracleDecimals < 6 || oracleDecimals > 18) revert Auctioneer_InvalidParams();

            // Calculate scaling values for market:
            // 1. We need a value to convert between the oracle decimals to the bond market decimals
            // 2. We need the bond scaling value to convert between quote and payout tokens using the market price

            // Get the price decimals for the current oracle price
            // Oracle price is in quote tokens per payout token
            // E.g. if quote token is $10 and payout token is $2000,
            // then the oracle price is 200 quote tokens per payout token.
            // If the oracle has 18 decimals, then it would return 200 * 10^18.
            // In this case, the price decimals would be 2 since 200 = 2 * 10^2.
            int8 priceDecimals = _getPriceDecimals(
                currentPrice[i].mulDivUp(
                    uint256(ONE_HUNDRED_PERCENT - fixedDiscount_[i]),
                    uint256(ONE_HUNDRED_PERCENT)
                ),
                oracleDecimals
            );

            // Check price decimals in reasonable range
            // These bounds are quite large and it is unlikely any combination of tokens
            // will have a price difference larger than 10^24 in either direction.
            // Check that oracle decimals are large enough to avoid precision loss from negative price decimals
            if (int8(oracleDecimals) <= -priceDecimals || priceDecimals > 24)
                revert Auctioneer_InvalidParams();

            // Calculate the oracle price conversion factor
            // oraclePriceFactor = int8(oracleDecimals) + priceDecimals;
            // bondPriceFactor = 36 - priceDecimals / 2 + priceDecimals;
            // oracleConversion = 10^(bondPriceFactor - oraclePriceFactor);
            oracleConversion[i] = 10**uint8(36 - priceDecimals / 2 - int8(oracleDecimals));

            // 
            currentPrice[i] *= oracleConversion[i];

            // Unit to scale calculation for this market by to ensure reasonable values
            // for price, debt, and control variable without under/overflows.
            //
            // scaleAdjustment should be equal to (payoutDecimals - quoteDecimals) - ((payoutPriceDecimals - quotePriceDecimals) / 2)
            // scale = 10^(36 + scaleAdjustment);
            scale[i] = 10 **
                uint8(36 + int8(payoutTokenDecimals) - int8(quoteTokenDecimals) - priceDecimals / 2);
        }

        return (currentPrice, oracleConversion, scale);
    }

    /// @inheritdoc IBondAuctioneer
    function pushOwnership(uint256 id_, address newOwner_) external override {
        if (msg.sender != markets[id_].owner) revert Auctioneer_OnlyMarketOwner();
        newOwners[id_] = newOwner_;
    }

    /// @inheritdoc IBondAuctioneer
    function pullOwnership(uint256 id_) external override {
        if (msg.sender != newOwners[id_]) revert Auctioneer_NotAuthorized();
        markets[id_].owner = newOwners[id_];
    }

    /// @inheritdoc IBondOFDA
    function setMinMarketDuration(uint48 duration_) external override requiresAuth {
        // Restricted to authorized addresses

        // Require duration to be greater than minimum deposit interval and at least 1 day
        if (duration_ < minDepositInterval || duration_ < 1 days) revert Auctioneer_InvalidParams();

        minMarketDuration = duration_;
    }

    /// @inheritdoc IBondOFDA
    function setMinDepositInterval(uint48 depositInterval_) external override requiresAuth {
        // Restricted to authorized addresses

        // Require min deposit interval to be less than minimum market duration and at least 1 hour
        if (depositInterval_ > minMarketDuration || depositInterval_ < 1 hours)
            revert Auctioneer_InvalidParams();

        minDepositInterval = depositInterval_;
    }

    // Unused, but required by interface
    function setIntervals(uint256 id_, uint32[3] calldata intervals_) external override {}

    // Unused, but required by interface
    function setDefaults(uint32[6] memory defaults_) external override {}

    /// @inheritdoc IBondAuctioneer
    function setAllowNewMarkets(bool status_) external override requiresAuth {
        // Restricted to authorized addresses
        allowNewMarkets = status_;
    }

    /// @inheritdoc IBondAuctioneer
    function setCallbackAuthStatus(address creator_, bool status_) external override requiresAuth {
        // Restricted to authorized addresses
        callbackAuthorized[creator_] = status_;
    }

    /// @inheritdoc IBondAuctioneer
    function closeMarket(uint256 id_) external override {
        if (msg.sender != markets[id_].owner) revert Auctioneer_OnlyMarketOwner();
        terms[id_].conclusion = uint48(block.timestamp);
        markets[id_].capacity = new uint256[](markets[id_].capacity.length);

        emit MarketClosed(id_);
    }

    /* ========== TELLER FUNCTIONS ========== */

    /// @inheritdoc IBondAuctioneer
    function purchaseBond(
        uint256 id_,
        uint256 amount_,
        uint256[] calldata minAmountOut_
    ) external override returns (uint256[] memory payout) {
        if (msg.sender != address(_teller)) revert Auctioneer_NotAuthorized();

        BondMarket storage market = markets[id_];
        BondTerms memory term = terms[id_];

        // If market uses a callback, check that owner is still callback authorized
        if (market.callbackAddr != address(0) && !callbackAuthorized[market.owner])
            revert Auctioneer_NotAuthorized();

        // Check if market is live, if not revert
        if (!isLive(id_)) revert Auctioneer_MarketNotActive();

        // Get current price with fixed discount
        uint256[] memory price = marketPrice(id_);

        for (uint8 i = 0; i < market.payoutToken.length; i++) {
            // Payout for the deposit = amount / price
            //
            // where:
            // payout = payout tokens out
            // amount = quote tokens in
            // price = quote tokens : payout token (i.e. 200 QUOTE : BASE), adjusted for scaling
            payout[i] = amount_.mulDiv(term.scale[i], price[i]);

            // Payout must be greater than user inputted minimum
            if (payout[i] < minAmountOut_[i]) revert Auctioneer_AmountLessThanMinimum();

            // Markets have a max payout amount per transaction
            if (payout[i] > market.maxPayout[i]) revert Auctioneer_MaxPayoutExceeded();

            // Update Capacity

            // Capacity is either the number of payout tokens that the market can sell
            // (if capacity in quote is false),
            //
            // or the number of quote tokens that the market can buy
            // (if capacity in quote is true)

            // If amount/payout is greater than capacity remaining, revert
            if (payout[i] > market.capacity[i])
                revert Auctioneer_NotEnoughCapacity();
            // Capacity is decreased by the deposited or paid amount
            market.capacity[i] -= payout[i];

            // Markets keep track of how many quote tokens have been sold
            market.sold[i] += payout[i];
        }

        // Markets keep track of how many quote tokens have been purchased
        market.purchased += amount_;
    }

    /* ========== INTERNAL VIEW FUNCTIONS ========== */

    /// @notice         Helper function to calculate number of price decimals based on the value returned from the price feed.
    /// @param price_   The price to calculate the number of decimals for
    /// @return         The number of decimals
    function _getPriceDecimals(uint256 price_, uint8 feedDecimals_) internal pure returns (int8) {
        int8 decimals;
        while (price_ >= 10) {
            price_ = price_ / 10;
            decimals++;
        }

        // Subtract the stated decimals from the calculated decimals to get the relative price decimals.
        // Required to do it this way vs. normalizing at the beginning since price decimals can be negative.
        return decimals - int8(feedDecimals_);
    }

    /* ========== EXTERNAL VIEW FUNCTIONS ========== */

    /// @inheritdoc IBondAuctioneer
    function getMarketInfoForPurchase(uint256 id_)
        external
        view
        returns (
            address owner,
            address callbackAddr,
            ERC20[] memory payoutToken,
            ERC20 quoteToken,
            uint48 vesting,
            uint256[] memory maxPayout_
        )
    {
        BondMarket memory market = markets[id_];
        return (
            market.owner,
            market.callbackAddr,
            market.payoutToken,
            market.quoteToken,
            terms[id_].vesting,
            maxPayout(id_)
        );
    }

    /// @inheritdoc IBondAuctioneer
    function marketPrice(uint256 id_) public view override returns (uint256[] memory prices) {
        // Get the current price from the oracle
        BondTerms memory term = terms[id_];
        
        for (uint8 i = 0; i < markets[id_].payoutToken.length; i++) {
            uint256 oraclePrice = term.oracle[i].currentPrice(id_);
             // Revert if price is 0
            if (oraclePrice == 0) revert Auctioneer_OraclePriceZero();

            // Convert the oracle price to market price decimals using the oracleConversion
            uint256 price = oraclePrice * term.oracleConversion[i];

            // Apply the fixed discount
            uint256 discountedPrice = price.mulDivUp(
                ONE_HUNDRED_PERCENT - term.fixedDiscount[i],
                ONE_HUNDRED_PERCENT
            );

            // Check if price is less than the minimum price and return
            prices[i] = discountedPrice < term.minPrice[i] ? term.minPrice[i] : discountedPrice;
        }
    }

    /// @inheritdoc IBondAuctioneer
    function marketScale(uint256 id_) external view override returns (uint256[] memory) {
        return terms[id_].scale;
    }

    /// @inheritdoc IBondAuctioneer
    function payoutFor(
        uint256 amount_,
        uint256 id_,
        address referrer_
    ) public view override returns (uint256[] memory payouts) {
        uint256[] memory prices = marketPrice(id_);
        uint256[] memory maxPayouts = maxPayout(id_);


        for (uint8 i = 0; i < markets[id_].payoutToken.length; i++) {
            // Calculate the payout for the given amount of tokens
            uint256 fee = amount_.mulDiv(_teller.getFee(referrer_), ONE_HUNDRED_PERCENT);
            uint256 payout = (amount_ - fee).mulDiv(terms[id_].scale[i], prices[i]);

            // Check that the payout is less than or equal to the maximum payout,
            // Revert if not, otherwise return the payout
            if (payout > maxPayouts[i]) {
                revert Auctioneer_MaxPayoutExceeded();
            } else {
                payouts[i] = payout;
            }
        }
    }

    /// @inheritdoc IBondOFDA
    function maxPayout(uint256 id_) public view override returns (uint256[] memory maxPayouts) {
        BondMarket memory market = markets[id_];

        for (uint8 i = 0; i < market.payoutToken.length; i++) {
            // Cap max payout at the remaining capacity
            maxPayouts[i] = market.maxPayout[i] > market.capacity[i] ? market.capacity[i] : market.maxPayout[i];
        }
    }

    /// @inheritdoc IBondAuctioneer
    function maxAmountAccepted(uint256 id_, address referrer_) external view returns (uint256) {
        // Calculate maximum amount of quote tokens that correspond to max bond size
        // Maximum of the maxPayout and the remaining capacity converted to quote tokens
        BondMarket memory market = markets[id_];
        BondTerms memory term = terms[id_];
        uint256[] memory price = marketPrice(id_);

        uint256 quoteCapacity = 0;
        uint256 maxQuote = 0;

        for (uint8 i = 0; i < market.payoutToken.length; i++) {
            quoteCapacity += market.capacity[i].mulDiv(price[i], term.scale[i]);
            maxQuote += market.maxPayout[i].mulDiv(price[i], term.scale[i]);
        }

        uint256 amountAccepted = quoteCapacity < maxQuote ? quoteCapacity : maxQuote;

        // Take into account teller fees and return
        // Estimate fee based on amountAccepted. Fee taken will be slightly larger than
        // this given it will be taken off the larger amount, but this avoids rounding
        // errors with trying to calculate the exact amount.
        // Therefore, the maxAmountAccepted is slightly conservative.
        uint256 estimatedFee = amountAccepted.mulDiv(
            _teller.getFee(referrer_),
            ONE_HUNDRED_PERCENT
        );

        return amountAccepted + estimatedFee;
    }

    /// @inheritdoc IBondAuctioneer
    function isInstantSwap(uint256 id_) public view returns (bool) {
        uint256 vesting = terms[id_].vesting;
        return (vesting <= MAX_FIXED_TERM) ? vesting == 0 : vesting <= block.timestamp;
    }

    /// @inheritdoc IBondAuctioneer
    function isEmpty(uint256 id_) public view override returns (bool) {
        bool isEmpty_ = false;
        for (uint8 i = 0; i < markets[id_].capacity.length; i++) {
            if (markets[id_].capacity[i] == 0) {
                isEmpty_ = true;
                break;
            }
        }
        return isEmpty_;
    }

    /// @inheritdoc IBondAuctioneer
    function isLive(uint256 id_) public view override returns (bool) {
        return (!isEmpty(id_) &&
            terms[id_].conclusion > uint48(block.timestamp) &&
            terms[id_].start <= uint48(block.timestamp));
    }

    /// @inheritdoc IBondAuctioneer
    function ownerOf(uint256 id_) external view override returns (address) {
        return markets[id_].owner;
    }

    /// @inheritdoc IBondAuctioneer
    function getTeller() external view override returns (IBondTeller) {
        return _teller;
    }

    /// @inheritdoc IBondAuctioneer
    function getAggregator() external view override returns (IBondAggregator) {
        return _aggregator;
    }

    /// @inheritdoc IBondAuctioneer
    function currentCapacity(uint256 id_) external view override returns (uint256[] memory) {
        return markets[id_].capacity;
    }
}
