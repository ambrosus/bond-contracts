/// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.15;

import {ERC20} from "solmate/src/tokens/ERC20.sol";
import {Auth, Authority} from "solmate/src/auth/Auth.sol";

import {IBondFPA, IBondAuctioneer} from "../interfaces/IBondFPA.sol";
import {IBondTeller} from "../interfaces/IBondTeller.sol";
import {IBondCallback} from "../interfaces/IBondCallback.sol";
import {IBondAggregator} from "../interfaces/IBondAggregator.sol";

import {TransferHelper} from "../lib/TransferHelper.sol";
import {FullMath} from "../lib/FullMath.sol";

/// @title Bond Fixed Price Auctioneer
/// @notice Bond Fixed Price Auctioneer Base Contract
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
///      an Aggregator to register new markets. The Fixed Price Auctioneer
///      lets issuers set a Fixed Price to buy a target amount of quote tokens or sell
///      a target amount of payout tokens over the duration of a market.
///      See IBondFPA.sol for price format details.
///
/// @author Oighty
abstract contract BondBaseFPA is IBondFPA, Auth {
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

    /* ========== EVENTS ========== */

    event MarketCreated(
        uint256 indexed id,
        address[] indexed payoutToken,
        address indexed quoteToken,
        uint48 vesting,
        uint256 fixedPrice
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

    /// @notice core market creation logic, see IBondFPA.MarketParams documentation
    function _createMarket(MarketParams memory params_) internal returns (uint256) {
        {
            // Check that the auctioneer is allowing new markets to be created
            if (!allowNewMarkets) revert Auctioneer_NewMarketsNotAllowed();
            
            // Ensure params are in bounds
            for (uint8 i = 0; i < params_.payoutTokensNumber; i++) {
                uint8 payoutTokenDecimals = params_.payoutToken[i].decimals();
                int8 scaleAdjustment = params_.scaleAdjustment[i];

                if (payoutTokenDecimals < 6 || payoutTokenDecimals > 18)
                    revert Auctioneer_InvalidParams();
                if (scaleAdjustment < -24 || scaleAdjustment > 24)
                    revert Auctioneer_InvalidParams();
            }
            
            uint8 quoteTokenDecimals = params_.quoteToken.decimals();
            if (quoteTokenDecimals < 6 || quoteTokenDecimals > 18)
                revert Auctioneer_InvalidParams();
            

            // Restrict the use of a callback address unless allowed
            if (!callbackAuthorized[msg.sender] && params_.callbackAddr != address(0))
                revert Auctioneer_NotAuthorized();

            // Start time must be zero or in the future
            if (params_.start > 0 && params_.start < block.timestamp)
                revert Auctioneer_InvalidParams();
        }

        // Unit to scale calculation for this market by to ensure reasonable values.
        // See IBondFPA for more details.
        //
        // scaleAdjustment should be equal to (payoutDecimals - quoteDecimals) - ((payoutPriceDecimals - quotePriceDecimals) / 2)
        uint256[] memory scale = new uint256[](params_.payoutTokensNumber);
        for (uint8 i = 0; i < params_.payoutTokensNumber; i++) {
            unchecked {
                scale[i] = 10**uint8(36 + params_.scaleAdjustment[i]);
            }
        }
        
        // Check that price is not zero
        for (uint8 i = 0; i < params_.payoutTokensNumber; i++) {
            if (params_.formattedPrice[i] == 0) revert Auctioneer_InvalidParams();
        }

        // Check time bounds
        if (
            params_.duration < minMarketDuration ||
            params_.depositInterval < minDepositInterval ||
            params_.depositInterval > params_.duration
        ) revert Auctioneer_InvalidParams();

        // Calculate the maximum payout amount for this market
        uint256[] memory _maxPayout = new uint256[](params_.payoutTokensNumber);
        for (uint8 i = 0; i < params_.payoutTokensNumber; i++) {
            _maxPayout[i] = params_.capacity[i].mulDiv(uint256(params_.depositInterval), uint256(params_.duration));
        }

        // Register new market on aggregator and get marketId
        ERC20[] memory payoutTokensAddresses_ = new ERC20[](params_.payoutTokensNumber);
        for (uint8 i = 0; i < params_.payoutTokensNumber; i++) {
            payoutTokensAddresses_[i] = params_.payoutToken[i];
        }

        uint256 marketId = _aggregator.registerMarket(payoutTokensAddresses_, params_.quoteToken);

        uint256 _purchased = 0;
        uint256[] memory _sold = new uint256[](params_.payoutTokensNumber);

        markets[marketId] = BondMarket(
            msg.sender,
            params_.payoutToken,
            params_.quoteToken,
            params_.callbackAddr,
            params_.capacity,
            _maxPayout,
            params_.formattedPrice,
            scale,
            _sold,
            _purchased
        );

        // Calculate and store time terms
        uint48 start = params_.start == 0 ? uint48(block.timestamp) : params_.start;

        terms[marketId] = BondTerms({
            start: start,
            conclusion: start + params_.duration,
            vesting: params_.vesting
        });

        address[] memory payoutTokensAddresses = new address[](params_.payoutToken.length);
        for (uint8 i = 0; i < params_.payoutTokensNumber; i++) {
            payoutTokensAddresses[i] = address(params_.payoutToken[i]);
        }

        emit MarketCreated(
            marketId,
            payoutTokensAddresses,
            address(params_.quoteToken),
            params_.vesting,
            params_.formattedPrice[0]
        );

        return marketId;
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

    /// @inheritdoc IBondFPA
    function setMinMarketDuration(uint48 duration_) external override requiresAuth {
        // Restricted to authorized addresses

        // Require duration to be greater than minimum deposit interval and at least 1 day
        if (duration_ < minDepositInterval || duration_ < 1 days) revert Auctioneer_InvalidParams();

        minMarketDuration = duration_;
    }

    /// @inheritdoc IBondFPA
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
        markets[id_].capacity = [0, 0, 0];

        emit MarketClosed(id_);
    }

    /* ========== TELLER FUNCTIONS ========== */

    /// @inheritdoc IBondAuctioneer
    function purchaseBond(
        uint256 id_,
        uint256 amount_,
        uint256[] calldata minAmountOut_
    ) external override returns (uint256[] memory) {
        if (msg.sender != address(_teller)) revert Auctioneer_NotAuthorized();

        BondMarket storage market = markets[id_];
        uint256[] memory payout = new uint256[](market.payoutToken.length);

        // If market uses a callback, check that owner is still callback authorized
        if (market.callbackAddr != address(0) && !callbackAuthorized[market.owner])
            revert Auctioneer_NotAuthorized();

        // Check if market is live, if not revert
        if (!isLive(id_)) revert Auctioneer_MarketNotActive();

        for (uint8 i = 0; i < market.payoutToken.length; i++) {
            // Calculate payout amount from fixed price
            payout[i] = amount_.mulDiv(market.scale[i], market.price[i]);

            // Payout must be greater than user inputted minimum
            if (payout[i] < minAmountOut_[i]) revert Auctioneer_AmountLessThanMinimum();

            // Markets have a max payout amount per transaction
            if (payout[i] > market.maxPayout[i]) revert Auctioneer_MaxPayoutExceeded();

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

        return payout;
    }

    /* ========== VIEW FUNCTIONS ========== */

    /* ========== EXTERNAL VIEW FUNCTIONS ========== */

    /// @inheritdoc IBondAuctioneer
    function getMarketInfoForPurchase(uint256 id_)
        external
        view
        returns (
            address,
            address,
            ERC20[] memory,
            ERC20,
            uint48,
            uint256[] memory
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
    function marketPrice(uint256 id_) public view override returns (uint256[] memory) {
        uint256[] memory prices = new uint256[](markets[id_].price.length);

        for (uint8 i = 0; i < markets[id_].price.length; i++) {
            prices[i] = markets[id_].price[i];
        }

        return prices;
    }

    /// @inheritdoc IBondAuctioneer
    function marketScale(uint256 id_) external view override returns (uint256[] memory) {
        uint256[] memory scale = new uint256[](markets[id_].scale.length);

        for (uint8 i = 0; i < markets[id_].scale.length; i++) {
            scale[i] = markets[id_].scale[i];
        }

        return scale;
    }

    /// @inheritdoc IBondAuctioneer
    function payoutFor(
        uint256 amount_,
        uint256 id_,
        address referrer_
    ) public view override returns (uint256[] memory) {
        // Calculate the payout for the given amount of tokens
        uint256 fee = amount_.mulDiv(_teller.getFee(referrer_), ONE_HUNDRED_PERCENT);
        uint256 amountWithoutFee = amount_ - fee;
        uint256[] memory prices = marketPrice(id_);
        uint256[] memory payouts = new uint256[](prices.length);
        uint256[] memory maxPayouts = maxPayout(id_);

        for (uint8 i = 0; i < prices.length; i++) {
            payouts[i] = amountWithoutFee.mulDiv(markets[id_].scale[i], prices[i]);

            // Check that the payout is less than or equal to the maximum payout,
            // Revert if not, otherwise return the payout
            if (payouts[i] > maxPayouts[i]) {
                revert Auctioneer_MaxPayoutExceeded();
            }
        }

        return payouts;
    }

    /// @inheritdoc IBondAuctioneer
    function maxAmountAccepted(uint256 id_, address referrer_) external view returns (uint256) {
        // Calculate maximum amount of quote tokens that correspond to max bond size
        // Maximum of the maxPayout and the remaining capacity converted to quote tokens
        BondMarket memory market = markets[id_];
        uint256[] memory prices = marketPrice(id_);

        uint256 quoteCapacity = 0;
        uint256 maxQuote = 0;

        for (uint8 i = 0; i < prices.length; i++) {
            quoteCapacity += market.capacity[i].mulDiv(
                prices[i],
                market.scale[i]
            );

            maxQuote += market.maxPayout[i].mulDiv(
                prices[i],
                market.scale[i]
            );
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

    /// @inheritdoc IBondFPA
    function maxPayout(uint256 id_) public view override returns (uint256[] memory) {
        BondMarket memory market = markets[id_];
        uint256[] memory prices = marketPrice(id_);

        uint256[] memory maxPayouts = new uint256[](prices.length);
        for (uint8 i = 0; i < prices.length; i++) {
            maxPayouts[i] = market.maxPayout[i] > market.capacity[i]
                ? market.capacity[i]
                : market.maxPayout[i];
        }

        return maxPayouts;
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
        uint256[] memory capacity = new uint256[](markets[id_].capacity.length);

        for (uint8 i = 0; i < markets[id_].capacity.length; i++) {
            capacity[i] = markets[id_].capacity[i];
        }

        return capacity;
    }
}
