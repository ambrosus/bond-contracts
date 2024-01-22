// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity 0.8.15;

import {BondBaseSDA, IBondAggregator, Authority} from "./bases/BondBaseSDA.sol";
import {IBondTeller} from "./interfaces/IBondTeller.sol";
import {ERC20} from "solmate/src/tokens/ERC20.sol";

/// @title Bond Fixed-Term Sequential Dutch Auctioneer
/// @notice Bond Fixed-Term Sequential Dutch Auctioneer Contract
/// @dev Bond Protocol is a permissionless system to create Olympus-style bond markets
///      for any token pair. The markets do not require maintenance and will manage
///      bond prices based on activity. Bond issuers create BondMarkets that pay out
///      a Payout Token in exchange for deposited Quote Tokens. Users can purchase
///      future-dated Payout Tokens with Quote Tokens at the current market price and
///      receive Bond Tokens to represent their position while their bond vests.
///      Once the Bond Tokens vest, they can redeem it for the Quote Tokens.
///
/// @dev The Fixed-Term Auctioneer is an implementation of the
///      Bond Base Auctioneer contract specific to creating bond markets where
///      purchases vest in a fixed amount of time after purchased (rounded to the day).
///
/// @author Oighty, Zeus, Potted Meat, indigo
contract BondFixedTermSDA is BondBaseSDA {
    /* ========== CONSTRUCTOR ========== */
    constructor(
        IBondTeller teller_,
        IBondAggregator aggregator_,
        address guardian_,
        Authority authority_
    ) BondBaseSDA(teller_, aggregator_, guardian_, authority_) {}

    /* ========== MARKET FUNCTIONS ========== */
    /// @inheritdoc BondBaseSDA
    function createMarket(bytes calldata params_) external override returns (uint256) {
        // Decode params into the struct type expected by this auctioneer
        (
            ERC20[] memory payoutToken,
            ERC20 quoteToken,
            address callbackAddr,
            uint256[] memory capacity,
            uint256[] memory formattedInitialPrice,
            uint256[] memory formattedMinimumPrice,
            uint32 debtBuffer,
            uint48 vesting,
            uint48 start,
            uint32 duration,
            uint32 depositInterval,
            int8[] memory scaleAdjustment
        ) = abi.decode(
                params_,
                (
                    ERC20[],
                    ERC20,
                    address,
                    uint256[],
                    uint256[],
                    uint256[],
                    uint32,
                    uint48,
                    uint48,
                    uint32,
                    uint32,
                    int8[]
                )
            );

        MarketParams memory params = MarketParams({
            payoutToken: payoutToken,
            quoteToken: quoteToken,
            callbackAddr: callbackAddr,
            capacity: capacity,
            formattedInitialPrice: formattedInitialPrice,
            formattedMinimumPrice: formattedMinimumPrice,
            debtBuffer: debtBuffer,
            depositInterval: depositInterval,
            vesting: vesting,
            start: start,
            duration: duration,
            scaleAdjustment: scaleAdjustment
        });

        // Check that the vesting parameter is valid for a fixed-term market
        if (params.vesting != 0 && (params.vesting < 1 days || params.vesting > MAX_FIXED_TERM))
            revert Auctioneer_InvalidParams();

        // Create market and return market ID
        return _createMarket(params);
    }
}
