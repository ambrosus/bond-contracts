// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity 0.8.15;

import "./interfaces/IBondOracle.sol";
import "@openzeppelin/contracts/access/AccessControl.sol";

contract BondOracle is IBondOracle, AccessControl {
    bytes32 public constant AUCTIONEER_ROLE = keccak256("AUCTIONEER_ROLE");  // can register markets
    bytes32 public constant PRICE_ORACLE_ROLE = keccak256("PRICE_ORACLE_ROLE");  // can set prices

    struct MarketTokens {ERC20 quoteToken; ERC20 payoutToken;}

    type Timestamp is uint256;
    // @note This is a constant value that represents the time window in seconds that a price is considered valid
    uint256 public constant VALIDITY_WINDOW = 300;  // 5 minutes
    // ------------ Error for old price ------------
    error Oracle_OldPrice(address token, uint lastUpdatedAt, uint currentWindow);
    // ------------  Data entry struct  ------------
    struct DataWithTimestamp {
        uint price;
        Timestamp updatedAt;
    }
    // ---------------------------------------------


    mapping(uint256 => MarketTokens) public marketsTokens;
    mapping(address => DataWithTimestamp) internal prices;  // price of token in USD
    uint8 public constant oracleDecimals = 18;

    constructor(){
        _setupRole(DEFAULT_ADMIN_ROLE, msg.sender);
    }

    /// @notice Modifier to restrict old price calculations
    modifier onlyValidPrice(address tokenAddress) {
        uint updatedAt = prices[tokenAddress].updatedAt;
        uint window = block.timestamp - VALIDITY_WINDOW;
        require(
            updatedAt >= window, 
            Oracle_OldPrice(tokenAddress, updatedAt, window)
        );
        _;
    }

    /// @notice Set price (in USD) for smallest unit of token
    function setPrice(address token, uint price) external onlyRole(PRICE_ORACLE_ROLE) {
        prices[token] = DataWithTimestamp(price, block.timestamp);
    }

    /// @notice Register a new bond market on the oracle
    function registerMarket(uint256 id_, ERC20 quoteToken_, ERC20 payoutToken_) external onlyRole(AUCTIONEER_ROLE) {
        marketsTokens[id_] = MarketTokens(quoteToken_, payoutToken_);
    }

    /// @notice Returns token price in USD
    function usdPrice(address tokenAddress) external view onlyValidPrice(tokenAddress) returns (uint256) {
        return prices[tokenAddress].price;
    }

    /// @notice Returns the price as a ratio of quote tokens to base tokens for the provided market id scaled by 10^decimals
    function currentPrice(uint256 id_) external view returns (uint256) {
        MarketTokens memory tokens = marketsTokens[id_];
        return this.currentPrice(tokens.quoteToken, tokens.payoutToken);
    }

    /// @notice Returns the price as a ratio of quote tokens to base tokens for the provided token pair scaled by 10^decimals
    function currentPrice(
        ERC20 quoteToken_, 
        ERC20 payoutToken_
    ) 
        external 
        view 
        onlyValidPrice(address(quoteToken_)) 
        onlyValidPrice(address(payoutToken_)) 
        returns (uint256) 
    {
        uint quotePrice = prices[address(quoteToken_)].price;
        uint payoutPrice = prices[address(payoutToken_)].price;
        uint quoteDecimals = quoteToken_.decimals();
        uint payoutDecimals = payoutToken_.decimals();

        return (quotePrice * 10 ** (payoutDecimals + oracleDecimals)) /
            (payoutPrice * 10 ** quoteDecimals);
    }

    /// @notice Returns the number of configured decimals of the price value for the provided market id
    function decimals(uint256 id_) external view returns (uint8) {
        return oracleDecimals;
    }

    /// @notice Returns the number of configured decimals of the price value for the provided token pair
    function decimals(ERC20 quoteToken_, ERC20 payoutToken_) 
        external 
        view 
        returns (uint8) 
    {
        return oracleDecimals;
    }

}