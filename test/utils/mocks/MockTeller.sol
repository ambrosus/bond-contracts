// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity 0.8.20;

import {IAuthority} from "../../../lib/interfaces/IAuthority.sol";

import {BondTeller1155Upgradeable} from "../../../src/bases/BondTeller1155Upgradeable.sol";
import {IBondAggregator} from "../../../src/interfaces/IBondAggregator.sol";
import {ERC20} from "@openzeppelin-contracts/token/ERC20/ERC20.sol";
import {SafeCast} from "@openzeppelin-contracts/utils/math/SafeCast.sol";

contract MockTeller is BondTeller1155Upgradeable {

    using SafeCast for uint256;

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(
        address protocol_,
        IBondAggregator aggregator_,
        address guardian_,
        IAuthority authority_
    ) public initializer {
        __BondTeller1155_init(protocol_, aggregator_, guardian_, authority_);
    }
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
    ) internal virtual override returns (uint48 expiry) {
        if (vesting_ == 0) {
            payoutToken_.transfer(recipient_, payout_);
        } else {
            uint256 tokenId = getTokenId(payoutToken_, (block.timestamp + vesting_).toUint48());
            if (!tokenMetadata[tokenId].active) _deploy(tokenId, payoutToken_, (block.timestamp + vesting_).toUint48());
            _mintToken(recipient_, tokenId, payout_);
        }
        return (block.timestamp + vesting_).toUint48();
    }

}
