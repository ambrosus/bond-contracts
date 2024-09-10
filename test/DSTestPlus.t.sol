// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.20;

import {DSTestPlus} from "./utils/DSTestPlus.sol";

contract DSTestPlusTest is DSTestPlus {

    function testBound() public {
        assertEq(bound(0, uint256(69), uint256(69)), 69);
        assertEq(bound(0, uint256(68), uint256(69)), 68);
        assertEq(bound(5, uint256(0), uint256(4)), 0);
        assertEq(bound(9999, uint256(1337), uint256(6666)), 4669);
        assertEq(bound(0, type(uint256).max - 3, type(uint256).max), type(uint256).max - 3);
        assertEq(bound(3, type(uint256).max - 3, type(uint256).max), type(uint256).max);
    }

    function testFailBoundMinBiggerThanMax() public {
        bound(5, uint256(100), uint256(10));
    }

    function testRelApproxEqBothZeroesPasses() public {
        assertRelApproxEq(0, 0, 1e18);
        assertRelApproxEq(0, 0, 0);
    }

    function testBound(uint256 num, uint256 min, uint256 max) public {
        if (min > max) (min, max) = (max, min);

        uint256 bounded = bound(num, min, max);

        assertGe(bounded, min);
        assertLe(bounded, max);
    }

    function testFailBoundMinBiggerThanMax(uint256 num, uint256 min, uint256 max) public {
        if (max == min) {
            unchecked {
                min++; // Overflow is handled below.
            }
        }

        if (max > min) (min, max) = (max, min);

        bound(num, min, max);
    }

    function testBrutalizeMemory() public brutalizeMemory("FEEDFACECAFEBEEFFEEDFACECAFEBEEF") {
        bytes32 scratchSpace1;
        bytes32 scratchSpace2;
        bytes32 freeMem1;
        bytes32 freeMem2;

        assembly {
            scratchSpace1 := mload(0)
            scratchSpace2 := mload(32)
            freeMem1 := mload(mload(0x40))
            freeMem2 := mload(add(mload(0x40), 32))
        }

        assertGt(uint256(freeMem1), 0);
        assertGt(uint256(freeMem2), 0);
        assertGt(uint256(scratchSpace1), 0);
        assertGt(uint256(scratchSpace2), 0);
    }

}
