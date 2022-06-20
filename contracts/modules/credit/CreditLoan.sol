import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import { BaseLoan } from "./BaseLoan.sol";
import { LoanLib } from "../../utils/LoanLib.sol";
import { MutualUpgrade } from "../../utils/MutualUpgrade.sol";

import { ICreditLoan } from "../../interfaces/ICreditLoan.sol";
import { InterestRateCredit } from "../interest-rate/InterestRateCredit.sol";

contract CreditLoan is ICreditLoan, BaseLoan, MutualUpgrade {
  
  InterestRateCredit immutable public interestRate;

  mapping(bytes32 => DebtPosition) public debts; // positionId -> DebtPosition

  bytes32[] public positionIds; // all active positions

  uint256 immutable public deadline;

  /**
   * @dev - Loan borrower and proposed lender agree on terms
            and add it to potential options for borrower to drawdown on
            Lender and borrower must both call function for MutualUpgrade to add debt position to Loan
   * @param oracle_ - price oracle to use for getting all token values
   * @param arbiter_ - neutral party with some special priviliges on behalf of borrower and lender
   * @param borrower_ - the debitor for all debt positions in this contract
   * @param ttl_ - time to live for line of credit contract across all lenders
  */
  constructor(
    address oracle_,
    address arbiter_,
    address borrower_,
    uint256 ttl_
  )
    BaseLoan(oracle_, arbiter_, borrower_)
  {
    interestRate = new InterestRateCredit();
    deadline = block.timestamp + ttl_;
  }


  function _healthcheck() internal virtual override returns(LoanLib.STATUS) {
    LoanLib.STATUS s = BaseLoan._healthcheck();
    if(s != LoanLib.STATUS.ACTIVE) {
      return s;
    }

    if(block.timestamp >= deadline && principalUsd > 0) {
      return LoanLib.STATUS.LIQUIDATABLE;
    }
  }

/**
  @dev Returns total debt obligation of borrower.
       Aggregated across all lenders.
       Denominated in USD 1e8.
  */
  function getOutstandingDebt() override external returns(uint256) {
    (uint p, uint i) = _updateOutstandingDebt();
    return p + i;
  }

  function _updateOutstandingDebt()
    internal
    view
    returns (uint principal, uint interest)
  {
    uint len = positionIds.length;
    if(len == 0) return (0,0);

    bytes32 id;
    DebtPosition memory debt;
    while(len > 0) {
      // fix off by 1 error on initial run 
      // sets to 0 and  prevents final run allowing unchecked
      unchecked { --len; }
      
      debt = debts[positionIds[len]];

      principal += LoanLib.getValuation(
        oracle,
        debt.token,
        debt.principal,
        debt.decimals
      );
      interest += LoanLib.getValuation(
        oracle,
        debt.token,
        debt.interestAccrued,
        debt.decimals
      );
    }
    principalUsd = principal;
    interestUsd = interest;
  }


  /**
    @notice see _accrueInterest()
  */
  function accrueInterest() override external returns(uint256 accruedValue) {
    uint256 len = positionIds.length;

    for(uint256 i = 0; i < len; i++) {
      (, uint256 accruedTokenValue) = _accrueInterest(positionIds[len]);
      accruedValue += accruedTokenValue;
    }

  }

  /**
   * @dev - Loan borrower and proposed lender agree on terms
            and add it to potential options for borrower to drawdown on
            Lender and borrower must both call function for MutualUpgrade to add debt position to Loan
   * @param amount - amount of `token` to initially deposit
   * @param token - the token to be lent out
   * @param lender - address that will manage debt position 
  */
  function addDebtPosition(
    uint256 amount,
    address token,
    address lender
  )
    isActive
    mutualUpgrade(lender, borrower) 
    virtual
    override
    external
    returns(bool)
  {
    bool success = IERC20(token).transferFrom(
      lender,
      address(this),
      amount
    );
    require(success, 'Loan: no tokens to lend');

    bytes32 id = _createDebtPosition(lender, token, amount, 0);

    positionIds.push(id);

    return true;
  }

    ///////////////
  // REPAYMENT //
  ///////////////

   /**
   * @dev - Transfers enough tokens to repay entire debt position from `borrower` to Loan contract.
            Only callable by borrower bc it closes position.
   * @param positionId -the debt position to pay down debt on and close
  */
  function depositAndClose(bytes32 positionId)
    onlyBorrower
    override external
    returns(bool)
  {
    _accrueInterest(positionId);

    uint256 totalOwed = debts[positionId].principal + debts[positionId].interestAccrued;

    // borrower deposits remaining balance not already repaid and held in contract
    bool success = IERC20(debts[positionId].token).transferFrom(
      msg.sender,
      address(this),
      totalOwed
    );
    require(success, 'Loan: deposit failed');
    // clear the debt 
    _repay(positionId, totalOwed);

    require(_close(positionId));
    return true;
  }

  /**
   * @dev - Transfers token used in debt position from msg.sender to Loan contract.
   * @notice - see _repay() for more details
   * @param positionId -the debt position to pay down debt on
   * @param amount - amount of `token` in `positionId` to pay back
  */

  function depositAndRepay(
    bytes32 positionId,
    uint256 amount
  )
    override external
    returns(bool)
  {
    _accrueInterest(positionId);

    require(amount <= debts[positionId].principal + debts[positionId].interestAccrued);
    
    bool success = IERC20(debts[positionId].token).transferFrom(
      msg.sender,
      address(this),
      amount
    );
    require(success, 'Loan: failed repayment');

    _repay(positionId, amount);
    return true;
  }



  ////////////////////
  // FUND TRANSFERS //
  ////////////////////


  /**
   * @dev - Transfers tokens from Loan to lender.
   *        Only allowed to withdraw tokens not already lent out (prevents bank run)
   * @param positionId -the debt position to pay down debt on and close
   * @param amount - amount of tokens lnder would like to withdraw (withdrawn amount may be lower)
  */
  function borrow(bytes32 positionId, uint256 amount)
    isActive
    onlyBorrower
    override external
    returns(bool)
  {
    _accrueInterest(positionId);
    DebtPosition memory debt = debts[positionId];
    
    require(amount <= debt.deposit - debt.principal, 'Loan: no liquidity');

    debt.principal += amount;

    principalUsd += LoanLib.getValuation(oracle, debt.token, amount, debt.decimals);

    debts[positionId] = debt;

    require(
      _updateLoanStatus(_healthcheck()) == LoanLib.STATUS.ACTIVE,
      'Loan: cant borrow'
    );

    bool success = IERC20(debt.token).transfer(
      borrower,
      amount
    );
    require(success, 'Loan: borrow failed');

    emit Borrow(positionId, amount);

    return true;
  }



  /**
   * @dev - Transfers tokens from Loan to lender.
   *        Only allowed to withdraw tokens not already lent out (prevents bank run)
   * @param positionId -the debt position to pay down debt on and close
   * @param amount - amount of tokens lnder would like to withdraw (withdrawn amount may be lower)
  */
  function withdraw(bytes32 positionId, uint256 amount) override external returns(bool) {
    require(msg.sender == debts[positionId].lender, "Loan: only lender can withdraw");
    
    _accrueInterest(positionId);
    DebtPosition memory debt = debts[positionId];
    
    require(amount <=  debt.deposit + debt.interestRepaid - debt.principal, 'Loan: no liquidity');

    if(amount > debt.interestRepaid) {
      debt.deposit -= amount - debt.interestRepaid;
      debt.interestRepaid = 0;
    } else {
      debt.interestRepaid -= amount;
    }

    bool success = IERC20(debt.token).transfer(
      debt.lender,
      amount
    );
    require(success, 'Loan: withdraw failed');

    debts[positionId] = debt;

    emit Withdraw(positionId, amount);

    return true;
  }


  /**
   * @dev - Deletes debt position preventing any more borrowing.
   *      - Only callable by borrower or lender for debt position
   *      - Requires that the debt has already been paid off
   * @param positionId -the debt position to close
  */
  function close(bytes32 positionId) override external returns(bool) {
    DebtPosition memory debt = debts[positionId];
    require(
      msg.sender == debt.lender ||
      msg.sender == borrower,
      "Loan: msg.sender must be the lender or borrower"
    );
    
    // return the lender's deposit
    if(debt.deposit > 0) {
      require(IERC20(debt.token).transfer(debt.lender, debt.deposit + debt.interestRepaid));
    }

    require(_close(positionId));
    
    return true;
  }


  //////
  //  Internal  funcs 
  //////


    function _createDebtPosition(
    address lender,
    address token,
    uint256 amount,
    uint256 initialPrincipal
  )
    internal
    returns(bytes32 positionId)
  {
    require(oracle.getLatestAnswer(token) > 0, "Loan: token cannot be valued");
    positionId = LoanLib.computePositionId(address(this), lender, token);
    
    // MUST not double add position. otherwise we can not _close()
    require(debts[positionId].lender == address(0), 'Loan: position exists');

    (bool passed, bytes memory result) = token.call(abi.encodeWithSignature("decimals()"));
    uint8 decimals = !passed ? 18 : abi.decode(result, (uint8));

    debts[positionId] = DebtPosition({
      lender: lender,
      token: token,
      decimals: decimals,
      deposit: amount,
      principal: initialPrincipal,
      interestAccrued: 0,
      interestRepaid: 0
    });

    emit AddDebtPosition(lender, token, amount, 0);

    return positionId;
  }


   /**
   * @dev - Reduces `principal` and/or `interestAccrued` on debt position, increases lender's `deposit`.
            Reduces global USD principal and interestUsd values.
            Expects checks for conditions of repaying and param sanitizing before calling
            e.g. early repayment of principal, tokens have actually been paid by borrower, etc.
   * @param positionId - debt position struct with all data pertaining to loan
   * @param amount - amount of token being repaid on debt position
  */
  function _repay(
    bytes32 positionId,
    uint256 amount
  )
    internal
    returns(bool)
  {
    DebtPosition memory debt = debts[positionId];
    
    uint256 price = _getTokenPrice(debt.token);

    if(amount <= debt.interestAccrued) {
      debt.interestAccrued -= amount;
      interestUsd -= price * amount / (1 * 10 ** debt.decimals);

      debt.interestRepaid += amount;
      emit RepayInterest(positionId, amount);
    } else {
      uint256 principalPayment = amount - debt.interestAccrued;

      emit RepayPrincipal(positionId, principalPayment);
      emit RepayInterest(positionId, debt.interestAccrued);

      // update global debt denominated in usd
      principalUsd -= price * principalPayment / (1 * 10 ** debt.decimals);
      interestUsd -= price * debt.interestAccrued / (1 * 10 ** debt.decimals);

      // update individual debt position denominated in token
      debt.principal -= principalPayment;
      debt.interestRepaid += debt.interestAccrued;
      debt.interestAccrued = 0;
    }

    debts[positionId] = debt;

    return true;
  }


  /**
   * @dev - Loops over all debt positions, calls InterestRate module with position data,
            then updates `interestAccrued` on position with returned data.
            Also updates global USD values for `interestUsd`.
            Can only be called when loan is not in distress
  */
  function _accrueInterest(bytes32 positionId)
    internal
    returns (uint256 accruedToken, uint256 accruedValue)
  {
    DebtPosition memory debt = debts[positionId];
    // get token demoninated interest accrued
    accruedToken = interestRate.accrueInterest(
      positionId,
      debt.principal,
      debt.deposit
    );

    // update debts balance
    debt.interestAccrued += accruedToken;

    // get USD value of interest accrued
    accruedValue = LoanLib.getValuation(oracle, debt.token, accruedToken, debt.decimals);
    interestUsd += accruedValue;

    emit InterestAccrued(positionId, accruedToken, accruedValue);

    debts[positionId] = debt; // save updates to intterestAccrued

    return (accruedToken, accruedValue);
  }

  /**
   * @notice - checks that debt is fully repaid and remvoes from available lines of credit.
   * @dev deletes Debt storage. Store any data u might need later in call before _close()
  */
  function _close(bytes32 positionId) virtual internal returns(bool) {
    require(
      debts[positionId].principal + debts[positionId].interestAccrued == 0,
      'Loan: close failed. debt owed'
    );

    delete debts[positionId]; // yay gas refunds!!!

    // remove from active list
    positionIds = LoanLib.removePosition(positionIds, positionId);

    // brick loan contract if all positions closed
    if(positionIds.length == 0) {
      loanStatus = LoanLib.STATUS.REPAID;
    }

    emit CloseDebtPosition(positionId);    

    return true;
  }
}
