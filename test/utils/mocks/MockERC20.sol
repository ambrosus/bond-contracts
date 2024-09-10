// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity 0.8.20;

import {MockERC20 as FakeERC20} from "forge-std/mocks/MockERC20.sol";

contract MockERC20 is FakeERC20 {

    constructor(string memory name_, string memory symbol_, uint8 decimals_) {
        initialize(name_, symbol_, decimals_);
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function burn(address from, uint256 amount) external {
        _burn(from, amount);
    }

}
