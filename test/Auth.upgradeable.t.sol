// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.20;

import {DSTestPlus} from "./utils/DSTestPlus.sol";
import {UnsafeUpgrades, Upgrades} from "./utils/LegacyUpgradesPlus.sol";
import {MockAuthChildUpgradeable} from "./utils/mocks/MockAuthChild.upgradeable.sol";
import {MockAuthority} from "./utils/mocks/MockAuthority.sol";

import {IAuthority} from "../lib/Auth.sol";

contract OutOfOrderAuthority is IAuthority {

    function canCall(address, address, bytes4) public pure override returns (bool) {
        revert("OUT_OF_ORDER");
    }

}

contract AuthTest is DSTestPlus {

    MockAuthChildUpgradeable mockAuthChildUpgradeable;

    function setUp() public {
        address implementation = address(new MockAuthChildUpgradeable());
        address proxy =
            UnsafeUpgrades.deployUUPSProxy(implementation, abi.encodeCall(MockAuthChildUpgradeable.initialize, ()));
        mockAuthChildUpgradeable = MockAuthChildUpgradeable(proxy);
    }

    function testTransferOwnershipAsOwner() public {
        mockAuthChildUpgradeable.setOwner(address(0xBEEF));
        assertEq(mockAuthChildUpgradeable.owner(), address(0xBEEF));
    }

    function testSetAuthorityAsOwner() public {
        mockAuthChildUpgradeable.setAuthority(IAuthority(address(0xBEEF)));
        assertEq(address(mockAuthChildUpgradeable.authority()), address(0xBEEF));
    }

    function testCallFunctionAsOwner() public {
        mockAuthChildUpgradeable.updateFlag();
    }

    function testTransferOwnershipWithPermissiveAuthority() public {
        mockAuthChildUpgradeable.setAuthority(new MockAuthority(true));
        mockAuthChildUpgradeable.setOwner(address(0));
        mockAuthChildUpgradeable.setOwner(address(this));
    }

    function testSetAuthorityWithPermissiveAuthority() public {
        mockAuthChildUpgradeable.setAuthority(new MockAuthority(true));
        mockAuthChildUpgradeable.setOwner(address(0));
        mockAuthChildUpgradeable.setAuthority(IAuthority(address(0xBEEF)));
    }

    function testCallFunctionWithPermissiveAuthority() public {
        mockAuthChildUpgradeable.setAuthority(new MockAuthority(true));
        mockAuthChildUpgradeable.setOwner(address(0));
        mockAuthChildUpgradeable.updateFlag();
    }

    function testSetAuthorityAsOwnerWithOutOfOrderAuthority() public {
        mockAuthChildUpgradeable.setAuthority(new OutOfOrderAuthority());
        mockAuthChildUpgradeable.setAuthority(new MockAuthority(true));
    }

    function testFailTransferOwnershipAsNonOwner() public {
        mockAuthChildUpgradeable.setOwner(address(0));
        mockAuthChildUpgradeable.setOwner(address(0xBEEF));
    }

    function testFailSetAuthorityAsNonOwner() public {
        mockAuthChildUpgradeable.setOwner(address(0));
        mockAuthChildUpgradeable.setAuthority(IAuthority(address(0xBEEF)));
    }

    function testFailCallFunctionAsNonOwner() public {
        mockAuthChildUpgradeable.setOwner(address(0));
        mockAuthChildUpgradeable.updateFlag();
    }

    function testFailTransferOwnershipWithRestrictiveAuthority() public {
        mockAuthChildUpgradeable.setAuthority(new MockAuthority(false));
        mockAuthChildUpgradeable.setOwner(address(0));
        mockAuthChildUpgradeable.setOwner(address(this));
    }

    function testFailSetAuthorityWithRestrictiveAuthority() public {
        mockAuthChildUpgradeable.setAuthority(new MockAuthority(false));
        mockAuthChildUpgradeable.setOwner(address(0));
        mockAuthChildUpgradeable.setAuthority(IAuthority(address(0xBEEF)));
    }

    function testFailCallFunctionWithRestrictiveAuthority() public {
        mockAuthChildUpgradeable.setAuthority(new MockAuthority(false));
        mockAuthChildUpgradeable.setOwner(address(0));
        mockAuthChildUpgradeable.updateFlag();
    }

    function testFailTransferOwnershipAsOwnerWithOutOfOrderAuthority() public {
        mockAuthChildUpgradeable.setAuthority(new OutOfOrderAuthority());
        mockAuthChildUpgradeable.setOwner(address(0));
    }

    function testFailCallFunctionAsOwnerWithOutOfOrderAuthority() public {
        mockAuthChildUpgradeable.setAuthority(new OutOfOrderAuthority());
        mockAuthChildUpgradeable.updateFlag();
    }

    function testTransferOwnershipAsOwner(
        address newOwner
    ) public {
        mockAuthChildUpgradeable.setOwner(newOwner);
        assertEq(mockAuthChildUpgradeable.owner(), newOwner);
    }

    function testSetAuthorityAsOwner(
        IAuthority newAuthority
    ) public {
        mockAuthChildUpgradeable.setAuthority(newAuthority);
        assertEq(address(mockAuthChildUpgradeable.authority()), address(newAuthority));
    }

    function testTransferOwnershipWithPermissiveAuthority(address deadOwner, address newOwner) public {
        if (deadOwner == address(this)) deadOwner = address(0);

        mockAuthChildUpgradeable.setAuthority(new MockAuthority(true));
        mockAuthChildUpgradeable.setOwner(deadOwner);
        mockAuthChildUpgradeable.setOwner(newOwner);
    }

    function testSetAuthorityWithPermissiveAuthority(address deadOwner, IAuthority newAuthority) public {
        if (deadOwner == address(this)) deadOwner = address(0);

        mockAuthChildUpgradeable.setAuthority(new MockAuthority(true));
        mockAuthChildUpgradeable.setOwner(deadOwner);
        mockAuthChildUpgradeable.setAuthority(newAuthority);
    }

    function testCallFunctionWithPermissiveAuthority(
        address deadOwner
    ) public {
        if (deadOwner == address(this)) deadOwner = address(0);

        mockAuthChildUpgradeable.setAuthority(new MockAuthority(true));
        mockAuthChildUpgradeable.setOwner(deadOwner);
        mockAuthChildUpgradeable.updateFlag();
    }

    function testFailTransferOwnershipAsNonOwner(address deadOwner, address newOwner) public {
        if (deadOwner == address(this)) deadOwner = address(0);

        mockAuthChildUpgradeable.setOwner(deadOwner);
        mockAuthChildUpgradeable.setOwner(newOwner);
    }

    function testFailSetAuthorityAsNonOwner(address deadOwner, IAuthority newAuthority) public {
        if (deadOwner == address(this)) deadOwner = address(0);

        mockAuthChildUpgradeable.setOwner(deadOwner);
        mockAuthChildUpgradeable.setAuthority(newAuthority);
    }

    function testFailCallFunctionAsNonOwner(
        address deadOwner
    ) public {
        if (deadOwner == address(this)) deadOwner = address(0);

        mockAuthChildUpgradeable.setOwner(deadOwner);
        mockAuthChildUpgradeable.updateFlag();
    }

    function testFailTransferOwnershipWithRestrictiveAuthority(address deadOwner, address newOwner) public {
        if (deadOwner == address(this)) deadOwner = address(0);

        mockAuthChildUpgradeable.setAuthority(new MockAuthority(false));
        mockAuthChildUpgradeable.setOwner(deadOwner);
        mockAuthChildUpgradeable.setOwner(newOwner);
    }

    function testFailSetAuthorityWithRestrictiveAuthority(address deadOwner, IAuthority newAuthority) public {
        if (deadOwner == address(this)) deadOwner = address(0);

        mockAuthChildUpgradeable.setAuthority(new MockAuthority(false));
        mockAuthChildUpgradeable.setOwner(deadOwner);
        mockAuthChildUpgradeable.setAuthority(newAuthority);
    }

    function testFailCallFunctionWithRestrictiveAuthority(
        address deadOwner
    ) public {
        if (deadOwner == address(this)) deadOwner = address(0);

        mockAuthChildUpgradeable.setAuthority(new MockAuthority(false));
        mockAuthChildUpgradeable.setOwner(deadOwner);
        mockAuthChildUpgradeable.updateFlag();
    }

    function testFailTransferOwnershipAsOwnerWithOutOfOrderAuthority(
        address deadOwner
    ) public {
        if (deadOwner == address(this)) deadOwner = address(0);

        mockAuthChildUpgradeable.setAuthority(new OutOfOrderAuthority());
        mockAuthChildUpgradeable.setOwner(deadOwner);
    }

}
