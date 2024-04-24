// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity 0.8.20;


import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {FullMath} from "../lib/FullMath.sol";
import {IAuthority} from "../interfaces/IAuthority.sol";
import {IBondAggregator} from "../interfaces/IBondAggregator.sol";
import {IBondTeller1155} from "../interfaces/IBondTeller1155.sol";
import {TicketUpgradeable} from "../lib/TicketUpgradeable.sol";
import {BondBaseTellerUpgradeable} from "./BondBaseTellerUpgradeable.sol";

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
abstract contract BondTeller1155Upgradeable is 
    IBondTeller1155, 
    TicketUpgradeable, 
    BondBaseTellerUpgradeable, 
    UUPSUpgradeable 
{
    using SafeERC20 for ERC20;
    using FullMath for uint256;

    /* ========== EVENTS ========== */
    event ERC1155BondTokenCreated(uint256 tokenId, ERC20 indexed underlying, uint48 indexed expiry);

    /* ========== STATE VARIABLES ========== */

    mapping(uint256 => TokenMetadata) public tokenMetadata; // metadata for bond tokens

    function __BondTeller1155_init(
        address guardian_,
        IAuthority authority_,
        address protocol_,
        IBondAggregator aggregator_
    ) internal onlyInitializing {
        __UUPSUpgradeable_init();
        __Ticket_init();
        __BondBaseTeller_init(
            guardian_,
            authority_,
            protocol_, 
            aggregator_
        );

    }


     function _authorizeUpgrade(address newImplementation)
        internal
        override
        requiresAuth
    {}

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
    ) internal virtual override returns (uint48 expiry);

    /* ========== DEPOSIT/MINT ========== */

    /// @inheritdoc IBondTeller1155
    function create(
        ERC20 underlying_,
        uint48 expiry_,
        uint256 amount_
    ) external override nonReentrant returns (uint256, uint256) {
        // Expiry is rounded to the nearest minute at 0000 UTC (in seconds) since bond tokens
        // are only unique to a minute, not a specific timestamp.
        uint48 expiry = uint48(expiry_ / 1 minutes) * 1 minutes;

        // Revert if expiry is in the past
        if (expiry < block.timestamp) revert Teller_InvalidParams();

        uint256 tokenId = getTokenId(underlying_, expiry);

        // Revert if no token exists, must call deploy first
        if (!tokenMetadata[tokenId].active) revert Teller_TokenDoesNotExist(underlying_, expiry);

        // Transfer in underlying
        // Check that amount received is not less than amount expected
        // Handles edge cases like fee-on-transfer tokens (which are not supported)
        uint256 oldBalance = underlying_.balanceOf(address(this));
        underlying_.safeTransferFrom(msg.sender, address(this), amount_);
        if (underlying_.balanceOf(address(this)) < oldBalance + amount_) revert Teller_UnsupportedToken();

        // If fee is greater than the create discount, then calculate the fee and store it
        // Otherwise, fee is zero.
        if (protocolFee > createFeeDiscount) {
            // Calculate fee amount
            uint256 feeAmount = amount_.mulDiv(protocolFee - createFeeDiscount, FEE_DECIMALS);
            _handleFeePayout(beneficiary, underlying_, feeAmount);

            // Mint new bond tokens
            _mintToken(msg.sender, tokenId, amount_ - feeAmount);

            return (tokenId, amount_ - feeAmount);
        } else {
            // Mint new bond tokens
            _mintToken(msg.sender, tokenId, amount_);

            return (tokenId, amount_);
        }
    }

    /* ========== REDEEM ========== */

    function _redeem(uint256 tokenId_, uint256 amount_) internal whenNotPaused {
        // Check that the tokenId is active
        if (!tokenMetadata[tokenId_].active) revert Teller_InvalidParams();

        // Cache token metadata
        TokenMetadata memory meta = tokenMetadata[tokenId_];

        // Check that the token has matured
        if (block.timestamp < meta.expiry) revert Teller_TokenNotMatured(meta.expiry);

        // Burn bond token and transfer underlying to sender
        _burnToken(msg.sender, tokenId_, amount_);

        // If payout token is native, handle it differently
        if (address(meta.underlying) == address(0)) {
            bool sent = payable(msg.sender).send(amount_);
            require(sent, "Failed to send native tokens");
        } else {
            meta.underlying.safeTransfer(msg.sender, amount_);
        }
    }

    /// @inheritdoc IBondTeller1155
    function redeem(uint256 tokenId_, uint256 amount_) public override nonReentrant {
        _redeem(tokenId_, amount_);
    }

    /// @inheritdoc IBondTeller1155
    function batchRedeem(uint256[] calldata tokenIds_, uint256[] calldata amounts_) external override nonReentrant {
        uint256 len = tokenIds_.length;
        if (len != amounts_.length) revert Teller_InvalidParams();
        for (uint256 i; i < len; ++i) {
            _redeem(tokenIds_[i], amounts_[i]);
        }
    }

    /* ========== TOKENIZATION ========== */

    /// @inheritdoc IBondTeller1155
    function deploy(ERC20 underlying_, uint48 expiry_) external override nonReentrant whenNotPaused returns (uint256) {
        uint256 tokenId = getTokenId(underlying_, expiry_);
        // Only creates token if it does not exist
        if (!tokenMetadata[tokenId].active) {
            _deploy(tokenId, underlying_, expiry_);
        }
        return tokenId;
    }

    /// @notice             "Deploy" a new ERC1155 bond token and stores its ID
    /// @dev                ERC1155 tokens used for fixed term bonds
    /// @param tokenId_     Calculated ID of new bond token (from getTokenId)
    /// @param underlying_  Underlying token to be paid out when the bond token vests
    /// @param expiry_      Timestamp that the token will vest at, will be rounded to the nearest minute
    function _deploy(uint256 tokenId_, ERC20 underlying_, uint48 expiry_) internal whenNotPaused {
        // Expiry is rounded to the nearest minute at 0000 UTC (in seconds) since bond tokens
        // are only unique to a minute, not a specific timestamp.
        uint48 expiry = uint48(expiry_ / 1 minutes) * 1 minutes;

        // Revert if expiry is in the past
        if (uint256(expiry) < block.timestamp) revert Teller_InvalidParams();

        // If token is native than decimals equal to 18,
        // otherwise get decimals from token contrtact
        uint8 decimals = 18;
        if (address(underlying_) != address(0)) {
            decimals = uint8(underlying_.decimals());
        }

        // Store token metadata
        tokenMetadata[tokenId_] = TokenMetadata(true, tokenId_, underlying_, decimals, expiry, 0);

        emit ERC1155BondTokenCreated(tokenId_, underlying_, expiry);
    }

    /// @notice             Mint bond token and update supply
    /// @param to_          Address to mint tokens to
    /// @param tokenId_     ID of bond token to mint
    /// @param amount_      Amount of bond tokens to mint
    function _mintToken(address to_, uint256 tokenId_, uint256 amount_) internal whenNotPaused {
        tokenMetadata[tokenId_].supply += amount_;
        _mint(to_, tokenId_, amount_, bytes(""));
    }

    /// @notice             Burn bond token and update supply
    /// @param from_        Address to burn tokens from
    /// @param tokenId_     ID of bond token to burn
    /// @param amount_      Amount of bond token to burn
    function _burnToken(address from_, uint256 tokenId_, uint256 amount_) internal whenNotPaused {
        tokenMetadata[tokenId_].supply -= amount_;
        _burn(from_, tokenId_, amount_);
    }

    /* ========== TOKEN NAMING ========== */

    /// @inheritdoc IBondTeller1155
    function getTokenId(ERC20 underlying_, uint48 expiry_) public pure override returns (uint256) {
        // Expiry is divided by 1 minute (in seconds) since bond tokens are only unique
        // to a minute, not a specific timestamp.
        uint256 tokenId = uint256(keccak256(abi.encodePacked(underlying_, expiry_ / uint48(1 minutes))));
        return tokenId;
    }

    /// @inheritdoc IBondTeller1155
    function getTokenNameAndSymbol(uint256 tokenId_) external view override returns (string memory, string memory) {
        TokenMetadata memory meta = tokenMetadata[tokenId_];
        (string memory name, string memory symbol) = _getNameAndSymbol(meta.underlying, meta.expiry);
        return (name, symbol);
    }
}
