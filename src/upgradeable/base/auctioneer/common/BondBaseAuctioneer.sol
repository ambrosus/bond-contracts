// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity 0.8.15;

import {ERC20} from "solmate/src/tokens/ERC20.sol";
import {Auth} from "solmate/src/auth/Auth.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {IBondAggregator} from "@self/interfaces/IBondAggregator.sol";
import {IBondAuctioneer} from "@self/interfaces/IBondAuctioneer.sol";
import {IBondOracle} from "@self/interfaces/IBondOracle.sol";
import {IBondTeller} from "@self/interfaces/IBondTeller.sol";
import {Pausable} from "@openzeppelin/contracts/security/Pausable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import {FullMath} from "@self/lib/FullMath.sol";


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
abstract contract BondBaseAuctioneer is IBondAuctioneer, AccessControl, Pausable, ReentrancyGuard {

    bytes32 public constant OWNER_ROLE = keccak256("OWNER_ROLE");
  

    // A 'vesting' param longer than 50 years is considered a timestamp for fixed expiry.
    uint48 internal constant MAX_FIXED_TERM = 52 weeks * 50;
    uint48 internal constant ONE_HUNDRED_PERCENT = 1e5; // one percent equals 1000.

    /// @notice Whether or not the auctioneer allows new markets to be created
    /// @dev    Changing to false will sunset the auctioneer after all active markets end
    bool public allowNewMarkets;

    // BondAggregator contract with utility functions
    IBondAggregator internal immutable _aggregator;

    // BondTeller contract that handles interactions with users and issues tokens
    IBondTeller internal immutable _teller;
    
    constructor(IBondTeller teller_, IBondAggregator aggregator_, address owner_) {
        _aggregator = aggregator_;
        _teller = teller_;
        allowNewMarkets = true;
        _setupRole(OWNER_ROLE, owner_);
        _setupRole(DEFAULT_ADMIN_ROLE, address(this));
    }

    /* ========== ERRORS ========== */

    error Auctioneer_Unreachable();

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
    error Auctioneer_UnsupportedToken();


    /**
     * @dev Modifier that checks that an account is market owner. Reverts
     * with a standardized message.
     *
     * The format of the revert reason is given by the following regular expression:
     *
     *  /^AccessControl: account (0x[0-9a-f]{40}) is not market {id} owner$/
     *
     * _Available since v4.1._
     */
    modifier onlyMarketOwner(uint256 id_) {
        if (msg.sender != this.ownerOf(id_)) revert Auctioneer_OnlyMarketOwner();
        _;
    }

    modifier onlyTeller() {
        if (
          address(msg.sender) != address(_teller) ||
          address(msg.sender) == address(0) || 
          address(msg.sender).code.length == 0
        ) revert Auctioneer_NotAuthorized();
        _;
    }

    /// @inheritdoc IBondAuctioneer
    function getTeller() external view override returns (IBondTeller) {
        return _teller;
    }

    /// @inheritdoc IBondAuctioneer
    function getAggregator() external view override returns (IBondAggregator) {
        return _aggregator;
    }
}

abstract contract BondBaseOracleAuctioneer is BondBaseAuctioneer {
  using FullMath for uint256;

  error Auctioneer_OraclePriceZero();

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

  constructor(
    IBondTeller teller_, 
    IBondAggregator aggregator_,
    address owner_
  ) BondBaseAuctioneer(teller_, aggregator_, owner_) 
  {}

  /* ========== INTERNAL FUNCTIONS ========== */

  function _validateOracle(
        uint256 id_,
        IBondOracle oracle_,
        ERC20 quoteToken_,
        ERC20 payoutToken_,
        uint48 fixedDiscount_
    ) internal returns (uint256, uint256, uint256) {
        // Default value for native token
        uint8 payoutTokenDecimals = 18;
        uint8 quoteTokenDecimals = 18;

        // Ensure token decimals are in bounds
        // If token is native no need to check decimals
        if (address(payoutToken_) != address(0)) {
            payoutTokenDecimals = payoutToken_.decimals();
            if (payoutTokenDecimals < 6 || payoutTokenDecimals > 18) revert Auctioneer_InvalidParams();
        }
        if (address(quoteToken_) != address(0)) {
            quoteTokenDecimals = quoteToken_.decimals();
            if (quoteTokenDecimals < 6 || quoteTokenDecimals > 18) revert Auctioneer_InvalidParams();
        }

        // Check that oracle is valid. It should:
        // 1. Be a contract
        if (address(oracle_) == address(0) || address(oracle_).code.length == 0) revert Auctioneer_InvalidParams();

        // 2. Allow registering markets
        oracle_.registerMarket(id_, quoteToken_, payoutToken_);

        // 3. Return a valid price for the quote token : payout token pair
        uint256 currentPrice = oracle_.currentPrice(id_);
        if (currentPrice == 0) revert Auctioneer_OraclePriceZero();

        // 4. Return a valid decimal value for the quote token : payout token pair price
        uint8 oracleDecimals = oracle_.decimals(id_);
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
            currentPrice.mulDivUp(uint256(ONE_HUNDRED_PERCENT - fixedDiscount_), uint256(ONE_HUNDRED_PERCENT)),
            oracleDecimals
        );
        // Check price decimals in reasonable range
        // These bounds are quite large and it is unlikely any combination of tokens
        // will have a price difference larger than 10^24 in either direction.
        // Check that oracle decimals are large enough to avoid precision loss from negative price decimals
        if (int8(oracleDecimals) <= -priceDecimals || priceDecimals > 24) revert Auctioneer_InvalidParams();

        // Calculate the oracle price conversion factor
        // oraclePriceFactor = int8(oracleDecimals) + priceDecimals;
        // bondPriceFactor = 36 - priceDecimals / 2 + priceDecimals;
        // oracleConversion = 10^(bondPriceFactor - oraclePriceFactor);
        uint256 oracleConversion = 10 ** uint8(36 - priceDecimals / 2 - int8(oracleDecimals));

        // Unit to scale calculation for this market by to ensure reasonable values
        // for price, debt, and control variable without under/overflows.
        //
        // scaleAdjustment should be equal to (payoutDecimals - quoteDecimals) - ((payoutPriceDecimals - quotePriceDecimals) / 2)
        // scale = 10^(36 + scaleAdjustment);
        uint256 scale = 10 ** uint8(36 + int8(payoutTokenDecimals) - int8(quoteTokenDecimals) - priceDecimals / 2);

        return (currentPrice * oracleConversion, oracleConversion, scale);
    }

}