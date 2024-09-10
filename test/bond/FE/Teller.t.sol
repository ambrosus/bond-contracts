// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {BondFixedExpiryTeller} from "../../../src/BondFixedExpiryTeller.sol";
import "../../../src/RolesAuthority.sol";
import {IBondAuctioneer} from "../../../src/interfaces/IBondAuctioneer.sol";
import {UnsafeUpgrades, Upgrades} from "../../utils/LegacyUpgradesPlus.sol";

import {MockAuctioneerDummy} from "../../utils/mocks/MockAuctioneers.sol";
import {BondBaseTestSetup} from "../BaseSetup.t.sol";
import {ERC20} from "@openzeppelin-contracts/token/ERC20/ERC20.sol";

contract BondFixedExpiryTestBase is BondBaseTestSetup {

    BondFixedExpiryTeller public fixedExpiryTeller;

    function setUp() public virtual override {
        super.setUp();

        address implementation = address(new BondFixedExpiryTeller());
        address proxy = UnsafeUpgrades.deployUUPSProxy(
            implementation,
            abi.encodeCall(BondFixedExpiryTeller.initialize, (beneficiary, aggregator, owner, rolesAuthority))
        );
        fixedExpiryTeller = BondFixedExpiryTeller(payable(proxy));
        teller = fixedExpiryTeller;
    }

}
