// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity 0.8.20;

import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Auth} from "../lib/Auth.sol";
import {IAuthority} from "../interfaces/IAuthority.sol";
import {IBondAggregator} from "../interfaces/IBondAggregator.sol";
import {IBondAuctioneer} from "../interfaces/IBondAuctioneer.sol";
import {IBondTeller} from "../interfaces/IBondTeller.sol";


/// @title Bond Auctioneer Base v1.1
/// @notice Bond Auctioneer Base Contract
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
///      an Aggregator to register new markets.
///
/// @author Oighty, Zeus, Potted Meat, indigo
abstract contract BondBaseAuctioneer is IBondAuctioneer, Auth, Pausable, ReentrancyGuard {  

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
    
     constructor(
        IBondTeller teller_,
        IBondAggregator aggregator_,
        address guardian_,
        IAuthority authority_
    ) Auth(guardian_, authority_) {
        _aggregator = aggregator_;
        _teller = teller_;

        allowNewMarkets = true;
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
     * with Auctioneer_OnlyMarketOwner error.
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

    function pause() external requiresAuth {
        _pause();
    }

    function unpause() external requiresAuth {
        _unpause();
    }

    function _setAllowNewMarkets(bool status_) internal requiresAuth {
        allowNewMarkets = status_;
    }

    /// @inheritdoc IBondAuctioneer
    function setAllowNewMarkets(bool status_) external virtual override {
        _setAllowNewMarkets(status_);
    }
}