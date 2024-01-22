// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity 0.8.15;

import {BondBaseFPA, IBondAggregator, Authority} from "./bases/BondBaseFPA.sol";
import {IBondTeller} from "./interfaces/IBondTeller.sol";
import {IBondFixedExpiryTeller} from "./interfaces/IBondFixedExpiryTeller.sol";
import {ERC20} from "solmate/src/tokens/ERC20.sol";

/// @title Bond Fixed-Expiry Fixed Price Auctioneer
/// @notice Bond Fixed-Expiry Fixed Price Auctioneer Contract
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
///      an Aggregator to register new markets. Th Fixed Price Auctioneer
///      lets issuers set a Fixed Price to buy a target amount of quote tokens or sell
///      a target amount of payout tokens over the duration of a market.
///      See IBondFPA.sol for price format details.
///
/// @dev The Fixed-Expiry Fixed Price Auctioneer is an implementation of the
///      Bond Base Fixed Price Auctioneer contract specific to creating bond markets where
///      all purchases on that market vest at a certain timestamp.
///
/// @author Oighty
contract BondFixedExpiryFPA is BondBaseFPA {
    /* ========== CONSTRUCTOR ========== */
    constructor(
        IBondTeller teller_,
        IBondAggregator aggregator_,
        address guardian_,
        Authority authority_
    ) BondBaseFPA(teller_, aggregator_, guardian_, authority_) {}

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

        // Vesting is rounded to the nearest day at 0000 UTC (in seconds) since bond tokens
        // are only unique to a day, not a specific timestamp.
        params.vesting = (params.vesting / 1 days) * 1 days;

        // Get conclusion from start time and duration
        // Don't need to check valid start time or duration here since it will be checked in _createMarket
        uint48 start_ = params.start == 0 ? uint48(block.timestamp) : params.start;
        uint48 conclusion_ = start_ + params.duration;

        // Check that the vesting parameter is valid for a fixed-expiry market
        if (params.vesting != 0 && params.vesting < conclusion_) revert Auctioneer_InvalidParams();

        // Create market with provided params
        uint256 marketId = _createMarket(params);

        // Create bond token (ERC20 for fixed expiry) if not instant swap
        if (params.vesting != 0) IBondFixedExpiryTeller(address(_teller)).deploy(params.payoutToken, params.vesting);

        // Return market ID
        return marketId;
    }
}
