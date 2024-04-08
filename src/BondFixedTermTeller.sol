// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity 0.8.15;

import {ERC20} from "solmate/src/tokens/ERC20.sol";

import {BondBaseTeller, IBondAggregator, Authority} from "./bases/BondBaseTeller.sol";
import {IBondTeller1155} from "./interfaces/IBondTeller1155.sol";

import {TransferHelper} from "./lib/TransferHelper.sol";
import {FullMath} from "./lib/FullMath.sol";
import {ERC1155} from "./lib/ERC1155.sol";
import "./bases/BondTeller1155.sol";

/// @title Bond Fixed Term Teller
/// @notice Bond Fixed Term Teller Contract
/// @dev Bond Protocol is a permissionless system to create Olympus-style bond markets
///      for any token pair. The markets do not require maintenance and will manage
///      bond prices based on activity. Bond issuers create BondMarkets that pay out
///      a Payout Token in exchange for deposited Quote Tokens. Users can purchase
///      future-dated Payout Tokens with Quote Tokens at the current market price and
///      receive Bond Tokens to represent their position while their bond vests.
///      Once the Bond Tokens vest, they can redeem it for the Quote Tokens.
///
/// @dev The Bond Fixed Term Teller is an implementation of the
///      Bond Base Teller contract specific to handling user bond transactions
///      and tokenizing bond markets where purchases vest in a fixed amount of time
///      (rounded to the minute) as ERC1155 tokens.
///
/// @author Oighty, Zeus, Potted Meat, indigo
contract BondFixedTermTeller is BondTeller1155 {
    using TransferHelper for ERC20;

    /* ========== CONSTRUCTOR ========== */
    constructor(
        address protocol_,
        IBondAggregator aggregator_,
        address guardian_,
        Authority authority_
    ) BondTeller1155(protocol_, aggregator_, guardian_, authority_) {}

    /* ========== PURCHASE ========== */

    /// @notice             Handle payout to recipient
    /// @param recipient_   Address to receive payout
    /// @param payout_      Amount of payoutToken to be paid
    /// @param payoutToken_   Token to be paid out
    /// @param vesting_     Amount of time to vest from current timestamp
    /// @return expiry      Timestamp when the payout will vest
    function _handlePayout(
        address recipient_,
        uint256 payout_,
        ERC20 payoutToken_,
        uint48 vesting_
    ) internal override returns (uint48 expiry) {
        // If there is no vesting time, the deposit is treated as an instant swap.
        // otherwise, deposit info is stored and payout is available at a future timestamp.
        // instant swap is denoted by expiry == 0.
        //
        // bonds mature with a cliff at a set timestamp
        // prior to the expiry timestamp, no payout tokens are accessible to the user
        // after the expiry timestamp, the entire payout can be redeemed
        //
        // fixed-term bonds mature in a set amount of time from deposit
        // i.e. term = 1 week. when alice deposits on day 1, her bond
        // expires on day 8. when bob deposits on day 2, his bond expires day 9.
        if (vesting_ != 0) {
            // Normalizing fixed term vesting timestamps to the same time each minute
            expiry = ((vesting_ + uint48(block.timestamp)) / uint48(1 minutes)) * uint48(1 minutes);

            // Fixed-term user payout information is handled in BondTeller.
            // Teller mints ERC-1155 bond tokens for user.
            uint256 tokenId = getTokenId(payoutToken_, expiry);

            // Create new bond token if it doesn't exist yet
            if (!tokenMetadata[tokenId].active) {
                _deploy(tokenId, payoutToken_, expiry);
            }

            // Mint bond token to recipient
            _mintToken(recipient_, tokenId, payout_);
        } else {
            // If no expiry, then transfer payout directly to user
            if (address(payoutToken_) == address(0)) {
                bool sent = payable(recipient_).send(payout_);
                require(sent, "Failed to send native tokens");
            } else {
                payoutToken_.safeTransfer(recipient_, payout_);
            }
        }
    }

}
