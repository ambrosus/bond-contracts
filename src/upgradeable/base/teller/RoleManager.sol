// SPDX-License-Identifier: MIT
// Compatible with OpenZeppelin Contracts ^4.9.3
pragma solidity ^0.8.15;

import "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";

abstract contract TellerRolesUpgradeable is AccessControlUpgradeable {
  bytes32 public constant OWNER_ROLE = keccak256("OWNER_ROLE");
  bytes32 public constant PAUSER_ROLE = keccak256("PAUSER_ROLE");
  bytes32 public constant MINTER_ROLE = keccak256("MINTER_ROLE");
  bytes32 public constant UPGRADER_ROLE = keccak256("UPGRADER_ROLE");
  bytes32 public constant FEE_ADMIN_ROLE = keccak256("FEE_ADMIN_ROLE");

  function __TellerRoles_init(address defaultAdmin, address pauser, address minter, address upgrader, address feeAdmin)
    internal onlyInitializing
  {
    __AccessControl_init();
    _grantRole(DEFAULT_ADMIN_ROLE, address(this));
    _grantRole(OWNER_ROLE, defaultAdmin);
    _grantRole(PAUSER_ROLE, pauser);
    _grantRole(MINTER_ROLE, minter);
    _grantRole(UPGRADER_ROLE, upgrader);
    _grantRole(FEE_ADMIN_ROLE, feeAdmin);
  }

  function supportsInterface(bytes4 interfaceId)
    public
    virtual
    view
    override
    returns (bool)
  {
    return super.supportsInterface(interfaceId);
  }
}
