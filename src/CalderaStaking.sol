// SPDX-License-Identifier: MIT
pragma solidity =0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Ownable2StepUpgradeable} from "@openzeppelin/contracts-upgradeable/access/Ownable2StepUpgradeable.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {ReentrancyGuardUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// @title Caldera Staking Contract
/// @notice This contract implements dynamic-rate staking rewards with
///         configurable stake lockup and unstake/withdrawal cooldown periods.
///         Based on Synthetix `StakingRewards`:
///         https://github.com/Synthetixio/synthetix/blob/master/contracts/StakingRewards.sol
contract CalderaStaking is
    Initializable,
    UUPSUpgradeable,
    PausableUpgradeable,
    Ownable2StepUpgradeable,
    ReentrancyGuardUpgradeable
{
    using SafeERC20 for IERC20;

    struct Stake {
        uint256 amount; // Amount staked
        uint256 depositedTimestamp; // When the stake was deposited
        uint256 lockedUntilTimestamp; // When the stake will be unlocked
        uint256 rewardPerTokenPaid; // The reward per token paid for the stake since the last update
        uint256 reward; // The reward already accrued by the stake since the last update
    }

    struct WithdrawalRequest {
        uint256 amount; // Amount requested to withdraw
        uint256 requestedTimestamp; // When withdrawal was requested
        uint256 cooldownPeriodEndTimestamp; // When the cooldown period ends
    }

    uint256 public constant MAX_MINIMUM_STAKE_AMOUNT = 1000 ether;
    uint256 public constant MAX_STAKE_LOCKUP_PERIOD = 90 days;
    uint256 public constant MAX_WITHDRAWAL_REQUEST_COOLDOWN_PERIOD = 7 days;
    uint256 public constant MAX_STAKES_COUNT = 100;
    uint256 public constant MAX_WITHDRAWAL_REQUESTS_COUNT = 100;
    uint256 public constant MAX_REWARD_RATE = uint256(100_000 ether) / 1 days;

    uint256 public totalStaked; // Total amount of tokens staked
    uint256 public totalRequestedWithdrawals; // Total amount of tokens requested to withdraw
    uint256 public accruedRewards; // Amount of rewards earned (locked and unlocked) but not yet claimed up until the last reward update
    mapping(address users => Stake[] stakes) public stakes;
    mapping(address users => WithdrawalRequest[] withdrawalRequests) public withdrawalRequests;

    uint256 public lastUpdatedTimestamp; // The last time the rewards were updated
    address public token; // The token to be staked and used for rewards
    address public rewardsVault; // The vault to store the staking rewards to pay out
    address public stakeForSenderAddress; // An address that is authorized to stake on behalf of other users
    uint256 public stakeLockupPeriod; // The lockup period in seconds, during which users cannot request to unstake
    uint256 public minimumStakeAmount = 1 ether; // The minimum amount of tokens that can be staked or withdrawn at a time
    uint256 public withdrawalRequestCooldownPeriod; // The cooldown period in seconds, during which users cannot withdraw after unstaking

    uint256 public rewardRate; // Rewards distributed per second
    uint256 public rewardPerTokenStored;
    uint256 public rewardsEndTimestamp; // When to stop paying out rewards

    event TokenSet(address token);
    event RewardsVaultSet(address previousRewardsVault, address newRewardsVault);
    event StakeForSenderAddressSet(address previousStakeForSenderAddress, address newStakeForSenderAddress);
    event StakeLockupPeriodSet(uint256 previousStakeLockupPeriod, uint256 newStakeLockupPeriod);
    event MinimumStakeAmountSet(uint256 previousMinimumStakeAmount, uint256 newMinimumStakeAmount);
    event WithdrawalRequestCooldownPeriodSet(
        uint256 previousWithdrawalRequestCooldownPeriod, uint256 newWithdrawalRequestCooldownPeriod
    );
    event RewardsEndTimestampSet(uint256 previousRewardsEndTimestamp, uint256 newRewardsEndTimestamp);
    event RewardRateSet(uint256 previousRewardRate, uint256 newRewardRate);

    event Staked(address indexed user, uint256 amount);
    event StakedFor(address indexed sender, address indexed beneficiary, uint256 amount);
    event Unstaked(address indexed user, uint256 amount);
    event Withdrawn(address indexed user, uint256 amount);
    event Rewarded(address indexed user, uint256 amount);

    error InvalidToken();
    error InvalidRewardsVault();
    error InvalidStakeLockupPeriod();
    error InvalidMinimumStakeAmount();
    error InvalidWithdrawalRequestCooldownPeriod();
    error InvalidRewardsEndTimestamp();
    error InvalidRewardsVaultTargetPercent();
    error RewardsDurationTooShort();
    error InsufficientRewardsVaultBalance();
    error RewardRateTooHigh();
    error UnauthorizedStakeForSender();
    error InvalidStakeForBeneficiary();

    error StakeAmountTooSmall();
    error TooManyStakes();
    error UnstakeAmountTooSmall();
    error WithdrawAmountTooSmall();
    error InsufficientWithdrawableAmount();
    error InsufficientUnlockedStake();
    error TooManyWithdrawalRequests();
    error NoClaimableReward();

    /// @notice Modifier to update the reward for a specific user. If called
    ///         with the zero address, it will only update the
    ///         `rewardPerTokenStored`.
    ///
    ///         This modifier should be called whenever a user stakes or
    ///         unstakes, and also whenever the reward rate is updated or the
    ///         `rewardsEndTimestamp` is set (in these cases, it should be
    ///         called with the zero address, just to update the
    ///         `rewardPerTokenStored`).
    /// @param user The user for which we should update the reward amount, or
    ///             the zero address to only update the `rewardPerTokenStored`.
    modifier updateReward(address user) {
        accruedRewards += _getRewardsAccruedSinceLastUpdate();

        rewardPerTokenStored = rewardPerToken();
        lastUpdatedTimestamp = lastTimeRewardApplicable();

        if (user != address(0)) {
            Stake[] storage userStakes = stakes[user];
            uint256 userStakesLength = userStakes.length;

            Stake storage stake_;
            for (uint256 i; i < userStakesLength; ++i) {
                stake_ = userStakes[i];

                stake_.reward = earned(stake_);
                stake_.rewardPerTokenPaid = rewardPerTokenStored;
            }
        }

        _;
    }

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /// @notice Initializes the contract with necessary parameters. After
    ///         initialization, reward tokens should be deposited to the
    ///         `rewardsVault` and `syncRewardRate` should be called.
    /// @param initialOwner The initial owner of the contract.
    /// @param token_ The token to be staked and used for rewards.
    /// @param rewardsVault_ The vault to store the staking rewards to pay out.
    ///                      The vault should approve the staking contract as a
    ///                      spender.
    /// @param stakeForSenderAddress_ The address that is authorized to stake
    ///                               on behalf of other users. Can be set to
    ///                               the zero address to disable staking on
    ///                               behalf of other users too. This address
    ///                               should approve the staking contract as
    ///                               a spender of the token to be staked.
    /// @param stakeLockupPeriod_ The lockup period in seconds, during which
    ///                           users cannot request to unstake after
    ///                           staking.
    /// @param minimumStakeAmount_ The minimum amount of tokens that can be
    ///                            staked.
    /// @param withdrawalRequestCooldownPeriod_ The cooldown period in seconds,
    ///                                         during which users cannot
    ///                                         withdraw after unstaking.
    /// @param rewardsEndTimestamp_ When to stop paying out rewards.
    function initialize(
        address initialOwner,
        address token_,
        address rewardsVault_,
        address stakeForSenderAddress_,
        uint256 stakeLockupPeriod_,
        uint256 minimumStakeAmount_,
        uint256 withdrawalRequestCooldownPeriod_,
        uint256 rewardsEndTimestamp_
    ) external initializer {
        __UUPSUpgradeable_init();
        __Pausable_init();
        __Ownable_init(initialOwner);
        __ReentrancyGuard_init();

        if (token_ == address(0)) {
            revert InvalidToken();
        }

        if (rewardsVault_ == address(0)) {
            revert InvalidRewardsVault();
        }

        if (stakeLockupPeriod_ == 0 || stakeLockupPeriod_ > MAX_STAKE_LOCKUP_PERIOD) {
            revert InvalidStakeLockupPeriod();
        }

        if (minimumStakeAmount_ == 0 || minimumStakeAmount_ > MAX_MINIMUM_STAKE_AMOUNT) {
            revert InvalidMinimumStakeAmount();
        }

        if (
            withdrawalRequestCooldownPeriod_ == 0
                || withdrawalRequestCooldownPeriod_ > MAX_WITHDRAWAL_REQUEST_COOLDOWN_PERIOD
        ) {
            revert InvalidWithdrawalRequestCooldownPeriod();
        }

        if (rewardsEndTimestamp_ < block.timestamp) {
            revert InvalidRewardsEndTimestamp();
        }

        token = token_;
        rewardsVault = rewardsVault_;
        stakeForSenderAddress = stakeForSenderAddress_;
        stakeLockupPeriod = stakeLockupPeriod_;
        minimumStakeAmount = minimumStakeAmount_;
        withdrawalRequestCooldownPeriod = withdrawalRequestCooldownPeriod_;
        rewardsEndTimestamp = rewardsEndTimestamp_;
        lastUpdatedTimestamp = lastTimeRewardApplicable();

        emit TokenSet(token_);
        emit RewardsVaultSet(address(0), rewardsVault_);
        emit StakeForSenderAddressSet(address(0), stakeForSenderAddress_);
        emit StakeLockupPeriodSet(0, stakeLockupPeriod);
        emit MinimumStakeAmountSet(0, minimumStakeAmount);
        emit WithdrawalRequestCooldownPeriodSet(0, withdrawalRequestCooldownPeriod);
        emit RewardsEndTimestampSet(0, rewardsEndTimestamp);
    }

    /// @notice Pauses the contract, preventing staking, unstaking,
    ///         withdrawing, and claiming rewards. Note that this does not pause
    ///         reward accrual. To stop reward accrual, set the `rewardRate` to
    ///         0.
    function pause() external onlyOwner {
        _pause();
    }

    /// @notice Unpauses the contract.
    function unpause() external onlyOwner {
        _unpause();
    }

    /// @notice Sets a new rewards vault address.
    /// @param rewardsVault_ The new rewards vault address.
    function setRewardsVault(address rewardsVault_) external onlyOwner {
        if (rewardsVault_ == address(0)) {
            revert InvalidRewardsVault();
        }

        address previousRewardsVault = rewardsVault;
        rewardsVault = rewardsVault_;
        emit RewardsVaultSet(previousRewardsVault, rewardsVault_);
    }

    /// @notice Sets the stake for sender address.
    /// @param stakeForSenderAddress_ The new stake for sender address, which
    ///                               should be authorized to stake on behalf
    ///                               of other users. Can be set to the zero
    ///                               address to disable staking on behalf of
    ///                               other users.
    function setStakeForSenderAddress(address stakeForSenderAddress_) external onlyOwner {
        address previousStakeForSenderAddress = stakeForSenderAddress;
        stakeForSenderAddress = stakeForSenderAddress_;
        emit StakeForSenderAddressSet(previousStakeForSenderAddress, stakeForSenderAddress_);
    }

    /// @notice Sets the stake lockup period, during which users cannot
    ///         unstake after staking.
    /// @param stakeLockupPeriod_ The new stake lockup period in seconds.
    function setStakeLockupPeriod(uint256 stakeLockupPeriod_) external onlyOwner {
        if (stakeLockupPeriod_ == 0 || stakeLockupPeriod_ > MAX_STAKE_LOCKUP_PERIOD) {
            revert InvalidStakeLockupPeriod();
        }

        uint256 previousStakeLockupPeriod = stakeLockupPeriod;
        stakeLockupPeriod = stakeLockupPeriod_;
        emit StakeLockupPeriodSet(previousStakeLockupPeriod, stakeLockupPeriod_);
    }

    /// @notice Sets the minimum amount of tokens that can be staked.
    /// @param minimumStakeAmount_ The new minimum amount of tokens that can be
    ///                            staked.
    function setMinimumStakeAmount(uint256 minimumStakeAmount_) external onlyOwner {
        if (minimumStakeAmount_ == 0 || minimumStakeAmount_ > MAX_MINIMUM_STAKE_AMOUNT) {
            revert InvalidMinimumStakeAmount();
        }

        uint256 previousMinimumStakeAmount = minimumStakeAmount;
        minimumStakeAmount = minimumStakeAmount_;
        emit MinimumStakeAmountSet(previousMinimumStakeAmount, minimumStakeAmount_);
    }
    /// @notice Sets the withdrawal request cooldown period, during which
    ///         users cannot withdraw after unstaking.
    /// @param withdrawalRequestCooldownPeriod_ The new withdrawal request
    ///                                         cooldown period in seconds.

    function setWithdrawalRequestCooldownPeriod(uint256 withdrawalRequestCooldownPeriod_) external onlyOwner {
        if (
            withdrawalRequestCooldownPeriod_ == 0
                || withdrawalRequestCooldownPeriod_ > MAX_WITHDRAWAL_REQUEST_COOLDOWN_PERIOD
        ) {
            revert InvalidWithdrawalRequestCooldownPeriod();
        }

        uint256 previousWithdrawalRequestCooldownPeriod = withdrawalRequestCooldownPeriod;
        withdrawalRequestCooldownPeriod = withdrawalRequestCooldownPeriod_;
        emit WithdrawalRequestCooldownPeriodSet(
            previousWithdrawalRequestCooldownPeriod, withdrawalRequestCooldownPeriod_
        );
    }

    /// @notice Sets the rewards end timestamp, after which no more rewards
    ///         will be distributed.
    /// @param rewardsEndTimestamp_ The new rewards end timestamp.
    /// @param shouldSyncRewardRate Whether to update the reward rate so that
    ///                             available rewards are spread out until the
    ///                             new rewards end timestamp.
    ///
    ///                             If `false`, the reward rate will remain the
    ///                             same as before. If `true`, the reward rate
    ///                             will be updated to pay out the entire
    ///                             balance of the rewards vault over the
    ///                             period from now until the new rewards end
    ///                             timestamp. If you wish to pay out a smaller
    ///                             percentage of the rewards vault, you should
    ///                             call `syncRewardRate` with the appropriate
    ///                             percentage separately.
    function setRewardsEndTimestamp(uint256 rewardsEndTimestamp_, bool shouldSyncRewardRate)
        external
        onlyOwner
        updateReward(address(0))
    {
        if (rewardsEndTimestamp_ < block.timestamp) {
            revert InvalidRewardsEndTimestamp();
        }

        uint256 previousRewardsEndTimestamp = rewardsEndTimestamp;
        rewardsEndTimestamp = rewardsEndTimestamp_;
        emit RewardsEndTimestampSet(previousRewardsEndTimestamp, rewardsEndTimestamp_);

        // If the `rewardsEndTimestamp` is in the past, `lastTimeRewardApplicable()`
        // will just be the old `rewardsEndTimestamp` after the initial call to
        // `updateReward`, since the function just takes the minimum of
        // `rewardsEndTimestamp` and `block.timestamp`. Since the new
        // `rewardsEndTimestamp` must be in the future, the implication for our
        // calculations is that users will be credited rewards for an inapplicable
        // period (they shouldn't earn after the previous period ended). So we
        // need to update `lastUpdatedTimestamp` here too, to the current
        // timestamp, so when we calculate rewards we start counting from the
        // current timestamp rather than the previous `rewardsEndTimestamp`.
        //
        // If `rewardsEndTimestamp` is in the future, `lastTimeRewardApplicable()`
        // will already be the current timestamp, so this call will be a no-op
        // (and hence safe).
        lastUpdatedTimestamp = lastTimeRewardApplicable();

        if (shouldSyncRewardRate) {
            _syncRewardRate(1e18);
        }
    }

    /// @notice Sync the reward rate with the current balance of the rewards
    ///         vault. Compare to the `notifyRewardAmount` on the Synthetix
    ///         staking contract — this is an automatic version that
    ///         automatically gets the correct amount from the rewards vault
    ///         and sets the reward rate accordingly. Should be called whenever
    ///         the rewards vault balance changes.
    /// @param rewardsVaultTargetPercent The percent of the rewards vault
    ///                                  balance to use as the basis for
    ///                                  calculating the reward rate, where
    ///                                  1e18 is 100%. For instance, if this
    ///                                  is set to 0.5e18 (i.e., 50%), at
    ///                                  the `rewardsEndTimestamp`, the
    ///                                  rewards vault will have paid out
    ///                                  50% of its balance as rewards.
    function syncRewardRate(uint256 rewardsVaultTargetPercent)
        external
        nonReentrant
        onlyOwner
        updateReward(address(0))
    {
        _syncRewardRate(rewardsVaultTargetPercent);
    }

    /// @notice Sets the reward rate manually. This is dangerous in that there
    ///         may not be enough rewards in the rewards vault to pay out all
    ///         earnings at the new reward rate if left unchecked.
    /// @dev We recommend using `syncRewardRate` instead, which automatically
    ///      gets the balance of the rewards vault, subtracts accrued rewards,
    ///      and sets the reward rate accordingly.
    /// @param rewardRate_ The new reward rate, in total tokens to distribute
    ///                    per second.
    /// @param areYouSure Whether you are truly sure you want to set the reward
    ///                   rate manually.
    function dangerouslySetRewardRate(uint256 rewardRate_, bool areYouSure)
        external
        onlyOwner
        updateReward(address(0))
    {
        require(areYouSure, "You must be truly sure of yourself to set the reward rate manually.");

        if (rewardRate_ > MAX_REWARD_RATE) {
            revert RewardRateTooHigh();
        }

        uint256 previousRewardRate = rewardRate;
        rewardRate = rewardRate_;
        emit RewardRateSet(previousRewardRate, rewardRate_);
    }

    /// @notice Allows users to stake tokens.
    /// @param amount The amount of tokens to stake.
    function stake(uint256 amount) external nonReentrant whenNotPaused updateReward(msg.sender) {
        if (amount < minimumStakeAmount) {
            revert StakeAmountTooSmall();
        }

        Stake[] storage userStakes = stakes[msg.sender];
        uint256 userStakesLength = userStakes.length;
        if (userStakesLength >= MAX_STAKES_COUNT) {
            revert TooManyStakes();
        }

        uint256 blockTimestamp = block.timestamp;
        uint256 lastDepositedTimestamp = userStakesLength > 0 ? userStakes[userStakesLength - 1].depositedTimestamp : 0;
        // Only allow one stake per minute
        if (lastDepositedTimestamp != 0 && lastDepositedTimestamp + 1 minutes > blockTimestamp) {
            revert TooManyStakes();
        }

        totalStaked += amount;
        userStakes.push(
            Stake({
                amount: amount,
                depositedTimestamp: block.timestamp,
                lockedUntilTimestamp: block.timestamp + stakeLockupPeriod,
                rewardPerTokenPaid: rewardPerToken(),
                reward: 0
            })
        );

        IERC20(token).safeTransferFrom(msg.sender, address(this), amount);
        emit Staked(msg.sender, amount);
    }

    /// @notice Allows tokens to be staked on behalf of another user. Note, we
    ///         assume that the `stakeFor` address is trusted, so we don't
    ///         rate-limit stakes to once per minute (this allows the airdrop
    ///         contract to automatically stake a user's address claim and
    ///         GitHub claim in the same block).
    /// @param user The address of the user to stake for.
    /// @param amount The amount of tokens to stake.
    function stakeFor(address user, uint256 amount) external nonReentrant whenNotPaused updateReward(user) {
        if (amount < minimumStakeAmount) {
            revert StakeAmountTooSmall();
        }

        Stake[] storage userStakes = stakes[user];
        if (userStakes.length >= MAX_STAKES_COUNT) {
            revert TooManyStakes();
        }

        if (msg.sender != stakeForSenderAddress) {
            revert UnauthorizedStakeForSender();
        }

        if (user == address(0)) {
            revert InvalidStakeForBeneficiary();
        }

        uint256 blockTimestamp = block.timestamp;
        totalStaked += amount;
        userStakes.push(
            Stake({
                amount: amount,
                depositedTimestamp: blockTimestamp,
                lockedUntilTimestamp: blockTimestamp + stakeLockupPeriod,
                rewardPerTokenPaid: rewardPerToken(),
                reward: 0
            })
        );

        IERC20(token).safeTransferFrom(msg.sender, address(this), amount);
        emit StakedFor(msg.sender, user, amount);
    }

    /// @notice Allows users to unstake their tokens, unstaking the earliest
    ///         unstaked stakes first.
    /// @param amount The amount of tokens to unstake.
    function unstake(uint256 amount) external nonReentrant whenNotPaused updateReward(msg.sender) {
        if (amount < minimumStakeAmount) {
            revert UnstakeAmountTooSmall();
        }

        _unstake(amount);
    }

    /// @notice Allows users to unstake all their tokens. Useful if they want
    ///         to unstake but their stake is less than the
    ///         `minimumStakeAmount`.
    function unstakeAll() external nonReentrant whenNotPaused updateReward(msg.sender) {
        _unstake(_getUserUnlockedStakeAmount(msg.sender));
    }

    /// @notice Withdraw tokens after the cooldown period
    /// @param amount Amount to withdraw, must be <= current cooling amount
    function withdraw(uint256 amount) external nonReentrant whenNotPaused {
        if (amount < minimumStakeAmount) {
            revert WithdrawAmountTooSmall();
        }

        _withdraw(amount);
    }

    /// @notice Allows users to withdraw all their tokens. Useful if they want
    ///         to withdraw but their withdrawable amount is less than the
    ///         `minimumStakeAmount`.
    function withdrawAll() external nonReentrant whenNotPaused {
        _withdraw(_getUserWithdrawableAmount(msg.sender));
    }

    /// @notice Gets all claimable rewards for a user
    /// @dev Only rewards for unlocked stakes can be claimed
    function getReward() external nonReentrant whenNotPaused updateReward(msg.sender) {
        Stake[] storage userStakes = stakes[msg.sender];
        uint256 claimableRewardAmount;
        uint256 blockTimestamp = block.timestamp;

        uint256 userStakesLength = userStakes.length;
        Stake storage stake_;
        for (uint256 i; i < userStakesLength; ++i) {
            stake_ = userStakes[i];
            if (_isStakeLocked(stake_, blockTimestamp)) {
                continue;
            }

            claimableRewardAmount += earned(stake_);
            stake_.reward = 0;
        }

        if (claimableRewardAmount == 0) {
            revert NoClaimableReward();
        }

        uint256 rewardsVaultBalance = IERC20(token).balanceOf(rewardsVault);
        if (rewardsVaultBalance < claimableRewardAmount) {
            revert InsufficientRewardsVaultBalance();
        }
        accruedRewards -= claimableRewardAmount;
        _cleanUserStakes(msg.sender);

        IERC20(token).safeTransferFrom(rewardsVault, msg.sender, claimableRewardAmount);
        emit Rewarded(msg.sender, claimableRewardAmount);
    }

    /// @notice Recovers ERC20 tokens from the contract.
    /// @param tokenToRecover The address of the token to recover.
    /// @param tokenAmount The amount of tokens to recover.
    function recoverErc20(address tokenToRecover, uint256 tokenAmount) external nonReentrant onlyOwner {
        require(tokenToRecover != address(token), "Cannot withdraw the staking token");
        IERC20(tokenToRecover).safeTransfer(owner(), tokenAmount);
    }

    /// @notice Gets the estimated current APR for the staking contract (as a
    ///         percent)
    /// @return apr The estimated APR as a percent
    function getEstimatedApr() external view returns (uint256) {
        if (totalStaked == 0) {
            return 0;
        }

        // `rewardRate * 365 days / totalStaked` gives the return on a single
        // staked token in a year; we multiply by 100 to get a percent
        return (rewardRate * 365 days * 100) / totalStaked;
    }

    /// @notice Gets claimable (unlocked) reward for a user
    /// @param user The user address
    /// @return total The total claimable reward from unlocked stakes
    function getUserClaimableRewardAmount(address user) external view returns (uint256) {
        Stake[] storage userStakes = stakes[user];
        uint256 userStakesLength = userStakes.length;
        uint256 claimableRewardAmount;
        uint256 blockTimestamp = block.timestamp;

        Stake storage stake_;
        for (uint256 i; i < userStakesLength; ++i) {
            stake_ = userStakes[i];
            if (_isStakeLocked(stake_, blockTimestamp)) {
                continue;
            }

            claimableRewardAmount += earned(stake_);
        }

        return claimableRewardAmount;
    }

    /// @notice Gets total amount of rewards for a user across all stakes
    ///         (locked and unlocked)
    /// @param user The user address
    /// @return userTotalRewardAmount The total rewards
    function getUserTotalRewardAmount(address user) external view returns (uint256) {
        Stake[] storage userStakes = stakes[user];
        uint256 userStakesLength = userStakes.length;

        uint256 userTotalRewardAmount;
        for (uint256 i; i < userStakesLength; ++i) {
            userTotalRewardAmount += earned(userStakes[i]);
        }

        return userTotalRewardAmount;
    }

    /// @notice Gets the amount of unlocked stake for a user.
    /// @param user The address of the user to get the unlocked stake for.
    /// @return The amount of unlocked stake.
    function getUserUnlockedStakeAmount(address user) external view returns (uint256) {
        return _getUserUnlockedStakeAmount(user);
    }

    /// @notice Gets the amount of withdrawable tokens for a user.
    /// @param user The address of the user to get the withdrawable amount for.
    /// @return The amount of withdrawable tokens.
    function getUserWithdrawableAmount(address user) external view returns (uint256) {
        return _getUserWithdrawableAmount(user);
    }

    /// @notice Gets the total amount staked for a user.
    /// @param user The address of the user to get the total amount staked for.
    /// @return The total amount staked.
    function getUserTotalStakeAmount(address user) external view returns (uint256) {
        Stake[] storage userStakes = stakes[user];
        uint256 userStakesLength = userStakes.length;

        uint256 totalStakeAmount;
        for (uint256 i; i < userStakesLength; ++i) {
            totalStakeAmount += userStakes[i].amount;
        }

        return totalStakeAmount;
    }

    /// @notice Gets the number of stakes for a user.
    /// @param user The address of the user to get the number of stakes for.
    /// @return The number of stakes.
    function getUserStakeCount(address user) external view returns (uint256) {
        return stakes[user].length;
    }

    /// @notice Gets the total amount of withdrawal requests for a user.
    /// @param user The address of the user to get the total amount of withdrawal requests for.
    /// @return The total amount of withdrawal requests.
    function getUserTotalWithdrawalRequestsAmount(address user) external view returns (uint256) {
        WithdrawalRequest[] storage userWithdrawalRequests = withdrawalRequests[user];
        uint256 userWithdrawalRequestsLength = userWithdrawalRequests.length;

        uint256 totalWithdrawalRequestsAmount;
        for (uint256 i; i < userWithdrawalRequestsLength; ++i) {
            totalWithdrawalRequestsAmount += userWithdrawalRequests[i].amount;
        }
        return totalWithdrawalRequestsAmount;
    }

    /// @notice Gets the number of withdrawal requests for a user.
    /// @param user The address of the user to get the number of withdrawal requests for.
    /// @return The number of withdrawal requests.
    function getUserWithdrawalRequestCount(address user) external view returns (uint256) {
        return withdrawalRequests[user].length;
    }

    /// @notice Returns the last time rewards are/were applicable, relative to
    ///         the current time (essentially, the minimum of the current time
    ///         and the `rewardsEndTimestamp`; we don't want to pay out rewards
    ///         after the reward period has ended).
    /// @return The last time rewards were applicable
    function lastTimeRewardApplicable() public view returns (uint256) {
        return Math.min(block.timestamp, rewardsEndTimestamp);
    }

    /// @notice Calculates the current reward per token
    /// @return The reward per token
    function rewardPerToken() public view returns (uint256) {
        if (totalStaked == 0) {
            return rewardPerTokenStored;
        }

        // We multiply `rewardRate` by `1e18` to minimize precision loss
        return rewardPerTokenStored
            + (rewardRate * (lastTimeRewardApplicable() - lastUpdatedTimestamp) * 1e18) / totalStaked;
    }

    /// @notice Calculates the total earned rewards for a stake
    /// @param stake_ The stake to calculate the earned rewards for
    /// @return The total earned rewards
    function earned(Stake memory stake_) public view returns (uint256) {
        // We divide by `1e18` since we multipled by `1e18` in `rewardPerToken()`
        return stake_.amount * (rewardPerToken() - stake_.rewardPerTokenPaid) / 1e18 + stake_.reward;
    }

    /// @notice Unstakes a user's tokens, unstaking the earliest unstaked
    ///         stakes first. The caller must call `updateReward` for the
    ///         user before calling this function.
    /// @param amount The amount of tokens to unstake.
    function _unstake(uint256 amount) internal whenNotPaused {
        uint256 userUnlockedStakeAmount = _getUserUnlockedStakeAmount(msg.sender);
        if (amount > userUnlockedStakeAmount) {
            revert InsufficientUnlockedStake();
        }

        WithdrawalRequest[] storage userWithdrawalRequests = withdrawalRequests[msg.sender];
        if (userWithdrawalRequests.length >= MAX_WITHDRAWAL_REQUESTS_COUNT) {
            revert TooManyWithdrawalRequests();
        }

        uint256 blockTimestamp = block.timestamp;
        uint256 lastRequestedTimestamp = userWithdrawalRequests.length > 0
            ? userWithdrawalRequests[userWithdrawalRequests.length - 1].requestedTimestamp
            : 0;
        // Only allow one withdrawal request per minute
        if (lastRequestedTimestamp != 0 && lastRequestedTimestamp + 1 minutes > blockTimestamp) {
            revert TooManyWithdrawalRequests();
        }

        Stake[] storage userStakes = stakes[msg.sender];
        uint256 amountRemainingToUnstake = amount;

        // At this point, we know that the user has enough unlocked stake to
        // unstake the requested amount.
        for (uint256 i; i < userStakes.length; i++) {
            Stake storage stake_ = userStakes[i];
            if (_isStakeLocked(stake_, blockTimestamp)) {
                continue;
            }

            if (amountRemainingToUnstake < stake_.amount) {
                stake_.amount -= amountRemainingToUnstake;
                amountRemainingToUnstake = 0;
                break;
            }

            amountRemainingToUnstake -= stake_.amount;
            stake_.amount = 0;
        }

        if (amountRemainingToUnstake > 0) {
            revert InsufficientUnlockedStake();
        }

        _cleanUserStakes(msg.sender);
        userWithdrawalRequests.push(
            WithdrawalRequest({
                amount: amount,
                requestedTimestamp: blockTimestamp,
                cooldownPeriodEndTimestamp: blockTimestamp + withdrawalRequestCooldownPeriod
            })
        );
        totalStaked -= amount;
        totalRequestedWithdrawals += amount;

        emit Unstaked(msg.sender, amount);
    }

    /// @notice Withdraws a user's tokens after the cooldown period
    /// @param amount Amount to withdraw, must be <= current cooling amount
    function _withdraw(uint256 amount) internal whenNotPaused {
        uint256 userWithdrawableAmount = _getUserWithdrawableAmount(msg.sender);
        if (amount > userWithdrawableAmount) {
            revert InsufficientWithdrawableAmount();
        }

        WithdrawalRequest[] storage userWithdrawalRequests = withdrawalRequests[msg.sender];
        uint256 amountRemainingToWithdraw = amount;
        uint256 blockTimestamp = block.timestamp;
        // At this point, we know that the user has enough cooled-down
        // withdrawal requests to withdraw the requested amount.
        for (uint256 i; i < userWithdrawalRequests.length; i++) {
            WithdrawalRequest storage withdrawalRequest_ = userWithdrawalRequests[i];
            if (blockTimestamp < withdrawalRequest_.cooldownPeriodEndTimestamp) {
                continue;
            }

            if (amountRemainingToWithdraw < withdrawalRequest_.amount) {
                withdrawalRequest_.amount -= amountRemainingToWithdraw;
                amountRemainingToWithdraw = 0;
                break;
            }

            amountRemainingToWithdraw -= withdrawalRequest_.amount;
            withdrawalRequest_.amount = 0;
        }

        if (amountRemainingToWithdraw > 0) {
            revert InsufficientWithdrawableAmount();
        }

        _cleanUserWithdrawalRequests(msg.sender);
        totalRequestedWithdrawals -= amount;

        IERC20(token).safeTransfer(msg.sender, amount);
        emit Withdrawn(msg.sender, amount);
    }

    /// @notice Cleans up any zero-amount stakes for a user.
    /// @param user The address of the user to clean up the stakes for.
    function _cleanUserStakes(address user) internal {
        Stake[] storage userStakes = stakes[user];
        uint256 writeIndex;
        uint256 cleanedStakesReward;

        for (uint256 i; i < userStakes.length; ++i) {
            // We declare a `memory` variable so we copy by value, not by
            // reference.
            Stake memory stake_ = userStakes[i];
            if (stake_.amount > 0) {
                userStakes[writeIndex] = stake_;
                writeIndex++;
            } else {
                cleanedStakesReward += earned(stake_);
            }
        }

        while (userStakes.length > writeIndex) {
            userStakes.pop();
        }

        if (userStakes.length > 0) {
            userStakes[0].reward += cleanedStakesReward;
        } else if (cleanedStakesReward > 0) {
            // If there are no stakes, create a new one to hold the reward
            // from the cleaned stakes.
            userStakes.push(
                Stake({
                    amount: 0,
                    depositedTimestamp: block.timestamp,
                    // If all stakes were cleaned up, these rewards must have
                    // already been unlocked.
                    lockedUntilTimestamp: block.timestamp,
                    rewardPerTokenPaid: rewardPerToken(),
                    reward: cleanedStakesReward
                })
            );
        }
    }

    /// @notice Cleans up any zero-amount withdrawal requests for a user.
    /// @param user The address of the user to clean up the withdrawal requests for.
    function _cleanUserWithdrawalRequests(address user) internal {
        WithdrawalRequest[] storage userWithdrawalRequests = withdrawalRequests[user];
        uint256 writeIndex;

        for (uint256 i; i < userWithdrawalRequests.length; ++i) {
            // We declare a `memory` variable so we copy by value, not by
            // reference.
            WithdrawalRequest memory withdrawalRequest_ = userWithdrawalRequests[i];
            if (withdrawalRequest_.amount > 0) {
                userWithdrawalRequests[writeIndex] = withdrawalRequest_;
                writeIndex++;
            }
        }

        while (userWithdrawalRequests.length > writeIndex) {
            userWithdrawalRequests.pop();
        }
    }

    /// @notice Gets the amount of rewards accrued since the last call to
    ///         `updateReward`.
    /// @return The amount of rewards accrued since the last call to
    ///         `updateReward`.
    function _getRewardsAccruedSinceLastUpdate() internal view returns (uint256) {
        // Rewards only accrue if there were tokens staked and earning rewards
        // since the last update.
        if (totalStaked == 0) {
            return 0;
        }

        return rewardRate * (lastTimeRewardApplicable() - lastUpdatedTimestamp);
    }

    /// @notice Gets the amount of unlocked stake for a user.
    /// @param user The address of the user to get the unlocked stake for.
    /// @return userUnlockedStakeAmount The amount of unlocked stake.
    function _getUserUnlockedStakeAmount(address user) internal view returns (uint256) {
        Stake[] storage userStakes = stakes[user];
        uint256 userStakesLength = userStakes.length;
        uint256 blockTimestamp = block.timestamp;

        uint256 userUnlockedStakeAmount;
        for (uint256 i; i < userStakesLength; ++i) {
            if (!_isStakeLocked(userStakes[i], blockTimestamp)) {
                userUnlockedStakeAmount += userStakes[i].amount;
            }
        }
        return userUnlockedStakeAmount;
    }

    /// @notice Gets the amount of withdrawable tokens for a user.
    /// @param user The address of the user to get the withdrawable amount for.
    /// @return The amount of withdrawable tokens.
    function _getUserWithdrawableAmount(address user) internal view returns (uint256) {
        WithdrawalRequest[] storage userWithdrawalRequests = withdrawalRequests[user];
        uint256 userWithdrawalRequestsLength = userWithdrawalRequests.length;
        uint256 blockTimestamp = block.timestamp;

        uint256 withdrawableAmount;
        for (uint256 i; i < userWithdrawalRequestsLength; ++i) {
            if (blockTimestamp >= userWithdrawalRequests[i].cooldownPeriodEndTimestamp) {
                withdrawableAmount += userWithdrawalRequests[i].amount;
            }
        }
        return withdrawableAmount;
    }

    /// @notice Checks if a stake is locked at a given timestamp.
    /// @param stake_ The stake to check.
    /// @param atTimestamp The timestamp at which to check if the stake is locked.
    /// @return True if the stake is locked at the given timestamp, false otherwise.
    function _isStakeLocked(Stake memory stake_, uint256 atTimestamp) internal pure returns (bool) {
        return stake_.lockedUntilTimestamp > atTimestamp;
    }

    /// @notice Sync the reward rate with the current balance of the rewards
    ///         vault. Compare to the `notifyRewardAmount` on the Synthetix
    ///         staking contract — this is an automatic version that
    ///         automatically gets the correct amount from the rewards vault
    ///         and sets the reward rate accordingly. Should be called whenever
    ///         the rewards vault balance changes.
    ///
    ///         The caller of this function must have the
    ///         `updateReward(address(0))` modifier for proper accounting.
    ///
    /// @param rewardsVaultTargetPercent The percent of the rewards vault
    ///                                  balance to use as the basis for
    ///                                  calculating the reward rate, where
    ///                                  1e18 is 100%. For instance, if this
    ///                                  is set to 0.5e18 (i.e., 50%), at
    ///                                  the `rewardsEndTimestamp`, the
    ///                                  rewards vault will have paid out
    ///                                  50% of its balance as rewards.
    function _syncRewardRate(uint256 rewardsVaultTargetPercent) internal {
        // 1e18 is 100%
        if (rewardsVaultTargetPercent > 1e18) {
            revert InvalidRewardsVaultTargetPercent();
        }

        uint256 previousRewardRate = rewardRate;
        uint256 blockTimestamp = block.timestamp;

        if (blockTimestamp >= rewardsEndTimestamp) {
            rewardRate = 0;
            emit RewardRateSet(previousRewardRate, rewardRate);
            return;
        }

        uint256 rewardsDuration = rewardsEndTimestamp - blockTimestamp;

        // When `rewardsDuration` is very short, the division operation to get
        // the new synced `rewardRate` can produce an extremely high rate due
        // to the small denominator. So we disallow syncing when the duration is
        // less than 1 day.
        if (rewardsDuration < 1 days) {
            revert RewardsDurationTooShort();
        }

        // We divide `rewardsVaultTargetPercent` by 1e18 to normalize to 1
        uint256 rewardsVaultAvailableBalance = IERC20(token).balanceOf(rewardsVault) * rewardsVaultTargetPercent / 1e18;
        uint256 currentAccruedRewards = accruedRewards + _getRewardsAccruedSinceLastUpdate();

        if (rewardsVaultAvailableBalance < currentAccruedRewards) {
            revert InsufficientRewardsVaultBalance();
        }

        uint256 availableRewards = rewardsVaultAvailableBalance - currentAccruedRewards;
        uint256 newRewardRate = availableRewards / rewardsDuration;
        if (newRewardRate > MAX_REWARD_RATE) {
            revert RewardRateTooHigh();
        }
        rewardRate = newRewardRate;

        emit RewardRateSet(previousRewardRate, rewardRate);
    }

    /// @dev Internal function to handle upgrades, only callable by the owner.
    /// @param newImplementation The address of the new implementation.
    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {}
}
