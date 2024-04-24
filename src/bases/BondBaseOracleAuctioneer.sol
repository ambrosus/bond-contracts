// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity 0.8.20;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IBondAggregator} from "../interfaces/IBondAggregator.sol";
import {IBondOracle} from "../interfaces/IBondOracle.sol";
import {IBondTeller} from "../interfaces/IBondTeller.sol";
import {FullMath} from "../lib/FullMath.sol";

import {BondBaseAuctioneer} from "./BondBaseAuctioneer.sol";
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
    address guardian_,
    Authority authority_
  ) BondBaseAuctioneer(teller_, aggregator_, guardian_, authority_) 
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
        // TODO: Check if this is correct calculation (priceDecimals / 2 instead of (payoutPriceDecimals - quotePriceDecimals) / 2)
        uint256 scale = 10 ** uint8(36 + int8(payoutTokenDecimals) - int8(quoteTokenDecimals) - priceDecimals / 2);

        return (currentPrice * oracleConversion, oracleConversion, scale);
    }

}