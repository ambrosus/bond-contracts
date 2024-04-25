// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity 0.8.20;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuardUpgradeable} from "@openzeppelin/contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";
import {AuthUpgradeable} from "../lib/AuthUpgradeable.sol";
import {IAuthority} from "../interfaces/IAuthority.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/security/PausableUpgradeable.sol";
import {IBondTeller} from "../interfaces/IBondTeller.sol";
import {IBondAggregator} from "../interfaces/IBondAggregator.sol";
import {IBondAuctioneer} from "../interfaces/IBondAuctioneer.sol";
import {FullMath} from "../lib/FullMath.sol";

/// @title Bond Teller
/// @notice Bond Teller Base Contract
/// @dev Bond Protocol is a permissionless system to create Olympus-style bond markets
///      for any token pair. The markets do not require maintenance and will manage
///      bond prices based on activity. Bond issuers create BondMarkets that pay out
///      a Payout Token in exchange for deposited Quote Tokens. Users can purchase
///      future-dated Payout Tokens with Quote Tokens at the current market price and
///      receive Bond Tokens to represent their position while their bond vests.
///      Once the Bond Tokens vest, they can redeem it for the Quote Tokens.
///
/// @dev The Teller contract handles all interactions with end users and manages tokens
///      issued to represent bond positions. Users purchase bonds by depositing Quote Tokens
///      and receive a Bond Token (token type is implementation-specific) that represents
///      their payout and the designated expiry. Once a bond vests, Investors can redeem their
///      Bond Tokens for the underlying Payout Token. A Teller requires one or more Auctioneer
///      contracts to be deployed to provide markets for users to purchase bonds from.
///
/// @author Oighty, Zeus, Potted Meat, indigo
abstract contract BondBaseTellerUpgradeable is 
    IBondTeller, 
    AuthUpgradeable, 
    PausableUpgradeable, 
    ReentrancyGuardUpgradeable 
{
    using SafeERC20 for ERC20;
    using FullMath for uint256;

    /* ========== ERRORS ========== */

    error Teller_InvalidCallback();
    error Teller_TokenNotMatured(uint48 maturesOn);
    error Teller_NotAuthorized();
    error Teller_TokenDoesNotExist(ERC20 underlying, uint48 expiry);
    error Teller_UnsupportedToken();
    error Teller_InvalidParams();

    /* ========== EVENTS ========== */
    event Bonded(uint256 indexed id, address indexed referrer, uint256 amount, uint256 payout);

    /* ========== STATE VARIABLES ========== */

    /// @notice Fee paid to a front end operator in basis points (3 decimals). Set by the referrer, must be less than or equal to 5% (5e3).
    /// @dev There are some situations where the fees may round down to zero if quantity of baseToken
    ///      is < 1e5 wei (can happen with big price differences on small decimal tokens). This is purely
    ///      a theoretical edge case, as the bond amount would not be practical.
    mapping(address => uint48) public referrerFees;

    /// @notice Fee paid to protocol in basis points (3 decimal places).
    uint48 public protocolFee;

    /// @notice 'Create' function fee discount in basis points (3 decimal places). Amount standard fee is reduced by for partners who just want to use the 'create' function to issue bond tokens.
    uint48 public createFeeDiscount;

    uint48 public constant FEE_DECIMALS = 1e5; // one percent equals 1000.

    // Address the protocol receives fees at
    address public beneficiary;

    // BondAggregator contract with utility functions
    IBondAggregator internal _aggregator;

    /* ========== INITIALIZER ========== */

    function __BondBaseTeller_init(
        address beneficiary_,
        IBondAggregator aggregator_,
        address guardian_,
        IAuthority authority_
    ) internal onlyInitializing {
        __ReentrancyGuard_init();
        // Initialize Auth
        __AuthUpgradeable_init(guardian_, authority_);
        beneficiary = beneficiary_;
        _aggregator = aggregator_;
        protocolFee = 0;
        createFeeDiscount = 0;
     }
    
    /* ================================ */

    function pause() public requiresAuth {
        _pause();
    }

    function unpause() public requiresAuth {
        _unpause();
    }


    /// @inheritdoc IBondTeller
    function setBeneficiary(address beneficiary_) external override requiresAuth {
        beneficiary = beneficiary_;
    }

    /// @inheritdoc IBondTeller
    function setReferrerFee(uint48 fee_) external override nonReentrant {
        if (fee_ > 5e3) revert Teller_InvalidParams();
        referrerFees[msg.sender] = fee_;
    }

    /// @inheritdoc IBondTeller
    function setProtocolFee(uint48 fee_) external override requiresAuth {
        if (fee_ > 5e3) revert Teller_InvalidParams();
        protocolFee = fee_;
    }

    /// @inheritdoc IBondTeller
    function setCreateFeeDiscount(uint48 discount_) external override requiresAuth {
        if (discount_ > protocolFee) revert Teller_InvalidParams();
        createFeeDiscount = discount_;
    }

    /// @inheritdoc IBondTeller
    function closeMarket(uint256 id_) external override nonReentrant {
        IBondAuctioneer auctioneer = _aggregator.getAuctioneer(id_);
        address owner;
        ERC20 payoutToken;
        (owner, payoutToken, , , ) = auctioneer.getMarketInfoForPurchase(id_);
        uint256 capacity = auctioneer.currentCapacity(id_);
        uint48 conclusion = auctioneer.getConclusion(id_);

        // Only owner can close market before conclusion
        if (conclusion > block.timestamp) {
            if (msg.sender != owner) revert Teller_NotAuthorized();
        }

        // Return remaining capacity to owner
        if (capacity != 0) {
            if (address(payoutToken) == address(0)) {
                bool sent = payable(owner).send(capacity);
                require(sent, "Failed to send native tokens");
            } else {
                payoutToken.safeTransfer(owner, capacity);
            }
        }

        auctioneer.closeMarket(id_);
    }

    /// @inheritdoc IBondTeller
    function getFee(address referrer_) external view returns (uint48) {
        return protocolFee + referrerFees[referrer_];
    }

    /* ========== USER FUNCTIONS ========== */

    /// @inheritdoc IBondTeller
    function purchase(
        address recipient_,
        address referrer_,
        uint256 id_,
        uint256 amount_,
        uint256 minAmountOut_
    ) external payable virtual nonReentrant returns (uint256, uint48) {
        ERC20 payoutToken;
        ERC20 quoteToken;
        uint48 vesting;
        uint256 payout;

        // Calculate fees for purchase
        // 1. Calculate referrer fee
        // 2. Calculate protocol fee as the total expected fee amount minus the referrer fee
        //    to avoid issues with rounding from separate fee calculations
        uint256 toReferrer = amount_.mulDiv(referrerFees[referrer_], FEE_DECIMALS);
        uint256 toProtocol = amount_.mulDiv(protocolFee + referrerFees[referrer_], FEE_DECIMALS) - toReferrer;

        {
            IBondAuctioneer auctioneer = _aggregator.getAuctioneer(id_);
            address owner;
            (owner, payoutToken, quoteToken, vesting, ) = auctioneer.getMarketInfoForPurchase(id_);

            // Auctioneer handles bond pricing, capacity, and duration
            uint256 amountLessFee = amount_ - toReferrer - toProtocol;
            payout = auctioneer.purchaseBond(id_, amountLessFee, minAmountOut_);
        }

        // Transfer quote tokens from sender and ensure enough payout tokens are available
        _handleTransfers(id_, amount_, toReferrer + toProtocol);

        // Transfer fees to beneficiary and referrer
        _handleFeePayout(referrer_, quoteToken, toReferrer);
        _handleFeePayout(beneficiary, quoteToken, toProtocol);

        // Handle payout to user (either transfer tokens if instant swap or issue bond token)
        uint48 expiry = _handlePayout(recipient_, payout, payoutToken, vesting);

        emit Bonded(id_, referrer_, amount_, payout);

        return (payout, expiry);
    }

    /// @notice     Handles transfer of funds from user
    function _handleTransfers(uint256 id_, uint256 amount_, uint256 feePaid_) internal whenNotPaused {
        // Get info from auctioneer
        (address owner, , ERC20 quoteToken, , ) = _aggregator.getAuctioneer(id_).getMarketInfoForPurchase(id_);

        // Calculate amount net of fees
        uint256 amountLessFee = amount_ - feePaid_;

        // if quoteToken is native token, ensure msg.value is equal to amount_
        // otherwise, transfer quoteToken from msg.sender to this contract
        if (address(quoteToken) == address(0)) {
            if (msg.value != amount_) revert Teller_InvalidParams();

            bool sent = payable(owner).send(amountLessFee);
            require(sent, "Failed to send native tokens");
        } else {
            // Have to transfer to teller first since fee is in quote token
            // Check balance before and after to ensure full amount received, revert if not
            // Handles edge cases like fee-on-transfer tokens (which are not supported)
            uint256 quoteBalance = quoteToken.balanceOf(address(this));
            quoteToken.safeTransferFrom(msg.sender, address(this), amount_);
            if (quoteToken.balanceOf(address(this)) < quoteBalance + amount_) revert Teller_UnsupportedToken();

            // Send quote token to callback (transferred in first to allow use during callback)
            quoteToken.safeTransfer(owner, amountLessFee);
        }
    }

    receive() external payable {} // need to receive native token from auctioner

    /// @notice             Handle payout to recipient
    /// @dev                Implementation-agnostic. Must be implemented in contracts that
    ///                     extend this base since it is called by purchase.
    /// @param recipient_   Address to receive payout
    /// @param payout_      Amount of payoutToken to be paid
    /// @param underlying_   Token to be paid out
    /// @param vesting_     Time parameter for when the payout is available, could be a
    ///                     timestamp or duration depending on the implementation
    /// @return expiry      Timestamp when the payout will vest
    function _handlePayout(
        address recipient_,
        uint256 payout_,
        ERC20 underlying_,
        uint48 vesting_
    ) internal virtual returns (uint48 expiry);

    /// @notice             Handle reward payout to recipient
    /// @param recipient_   Address to receive payout
    /// @param token_       Token to be paid out
    /// @param amount_      Amount of token to be paid
    function _handleFeePayout(
        address recipient_, 
        ERC20 token_, 
        uint256 amount_
    ) internal {
        if (address(token_) == address(0)) {
            bool sent = payable(recipient_).send(amount_);
            require(sent, "Failed to send native tokens");
        } else {
            // Check balance before and after to ensure full amount received, revert if not
            // Handles edge cases like fee-on-transfer tokens (which are not supported)
            uint256 tokenBalance = token_.balanceOf(address(recipient_));
            token_.safeTransfer(recipient_, amount_);
            if (token_.balanceOf(address(recipient_)) < tokenBalance + amount_) revert Teller_UnsupportedToken();
        }
    }

    /// @notice             Derive name and symbol of token for market
    /// @param underlying_   Underlying token to be paid out when the Bond Token vests
    /// @param expiry_      Timestamp that the Bond Token vests at
    /// @return name        Bond token name, format is "Token YYYY-MM-DD"
    /// @return symbol      Bond token symbol, format is "TKN-YYYYMMDD"
    function _getNameAndSymbol(
        ERC20 underlying_,
        uint256 expiry_
    ) internal view returns (string memory name, string memory symbol) {
        // Convert a number of days into a human-readable date, courtesy of BokkyPooBah.
        // Source: https://github.com/bokkypoobah/BokkyPooBahsDateTimeLibrary/blob/master/contracts/BokkyPooBahsDateTimeLibrary.sol

        uint256 year;
        uint256 month;
        uint256 day;
        {
            int256 __days = int256(expiry_ / 1 days);

            int256 num1 = __days + 68569 + 2440588; // 2440588 = OFFSET19700101
            int256 num2 = (4 * num1) / 146097;
            num1 = num1 - (146097 * num2 + 3) / 4;
            int256 _year = (4000 * (num1 + 1)) / 1461001;
            num1 = num1 - (1461 * _year) / 4 + 31;
            int256 _month = (80 * num1) / 2447;
            int256 _day = num1 - (2447 * _month) / 80;
            num1 = _month / 11;
            _month = _month + 2 - 12 * num1;
            _year = 100 * (num2 - 49) + _year + num1;

            year = uint256(_year);
            month = uint256(_month);
            day = uint256(_day);
        }

        string memory yearStr = _uint2str(year % 10000);
        string memory monthStr = month < 10 ? string(abi.encodePacked("0", _uint2str(month))) : _uint2str(month);
        string memory dayStr = day < 10 ? string(abi.encodePacked("0", _uint2str(day))) : _uint2str(day);

        string memory initialName = "amb";
        string memory initialSymbol = "AMB";
        if (address(underlying_) != address(0)) {
            initialName = underlying_.name();
            initialSymbol = underlying_.symbol();
        }

        // Construct name/symbol strings.
        name = string(abi.encodePacked(initialName, " ", yearStr, "-", monthStr, "-", dayStr));
        symbol = string(abi.encodePacked(initialSymbol, "-", yearStr, monthStr, dayStr));
    }

    // Some fancy math to convert a uint into a string, courtesy of Provable Things.
    // Updated to work with solc 0.8.0.
    // https://github.com/provable-things/ethereum-api/blob/master/provableAPI_0.6.sol
    function _uint2str(uint256 _i) internal pure returns (string memory) {
        if (_i == 0) {
            return "0";
        }
        uint256 j = _i;
        uint256 len;
        while (j != 0) {
            len++;
            j /= 10;
        }
        bytes memory bstr = new bytes(len);
        uint256 k = len;
        while (_i != 0) {
            k = k - 1;
            uint8 temp = (48 + uint8(_i - (_i / 10) * 10));
            bytes1 b1 = bytes1(temp);
            bstr[k] = b1;
            _i /= 10;
        }
        return string(bstr);
    }
}
