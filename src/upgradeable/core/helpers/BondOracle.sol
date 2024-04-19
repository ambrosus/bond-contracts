// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity 0.8.15;

import "@self/interfaces/IBondOracle.sol";
import "@openzeppelin/contracts/access/AccessControl.sol";

contract BondOracle is IBondOracle, AccessControl {
    bytes32 public constant AUCTIONEER_ROLE = keccak256("AUCTIONEER_ROLE");  // can register markets
    bytes32 public constant PRICE_ORACLE_ROLE = keccak256("PRICE_ORACLE_ROLE");  // can set prices

    struct MarketTokens {ERC20 quoteToken; ERC20 payoutToken;}

    mapping(uint256 => MarketTokens) public marketsTokens;
    mapping(address => uint) internal prices;  // price of token in USD
    uint8 public constant oracleDecimals = 18;

    constructor(){
        _setupRole(DEFAULT_ADMIN_ROLE, msg.sender);
    }

    /// @notice Set price (in USD) for smallest unit of token
    function setPrice(address token, uint price) external onlyRole(PRICE_ORACLE_ROLE) {
        prices[token] = price;
    }

    /// @notice Register a new bond market on the oracle
    function registerMarket(uint256 id_, ERC20 quoteToken_, ERC20 payoutToken_) external onlyRole(AUCTIONEER_ROLE) {
        marketsTokens[id_] = MarketTokens(quoteToken_, payoutToken_);
    }

    /// @notice Returns token price in USD
    function usdPrice(address tokenAddress) external view returns (uint256) {
        return prices[tokenAddress];
    }

    /// @notice Returns the price as a ratio of quote tokens to base tokens for the provided market id scaled by 10^decimals
    function currentPrice(uint256 id_) external view returns (uint256) {
        MarketTokens memory tokens = marketsTokens[id_];
        return this.currentPrice(tokens.quoteToken, tokens.payoutToken);
    }

    /// @notice Returns the price as a ratio of quote tokens to base tokens for the provided token pair scaled by 10^decimals
    function currentPrice(ERC20 quoteToken_, ERC20 payoutToken_) external view returns (uint256) {
        uint quotePrice = prices[address(quoteToken_)];
        uint payoutPrice = prices[address(payoutToken_)];
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
    function decimals(ERC20 quoteToken_, ERC20 payoutToken_) external view returns (uint8) {
        return oracleDecimals;
    }

}