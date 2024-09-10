// SPDX-License-Identifier: AGPL-3.0
pragma solidity >=0.8.0;

import {ERC20} from "@openzeppelin-contracts/token/ERC20/ERC20.sol";

interface IBondTeller {

    /// @notice                 Exchange quote tokens for a bond in a specified market
    /// @param recipient_       Address of recipient of bond. Allows deposits for other addresses
    /// @param referrer_        Address of referrer who will receive referral fee. For frontends to fill.
    ///                         Direct calls can use the zero address for no referrer fee.
    /// @param id_              ID of the Market the bond is being purchased from
    /// @param amount_          Amount to deposit in exchange for bond
    /// @param minAmountOut_    Minimum acceptable amount of bond to receive. Prevents frontrunning
    /// @return                 Amount of payout token to be received from the bond
    /// @return                 Timestamp at which the bond token can be redeemed for the underlying token
    function purchase(
        address recipient_,
        address referrer_,
        uint256 id_,
        uint256 amount_,
        uint256 minAmountOut_
    ) external payable returns (uint256, uint48);

    /// @notice             Change the beneficiary of the teller
    /// @param beneficiary_ Address of the new beneficiary
    function setBeneficiary(
        address beneficiary_
    ) external;

    /// @notice          Get current fee charged by the teller based on the combined protocol and referrer fee
    /// @param referrer_ Address of the referrer
    /// @return          Fee in basis points (3 decimal places)
    function getFee(
        address referrer_
    ) external view returns (uint48);

    /// @notice         Set protocol fee
    /// @notice         Must be guardian
    /// @param fee_     Protocol fee in basis points (3 decimal places)
    function setProtocolFee(
        uint48 fee_
    ) external;

    /// @notice          Set the discount for creating bond tokens from the base protocol fee
    /// @dev             The discount is subtracted from the protocol fee to determine the fee
    ///                  when using create() to mint bond tokens without using an Auctioneer
    /// @param discount_ Create Fee Discount in basis points (3 decimal places)
    function setCreateFeeDiscount(
        uint48 discount_
    ) external;

    /// @notice         Set your fee as a referrer to the protocol
    /// @notice         Fee is set for sending address
    /// @param fee_     Referrer fee in basis points (3 decimal places)
    function setReferrerFee(
        uint48 fee_
    ) external;

    /// @notice         Return the remaining capacity of a market back to the market owner
    /// @notice         Only owner can close market earlier than the market conclusion
    /// @notice         Once market conclusion has passed, anyone can initiate payout to market owner
    /// @param id_      ID of the Market to close
    function closeMarket(
        uint256 id_
    ) external;

}
