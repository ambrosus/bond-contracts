// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity >=0.8.0;

import {AuthUpgradeable, IAuthority} from "../../../lib/AuthUpgradeable.sol";

contract MockAuthChildUpgradeable is AuthUpgradeable {

    function __MockAuthChildUpgradeable_init(address _owner, IAuthority _authority) internal onlyInitializing {
        __AuthUpgradeable_init(_owner, _authority);
    }

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize() public initializer {
        __MockAuthChildUpgradeable_init(msg.sender, IAuthority(address(0)));
    }

    bool public flag;

    function updateFlag() public virtual requiresAuth {
        flag = true;
    }

}
