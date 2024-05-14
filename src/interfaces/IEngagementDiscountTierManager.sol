pragma solidity >=0.8.0 <0.9.0;
interface IEngagementOracle {
    struct UserTier {
        uint8 tier;
        uint48 resetCounter;
    }

    event TierSet(address indexed user, uint8 indexed tier);
    event TiersReset();

    error EngagementOracle_OnlyWriter();

    /// @notice Set the engagement points for a user from Backend
    function setTier(address user_, uint8 tier_) external;

    /// @notice Returns the engagement points for a user
    function getUserTier(address user_) external view returns (uint8 tier);

    function resetTiers() external;

    function setWriter(address dataWriter_) external;
}

interface IEngagementDiscountTierManager {
    error Manager_InvalidOracle();
    error Manager_ConstantTier();
    error Manager_TierListEmpty();
    error Manager_TierNotDefined(uint8 level);
    error Manager_TierNotFound(uint8 level, uint8 maxLevel);
    error Manager_LargeTierList(uint8 maxLevel);
    error Manager_TierListNotSorted();
    error Manager_PercentageTooLarge(uint percentage, uint oneHundredPercent);

    event TierDiscountSet(uint8 indexed level, uint discount);
    event TierDiscountRemoved(uint8 indexed level);
    event TiersCleared();

    struct TierStore {
        uint discount;
        bool defined;
    }

    struct Tier {
        uint discount;
    }

    struct TierWithLevel {
        uint8 level;
        uint discount;
    }

    // utility views to retrieve user related data
    function getTier(address user) external view returns (TierWithLevel memory tier);

    function getDiscount(address user) external view returns (uint256);

    function applyDiscount(uint256 amount, address user) external view returns (uint256);

    // utility views to retrieve tier related data
    function tier(uint8 level) external view returns (TierWithLevel memory tier);

    function tiers() external view returns (TierWithLevel[] memory tiers);

    // management functions
    function setTier(uint8 level, Tier calldata discount) external;

    function setTiers(Tier[] calldata tiers) external;

    function removeTier(uint8 level) external;

    function clearTiers() external;

    // utility views to retrieve oracle related data
    function oracle() external view returns (IEngagementOracle);

    function setOracle(IEngagementOracle oracle_) external;

    function getUserLevel(address user) external view returns (uint8);

    // view showing the number of decimals used for the discount percentage, 10 ** decimals equals 100%
    function decimals() external view returns (uint8);
}
