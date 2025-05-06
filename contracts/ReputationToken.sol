// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

contract ReputationToken is ERC20, Ownable {
    constructor() ERC20("DeFi Social Reputation", "DSR") Ownable(msg.sender) {}

    function mint(address to, uint256 amount) public onlyOwner {
        _mint(to, amount);
    }

    function burn(address from, uint256 amount) public onlyOwner {
        // Allow burning from any address if owner initiates, useful for slashing staked tokens
        // Or only allow burning from the contract itself if tokens are sent there first
        _burn(from, amount);
    }
}