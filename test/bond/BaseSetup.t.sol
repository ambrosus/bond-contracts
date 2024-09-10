// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {ERC1155TokenReceiver} from "../../lib/ERC1155.sol";
import "../../src/BondAggregator.sol";
import "../../src/RolesAuthority.sol";
import "../../src/bases/BondTeller1155Upgradeable.sol";
import {MockERC20} from "../utils/mocks/MockERC20.sol";
import "forge-std/Test.sol";

contract QuoteToken is MockERC20("Quote token", "QTK", 18) {}

contract PayoutToken is MockERC20("Payout token", "PTK", 18) {}

abstract contract BondBaseTestSetup is Test, ERC1155TokenReceiver {

    RolesAuthority public rolesAuthority;
    BondAggregator public aggregator;
    BondTeller1155Upgradeable public teller;
    IBondAuctioneer public auctioneer;
    ERC20 public quoteToken;
    ERC20 public payoutToken;

    address public owner;
    address public beneficiary;
    uint256 public marketId;

    function onERC1155Received(
        address _operator,
        address _from,
        uint256 _id,
        uint256 _amount,
        bytes calldata _data
    ) public override returns (bytes4) {
        return ERC1155TokenReceiver.onERC1155Received.selector;
    }

    function onERC1155BatchReceived(
        address _operator,
        address _from,
        uint256[] calldata _ids,
        uint256[] calldata _amounts,
        bytes calldata _data
    ) external override returns (bytes4) {
        return ERC1155TokenReceiver.onERC1155BatchReceived.selector;
    }

    function mintToken(
        MockERC20 token_
    ) internal returns (ERC20 token) {
        uint256 amountToMint = 10_000_000_000 * 10 ** token_.decimals();
        token_.mint(address(this), amountToMint);
        token_.mint(address(0xA11CE), amountToMint);
        token_.mint(address(0xB0B), amountToMint);
        token_.mint(address(0xBEEF), amountToMint);
        token_.mint(address(0xCA41), amountToMint);
        token_.mint(address(0xCAFE), amountToMint);
        token_.mint(address(0xFACE), amountToMint);
        return ERC20(address(token_));
    }

    function setUp() public virtual {
        owner = address(this);
        beneficiary = address(0xB0B);
        rolesAuthority = new RolesAuthority(owner, IAuthority(address(0)));
        aggregator = new BondAggregator(owner, rolesAuthority);
        quoteToken = mintToken(new QuoteToken());
        payoutToken = mintToken(new PayoutToken());
        ///@dev here should be the setup of teller and auctioneer
    }

}
