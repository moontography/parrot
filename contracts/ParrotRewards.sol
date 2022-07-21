// SPDX-License-Identifier: MIT
pragma solidity ^0.8.9;

import '@openzeppelin/contracts/access/Ownable.sol';
import '@openzeppelin/contracts/interfaces/IERC20.sol';
import './interfaces/IParrotRewards.sol';

contract ParrotRewards is IParrotRewards, Ownable {
  struct Reward {
    uint256 totalExcluded; // excluded reward
    uint256 totalRealised;
    uint256 lastClaim; // used for boosting logic
  }

  struct Share {
    uint256 amount; // used to keep track of rewards owed to users and will change if user is/is not excluded
    uint256 amountActual; // number of user's tokens in the contract, will only change when tokens change hands
    uint256 lockedTime;
    bool isExcluded;
  }

  uint256 public timeLock = 30 days;
  address public shareholderToken;
  uint256 public totalLockedUsers;
  uint256 public totalSharesDeposited; // will be all tokens locked, regardless of reward exclusion status
  uint256 public totalSharesForRewards; // will be all tokens eligible to receive rewards (i.e. checks exclusion)

  // amount of shares a user has
  mapping(address => Share) shares;
  // reward information per user
  mapping(address => Reward) public rewards;

  uint256 public totalRewards;
  uint256 public totalDistributed;
  uint256 public rewardsPerShare;

  uint256 private constant ACC_FACTOR = 10**36;

  event ClaimReward(address wallet);
  event DistributeReward(address indexed wallet, address payable receiver);
  event DepositRewards(address indexed wallet, uint256 amountETH);

  modifier onlyOrOwnerToken() {
    require(
      msg.sender == owner() || msg.sender == shareholderToken,
      'must be owner or token contract'
    );
    _;
  }

  constructor(address _shareholderToken) {
    shareholderToken = _shareholderToken;
  }

  function lock(uint256 _amount) external {
    address shareholder = msg.sender;
    IERC20(shareholderToken).transferFrom(shareholder, address(this), _amount);
    _addShares(shareholder, _amount);
  }

  function unlock(uint256 _amount) external {
    address shareholder = msg.sender;
    require(
      shares[shareholder].isExcluded ||
        block.timestamp >= shares[shareholder].lockedTime + timeLock,
      'must wait the time lock before unstaking'
    );
    _amount = _amount == 0 ? shares[shareholder].amountActual : _amount;
    require(_amount > 0, 'need tokens to unlock');
    require(
      _amount <= shares[shareholder].amountActual,
      'cannot unlock more than you have locked'
    );
    IERC20(shareholderToken).transferFrom(address(this), shareholder, _amount);
    _removeShares(shareholder, _amount);
  }

  function _addShares(address shareholder, uint256 amount) private {
    _distributeReward(shareholder);

    uint256 sharesBefore = shares[shareholder].amount;
    totalSharesDeposited += amount;
    totalSharesForRewards += shares[shareholder].isExcluded ? 0 : amount;
    shares[shareholder].amount += shares[shareholder].isExcluded ? 0 : amount;
    shares[shareholder].amountActual += amount;
    shares[shareholder].lockedTime = block.timestamp;
    if (sharesBefore == 0 && shares[shareholder].amount > 0) {
      totalLockedUsers++;
    }
    rewards[shareholder].totalExcluded = getCumulativeRewards(
      shares[shareholder].amountActual
    );
  }

  function _removeShares(address shareholder, uint256 amount) private {
    amount = amount == 0 ? shares[shareholder].amount : amount;
    require(
      shares[shareholder].amountActual > 0 &&
        amount <= shares[shareholder].amountActual,
      'you can only unlock if you have some lockd'
    );
    _distributeReward(shareholder);

    totalSharesDeposited -= amount;
    totalSharesForRewards -= shares[shareholder].isExcluded ? 0 : amount;
    shares[shareholder].amount -= shares[shareholder].isExcluded ? 0 : amount;
    shares[shareholder].amountActual -= amount;
    rewards[shareholder].totalExcluded = getCumulativeRewards(
      shares[shareholder].amountActual
    );
  }

  function depositRewards() external payable override {
    require(msg.value > 0, 'value must be greater than 0');
    require(
      totalSharesForRewards > 0,
      'must be shares deposited to be rewarded rewards'
    );

    uint256 amount = msg.value;
    totalRewards += amount;
    rewardsPerShare += (ACC_FACTOR * amount) / totalSharesForRewards;
    emit DepositRewards(msg.sender, msg.value);
  }

  function _distributeReward(address shareholder) internal {
    if (shares[shareholder].amount == 0) {
      return;
    }

    uint256 amount = getUnpaid(shareholder);

    rewards[shareholder].totalRealised += amount;
    rewards[shareholder].totalExcluded = getCumulativeRewards(
      shares[shareholder].amountActual
    );
    rewards[shareholder].lastClaim = block.timestamp;

    if (amount > 0) {
      address payable receiver = payable(shareholder);
      totalDistributed += amount;
      uint256 balanceBefore = address(this).balance;
      receiver.call{ value: amount }('');
      require(address(this).balance >= balanceBefore - amount);
      emit DistributeReward(shareholder, receiver);
    }
  }

  function claimReward() external override {
    _distributeReward(msg.sender);
    emit ClaimReward(msg.sender);
  }

  // returns the unpaid rewards
  function getUnpaid(address shareholder) public view returns (uint256) {
    if (shares[shareholder].amount == 0) {
      return 0;
    }

    uint256 earnedRewards = getCumulativeRewards(
      shares[shareholder].amountActual
    );
    uint256 rewardsExcluded = rewards[shareholder].totalExcluded;
    if (earnedRewards <= rewardsExcluded) {
      return 0;
    }

    return earnedRewards - rewardsExcluded;
  }

  function getCumulativeRewards(uint256 share) internal view returns (uint256) {
    return (share * rewardsPerShare) / ACC_FACTOR;
  }

  function getRewardsShares(address user)
    external
    view
    override
    returns (uint256)
  {
    return shares[user].amount;
  }

  function getLockedShares(address user)
    external
    view
    override
    returns (uint256)
  {
    return shares[user].amountActual;
  }

  function setIsRewardsExcluded(address shareholder, bool isExcluded)
    external
    onlyOwner
  {
    require(
      shares[shareholder].isExcluded != isExcluded,
      'can only change exclusion status from what it is not already'
    );
    shares[shareholder].isExcluded = isExcluded;

    // distribute any outstanding rewards for the excluded user and
    // adjust the total rewards shares for the next reward deposit
    // to be accurately calculated
    if (isExcluded) {
      _distributeReward(shareholder);
      totalSharesForRewards -= shares[shareholder].amountActual;
      totalLockedUsers--;
    } else {
      totalSharesForRewards += shares[shareholder].amountActual;
      totalLockedUsers++;
    }
    shares[shareholder].amount = isExcluded
      ? 0
      : shares[shareholder].amountActual;
  }

  function setTimeLock(uint256 numSec) external onlyOwner {
    require(numSec <= 365 days, 'must be less than a year');
    timeLock = numSec;
  }
}
