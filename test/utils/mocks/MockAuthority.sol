// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity >=0.8.0;

import {IAuthority} from "../../../lib/Auth.sol";

contract MockAuthority is IAuthority {

    bool immutable allowCalls;

    constructor(
        bool _allowCalls
    ) {
        allowCalls = _allowCalls;
    }

    function canCall(address, address, bytes4) public view override returns (bool) {
        return allowCalls;
    }

}
