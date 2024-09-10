// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {BondFixedTermTeller} from "../../../src/BondFixedTermTeller.sol";
import "../../../src/RolesAuthority.sol";
import {IBondAuctioneer} from "../../../src/interfaces/IBondAuctioneer.sol";
import {UnsafeUpgrades, Upgrades} from "../../utils/LegacyUpgradesPlus.sol";

import {MockAuctioneerDummy} from "../../utils/mocks/MockAuctioneers.sol";
import {BondBaseTestSetup} from "../BaseSetup.t.sol";
import {ERC20} from "@openzeppelin-contracts/token/ERC20/ERC20.sol";

contract BondFixedTermTestBase is BondBaseTestSetup {

    BondFixedTermTeller public fixedTermTeller;

    function setUp() public virtual override {
        super.setUp();

        address implementation = address(new BondFixedTermTeller());
        address proxy = UnsafeUpgrades.deployUUPSProxy(
            implementation,
            abi.encodeCall(BondFixedTermTeller.initialize, (beneficiary, aggregator, owner, rolesAuthority))
        );
        fixedTermTeller = BondFixedTermTeller(payable(proxy));
        teller = fixedTermTeller;
    }

}
