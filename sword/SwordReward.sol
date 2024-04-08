// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity 0.8.15;

import "../src/interfaces/IBondOracle.sol";


contract SwordReward {


    IBondOracle public bondOracle;


    constructor(IBondOracle _bondOracle){
        bondOracle = _bondOracle;
    }


    function issueRewards(address tokenAddress, uint amount) external{

    }

    function getFeeDiscount(address forAddress) external view returns(uint){

    }

    function setFeeDiscount(address forAddress, uint discount) external{

    }





    function getTokenUsdPrice(address tokenAddress) internal view returns(uint){
        return bondOracle.usdPrice(tokenAddress);
    }







}
