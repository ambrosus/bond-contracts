// SPDX-License-Identifier: MIT
// Compatible with OpenZeppelin Contracts ^4.9.3
pragma solidity ^0.8.15;

import "@openzeppelin/contracts-upgradeable/token/ERC1155/ERC1155Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC1155/extensions/ERC1155PausableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC1155/extensions/ERC1155BurnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC1155/extensions/ERC1155SupplyUpgradeable.sol";

abstract contract Teller1155Upgradeable 
                  is  ERC1155Upgradeable, 
                      ERC1155PausableUpgradeable,
                      ERC1155BurnableUpgradeable, 
                      ERC1155SupplyUpgradeable {

  function __Teller1155_init()
    internal onlyInitializing
  {
    __ERC1155_init("");
    __ERC1155Pausable_init();
    __ERC1155Burnable_init();
    __ERC1155Supply_init();
  }
  
  // The following functions are overrides required by Solidity.

  function _beforeTokenTransfer(address operator, address from, address to, uint256[] memory ids, uint256[] memory amounts, bytes memory data)
    internal
    override(ERC1155Upgradeable, ERC1155PausableUpgradeable, ERC1155SupplyUpgradeable)
  {
    super._beforeTokenTransfer(operator, from, to, ids, amounts, data);
  }

  function supportsInterface(bytes4 interfaceId)
    public 
    virtual 
    view
    override returns (bool) {
    return super.supportsInterface(interfaceId);
  }

  
}
