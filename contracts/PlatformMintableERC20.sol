// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

// Represents a fungible Real-World Asset tokenized by the platform
contract PlatformMintableERC20 is ERC20, Ownable {
    constructor(
        string memory name,     // e.g., "Tokenized Gold Batch X"
        string memory symbol    // e.g., "TGOLDX"
    ) ERC20(name, symbol) Ownable(msg.sender) {}

    function mint(address to, uint256 amount) public onlyOwner {
        _mint(to, amount);
    }

    function burn(address from, uint256 amount) public onlyOwner {
        _burn(from, amount);
    }
}