// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity >=0.8.0;

import {Auth, IAuthority} from "../../../lib/Auth.sol";

contract MockAuthChild is Auth(msg.sender, IAuthority(address(0))) {

    bool public flag;

    function updateFlag() public virtual requiresAuth {
        flag = true;
    }

}
