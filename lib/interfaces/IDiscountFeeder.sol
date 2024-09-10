pragma solidity ^0.8.20;

import "@openzeppelin-contracts/token/ERC20/IERC20.sol";

interface IDiscountFeeder {
    error DiscountFeeder_TierNotDefined(uint256 tierLevel);
    error DiscountFeeder_PercentageTooLarge(uint percentage, uint oneHundredPercent);

    struct DiscountDataStore {
        bool defined;
        uint256 discount;
    }

    function getDiscount(address staker, IERC20 token) external view returns (uint256);

    function setDiscount(IERC20 token, uint256 tierLevel, uint256 discount) external;

    function removeDiscount(IERC20 token, uint256 tierLevel) external;

    function decimals() external view returns (uint8);
}
