// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import "./interfaces/IHooks.sol";
import "./ReputationToken.sol"; // For potential reputation adjustments

// This contract is called by RWALendingProtocol at specific points.
// It's a "hook" in the sense that it reacts to lending protocol actions.
contract SocialReputationHook is IHooks {
    uint16 internal constant AFTER_LOAN_CREATED_FLAG = 1;
    uint16 internal constant AFTER_LOAN_REPAID_FLAG = 2;
    uint16 internal constant AFTER_LOAN_LIQUIDATED_FLAG = 4;

    ReputationToken public immutable reputationToken;
    address public lendingProtocolAddress; // Set by owner or lending protocol
    address public owner;

    event HookLoanCreated(address indexed borrower, uint256 indexed loanId, uint256 loanAmount);
    event HookLoanRepaid(address indexed borrower, uint256 indexed loanId, uint256 interestPaid);
    event HookLoanLiquidated(address indexed liquidator, uint256 indexed loanId);

    modifier onlyLendingProtocol() {
        require(msg.sender == lendingProtocolAddress, "Hook: Caller is not the lending protocol");
        _;
    }
    
    modifier onlyOwner() {
        require(msg.sender == owner, "Hook: Caller is not the owner");
        _;
    }

    constructor(address _reputationTokenAddress) {
        reputationToken = ReputationToken(_reputationTokenAddress);
        owner = msg.sender;
    }

    function setLendingProtocolAddress(address _protocolAddress) external onlyOwner {
        require(lendingProtocolAddress == address(0) || msg.sender == owner, "Hook: Already set or not owner");
        lendingProtocolAddress = _protocolAddress;
    }

    function getHookPermissions() external pure override returns (uint16) {
        return AFTER_LOAN_CREATED_FLAG | AFTER_LOAN_REPAID_FLAG | AFTER_LOAN_LIQUIDATED_FLAG;
    }

    function afterLoanCreated(
        address borrower,
        uint256 loanId,
        uint256 loanAmount,
        address collateralToken, // Added to match interface
        uint256 collateralAmountOrId // Added to match interface
    ) external override onlyLendingProtocol returns (bytes4) {
        // Example: Mint a very small amount of reputation for initiating a loan
        // This logic can be expanded (e.g., based on loanAmount or collateral type)
        // reputationToken.mint(borrower, (1 * 10**reputationToken.decimals()) / 100 ); // 0.01 DSR
        emit HookLoanCreated(borrower, loanId, loanAmount);
        return SocialReputationHook.afterLoanCreated.selector;
    }

    function afterLoanRepaid(
        address borrower,
        uint256 loanId,
        uint256 interestPaid
    ) external override onlyLendingProtocol returns (bytes4) {
        // Example: Mint reputation for borrower based on interest paid or loan duration
        // uint256 rewardAmount = (interestPaid * 10**reputationToken.decimals()) / (100 * 10**ReputationToken(reputationToken).decimals()); // e.g. 1% of interest value
        // reputationToken.mint(borrower, rewardAmount);
        emit HookLoanRepaid(borrower, loanId, interestPaid);
        return SocialReputationHook.afterLoanRepaid.selector;
    }

    function afterLoanLiquidated(
        address liquidator,
        uint256 loanId
    ) external override onlyLendingProtocol returns (bytes4) {
        // Example: Could penalize borrower's reputation (burn DSR if this hook has mint/burn rights)
        // Or reward liquidator with some DSR
        emit HookLoanLiquidated(liquidator, loanId);
        return SocialReputationHook.afterLoanLiquidated.selector;
    }
}