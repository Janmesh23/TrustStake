// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import "@openzeppelin/contracts/token/ERC721/extensions/ERC721URIStorage.sol";
import "@openzeppelin/contracts/utils/Counters.sol";
import "@openzeppelin/contracts/utils/Base64.sol";
import "@openzeppelin/contracts/utils/Strings.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

contract BorrowerProfile is ERC721URIStorage, Ownable {
    using Counters for Counters.Counter;
    using Strings for uint256;
    
    Counters.Counter private _tokenIds;
    
    // Document type structure
    struct Document {
        string docType; // "PASSPORT", "LAND_DEED", "CAR_REGISTRATION" etc.
        string docURI;  // IPFS hash or URL to document
        uint256 uploadDate;
        bool verified;  // Admin verification status
    }
    
    // User profile structure
    struct UserInfo {
        string name;
        string dateOfBirth;
        string profileImageURI;
        uint256 totalAssetValue;
        string assetBreakdown;
        string contactInfo;
        string loanPurpose;
        uint256 registrationDate;
        string additionalInfo;
        Document[] documents; // Array of all submitted documents
        string[] docTypesSubmitted; // Track which types of docs were submitted
    }
    
    mapping(address => uint256) private _borrowerToToken;
    mapping(uint256 => UserInfo) private _profileInfo;
    
    event ProfileCreated(address indexed borrower, uint256 tokenId);
    event ProfileUpdated(address indexed borrower, uint256 tokenId);
    event DocumentAdded(address indexed borrower, string docType, string docURI);
    event DocumentVerified(uint256 tokenId, string docType, bool verified);

    constructor() ERC721("DeFi Borrower Profile", "DEFI-BP") Ownable(msg.sender) {}

    // Modified createProfile function with initial document support
    function createProfile(
        string memory name,
        string memory dateOfBirth,
        string memory profileImageURI,
        uint256 totalAssetValue,
        string memory assetBreakdown,
        string memory contactInfo,
        string memory loanPurpose,
        string memory additionalInfo,
        string[] memory initialDocTypes,
        string[] memory initialDocURIs
    ) external returns (uint256) {
        require(_borrowerToToken[msg.sender] == 0, "Profile already exists");
        require(bytes(name).length > 0, "Name cannot be empty");
        require(initialDocTypes.length == initialDocURIs.length, "Document arrays mismatch");
        
        _tokenIds.increment();
        uint256 newTokenId = _tokenIds.current();
        
        UserInfo storage newProfile = _profileInfo[newTokenId];
        newProfile.name = name;
        newProfile.dateOfBirth = dateOfBirth;
        newProfile.profileImageURI = profileImageURI;
        newProfile.totalAssetValue = totalAssetValue;
        newProfile.assetBreakdown = assetBreakdown;
        newProfile.contactInfo = contactInfo;
        newProfile.loanPurpose = loanPurpose;
        newProfile.registrationDate = block.timestamp;
        newProfile.additionalInfo = additionalInfo;
        
        // Add initial documents
        for (uint i = 0; i < initialDocTypes.length; i++) {
            newProfile.documents.push(Document({
                docType: initialDocTypes[i],
                docURI: initialDocURIs[i],
                uploadDate: block.timestamp,
                verified: false
            }));
            newProfile.docTypesSubmitted.push(initialDocTypes[i]);
            emit DocumentAdded(msg.sender, initialDocTypes[i], initialDocURIs[i]);
        }
        
        _borrowerToToken[msg.sender] = newTokenId;
        _mint(msg.sender, newTokenId);
        
        string memory tokenURI = _generateTokenURI(newTokenId);
        _setTokenURI(newTokenId, tokenURI);
        
        emit ProfileCreated(msg.sender, newTokenId);
        return newTokenId;
    }

    // Add new documents to existing profile
    function addDocuments(
        string[] memory docTypes,
        string[] memory docURIs
    ) external {
        uint256 tokenId = _borrowerToToken[msg.sender];
        require(tokenId != 0, "Profile does not exist");
        require(docTypes.length == docURIs.length, "Document arrays mismatch");
        
        UserInfo storage profile = _profileInfo[tokenId];
        
        for (uint i = 0; i < docTypes.length; i++) {
            profile.documents.push(Document({
                docType: docTypes[i],
                docURI: docURIs[i],
                uploadDate: block.timestamp,
                verified: false
            }));
            profile.docTypesSubmitted.push(docTypes[i]);
            emit DocumentAdded(msg.sender, docTypes[i], docURIs[i]);
        }
        
        // Update token URI to reflect new documents
        string memory tokenURI = _generateTokenURI(tokenId);
        _setTokenURI(tokenId, tokenURI);
    }

    // Admin function to verify documents
    function verifyDocument(
        uint256 tokenId,
        uint256 docIndex,
        bool isVerified
    ) external onlyOwner {
        require(_profileInfo[tokenId].documents.length > docIndex, "Invalid document index");
        _profileInfo[tokenId].documents[docIndex].verified = isVerified;
        emit DocumentVerified(tokenId, _profileInfo[tokenId].documents[docIndex].docType, isVerified);
    }

    // Enhanced token URI generation including documents
    function _generateTokenURI(uint256 tokenId) internal view returns (string memory) {
        UserInfo memory profile = _profileInfo[tokenId];
        
        // Format asset value
        string memory assetValueString = uint256(profile.totalAssetValue / 1e18).toString();
        
        // Generate documents array JSON
        string memory documentsJson = "[";
        for (uint i = 0; i < profile.documents.length; i++) {
            documentsJson = string(abi.encodePacked(
                documentsJson,
                i > 0 ? "," : "",
                '{"type":"', profile.documents[i].docType,
                '","uri":"', profile.documents[i].docURI,
                '","uploadDate":', Strings.toString(profile.documents[i].uploadDate),
                ',"verified":', profile.documents[i].verified ? "true" : "false",
                '}'
            ));
        }
        documentsJson = string(abi.encodePacked(documentsJson, "]"));
        
        // Create complete metadata JSON
        bytes memory json = abi.encodePacked(
            '{',
                '"name": "', profile.name, ' - Borrower Profile",',
                '"description": "DeFi Social Reputation System Borrower Profile",',
                '"image": "', profile.profileImageURI, '",',
                '"attributes": [',
                    '{"trait_type": "Name", "value": "', profile.name, '"},',
                    '{"trait_type": "Date of Birth", "value": "', profile.dateOfBirth, '"},',
                    '{"trait_type": "Total Asset Value", "value": "', assetValueString, ' USD"},',
                    '{"trait_type": "Registration Date", "value": ', Strings.toString(profile.registrationDate), '},',
                    '{"trait_type": "Loan Purpose", "value": "', profile.loanPurpose, '"}',
                '],',
                '"asset_breakdown": ', profile.assetBreakdown, ',',
                '"additional_info": "', profile.additionalInfo, '",',
                '"documents": ', documentsJson,
            '}'
        );
        
        return string(abi.encodePacked(
            "data:application/json;base64,",
            Base64.encode(json)
        ));
    }

    // Get all documents for a borrower
    function getDocuments(address borrower) external view returns (Document[] memory) {
        uint256 tokenId = _borrowerToToken[borrower];
        require(tokenId != 0, "Profile does not exist");
        return _profileInfo[tokenId].documents;
    }
    
    /**
     * @dev Gets the profile information for a specific borrower
     * @param borrower Address of the borrower
     * @return The complete UserInfo struct
     */
    function getBorrowerProfile(address borrower) external view returns (UserInfo memory) {
        uint256 tokenId = _borrowerToToken[borrower];
        require(tokenId != 0, "Profile does not exist");
        
        return _profileInfo[tokenId];
    }
    
    /**
     * @dev Gets the token ID for a borrower
     * @param borrower Address of the borrower
     * @return The token ID of the borrower's profile NFT
     */
    function getBorrowerTokenId(address borrower) external view returns (uint256) {
        return _borrowerToToken[borrower];
    }
    
    /**
     * @dev Gets the asset breakdown for a borrower
     * @param borrower Address of the borrower
     * @return The asset breakdown JSON string
     */
    function getBorrowerAssets(address borrower) external view returns (string memory) {
        uint256 tokenId = _borrowerToToken[borrower];
        require(tokenId != 0, "Profile does not exist");
        
        return _profileInfo[tokenId].assetBreakdown;
    }
    
    /**
     * @dev Checks if a borrower has a profile
     * @param borrower Address of the borrower
     * @return True if the borrower has a profile, false otherwise
     */
    function hasProfile(address borrower) external view returns (bool) {
        return _borrowerToToken[borrower] != 0;
    }
    
    /**
     * @dev Gets the total number of registered borrower profiles
     * @return The total number of profiles
     */
    function getTotalProfiles() external view returns (uint256) {
        return _tokenIds.current();
    }
}