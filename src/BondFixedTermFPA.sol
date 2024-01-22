// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity 0.8.15;

import {BondBaseFPA, IBondAggregator, Authority} from "./bases/BondBaseFPA.sol";
import {IBondTeller} from "./interfaces/IBondTeller.sol";
import {ERC20} from "solmate/src/tokens/ERC20.sol";

/// @title Bond Fixed-Term Fixed Price Auctioneer
/// @notice Bond Fixed-Term Fixed Price Auctioneer Contract
/// @dev Bond Protocol is a permissionless system to create bond markets
///      for any token pair. Bond issuers create BondMarkets that pay out
///      a Payout Token in exchange for deposited Quote Tokens. Users can purchase
///      future-dated Payout Tokens with Quote Tokens at the current market price and
///      receive Bond Tokens to represent their position while their bond vests.
///      Once the Bond Tokens vest, they can redeem it for the Quote Tokens.
///
/// @dev An Auctioneer contract allows users to create and manage bond markets.
///      All bond pricing logic and market data is stored in the Auctioneer.
///      An Auctioneer is dependent on a Teller to serve external users and
///      an Aggregator to register new markets. The Fixed Price Auctioneer
///      lets issuers set a Fixed Price to buy a target amount of quote tokens or sell
///      a target amount of payout tokens over the duration of a market.
///      See IBondFPA.sol for price format details.
///
/// @dev The Fixed-Term Fixed Price Auctioneer is an implementation of the
///      Bond Base Auctioneer contract specific to creating bond markets where
///      purchases vest in a fixed amount of time after purchased (rounded to the day).
///
/// @author Oighty
contract BondFixedTermFPA is BondBaseFPA {
    /* ========== CONSTRUCTOR ========== */
    constructor(
        IBondTeller teller_,
        IBondAggregator aggregator_,
        address guardian_,
        Authority authority_
    ) BondBaseFPA(teller_, aggregator_, guardian_, authority_) {}

    /* ========== MARKET FUNCTIONS ========== */
    /// @inheritdoc BondBaseFPA
    function createMarket(bytes calldata params_) external override returns (uint256) {
        // Decode params into the struct type expected by this auctioneer
        (
            ERC20[] memory payoutToken,
            ERC20 quoteToken,
            address callbackAddr,
            uint256[] memory capacity,
            uint256[] memory formattedPrice,
            uint48 depositInterval,
            uint48 vesting,
            uint48 start,
            uint48 duration,
            int8[] memory scaleAdjustment,
            uint8 payoutTokensNumber
        ) = abi.decode(
                params_,
                (ERC20[], ERC20, address, uint256[], uint256[], uint48, uint48, uint48, uint48, int8[], uint8)
            );

        MarketParams memory params = MarketParams({
            payoutToken: payoutToken,
            quoteToken: quoteToken,
            callbackAddr: callbackAddr,
            capacity: capacity,
            formattedPrice: formattedPrice,
            depositInterval: depositInterval,
            vesting: vesting,
            start: start,
            duration: duration,
            scaleAdjustment: scaleAdjustment,
            payoutTokensNumber: payoutTokensNumber
        });

        // Check that the vesting parameter is valid for a fixed-term market
        if (params.vesting != 0 && (params.vesting < 1 days || params.vesting > MAX_FIXED_TERM))
            revert Auctioneer_InvalidParams();

        // Create market and return market ID
        return _createMarket(params);
    }
}
