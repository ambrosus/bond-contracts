// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity 0.8.15;

import {ERC20} from "solmate/src/tokens/ERC20.sol";
import {ReentrancyGuard} from "solmate/src/utils/ReentrancyGuard.sol";
import {Auth, Authority} from "solmate/src/auth/Auth.sol";

import {IBondSDA, IBondAuctioneer} from "../interfaces/IBondSDA.sol";
import {IBondTeller} from "../interfaces/IBondTeller.sol";
import {IBondCallback} from "../interfaces/IBondCallback.sol";
import {IBondAggregator} from "../interfaces/IBondAggregator.sol";

import {TransferHelper} from "../lib/TransferHelper.sol";
import {FullMath} from "../lib/FullMath.sol";

/// @title Bond Sequential Dutch Auctioneer (SDA) v1.1
/// @notice Bond Sequential Dutch Auctioneer Base Contract
/// @dev Bond Protocol is a system to create Olympus-style bond markets
///      for any token pair. The markets do not require maintenance and will manage
///      bond prices based on activity. Bond issuers create BondMarkets that pay out
///      a Payout Token in exchange for deposited Quote Tokens. Users can purchase
///      future-dated Payout Tokens with Quote Tokens at the current market price and
///      receive Bond Tokens to represent their position while their bond vests.
///      Once the Bond Tokens vest, they can redeem it for the Quote Tokens.
///
/// @dev The Auctioneer contract allows users to create and manage bond markets.
///      All bond pricing logic and market data is stored in the Auctioneer.
///      A Auctioneer is dependent on a Teller to serve external users and
///      an Aggregator to register new markets. This implementation of the Auctioneer
///      uses a Sequential Dutch Auction pricing system to buy a target amount of quote
///      tokens or sell a target amount of payout tokens over the duration of a market.
///
/// @author Oighty, Zeus, Potted Meat, indigo
abstract contract BondBaseSDA is IBondSDA, Auth {
    using TransferHelper for ERC20;
    using FullMath for uint256;

    /* ========== ERRORS ========== */

    error Auctioneer_OnlyMarketOwner();
    error Auctioneer_InitialPriceLessThanMin();
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
        uint256[] initialPrice
    );
    event MarketClosed(uint256 indexed id);
    event Tuned(uint256 indexed id, uint256[] oldControlVariable, uint256[] newControlVariable);
    event DefaultsUpdated(
        uint32 defaultTuneInterval,
        uint32 defaultTuneAdjustment,
        uint32 minDebtDecayInterval,
        uint32 minDepositInterval,
        uint32 minMarketDuration,
        uint32 minDebtBuffer
    );

    /* ========== STATE VARIABLES ========== */

    /// @notice Main information pertaining to bond market
    mapping(uint256 => BondMarket) public markets;

    /// @notice Information used to control how a bond market changes
    mapping(uint256 => BondTerms) public terms;

    /// @notice Data needed for tuning bond market
    mapping(uint256 => BondMetadata) public metadata;

    /// @notice Control variable changes
    mapping(uint256 => Adjustment) public adjustments;

    /// @notice New address to designate as market owner. They must accept ownership to transfer permissions.
    mapping(uint256 => address) public newOwners;

    /// @notice Whether or not the auctioneer allows new markets to be created
    /// @dev    Changing to false will sunset the auctioneer after all active markets end
    bool public allowNewMarkets;

    /// @notice Whether or not the market creator is authorized to use a callback address
    mapping(address => bool) public callbackAuthorized;

    /// Sane defaults for tuning. Can be adjusted for a specific market via setters.
    uint32 public defaultTuneInterval;
    uint32 public defaultTuneAdjustment;
    /// Minimum values for decay, deposit interval, market duration and debt buffer.
    uint32 public minDebtDecayInterval;
    uint32 public minDepositInterval;
    uint32 public minMarketDuration;
    uint32 public minDebtBuffer;

    // A 'vesting' param longer than 50 years is considered a timestamp for fixed expiry.
    uint48 internal constant MAX_FIXED_TERM = 52 weeks * 50;
    uint48 internal constant FEE_DECIMALS = 1e5; // one percent equals 1000.

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

        defaultTuneInterval = 24 hours;
        defaultTuneAdjustment = 6 hours;
        minDebtDecayInterval = 3 days;
        minDepositInterval = 1 hours;
        minMarketDuration = 1 days;
        minDebtBuffer = 10000; // 10%

        allowNewMarkets = true;
    }

    /* ========== MARKET FUNCTIONS ========== */

    /// @inheritdoc IBondAuctioneer
    function createMarket(bytes calldata params_) external virtual returns (uint256);

    /// @notice core market creation logic, see IBondSDA.MarketParams documentation
    function _createMarket(MarketParams memory params_) internal returns (uint256) {
        {
            // Check that the auctioneer is allowing new markets to be created
            if (!allowNewMarkets) revert Auctioneer_NewMarketsNotAllowed();

            if (params_.payoutToken.length != params_.capacity.length)
                revert Auctioneer_InvalidParams();
            if (params_.payoutToken.length != params_.formattedInitialPrice.length)
                revert Auctioneer_InvalidParams();
            if (params_.payoutToken.length != params_.formattedMinimumPrice.length)
                revert Auctioneer_InvalidParams();
            if (params_.payoutToken.length != params_.scaleAdjustment.length)
                revert Auctioneer_InvalidParams();

            // Ensure params are in bounds
            for (uint8 i = 0; i < params_.payoutToken.length; i++) {
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

        // Unit to scale calculation for this market by to ensure reasonable values
        // for price, debt, and control variable without under/overflows.
        // See IBondSDA for more details.
        //
        // scaleAdjustment should be equal to (payoutDecimals - quoteDecimals) - ((payoutPriceDecimals - quotePriceDecimals) / 2)
        uint256[] memory scale = new uint256[](params_.payoutToken.length);
        for (uint8 i = 0; i < params_.scaleAdjustment.length; i++) {
            unchecked {
                scale[i] = 10**uint8(36 + params_.scaleAdjustment[i]);
            }
        }
        
        // Check that initial price is greater than minimum price
        for (uint8 i = 0; i < params_.formattedInitialPrice.length; i++) {  
            if (params_.formattedInitialPrice[i] < params_.formattedMinimumPrice[i])
                revert Auctioneer_InitialPriceLessThanMin();
        }

        // Register new market on aggregator and get marketId
        uint256 marketId = _aggregator.registerMarket(params_.payoutToken, params_.quoteToken);

        uint32 debtDecayInterval;
        {
            // Check time bounds
            if (
                params_.duration < minMarketDuration ||
                params_.depositInterval < minDepositInterval ||
                params_.depositInterval > params_.duration
            ) revert Auctioneer_InvalidParams();

            // The debt decay interval is how long it takes for price to drop to 0 from the last decay timestamp.
            // In reality, a 50% drop is likely a guaranteed bond sale. Therefore, debt decay interval needs to be
            // long enough to allow a bond to adjust if oversold. It also needs to be some multiple of deposit interval
            // because you don't want to go from 100 to 0 during the time frame you expected to sell a single bond.
            // A multiple of 5 is a sane default observed from running OP v1 bond markets.
            uint32 userDebtDecay = params_.depositInterval * 5;
            debtDecayInterval = minDebtDecayInterval > userDebtDecay
                ? minDebtDecayInterval
                : userDebtDecay;

            uint256[] memory tuneIntervalCapacity = new uint256[](params_.capacity.length);
            uint256[] memory tuneBelowCapacity = new uint256[](params_.capacity.length);
            uint256[] memory lastTuneDebt = new uint256[](params_.capacity.length);

            for (uint8 i = 0; i < params_.capacity.length; i++) {
                tuneIntervalCapacity[i] = params_.capacity[i].mulDiv(
                    uint256(
                        params_.depositInterval > defaultTuneInterval
                            ? params_.depositInterval
                            : defaultTuneInterval
                    ),
                    uint256(params_.duration)
                );

                tuneBelowCapacity[i] = params_.capacity[i] - tuneIntervalCapacity[i];

                lastTuneDebt[i] = params_.capacity[i].mulDiv(
                    uint256(debtDecayInterval),
                    uint256(params_.duration)
                );
            }

            uint48 start_ = params_.start == 0 ? uint48(block.timestamp) : params_.start;
            metadata[marketId] = BondMetadata({
                lastTune: start_,
                lastDecay: start_,
                depositInterval: params_.depositInterval,
                tuneInterval: params_.depositInterval > defaultTuneInterval
                    ? params_.depositInterval
                    : defaultTuneInterval,
                tuneAdjustmentDelay: defaultTuneAdjustment,
                debtDecayInterval: debtDecayInterval,
                tuneIntervalCapacity: tuneIntervalCapacity,
                tuneBelowCapacity: tuneBelowCapacity,
                lastTuneDebt: lastTuneDebt
            });
        }

        // Initial target debt is equal to capacity scaled by the ratio of the debt decay interval and the length of the market.
        // This is the amount of debt that should be decayed over the decay interval if no purchases are made.
        // Note price should be passed in a specific format:
        // price = (payoutPriceCoefficient / quotePriceCoefficient)
        //         * 10**(36 + scaleAdjustment + quoteDecimals - payoutDecimals + payoutPriceDecimals - quotePriceDecimals)
        // See IBondSDA for more details and variable definitions.
        uint256[] memory targetDebt;
        uint256[] memory _maxPayout; 
        for (uint8 i = 0; i < params_.capacity.length; i++) {
            targetDebt[i] = params_.capacity[i].mulDiv(uint256(debtDecayInterval), uint256(params_.duration));

            // Max payout is the amount of capacity that should be utilized in a deposit
            // interval. for example, if capacity is 1,000 TOKEN, there are 10 days to conclusion,
            // and the preferred deposit interval is 1 day, max payout would be 100 TOKEN.
            // Additionally, max payout is the maximum amount that a user can receive from a single
            // purchase at that moment in time.
            _maxPayout[i] = params_.capacity[i].mulDiv(
                uint256(params_.depositInterval),
                uint256(params_.duration)
            );
        }

        markets[marketId] = BondMarket({
            owner: msg.sender,
            payoutToken: params_.payoutToken,
            quoteToken: params_.quoteToken,
            callbackAddr: params_.callbackAddr,
            capacity: params_.capacity,
            totalDebt: targetDebt,
            minPrice: params_.formattedMinimumPrice,
            maxPayout: _maxPayout,
            purchased: 0,
            sold: new uint256[](params_.payoutToken.length),
            scale: scale
        });

        // Max debt serves as a circuit breaker for the market. let's say the quote token is a stablecoin,
        // and that stablecoin depegs. without max debt, the market would continue to buy until it runs
        // out of capacity. this is configurable with a 3 decimal buffer (1000 = 1% above initial price).
        // Note that its likely advisable to keep this buffer wide.
        // Note that the buffer is above 100%. i.e. 10% buffer = initial debt * 1.1
        // 1e5 = 100,000. 10,000 / 100,000 = 10%.
        // See IBondSDA.MarketParams for more information on determining a reasonable debt buffer.
        uint256[] memory maxDebt = new uint256[](_maxPayout.length);
        for (uint8 i = 0; i < _maxPayout.length; i++) {
            uint256 minDebtBuffer_ = _maxPayout[i].mulDiv(FEE_DECIMALS, targetDebt[i]) > minDebtBuffer
                ? _maxPayout[i].mulDiv(FEE_DECIMALS, targetDebt[i])
                : minDebtBuffer;
            maxDebt[i] = targetDebt[i] +
                targetDebt[i].mulDiv(
                    uint256(params_.debtBuffer > minDebtBuffer_ ? params_.debtBuffer : minDebtBuffer_),
                    1e5
                );
        }

        // The control variable is set as the ratio of price to the initial targetDebt, scaled to prevent under/overflows.
        // It determines the price of the market as the debt decays and is tuned by the market based on user activity.
        // See _tune() for more information.
        //
        // price = control variable * debt / scale
        // therefore, control variable = price * scale / debt
        uint256[] memory controlVariable = new uint256[](params_.formattedInitialPrice.length);
        for (uint8 i = 0; i < params_.formattedInitialPrice.length; i++) {
            controlVariable[i] = params_.formattedInitialPrice[i].mulDiv(
                scale[i],
                targetDebt[i]
            );
        }

        uint48 start = params_.start == 0 ? uint48(block.timestamp) : params_.start;
        terms[marketId] = BondTerms({
            controlVariable: controlVariable,
            maxDebt: maxDebt,
            start: start,
            conclusion: start + uint48(params_.duration),
            vesting: params_.vesting
        });

        address[] memory payoutTokensAddresses = new address[](params_.payoutToken.length);
        for (uint8 i = 0; i < params_.payoutToken.length; i++) {
            payoutTokensAddresses[i] = address(params_.payoutToken[i]);
        }

        emit MarketCreated(
            marketId,
            payoutTokensAddresses,
            address(params_.quoteToken),
            params_.vesting,
            params_.formattedInitialPrice
        );

        return marketId;
    }

    /// @inheritdoc IBondAuctioneer
    function setIntervals(uint256 id_, uint32[3] calldata intervals_) external override {
        // Check that the market is live
        if (!isLive(id_)) revert Auctioneer_InvalidParams();

        // Check that the intervals are non-zero
        if (intervals_[0] == 0 || intervals_[1] == 0 || intervals_[2] == 0)
            revert Auctioneer_InvalidParams();

        // Check that tuneInterval >= tuneAdjustmentDelay
        if (intervals_[0] < intervals_[1]) revert Auctioneer_InvalidParams();

        BondMetadata storage meta = metadata[id_];
        // Check that tuneInterval >= depositInterval
        if (intervals_[0] < meta.depositInterval) revert Auctioneer_InvalidParams();

        // Check that debtDecayInterval >= minDebtDecayInterval
        if (intervals_[2] < minDebtDecayInterval) revert Auctioneer_InvalidParams();

        // Check that sender is market owner
        BondMarket memory market = markets[id_];
        if (msg.sender != market.owner) revert Auctioneer_OnlyMarketOwner();

        // Update intervals
        meta.tuneInterval = intervals_[0];
        for (uint8 i = 0; i < meta.tuneIntervalCapacity.length; i++) {
            // this will update tuneIntervalCapacity based on time remaining
            meta.tuneIntervalCapacity[i] = market.capacity[i].mulDiv(
                uint256(intervals_[0]),
                uint256(terms[id_].conclusion) - block.timestamp
            );

            meta.tuneBelowCapacity[i] = market.capacity[i] > meta.tuneIntervalCapacity[i]
                ? market.capacity[i] - meta.tuneIntervalCapacity[i]
                : 0;
        }
        
        meta.tuneAdjustmentDelay = intervals_[1];
        meta.debtDecayInterval = intervals_[2];
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

    /// @inheritdoc IBondAuctioneer
    function setDefaults(uint32[6] memory defaults_) external override requiresAuth {
        // Restricted to authorized addresses

        // Validate inputs
        // Check that defaultTuneInterval >= defaultTuneAdjustment
        if (defaults_[0] < defaults_[1]) revert Auctioneer_InvalidParams();

        // Check that defaultTuneInterval >= minDepositInterval
        if (defaults_[0] < defaults_[3]) revert Auctioneer_InvalidParams();

        // Check that minDepositInterval <= minMarketDuration
        if (defaults_[3] > defaults_[4]) revert Auctioneer_InvalidParams();

        // Check that minDebtDecayInterval >= 5 * minDepositInterval
        if (defaults_[2] < defaults_[3] * 5) revert Auctioneer_InvalidParams();

        // Update defaults
        defaultTuneInterval = defaults_[0];
        defaultTuneAdjustment = defaults_[1];
        minDebtDecayInterval = defaults_[2];
        minDepositInterval = defaults_[3];
        minMarketDuration = defaults_[4];
        minDebtBuffer = defaults_[5];

        emit DefaultsUpdated(
            defaultTuneInterval,
            defaultTuneAdjustment,
            minDebtDecayInterval,
            minDepositInterval,
            minMarketDuration,
            minDebtBuffer
        );
    }

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
        _close(id_);
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

        uint256[] memory price;
        (price, payout) = _decayAndGetPrice(id_, amount_, uint48(block.timestamp)); // Debt and the control variable decay over time

        for (uint8 i = 0; i < market.payoutToken.length; i++) {
            // Payout must be greater than user inputted minimum
            if (payout[i] < minAmountOut_[i]) revert Auctioneer_AmountLessThanMinimum();

            // Markets have a max payout amount, capping size because deposits
            // do not experience slippage. max payout is recalculated upon tuning
            if (payout[i] > market.maxPayout[i]) revert Auctioneer_MaxPayoutExceeded();

            // Update Capacity and Debt values

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
        

        // Circuit breaker. If max debt is breached, the market is closed
        for (uint8 i = 0; i < market.payoutToken.length; i++) {
            if (term.maxDebt[i] < market.totalDebt[i]) {
                _close(id_);
                return payout;
            }
        } 

        // If market will continue, the control variable is tuned to to expend remaining capacity over remaining market duration
        _tune(id_, uint48(block.timestamp), price);
    }

    /* ========== INTERNAL DEPO FUNCTIONS ========== */

    /// @notice          Close a market
    /// @dev             Closing a market sets capacity to 0 and immediately stops bonding
    function _close(uint256 id_) internal {
        terms[id_].conclusion = uint48(block.timestamp);
        markets[id_].capacity = new uint256[](markets[id_].capacity.length);

        emit MarketClosed(id_);
    }

    /// @notice                 Decay debt, and adjust control variable if there is an active change
    /// @param id_              ID of market
    /// @param amount_          Amount of quote tokens being purchased
    /// @param time_            Current timestamp (saves gas when passed in)
    /// @return marketPrice_    Current market price of bond, accounting for decay
    /// @return payout_         Amount of payout tokens received at current price
    function _decayAndGetPrice(
        uint256 id_,
        uint256 amount_,
        uint48 time_
    ) internal returns (uint256[] memory marketPrice_, uint256[] memory payout_) {
        BondMarket memory market = markets[id_];

        // Debt is a time-decayed sum of tokens spent in a market
        // Debt is added when deposits occur and removed over time
        // |
        // |    debt falls with
        // |   / \  inactivity        / \
        // | /     \              /\ /   \
        // |         \           /        \ / \
        // |           \      /\/
        // |             \  /  and rises
        // |                with deposits
        // |
        // |------------------------------------| t

        // Decay debt by the amount of time since the last decay
        uint256[] memory decayedDebt = currentDebt(id_);
        markets[id_].totalDebt = decayedDebt;

        // Control variable decay

        // The bond control variable is continually tuned. When it is lowered (which
        // lowers the market price), the change is carried out smoothly over time.
        if (adjustments[id_].active) {
            Adjustment storage adjustment = adjustments[id_];

            (uint256[] memory adjustBy, uint48 secondsSince, bool stillActive) = _controlDecay(id_);
            for (uint8 i = 0; i < terms[id_].controlVariable.length; i++) {
                terms[id_].controlVariable[i] -= adjustBy[i];
            }

            if (stillActive) {
                for (uint8 i = 0; i < adjustment.change.length; i++) {
                    adjustment.change[i] -= adjustBy[i];
                }
                adjustment.timeToAdjusted -= secondsSince;
                adjustment.lastAdjustment = time_;
            } else {
                adjustment.active = false;
            }
        }

        // Price is not allowed to be lower than the minimum price
        marketPrice_ = _currentMarketPrice(id_);
        for (uint8 i = 0; i < marketPrice_.length; i++) {
            if (marketPrice_[i] < market.minPrice[i]) marketPrice_[i] = market.minPrice[i];
        }

        // Payout for the deposit = amount / price
        //
        // where:
        // payout = payout tokens out
        // amount = quote tokens in
        // price = quote tokens : payout token (i.e. 200 QUOTE : BASE), adjusted for scaling
        for (uint8 i = 0; i < marketPrice_.length; i++) {
            payout_[i] = amount_.mulDiv(market.scale[i], marketPrice_[i]);
        }

        // Cache storage variables to memory
        uint256 debtDecayInterval = uint256(metadata[id_].debtDecayInterval);
        uint256[] memory lastTuneDebt = metadata[id_].lastTuneDebt;
        uint256 lastDecay = uint256(metadata[id_].lastDecay);

        // Set last decay timestamp based on size of purchase to linearize decay
        // TODO: is this right assuming the lastDecayIncrement is same for all payout tokens? 
        uint256 lastDecayIncrement = debtDecayInterval.mulDivUp(payout_[0], lastTuneDebt[0]);
        metadata[id_].lastDecay += uint48(lastDecayIncrement);

        for (uint8 i = 0; i < marketPrice_.length; i++) {
            // Update total debt following the purchase
            // Goal is to have the same decayed debt post-purchase as pre-purchase so that price is the same as before purchase and then add new debt to increase price
            // 1. Adjust total debt so that decayed debt is equal to the current debt after updating the last decay timestamp.
            //    This is the currentDebt function solved for totalDebt and adding lastDecayIncrement (the number of seconds lastDecay moves forward in time)
            //    to the number of seconds used to calculate the previous currentDebt.
            // 2. Add the payout to the total debt to increase the price.
            uint256 decayOffset = time_ > lastDecay
                ? (
                    debtDecayInterval > (time_ - lastDecay)
                        ? debtDecayInterval - (time_ - lastDecay)
                        : 0
                )
                : debtDecayInterval + (lastDecay - time_);
            markets[id_].totalDebt[i] =
                decayedDebt[i].mulDiv(debtDecayInterval, decayOffset + lastDecayIncrement) +
                payout_[i] +
                1; // add 1 to satisfy price inequality
        }
    }

    /// @notice             Auto-adjust control variable to hit capacity/spend target
    /// @param id_          ID of market
    /// @param time_        Timestamp (saves gas when passed in)
    /// @param price_       Current price of the market
    function _tune(
        uint256 id_,
        uint48 time_,
        uint256[] memory price_
    ) internal {
        BondMetadata memory meta = metadata[id_];
        BondMarket memory market = markets[id_];
        BondTerms memory term = terms[id_];

        // Market tunes in 2 situations:
        // 1. If capacity has exceeded target since last tune adjustment and the market is oversold
        // 2. If a tune interval has passed since last tune adjustment and the market is undersold
        //
        // Markets are created with a target capacity with the expectation that capacity will
        // be utilized evenly over the duration of the market.
        // The intuition with tuning is:
        // - When the market is ahead of target capacity, we should tune based on capacity.
        // - When the market is behind target capacity, we should tune based on time.

        // Compute seconds remaining until market will conclude and total duration of market
        uint256 timeRemaining = uint256(term.conclusion - time_);
        uint256 duration = uint256(term.conclusion - term.start);
        uint256[] memory newControlVariable_ = new uint256[](term.controlVariable.length);

        for (uint8 i = 0; i < market.capacity.length; i++) {
            // Calculate initial capacity based on remaining capacity and amount sold/purchased up to this point
            uint256 initialCapacity = market.capacity[i] + market.sold[i];

            // Calculate timeNeutralCapacity as the capacity expected to be sold up to this point and the current capacity
            // Higher than initial capacity means the market is undersold, lower than initial capacity means the market is oversold
            uint256 timeNeutralCapacity = initialCapacity.mulDiv(duration - timeRemaining, duration) +
                market.capacity[i];

            if (
                (market.capacity[i] < meta.tuneBelowCapacity[i] && timeNeutralCapacity < initialCapacity) ||
                (time_ >= meta.lastTune + meta.tuneInterval && timeNeutralCapacity > initialCapacity)
            ) {
                // Calculate the correct payout to complete on time assuming each bond
                // will be max size in the desired deposit interval for the remaining time
                //
                // i.e. market has 10 days remaining. deposit interval is 1 day. capacity
                // is 10,000 TOKEN. max payout would be 1,000 TOKEN (10,000 * 1 / 10).
                markets[id_].maxPayout[i] = market.capacity[i].mulDiv(uint256(meta.depositInterval), timeRemaining);

                // Calculate ideal target debt to satisfy capacity in the remaining time
                // The target debt is based on whether the market is under or oversold at this point in time
                // This target debt will ensure price is reactive while ensuring the magnitude of being over/undersold
                // doesn't cause larger fluctuations towards the end of the market.
                //
                // Calculate target debt from the timeNeutralCapacity and the ratio of debt decay interval and the length of the market
                uint256 targetDebt = timeNeutralCapacity.mulDiv(
                    uint256(meta.debtDecayInterval),
                    duration
                );

                // Derive a new control variable from the target debt
                newControlVariable_[i] = price_[i].mulDivUp(market.scale[i], targetDebt);

                metadata[id_].lastTune = time_;
                metadata[id_].tuneBelowCapacity[i] = market.capacity[i] > meta.tuneIntervalCapacity[i]
                    ? market.capacity[i] - meta.tuneIntervalCapacity[i]
                    : 0;
                metadata[id_].lastTuneDebt[i] = targetDebt;
            }
        }

        emit Tuned(id_, term.controlVariable, newControlVariable_);

            // TODO: is this right assuming the controlVariable diff is the same for all payout tokens?
            if (newControlVariable_[0] < term.controlVariable[0]) {
                    uint256[] memory newChange_ = new uint256[](term.controlVariable.length);
                    
                    for (uint8 i = 0; i < term.controlVariable.length; i++) {
                        newChange_[i] = term.controlVariable[i] - newControlVariable_[i];
                    }

                    // If decrease, control variable change will be carried out over the tune adjustment delay
                    // this is because price will be lowered
                    adjustments[id_] = Adjustment(
                        newChange_,
                        time_,
                        meta.tuneAdjustmentDelay,
                        true
                    );
                } else {
                    // Tune up immediately
                    terms[id_].controlVariable = newControlVariable_;
                    // Set current adjustment to inactive (e.g. if we are re-tuning early)
                    adjustments[id_].active = false;
                }
    }

    /* ========== INTERNAL VIEW FUNCTIONS ========== */

    /// @notice             Calculate current market price of payout token in quote tokens
    /// @dev                See marketPrice() in IBondSDA for explanation of price computation
    /// @dev                Uses info from storage because data has been updated before call (vs marketPrice())
    /// @param id_          Market ID
    /// @return             Price for market in payout token decimals
    function _currentMarketPrice(uint256 id_) internal view returns (uint256[] memory) {
        BondMarket memory market = markets[id_];
        uint256[] memory currentDebt_ = currentDebt(id_);
        uint256[] memory prices = new uint256[](market.payoutToken.length);

        for (uint8 i = 0; i < market.payoutToken.length; i++) {
            prices[i] = terms[id_].controlVariable[i].mulDivUp(currentDebt_[i], market.scale[i]);
        }

        return prices;
    }

    /// @notice                 Amount to decay control variable by
    /// @param id_              ID of market
    /// @return decay           change in control variable
    /// @return secondsSince    seconds since last change in control variable
    /// @return active          whether or not change remains active
    function _controlDecay(uint256 id_)
        internal
        view
        returns (
            uint256[] memory decay,
            uint48 secondsSince,
            bool active
        )
    {
        Adjustment memory info = adjustments[id_];
        if (!info.active) return (new uint256[](info.change.length), 0, false);

        secondsSince = uint48(block.timestamp) - info.lastAdjustment;
        active = secondsSince < info.timeToAdjusted;
        if (active) {
            for (uint8 i = 0; i < info.change.length; i++) {
                decay[i] = info.change[i].mulDiv(uint256(secondsSince), uint256(info.timeToAdjusted));
            }
        } else {
            decay = info.change;
        }
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

    /// @inheritdoc IBondSDA
    function marketPrice(uint256 id_) public view override returns (uint256[] memory price) {
        uint256[] memory currentControlVariable_ = currentControlVariable(id_);
        uint256[] memory currentDebt_ = currentDebt(id_);

        for (uint8 i = 0; i < currentControlVariable_.length; i++) {
            price[i] = currentControlVariable_[i].mulDivUp(currentDebt_[i], markets[id_].scale[i]);
            price[i] = (price[i] > markets[id_].minPrice[i]) ? price[i] : markets[id_].minPrice[i];
        }
    }

    /// @inheritdoc IBondAuctioneer
    function marketScale(uint256 id_) external view override returns (uint256[] memory) {
        return markets[id_].scale;
    }

    /// @inheritdoc IBondAuctioneer
    function payoutFor(
        uint256 amount_,
        uint256 id_,
        address referrer_
    ) public view override returns (uint256[] memory payouts) {
        uint256[] memory prices = marketPrice(id_);
        uint256[] memory maxPayout_ = maxPayout(id_);

        for (uint256 i = 0; i < amount_; i++) {
           // Calculate the payout for the given amount of tokens
            uint256 fee = amount_.mulDiv(_teller.getFee(referrer_), 1e5);
            payouts[i] = (amount_ - fee).mulDiv(markets[id_].scale[i], prices[i]);

            // Check that the payout is less than or equal to the maximum payout,
            // Revert if not, otherwise return the payout
            if (payouts[i] > maxPayout_[i]) revert Auctioneer_MaxPayoutExceeded();
        }
    }

    /// @inheritdoc IBondSDA
    function maxPayout(uint256 id_) public view override returns (uint256[] memory maxPayout_) {
        BondMarket memory market = markets[id_];

        // Get current price
        uint256[] memory prices = marketPrice(id_);

        for (uint8 i = 0; i < market.payoutToken.length; i++) {
            // Calculate max payout based on current price
            uint256 payout = market.capacity[i].mulDiv(prices[i], market.scale[i]);
            // Cap max payout at the remaining capacity
            maxPayout_[i] = payout > maxPayout_[i] ? maxPayout_[i] : payout;
        }
    }

    /// @inheritdoc IBondAuctioneer
    function maxAmountAccepted(uint256 id_, address referrer_) external view returns (uint256) {
        // Calculate maximum amount of quote tokens that correspond to max bond size
        // Maximum of the maxPayout and the remaining capacity converted to quote tokens
        BondMarket memory market = markets[id_];
        uint256[] memory price = marketPrice(id_);
        uint256 quoteCapacity = 0;
        uint256 maxQuote = 0;

        for (uint8 i = 0; i < market.payoutToken.length; i++) {
            quoteCapacity += market.capacity[i].mulDiv(price[i], market.scale[i]);
            maxQuote += market.maxPayout[i].mulDiv(price[i], market.scale[i]);
        }

        uint256 amountAccepted = quoteCapacity < maxQuote ? quoteCapacity : maxQuote;

        // Take into account teller fees and return
        // Estimate fee based on amountAccepted. Fee taken will be slightly larger than
        // this given it will be taken off the larger amount, but this avoids rounding
        // errors with trying to calculate the exact amount.
        // Therefore, the maxAmountAccepted is slightly conservative.
        uint256 estimatedFee = amountAccepted.mulDiv(_teller.getFee(referrer_), 1e5);

        return amountAccepted + estimatedFee;
    }

    /// @inheritdoc IBondSDA
    function currentDebt(uint256 id_) public view override returns (uint256[] memory) {
        uint256 currentTime = block.timestamp;

        // Don't decay debt prior to start time
        if (currentTime < uint256(terms[id_].start)) return markets[id_].totalDebt;

        BondMetadata memory meta = metadata[id_];
        uint256 lastDecay = uint256(meta.lastDecay);
        uint256[] memory currentDebt_ = new uint256[](markets[id_].totalDebt.length);

        // Determine if decay should increase or decrease debt based on last decay time
        // If last decay time is in the future, then debt should be increased
        // If last decay time is in the past, then debt should be decreased
        if (lastDecay > currentTime) {
            uint256 secondsUntil;
            unchecked {
                secondsUntil = lastDecay - currentTime;
            }

            for (uint8 i = 0; i < markets[id_].totalDebt.length; i++) {
                currentDebt_[i] = markets[id_].totalDebt[i].mulDiv(
                    uint256(meta.debtDecayInterval) + secondsUntil,
                    uint256(meta.debtDecayInterval)
                );
            }

            return currentDebt_;
        } else {
            uint256 secondsSince;
            unchecked {
                secondsSince = currentTime - lastDecay;
            }

            if (secondsSince > meta.debtDecayInterval) return currentDebt_;
            
            for (uint8 i = 0; i < markets[id_].totalDebt.length; i++) {
                currentDebt_[i] = markets[id_].totalDebt[i].mulDiv(
                    uint256(meta.debtDecayInterval) - secondsSince,
                    uint256(meta.debtDecayInterval)
                );
            }

            return currentDebt_;
        }
    }

    /// @inheritdoc IBondSDA
    function currentControlVariable(uint256 id_) public view override returns (uint256[] memory) {
        (uint256[] memory decay, , ) = _controlDecay(id_);

        uint256[] memory currentControlVariable_ = new uint256[](terms[id_].controlVariable.length);
        for (uint8 i = 0; i < terms[id_].controlVariable.length; i++) {
            currentControlVariable_[i] = terms[id_].controlVariable[i] - decay[i];
        }

        return currentControlVariable_;
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
