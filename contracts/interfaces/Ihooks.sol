// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

interface IHooks {
    function getHookPermissions() external pure returns (uint16);

    function afterLoanCreated(
        address borrower,
        uint256 loanId,
        uint256 loanAmount,
        address collateralToken,
        uint256 collateralAmountOrId // Can be amount for ERC20 or tokenId for ERC721
    ) external returns (bytes4);

    function afterLoanRepaid(
        address borrower,
        uint256 loanId,
        uint256 interestPaid
    ) external returns (bytes4);

    function afterLoanLiquidated(
        address liquidator,
        uint256 loanId
    ) external returns (bytes4);
}