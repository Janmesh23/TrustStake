// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "./ReputationToken.sol";
import "./interfaces/IHooks.sol";
// BorrowerProfile is not directly used here for loan logic, but its existence is a prerequisite
// for the admin to mint the RWA tokens that *are* used here as collateral.

contract RWALendingProtocol is Ownable, ReentrancyGuard {
    ReputationToken public immutable reputationToken;
    IHooks public socialReputationHook;
    IERC20 public immutable loanAsset; // e.g., USDC

    uint256 public constant BPS_DIVISOR = 10000; // For Basis Points calculations

    // Protocol parameters
    uint256 public baseCollateralizationRatioBps = 15000; // 150%
    uint256 public maxReputationDiscountBps = 3000;      // Max 30% discount
    uint256 public reputationToDiscountRatio = 100;      // 100 DSR for 1 BPS discount
    uint256 public stakerInterestShareBps = 1500;        // 15% of interest
    uint256 public protocolFeeBps = 500;                 // 5% of interest
    uint256 public loanInterestRateBps = 500;            // 5% APR (annualized)
    uint256 public liquidationThresholdBps = 11000;      // Liquidatable at 110% LTV
    // uint256 public liquidationPenaltyBps = 500;          // 5% bonus to liquidator (taken from collateral value)
                                                        // For ERC721, penalty is harder, liquidator gets the whole NFT.

    enum TokenType { ERC20, ERC721 }

    struct CollateralTypeInfo {
        bool isSupported;
        uint256 pricePerTokenOrNFT; // Price for one whole ERC20 token (smallest unit) or one whole ERC721 NFT
        uint8 decimals;             // Only relevant for ERC20, set to 0 for ERC721
        TokenType tokenType;
    }
    mapping(address => CollateralTypeInfo) public collateralInfo;

    struct Loan {
        uint256 id;
        address borrower;
        address collateralTokenAddress;
        uint256 collateralAmountOrId; // Amount for ERC20, Token ID for ERC721
        TokenType collateralType;
        uint256 loanAmount;
        uint256 startTime;
        bool isActive;
        mapping(address => uint256) vouches; // staker => reputationAmountVouched
        address[] stakers; // Keep track of stakers for payouts/slashing
        uint256 totalVouchedReputation;
    }
    mapping(uint256 => Loan) public loans;
    uint256 public nextLoanId = 1;

    mapping(address => mapping(uint256 => uint256)) public stakerVouchesOnLoan; // Staker => LoanID => Vouched Amount

    event CollateralTypeSet(address indexed token, bool isSupported, uint256 price, uint8 decimals, TokenType tokenType);
    event LoanCreated(uint256 indexed loanId, address indexed borrower, uint256 loanAmount, address collateralToken, uint256 collateralAmountOrId);
    event LoanRepaid(uint256 indexed loanId, address indexed borrower, uint256 interestPaid, uint256 protocolFee);
    event LoanLiquidated(uint256 indexed loanId, address indexed liquidator, address collateralToken, uint256 collateralAmountOrId);
    event VouchAdded(uint256 indexed loanId, address indexed staker, address indexed borrower, uint256 reputationAmount);
    event StakerRewardsClaimed(uint256 indexed loanId, address indexed staker, uint256 dsrReturned, uint256 dsrBonus, uint256 loanAssetReward);
    event ReputationSlashed(uint256 indexed loanId, address indexed staker, uint256 slashedDsrAmount);

    // Store claimable interest for stakers per loan
    mapping(uint256 => uint256) public claimableLoanAssetInterestForStakers;


    constructor(
        address _reputationTokenAddress,
        address _loanAssetAddress,
        address _hookAddress
    ) Ownable(msg.sender) {
        reputationToken = ReputationToken(_reputationTokenAddress);
        loanAsset = IERC20(_loanAssetAddress);
        socialReputationHook = IHooks(_hookAddress);
        // Ensure hook's setLendingProtocolAddress is called by its owner post-deployment
    }

    // --- Admin Functions ---
    function setCollateralType(address _rwaToken, bool _isSupported, uint256 _price, uint8 _decimals, TokenType _tokenType) external onlyOwner {
        require(_tokenType == TokenType.ERC20 || _tokenType == TokenType.ERC721, "Invalid token type");
        if (_tokenType == TokenType.ERC721) {
            require(_decimals == 0, "ERC721 decimals must be 0");
        }
        collateralInfo[_rwaToken] = CollateralTypeInfo(_isSupported, _price, _decimals, _tokenType);
        emit CollateralTypeSet(_rwaToken, _isSupported, _price, _decimals, _tokenType);
    }
    // ... other setters for parameters ...

    // --- Value Calculation ---
    function _getCollateralValue(address _collateralTokenAddr, uint256 _collateralAmountOrId) internal view returns (uint256) {
        CollateralTypeInfo storage cInfo = collateralInfo[_collateralTokenAddr];
        require(cInfo.isSupported, "Collateral type not supported");

        if (cInfo.tokenType == TokenType.ERC20) {
            // Price is per smallest unit of ERC20, value = (Amount / 10^collateralDecimals) * pricePerToken
            // Assuming pricePerToken is already adjusted for loanAsset decimals
            // Example: if loan asset 6 dec, RWA 18 dec, price is for 1 RWA token in 10^-6 loanAsset units
            // Correct calculation: (amount * price) / 10^RWA_decimals
            return (_collateralAmountOrId * cInfo.pricePerToken) / (10**cInfo.decimals);
        } else { // ERC721
            // Price is for the single NFT
            return cInfo.pricePerToken;
        }
    }

    function getEffectiveCollateralizationRatioBps(uint256 _totalVouchedReputation) public view returns (uint256) {
        uint256 reputationDiscount = _totalVouchedReputation / reputationToDiscountRatio;
        reputationDiscount = reputationDiscount > maxReputationDiscountBps ? maxReputationDiscountBps : reputationDiscount;
        
        if (reputationDiscount >= baseCollateralizationRatioBps) return 1000; // Min 10% CR
        return baseCollateralizationRatioBps - reputationDiscount;
    }

    // --- Core Logic ---
    function createLoan(
        address _collateralTokenAddr,
        uint256 _collateralAmountOrId, // Amount for ERC20, Token ID for ERC721
        uint256 _loanAmount,
        address[] calldata _stakers,
        uint256[] calldata _stakerAmounts
    ) external nonReentrant {
        CollateralTypeInfo storage cInfo = collateralInfo[_collateralTokenAddr];
        require(cInfo.isSupported, "Collateral not supported");
        require(_loanAmount > 0, "Loan amount must be positive");
        if (cInfo.tokenType == TokenType.ERC20) require(_collateralAmountOrId > 0, "Collateral amount must be > 0");
        // For ERC721, _collateralAmountOrId is an ID, can be 0 if that's a valid ID, but usually starts from 1.
        // Let's assume ERC721 token IDs are non-zero.
        if (cInfo.tokenType == TokenType.ERC721) require(_collateralAmountOrId != 0, "ERC721 Token ID cannot be zero");


        require(_stakers.length == _stakerAmounts.length, "Staker array mismatch");

        uint256 collateralValue = _getCollateralValue(_collateralTokenAddr, _collateralAmountOrId);
        
        uint256 totalVouchedForThisLoan = 0;
        for (uint i = 0; i < _stakerAmounts.length; i++) {
            totalVouchedForThisLoan += _stakerAmounts[i];
        }

        uint256 effectiveCR_Bps = getEffectiveCollateralizationRatioBps(totalVouchedForThisLoan);
        uint256 requiredCollateralValue = (_loanAmount * effectiveCR_Bps) / BPS_DIVISOR;
        require(collateralValue >= requiredCollateralValue, "Insufficient collateral value");

        // Escrow collateral
        if (cInfo.tokenType == TokenType.ERC20) {
            IERC20(_collateralTokenAddr).transferFrom(msg.sender, address(this), _collateralAmountOrId);
        } else { // ERC721
            IERC721(_collateralTokenAddr).transferFrom(msg.sender, address(this), _collateralAmountOrId);
        }

        uint256 currentLoanId = nextLoanId;
        Loan storage newLoan = loans[currentLoanId];

        for (uint i = 0; i < _stakers.length; i++) {
            require(_stakerAmounts[i] > 0, "Staker amount must be > 0");
            // Staker must approve this contract for their DSR
            reputationToken.transferFrom(_stakers[i], address(this), _stakerAmounts[i]);
            stakerVouchesOnLoan[_stakers[i]][currentLoanId] = _stakerAmounts[i];
            newLoan.vouches[_stakers[i]] = _stakerAmounts[i];
            newLoan.stakers.push(_stakers[i]); // Store staker address
        }
        
        newLoan.id = currentLoanId;
        newLoan.borrower = msg.sender;
        newLoan.collateralTokenAddress = _collateralTokenAddr;
        newLoan.collateralAmountOrId = _collateralAmountOrId;
        newLoan.collateralType = cInfo.tokenType;
        newLoan.loanAmount = _loanAmount;
        newLoan.startTime = block.timestamp;
        newLoan.isActive = true;
        newLoan.totalVouchedReputation = totalVouchedForThisLoan;

        loanAsset.transfer(msg.sender, _loanAmount);
        
        // Small DSR mint to borrower for taking a loan
        // uint256 dsrToMintBorrower = (_loanAmount / 1000) * (10**reputationToken.decimals()) / (10**loanAsset.decimals());
        // if (dsrToMintBorrower > 0) reputationToken.mint(msg.sender, dsrToMintBorrower);


        emit LoanCreated(currentLoanId, msg.sender, _loanAmount, _collateralTokenAddr, _collateralAmountOrId);
        socialReputationHook.afterLoanCreated(msg.sender, currentLoanId, _loanAmount, _collateralTokenAddr, _collateralAmountOrId);
        
        nextLoanId++;
    }

    function repayLoan(uint256 _loanId) external nonReentrant {
        Loan storage loan = loans[_loanId];
        require(loan.isActive, "Loan not active");
        require(loan.borrower == msg.sender, "Not borrower");

        uint256 timeElapsed = block.timestamp - loan.startTime;
        uint256 interest = (loan.loanAmount * loanInterestRateBps * timeElapsed) / (365 days * BPS_DIVISOR);
        uint256 totalPayment = loan.loanAmount + interest;

        loanAsset.transferFrom(msg.sender, address(this), totalPayment);

        uint256 protocolCut = (interest * protocolFeeBps) / BPS_DIVISOR;
        uint256 interestForStakersPool = (interest * stakerInterestShareBps) / BPS_DIVISOR;
        
        if (protocolCut > 0) {
            loanAsset.transfer(owner(), protocolCut); // Or treasury
        }
        if (interestForStakersPool > 0) {
            claimableLoanAssetInterestForStakers[_loanId] = interestForStakersPool;
            // Stakers will claim their proportional share via claimStakerRewards
        }

        // Return collateral
        if (loan.collateralType == TokenType.ERC20) {
            IERC20(loan.collateralTokenAddress).transfer(loan.borrower, loan.collateralAmountOrId);
        } else { // ERC721
            IERC721(loan.collateralTokenAddress).transfer(loan.borrower, loan.collateralAmountOrId);
        }

        // DSR for borrower (successful repayment)
        // uint256 dsrRepaymentBonus = (interest / 100) * (10**reputationToken.decimals()) / (10**loanAsset.decimals());
        // if (dsrRepaymentBonus > 0) reputationToken.mint(msg.sender, dsrRepaymentBonus);

        loan.isActive = false;
        emit LoanRepaid(_loanId, msg.sender, interest, protocolCut);
        socialReputationHook.afterLoanRepaid(msg.sender, _loanId, interest);
    }

    function claimStakerRewards(uint256 _loanId) external nonReentrant {
        Loan storage loan = loans[_loanId];
        require(!loan.isActive, "Loan must be settled (repaid/liquidated)"); // Ensure loan is finished
        require(stakerVouchesOnLoan[msg.sender][_loanId] > 0, "Not a staker or already claimed/slashed");

        uint256 vouchedAmountByStaker = stakerVouchesOnLoan[msg.sender][_loanId];
        
        // Return original DSR stake (if not slashed)
        reputationToken.transfer(msg.sender, vouchedAmountByStaker); // Transfer DSR from contract back to staker

        uint256 dsrBonus = 0;
        uint256 loanAssetRewardForStaker = 0;

        // Check if loan was repaid (not liquidated) to give rewards
        // A loan is repaid if claimableLoanAssetInterestForStakers[_loanId] > 0 (or other flags)
        bool loanSuccessfullyRepaid = claimableLoanAssetInterestForStakers[_loanId] > 0; // Simplified check

        if (loanSuccessfullyRepaid) {
            // DSR Bonus for successful vouching
            dsrBonus = (vouchedAmountByStaker * 5) / 100; // e.g., 5% of their stake
            if (dsrBonus > 0) reputationToken.mint(msg.sender, dsrBonus);

            // Loan Asset (e.g., USDC) reward distribution
            if (loan.totalVouchedReputation > 0) { // Avoid division by zero
                 uint256 totalInterestForStakersPool = claimableLoanAssetInterestForStakers[_loanId];
                 loanAssetRewardForStaker = (totalInterestForStakersPool * vouchedAmountByStaker) / loan.totalVouchedReputation;
                 if (loanAssetRewardForStaker > 0) {
                    loanAsset.transfer(msg.sender, loanAssetRewardForStaker);
                 }
            }
        }
        
        stakerVouchesOnLoan[msg.sender][_loanId] = 0; // Mark as processed for this staker
        // Note: If loan was liquidated, vouched DSR is slashed (not returned here, handled in liquidate)

        emit StakerRewardsClaimed(_loanId, msg.sender, vouchedAmountByStaker, dsrBonus, loanAssetRewardForStaker);
    }


    function liquidateLoan(uint256 _loanId) external nonReentrant {
        Loan storage loan = loans[_loanId];
        require(loan.isActive, "Loan not active");

        uint256 collateralValue = _getCollateralValue(loan.collateralTokenAddress, loan.collateralAmountOrId);
        uint256 minCollateralValueForSafety = (loan.loanAmount * liquidationThresholdBps) / BPS_DIVISOR;
        require(collateralValue < minCollateralValueForSafety, "Loan not eligible for liquidation");

        // Liquidator pays the outstanding loan amount
        loanAsset.transferFrom(msg.sender, address(this), loan.loanAmount);
        
        // Liquidator receives the collateral
        if (loan.collateralType == TokenType.ERC20) {
            IERC20(loan.collateralTokenAddress).transfer(msg.sender, loan.collateralAmountOrId);
        } else { // ERC721
            IERC721(loan.collateralTokenAddress).transfer(msg.sender, loan.collateralAmountOrId);
        }

        // Slash stakers' DSR - the DSR is held by this contract
        for (uint i = 0; i < loan.stakers.length; i++) {
            address staker = loan.stakers[i];
            uint256 stakedAmount = loan.vouches[staker];
            if (stakedAmount > 0) {
                // The DSR tokens were transferred to this contract. Now burn them.
                reputationToken.burn(address(this), stakedAmount);
                stakerVouchesOnLoan[staker][_loanId] = 0; // Mark as slashed, no claim possible
                emit ReputationSlashed(_loanId, staker, stakedAmount);
            }
        }

        loan.isActive = false;
        emit LoanLiquidated(_loanId, msg.sender, loan.collateralTokenAddress, loan.collateralAmountOrId);
        socialReputationHook.afterLoanLiquidated(msg.sender, _loanId);
    }
}