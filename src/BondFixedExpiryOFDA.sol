// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity 0.8.20;

import {IAuthority} from "./interfaces/IAuthority.sol";
import {IBondAggregator} from "./interfaces/IBondAggregator.sol";
import {IBondTeller} from "./interfaces/IBondTeller.sol";
import {BondBaseOFDA} from "./bases/BondBaseOFDA.sol";

/// @title Bond Fixed-Expiry Fixed Discount Auctioneer
/// @notice Bond Fixed-Expiry Fixed Discount Auctioneer Contract
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
///      an Aggregator to register new markets. The Fixed Discount Auctioneer
///      lets issuers set a Fixed Discount to an oracle price to buy a
///      target amount of quote tokens or sell a target amount of payout tokens
///      over the duration of a market.
///      See IBondOFDA.sol for price format details.
///
/// @dev The Fixed-Expiry Fixed Discount Auctioneer is an implementation of the
///      Bond Base Fixed Discount Auctioneer contract specific to creating bond markets where
///      all purchases on that market vest at a certain timestamp.
///
/// @author Oighty
contract BondFixedExpiryOFDA is BondBaseOFDA {
    /* ========== CONSTRUCTOR ========== */
    constructor(
        IBondTeller teller_,
        IBondAggregator aggregator_,
        address guardian_,
        IAuthority authority_
    ) BondBaseOFDA(teller_, aggregator_, guardian_, authority_) {}

    /// @inheritdoc BondBaseOFDA
    function createMarket(bytes calldata params_) external payable override returns (uint256) {
        // Decode params into the struct type expected by this auctioneer
        MarketParams memory params = abi.decode(params_, (MarketParams));

        // Vesting is rounded to the nearest minute at 0000 UTC (in seconds) since bond tokens
        // are only unique to a minute, not a specific timestamp.
        params.vesting = (params.vesting / 1 minutes) * 1 minutes;

        // Get conclusion from start time and duration
        // Don't need to check valid start time or duration here since it will be checked in _createMarket
        uint48 start = params.start == 0 ? uint48(block.timestamp) : params.start;
        uint48 conclusion = start + params.duration;

        // Check that the vesting parameter is valid for a fixed-expiry market
        if (params.vesting != 0 && params.vesting < conclusion) revert Auctioneer_InvalidParams();

        // Create market and return market ID
        return _createMarket(params);
    }
}
