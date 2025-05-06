// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import "@openzeppelin/contracts/token/ERC721/extensions/ERC721URIStorage.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/Counters.sol";

// Represents a non-fungible Real-World Asset tokenized by the platform
contract PlatformMintableERC721 is ERC721URIStorage, Ownable {
    using Counters for Counters.Counter;
    Counters.Counter private _tokenIds;

    constructor(
        string memory name,     // e.g., "Tokenized Real Estate Plot XYZ"
        string memory symbol    // e.g., "TREPXYZ"
    ) ERC721(name, symbol) Ownable(msg.sender) {}

    function mintWithTokenURI(address to, string memory tokenURI) public onlyOwner returns (uint256) {
        _tokenIds.increment();
        uint256 newItemId = _tokenIds.current();
        _mint(to, newItemId);
        _setTokenURI(newItemId, tokenURI);
        return newItemId;
    }
    
    function burn(uint256 tokenId) public onlyOwner { // Only owner can burn
        _burn(tokenId);
    }

    // The admin (owner) is responsible for setting correct URIs that point to asset details.
}