
pragma solidity ^0.8.9;

import { BaseLoan } from "./BaseLoan.sol";
import { LoanLib } from "../../utils/LoanLib.sol";
import { SpigotController } from "../spigot/Spigot.sol";
import { ISpigotedLoan } from "../../interfaces/ISpigotedLoan.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

abstract contract SpigotedLoan is BaseLoan, ISpigotedLoan {

  SpigotController immutable public spigot;

  // 0x exchange to trade spigot revenue for debt tokens for
  address immutable public swapTarget;

  // amount of revenue to take from spigot if loan is healthy
  uint8 immutable public defaultRevenueSplit;

  // max revenue to take from spigot if loan is in distress
  uint8 constant MAX_SPLIT =  100;

  // debt tokens we bought from revenue but didn't use to repay loan
  // needed because Revolver might have same token held in contract as being bought/sold
  mapping(address => uint256) unusedTokens;


    /**
   * @dev - BaseLoan contract with additional functionality for integrating with Spigot and borrower revenue streams to repay loans
   * @param oracle_ - price oracle to use for getting all token values
   * @param arbiter_ - neutral party with some special priviliges on behalf of borrower and lender
   * @param borrower_ - the debitor for all debt positions in this contract
   * @param interestRateModel_ - contract calculating lender interest from debt position values
  */
  constructor(
    address oracle_,
    address arbiter_,
    address borrower_,
    address interestRateModel_,
    address swapTarget_,
    uint8 defaultRevenueSplit_
  )
    BaseLoan(oracle_, arbiter_, borrower_, interestRateModel_)
  {
    // empty arrays to init spigot
    address[] memory revContracts;
    SpigotController.SpigotSettings[] memory settings;
    bytes4[] memory whitelistedFuncs;
    
    spigot = new SpigotController(
      address(this),
      borrower,
      borrower,
      revContracts,
      settings,
      whitelistedFuncs
    );
    
    defaultRevenueSplit = defaultRevenueSplit_;

    swapTarget = swapTarget_;

    loanStatus = LoanLib.STATUS.INITIALIZED;
  }

  function updateOwnerSplit(address revenueContract) external {
    ( , uint8 split, , bytes4 transferFunc) = spigot.getSetting(revenueContract);
    
    require(transferFunc != bytes4(0), "SpgtLoan: no spigot");

    if(loanStatus == LoanLib.STATUS.ACTIVE && split != defaultRevenueSplit) {
      // if loan is healthy set split to default take rate
      spigot.updateOwnerSplit(revenueContract, defaultRevenueSplit);
    } else if (
      split != MAX_SPLIT && 
      (loanStatus == LoanLib.STATUS.DELINQUENT || loanStatus == LoanLib.STATUS.LIQUIDATABLE)
    ) {
      // if loan is in distress take all revenue to repay loan
      spigot.updateOwnerSplit(revenueContract, MAX_SPLIT);
    }
  }

 /**
   * @dev - Claims revenue tokens from Spigot attached to borrowers revenue generating tokens
            and sells them via 0x protocol to repay debts
            Only callable by borrower for security pasing arbitrary data in contract call
            and they are most incentivized to get best price on assets being sold.
   * @notice see _repay() for more details
   * @param positionId -the debt position to pay down debt on
   * @param claimToken - The revenue token escrowed by Spigot to claim and use to repay debt
   * @param zeroExTradeData - data generated by 0x API to trade `claimToken` against their exchange contract
  */
  function claimAndRepay(
    bytes32 positionId,
    address claimToken,
    bytes calldata zeroExTradeData
  )
    validPositionId(positionId)
    external
    returns(bool)
  {
    require(msg.sender == borrower || msg.sender == arbiter);
    _accrueInterest(positionId);

    address targetToken = debts[positionId].token;

    uint256 tokensBought = _claimAndTrade(
      claimToken,
      targetToken,
      zeroExTradeData
    );

    uint256 amountToRepay = _getMaxRepayableAmount(positionId, tokensBought + unusedTokens[targetToken]);
    
    if(amountToRepay > tokensBought) {
      // using bought + unused to repay loan
      unusedTokens[targetToken] -= amountToRepay - tokensBought;
    } else {
      //  high revenue and bought more than we need
      unusedTokens[targetToken] += tokensBought - amountToRepay;  
    }

    _repay(positionId, amountToRepay);

    emit RevenuePayment(
      claimToken,
      amountToRepay,
      _getTokenPrice(targetToken) * amountToRepay
    );

    return true;
  }

  function claimAndTrade(
    bytes32 positionId,
    address claimToken,
    bytes calldata zeroExTradeData
  )
    validPositionId(positionId)
    external
    returns(uint256 tokensBought)
  {
    require(msg.sender == borrower || msg.sender == arbiter);

    address targetToken = debts[positionId].token;
    uint256 tokensBought = _claimAndTrade(claimToken, targetToken, zeroExTradeData);
    
    // add bought tokens to unused balance
    unusedTokens[targetToken] += tokensBought;
  }


  function _claimAndTrade(
    address claimToken, 
    address targetToken, 
    bytes calldata zeroExTradeData
  )
    internal
    returns(uint256 tokensBought)
  {
    uint256 existingClaimTokens = IERC20(claimToken).balanceOf(address(this));
    uint256 existingTargetTokens = IERC20(targetToken).balanceOf(address(this));

    uint256 tokensClaimed = spigot.claimEscrow(claimToken);


    if(claimToken == address(0)) {
      // if claiming/trading eth send as msg.value to dex
      (bool success, ) = swapTarget.call{value: tokensClaimed}(zeroExTradeData);
      require(success, 'SpigotCnsm: trade failed');
    } else {
      IERC20(claimToken).approve(swapTarget, tokensClaimed);
      (bool success, ) = swapTarget.call(zeroExTradeData);
      require(success, 'SpigotCnsm: trade failed');
    }

    uint256 targetTokens = IERC20(targetToken).balanceOf(address(this));

    // ideally we could use oracle to calculate # of tokens to receive
    // but claimToken might not have oracle. targetToken must have oracle

    // underflow revert ensures we have more tokens than we started with
    uint256 tokensBought= targetTokens - existingTargetTokens;

    emit TradeSpigotRevenue(
      claimToken,
      tokensClaimed,
      targetToken,
      tokensBought
    );

    // update unused if we didnt sell all claimed tokens in trade
    // also underflow revert protection here
    unusedTokens[claimToken] += IERC20(claimToken).balanceOf(address(this)) - existingClaimTokens;
  }

  function releaseSpigot() external returns(bool) {
    if(loanStatus == LoanLib.STATUS.REPAID) {
      require(spigot.updateOwner(borrower), "SpigotCnsmr: cant release spigot");
    }
    // TODO ask fintards if should be LIQUIDATABLE
    if(loanStatus == LoanLib.STATUS.INSOLVENT) {
      require(spigot.updateOwner(arbiter), "SpigotCnsmr: cant release spigot");
    }
    return true;
  }

  function sweep(address token) external returns(uint256) {
    if(loanStatus == LoanLib.STATUS.REPAID) {
      bool success = IERC20(token).transfer(borrower, unusedTokens[token]);
      require(success);
    }
    if(loanStatus == LoanLib.STATUS.INSOLVENT) {
      bool success = IERC20(token).transfer(arbiter, unusedTokens[token]);
      require(success);
    }
  }
}
