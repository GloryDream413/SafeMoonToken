// SPDX-License-Identifier: MIT

pragma solidity 0.8.4;

import "./utils/SafeERC20.sol";
import "./utils/Ownable.sol";
import "./utils/ReentrancyGuard.sol";
import "./utils/Pausable.sol";
import "./utils/Referral.sol";

contract StakingVault is Ownable, ReentrancyGuard, Pausable {
    using SafeERC20 for IERC20;

    // Info of each user.
    struct UserInfo {
        uint256 amount;         // How many tokens the user has provided.
        uint256 rewardDebt;     // Reward debt. See explanation below.

        // We do some fancy math here. Basically, any point in time, the amount of Tokens
        // entitled to a user but is pending to be distributed is:
        //
        //   pending reward = (user.amount * pool.accTokenPerShare) - user.rewardDebt
        //
        // Whenever a user deposits or withdraws tokens to a pool. Here's what happens:
        //   1. The pool's `accTokenPerShare` (and `lastRewardBlock`) gets updated.
        //   2. User receives the pending reward sent to his/her address.
        //   3. User's `amount` gets updated.
        //   4. User's `rewardDebt` gets updated.
    }

    // Info of each pool.
    struct PoolInfo {
        uint256 amount;
        uint256 lastRewardBlock;  // Last block number that Tokens distribution occurs.
        uint256 accTokenPerShare;   // Accumulated Tokens per share, times 1e12. See below.
    }

    // The Main TOKEN
    IERC20 public immutable token;
    // Reward Treasury
    address public treasury;
    // Main tokens created per block.
    uint256 public _rewardPerBlock;

    // Info of pool.
    PoolInfo public poolInfo;
    // Info of each user that stakes tokens.
    mapping(address => UserInfo) public userInfo;

    // Referral contract address.
    Referral public immutable referral;
    // Referral commission rate in basis points.
    uint16 public referralCommissionRate = 1000;
    // Max referral commission rate: 20%.
    uint16 public constant MAXIMUM_REFERRAL_COMMISSION_RATE = 2000;

    event Deposit(address indexed user, uint256 amount);
    event Withdraw(address indexed user, uint256 amount);
    event EmissionRateUpdated(address indexed caller, uint256 previousAmount, uint256 newAmount);
    event ReferralCommissionWithdrawn(address indexed user, address indexed referrer, uint256 commissionAmount);

    /**
     * @param _token Main token contract address
     * @param _startBlock Start blocknumber of Staking Vault
     * @param __rewardPerBlock Reward Amount of token per block
     * @param _treasury Treasury Address
     */
    constructor(
        IERC20 _token,
        uint256 _startBlock,
        uint256 __rewardPerBlock,
        address _treasury
    ) {
        token = _token;
        _rewardPerBlock = __rewardPerBlock;

        Referral _referral = new Referral(address(_token));
        _referral.updateOperator(address(this), true);
        _referral.transferOwnership(msg.sender);

        referral = _referral;
        treasury = _treasury;
        uint256 lastRewardBlock = block.number > _startBlock ? block.number : _startBlock;
        poolInfo = PoolInfo({
            amount: 0,
            lastRewardBlock: lastRewardBlock,
            accTokenPerShare: 0
        });
    }

    // View function to see pending Tokens
    function pendingToken(address _user) external view returns (uint256) {
        PoolInfo storage pool = poolInfo;
        UserInfo storage user = userInfo[_user];
        uint256 accTokenPerShare = pool.accTokenPerShare;
        if (block.number > pool.lastRewardBlock && pool.amount != 0) {
            uint256 multiplier = block.number - pool.lastRewardBlock;
            uint256 tokenReward = multiplier * _rewardPerBlock;
            accTokenPerShare = accTokenPerShare + (tokenReward * 1e12 / pool.amount);
        }
        uint256 pending = user.amount * accTokenPerShare / 1e12 - user.rewardDebt;
        return pending;
    }

    // Update reward variables to be up-to-date.
    function updatePool() public {
        PoolInfo storage pool = poolInfo;
        if (block.number <= pool.lastRewardBlock) {
            return;
        }
        if (pool.amount == 0) {
            pool.lastRewardBlock = block.number;
            return;
        }
        uint256 multiplier = block.number - pool.lastRewardBlock;
        uint256 tokenReward = multiplier * _rewardPerBlock;
        pool.accTokenPerShare = pool.accTokenPerShare + (tokenReward * 1e12 / pool.amount);
        pool.lastRewardBlock = block.number;
    }

    // Deposit tokens to StakingVault for Main allocation.
    function deposit(uint256 _amount, address _referrer) external nonReentrant whenNotPaused {
        PoolInfo storage pool = poolInfo;
        UserInfo storage user = userInfo[msg.sender];
        updatePool();
        if (_amount > 0 && address(referral) != address(0) && _referrer != address(0) && _referrer != msg.sender) {
            referral.recordReferral(msg.sender, _referrer);
        }
        withdrawPendingReward();
        if (_amount > 0) {
            token.safeTransferFrom(address(msg.sender), address(this), _amount);
            user.amount = user.amount + _amount;
            pool.amount = pool.amount + _amount;
        }
        user.rewardDebt = user.amount * pool.accTokenPerShare / 1e12;
        emit Deposit(msg.sender, _amount);
    }

    // Withdraw tokens from StakingVault.
    function withdraw(uint256 _amount) external nonReentrant whenNotPaused {
        PoolInfo storage pool = poolInfo;
        UserInfo storage user = userInfo[msg.sender];
        require(user.amount >= _amount, "withdraw: not good");
        updatePool();
        withdrawPendingReward();
        if (_amount > 0) {
            user.amount = user.amount - _amount;
            pool.amount = pool.amount - _amount;
            token.safeTransfer(address(msg.sender), _amount);
        }
        user.rewardDebt = user.amount * pool.accTokenPerShare / 1e12;
        emit Withdraw(msg.sender, _amount);
    }

    function withdrawPendingReward() internal {
        PoolInfo storage pool = poolInfo;
        UserInfo storage user = userInfo[msg.sender];

        uint256 pending = user.amount * pool.accTokenPerShare / 1e12 - user.rewardDebt;
        if (pending > 0) {
            // send rewards
            token.safeTransferFrom(treasury, msg.sender, pending);
            withdrawReferralCommission(msg.sender, pending);
        }
    }

    function setTreasury(address _treasury) external onlyOwner {
        require(_treasury != address(0), "setTreasury: ZERO");
        treasury = _treasury;
    }

    function setPool() external onlyOwner {
        if (token.balanceOf(address(this)) > poolInfo.amount) {
            token.safeTransfer(treasury, token.balanceOf(address(this)) - poolInfo.amount);
        }
    }

    // Pancake has to add hidden dummy pools in order to alter the emission, here we make it simple and transparent to all.
    function updateEmissionRate(uint256 __rewardPerBlock) external onlyOwner {
        updatePool();
        emit EmissionRateUpdated(msg.sender, _rewardPerBlock, __rewardPerBlock);
        _rewardPerBlock = __rewardPerBlock;
    }

    function setReferralCommissionRate(uint16 _referralCommissionRate) external onlyOwner {
        require(_referralCommissionRate <= MAXIMUM_REFERRAL_COMMISSION_RATE, "setReferralCommissionRate: invalid referral commission rate basis points");
        referralCommissionRate = _referralCommissionRate;
    }

    function setPause() external onlyOwner {
        _pause();
    }

    function setUnpause() external onlyOwner {
        _unpause();
    }

    // Withdraw referral commission to the referrer who referred this user.
    function withdrawReferralCommission(address _user, uint256 _pending) internal {
        if (address(referral) != address(0) && referralCommissionRate > 0) {
            address referrer = referral.getReferrer(_user);
            uint256 commissionAmount = _pending * referralCommissionRate / 10000;

            if (referrer != address(0) && commissionAmount > 0) {
                token.safeTransferFrom(treasury, address(referral), commissionAmount);
                referral.recordReferralCommission(referrer, commissionAmount);
                emit ReferralCommissionWithdrawn(_user, referrer, commissionAmount);
            }
        }
    }
}
