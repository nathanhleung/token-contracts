// SPDX-License-Identifier: MIT
pragma solidity =0.8.26;

import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Test, console} from "forge-std/Test.sol";
import {CalderaStaking} from "../src/CalderaStaking.sol";
import {CalderaToken} from "../src/CalderaToken.sol";

contract CalderaStakingTest is Test {
    CalderaStaking public staking;
    CalderaToken public token;

    address public owner;
    address public user1;
    address public user2;
    address public user3;
    address public rewardsVault;
    address public stakeForSenderAddress;

    uint256 public stakeLockupPeriod = 90 days;
    uint256 public withdrawalRequestCooldownPeriod = 7 days;
    uint256 public minimumStakeAmount = 1 ether;
    uint256 public rewardsEndTimestamp;

    uint256 public constant INITIAL_SUPPLY = 1_000_000 ether;
    uint256 public constant LOCKED_SUPPLY = 1_000_000 ether;
    uint256 public constant STAKE_AMOUNT = 1000 ether;
    uint256 public constant REWARD_AMOUNT = INITIAL_SUPPLY / 10;
    uint256 public constant REWARD_RATE = 1 ether; // 1 token per second for easy math

    function getStake(address user, uint256 index) internal view returns (CalderaStaking.Stake memory) {
        (
            uint256 amount,
            uint256 depositedTimestamp,
            uint256 lockedUntilTimestamp,
            uint256 rewardPerTokenPaid,
            uint256 reward
        ) = staking.stakes(user, index);
        return CalderaStaking.Stake(amount, depositedTimestamp, lockedUntilTimestamp, rewardPerTokenPaid, reward);
    }

    function getWithdrawalRequest(address user, uint256 index)
        internal
        view
        returns (CalderaStaking.WithdrawalRequest memory)
    {
        (uint256 amount, uint256 requestedTimestamp, uint256 cooldownPeriodEndTimestamp) =
            staking.withdrawalRequests(user, index);
        return CalderaStaking.WithdrawalRequest(amount, requestedTimestamp, cooldownPeriodEndTimestamp);
    }

    function setUp() public {
        owner = address(this);
        user1 = address(0x1);
        user2 = address(0x2);
        user3 = address(0x3);
        rewardsVault = address(0x4);
        stakeForSenderAddress = address(0x5);
        rewardsEndTimestamp = block.timestamp + 365 days;

        // Deploy token
        CalderaToken tokenImpl = new CalderaToken();
        ERC1967Proxy tokenProxy = new ERC1967Proxy(
            address(tokenImpl),
            abi.encodeWithSelector(
                CalderaToken.reinitialize.selector, "Test Token", "TEST", owner, INITIAL_SUPPLY, LOCKED_SUPPLY
            )
        );
        token = CalderaToken(address(tokenProxy));

        // Distribute tokens
        token.transfer(user1, INITIAL_SUPPLY / 10);
        token.transfer(user2, INITIAL_SUPPLY / 10);
        token.transfer(user3, INITIAL_SUPPLY / 10);
        token.transfer(rewardsVault, REWARD_AMOUNT);
        token.transfer(stakeForSenderAddress, INITIAL_SUPPLY / 10);

        // Deploy staking contract
        CalderaStaking stakingImpl = new CalderaStaking();
        ERC1967Proxy stakingProxy = new ERC1967Proxy(address(stakingImpl), "");
        staking = CalderaStaking(address(stakingProxy));
        staking.initialize(
            owner,
            address(token),
            rewardsVault,
            stakeForSenderAddress,
            stakeLockupPeriod,
            minimumStakeAmount,
            withdrawalRequestCooldownPeriod,
            rewardsEndTimestamp
        );

        // Approvals
        vm.prank(rewardsVault);
        token.approve(address(staking), type(uint256).max);

        vm.prank(stakeForSenderAddress);
        token.approve(address(staking), type(uint256).max);

        staking.dangerouslySetRewardRate(REWARD_RATE, true);
    }

    function testInitialization() public view {
        assertEq(staking.token(), address(token));
        assertEq(staking.rewardsVault(), rewardsVault);
        assertEq(staking.stakeForSenderAddress(), stakeForSenderAddress);
        assertEq(staking.stakeLockupPeriod(), stakeLockupPeriod);
        assertEq(staking.minimumStakeAmount(), minimumStakeAmount);
        assertEq(staking.withdrawalRequestCooldownPeriod(), withdrawalRequestCooldownPeriod);
        assertEq(staking.rewardsEndTimestamp(), rewardsEndTimestamp);
        assertEq(staking.totalStaked(), 0);
        assertEq(staking.totalRequestedWithdrawals(), 0);
        assertEq(staking.accruedRewards(), 0);
        assertEq(staking.rewardRate(), REWARD_RATE);
    }

    function testCannotInitializeWithZeroOwner() public {
        CalderaStaking stakingImpl = new CalderaStaking();
        ERC1967Proxy stakingProxy = new ERC1967Proxy(address(stakingImpl), "");
        CalderaStaking newStaking = CalderaStaking(address(stakingProxy));

        vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableInvalidOwner.selector, address(0)));
        newStaking.initialize(
            address(0),
            address(token),
            rewardsVault,
            stakeForSenderAddress,
            stakeLockupPeriod,
            minimumStakeAmount,
            withdrawalRequestCooldownPeriod,
            rewardsEndTimestamp
        );
    }

    function testCannotInitializeWithZeroToken() public {
        CalderaStaking stakingImpl = new CalderaStaking();
        ERC1967Proxy stakingProxy = new ERC1967Proxy(address(stakingImpl), "");
        CalderaStaking newStaking = CalderaStaking(address(stakingProxy));

        vm.expectRevert(CalderaStaking.InvalidToken.selector);
        newStaking.initialize(
            owner,
            address(0),
            rewardsVault,
            stakeForSenderAddress,
            stakeLockupPeriod,
            minimumStakeAmount,
            withdrawalRequestCooldownPeriod,
            rewardsEndTimestamp
        );
    }

    function testCannotInitializeWithZeroRewardsVault() public {
        CalderaStaking stakingImpl = new CalderaStaking();
        ERC1967Proxy stakingProxy = new ERC1967Proxy(address(stakingImpl), "");
        CalderaStaking newStaking = CalderaStaking(address(stakingProxy));

        vm.expectRevert(CalderaStaking.InvalidRewardsVault.selector);
        newStaking.initialize(
            owner,
            address(token),
            address(0),
            stakeForSenderAddress,
            stakeLockupPeriod,
            minimumStakeAmount,
            withdrawalRequestCooldownPeriod,
            rewardsEndTimestamp
        );
    }

    function testCannotInitializeWithZeroStakeLockupPeriod() public {
        CalderaStaking stakingImpl = new CalderaStaking();
        ERC1967Proxy stakingProxy = new ERC1967Proxy(address(stakingImpl), "");
        CalderaStaking newStaking = CalderaStaking(address(stakingProxy));

        vm.expectRevert(CalderaStaking.InvalidStakeLockupPeriod.selector);
        newStaking.initialize(
            owner,
            address(token),
            rewardsVault,
            stakeForSenderAddress,
            0,
            minimumStakeAmount,
            withdrawalRequestCooldownPeriod,
            rewardsEndTimestamp
        );
    }

    function testCannotInitializeWithZeroMinimumStakeAmount() public {
        CalderaStaking stakingImpl = new CalderaStaking();
        ERC1967Proxy stakingProxy = new ERC1967Proxy(address(stakingImpl), "");
        CalderaStaking newStaking = CalderaStaking(address(stakingProxy));

        vm.expectRevert(CalderaStaking.InvalidMinimumStakeAmount.selector);
        newStaking.initialize(
            owner,
            address(token),
            rewardsVault,
            stakeForSenderAddress,
            stakeLockupPeriod,
            0,
            withdrawalRequestCooldownPeriod,
            rewardsEndTimestamp
        );
    }

    function testCannotInitializeWithZeroWithdrawalRequestCooldownPeriod() public {
        CalderaStaking stakingImpl = new CalderaStaking();
        ERC1967Proxy stakingProxy = new ERC1967Proxy(address(stakingImpl), "");
        CalderaStaking newStaking = CalderaStaking(address(stakingProxy));

        vm.expectRevert(CalderaStaking.InvalidWithdrawalRequestCooldownPeriod.selector);
        newStaking.initialize(
            owner,
            address(token),
            rewardsVault,
            stakeForSenderAddress,
            stakeLockupPeriod,
            minimumStakeAmount,
            0,
            rewardsEndTimestamp
        );
    }

    function testCannotInitializeWithPastRewardsEndTimestamp() public {
        CalderaStaking stakingImpl = new CalderaStaking();
        ERC1967Proxy stakingProxy = new ERC1967Proxy(address(stakingImpl), "");
        CalderaStaking newStaking = CalderaStaking(address(stakingProxy));

        vm.expectRevert(CalderaStaking.InvalidRewardsEndTimestamp.selector);
        newStaking.initialize(
            owner,
            address(token),
            rewardsVault,
            stakeForSenderAddress,
            stakeLockupPeriod,
            minimumStakeAmount,
            withdrawalRequestCooldownPeriod,
            block.timestamp - 1
        );
    }

    function testBasicStake() public {
        vm.startPrank(user1);
        token.approve(address(staking), STAKE_AMOUNT);

        vm.expectEmit(true, true, true, true);
        emit CalderaStaking.Staked(user1, STAKE_AMOUNT);
        staking.stake(STAKE_AMOUNT);
        vm.stopPrank();

        assertEq(staking.totalStaked(), STAKE_AMOUNT);
        assertEq(staking.getUserTotalStakeAmount(user1), STAKE_AMOUNT);

        CalderaStaking.Stake memory userStake = getStake(user1, 0);
        assertEq(userStake.amount, STAKE_AMOUNT);
        assertEq(userStake.depositedTimestamp, block.timestamp);
        assertEq(userStake.lockedUntilTimestamp, block.timestamp + stakeLockupPeriod);
    }

    function testStakeFor() public {
        vm.startPrank(stakeForSenderAddress);
        token.approve(address(staking), STAKE_AMOUNT);
        vm.expectEmit(true, true, true, true);
        emit CalderaStaking.StakedFor(stakeForSenderAddress, user1, STAKE_AMOUNT);
        staking.stakeFor(user1, STAKE_AMOUNT);
        vm.stopPrank();

        assertEq(staking.totalStaked(), STAKE_AMOUNT);
        assertEq(staking.getUserTotalStakeAmount(user1), STAKE_AMOUNT);
    }

    function testStakeForUnauthorized() public {
        vm.startPrank(user1);
        token.approve(address(staking), STAKE_AMOUNT);
        vm.expectRevert(CalderaStaking.UnauthorizedStakeForSender.selector);
        staking.stakeFor(user2, STAKE_AMOUNT);
        vm.stopPrank();
    }

    function testStakeForTooSmall() public {
        vm.startPrank(stakeForSenderAddress);
        token.approve(address(staking), minimumStakeAmount - 1);
        vm.expectRevert(CalderaStaking.StakeAmountTooSmall.selector);
        staking.stakeFor(user1, minimumStakeAmount - 1);
        vm.stopPrank();
    }

    function testStakeForBadBeneficiary() public {
        vm.startPrank(stakeForSenderAddress);
        token.approve(address(staking), STAKE_AMOUNT);
        vm.expectRevert(CalderaStaking.InvalidStakeForBeneficiary.selector);
        staking.stakeFor(address(0), STAKE_AMOUNT);
        vm.stopPrank();
    }

    function testBasicUnstakeAndWithdraw() public {
        // Stake
        vm.startPrank(user1);
        token.approve(address(staking), STAKE_AMOUNT);
        staking.stake(STAKE_AMOUNT);
        assertEq(staking.getUserStakeCount(user1), 1);
        vm.stopPrank();

        // Fast forward past lockup period
        vm.warp(block.timestamp + stakeLockupPeriod + 1);

        // Unstake
        vm.startPrank(user1);
        vm.expectEmit(true, true, true, true);
        emit CalderaStaking.Unstaked(user1, STAKE_AMOUNT);
        staking.unstake(STAKE_AMOUNT);

        // Verify withdrawal request created
        assertEq(staking.totalRequestedWithdrawals(), STAKE_AMOUNT);
        assertEq(staking.getUserWithdrawalRequestCount(user1), 1);
        CalderaStaking.WithdrawalRequest memory request = getWithdrawalRequest(user1, 0);
        assertEq(request.amount, STAKE_AMOUNT);
        assertEq(request.requestedTimestamp, block.timestamp);
        assertEq(request.cooldownPeriodEndTimestamp, block.timestamp + withdrawalRequestCooldownPeriod);

        // Fast forward past cooldown period
        vm.warp(block.timestamp + withdrawalRequestCooldownPeriod + 1);

        // Withdraw
        uint256 balanceBefore = token.balanceOf(user1);
        vm.expectEmit(true, true, true, true);
        emit CalderaStaking.Withdrawn(user1, STAKE_AMOUNT);
        staking.withdraw(STAKE_AMOUNT);
        vm.stopPrank();

        // Verify tokens returned and state updated
        assertEq(token.balanceOf(user1), balanceBefore + STAKE_AMOUNT);
        assertEq(staking.totalRequestedWithdrawals(), 0);
        assertEq(staking.getUserWithdrawalRequestCount(user1), 0);
    }

    function testRewardCalculation() public {
        staking.setStakeLockupPeriod(99);

        // User1 stakes
        vm.startPrank(user1);
        token.approve(address(staking), STAKE_AMOUNT);
        staking.stake(STAKE_AMOUNT);
        vm.stopPrank();

        // Fast forward 100 seconds
        vm.warp(block.timestamp + 100);

        // With a reward rate of 10 tokens/second, should earn 1000 tokens
        uint256 expectedReward = REWARD_RATE * 100;
        assertEq(staking.earned(getStake(user1, 0)), expectedReward);

        // Claim rewards
        vm.startPrank(user1);
        uint256 balanceBefore = token.balanceOf(user1);
        staking.getReward();
        vm.stopPrank();

        assertEq(token.balanceOf(user1), balanceBefore + expectedReward);
        assertEq(staking.accruedRewards(), 0);
    }

    function testMultipleStakesWithDifferentTimings() public {
        // User1 stakes first
        vm.startPrank(user1);
        token.approve(address(staking), STAKE_AMOUNT * 2);
        staking.stake(STAKE_AMOUNT);
        vm.stopPrank();

        // Fast forward 50 seconds
        vm.warp(block.timestamp + 50);

        // User2 stakes
        vm.startPrank(user2);
        token.approve(address(staking), STAKE_AMOUNT);
        staking.stake(STAKE_AMOUNT);
        vm.stopPrank();

        // Fast forward 50 more seconds
        vm.warp(block.timestamp + 50);
        // User1 stakes again
        vm.startPrank(user1);
        staking.stake(STAKE_AMOUNT);
        vm.stopPrank();

        // Verify rewards:
        // User1 first stake: 1 tokens/s * 50s + 1 tokens/s * 50s * 1000/2000 = 75 tokens
        // User1 second stake: 0 tokens (just staked)
        // User2: 1 tokens/s * 50s * 1000/2000 = 25 tokens
        assertEq(staking.earned(getStake(user1, 0)), 75 ether);
        assertEq(staking.earned(getStake(user1, 1)), 0);
        assertEq(staking.earned(getStake(user2, 0)), 25 ether);
    }

    function testUnstakeMultipleStakes() public {
        // Create multiple stakes with different amounts
        vm.startPrank(user1);
        token.approve(address(staking), STAKE_AMOUNT * 4);
        staking.stake(STAKE_AMOUNT);
        vm.warp(block.timestamp + 2 minutes);
        staking.stake(STAKE_AMOUNT * 2);
        vm.warp(block.timestamp + 2 minutes);
        staking.stake(STAKE_AMOUNT);
        vm.stopPrank();

        assertEq(staking.getUserTotalStakeAmount(user1), STAKE_AMOUNT * 4);

        // Fast forward past lockup period
        vm.warp(block.timestamp + stakeLockupPeriod + 1);

        // Unstake more than one stake's worth
        vm.startPrank(user1);
        staking.unstake(STAKE_AMOUNT * 3);
        vm.stopPrank();

        // Should have 1 stake left
        assertEq(staking.getUserTotalStakeAmount(user1), STAKE_AMOUNT);
        assertEq(staking.totalRequestedWithdrawals(), STAKE_AMOUNT * 3);
    }

    function testMaxStakesLimit() public {
        vm.startPrank(user1);
        token.approve(address(staking), STAKE_AMOUNT * 101);

        // Create MAX_STAKES_COUNT stakes
        for (uint256 i = 0; i < staking.MAX_STAKES_COUNT(); i++) {
            staking.stake(STAKE_AMOUNT);
            vm.warp(block.timestamp + 2 minutes);
        }

        // Adding one more should fail
        vm.expectRevert(CalderaStaking.TooManyStakes.selector);
        staking.stake(STAKE_AMOUNT);
        vm.stopPrank();

        // Test stakeFor with max stakes
        vm.startPrank(owner);
        staking.setStakeForSenderAddress(address(this));
        token.approve(address(staking), STAKE_AMOUNT * 101);

        // Adding one more should fail
        vm.expectRevert(CalderaStaking.TooManyStakes.selector);
        staking.stakeFor(user1, STAKE_AMOUNT);
        vm.stopPrank();
    }

    function testStakingTooFast() public {
        vm.startPrank(user1);
        token.approve(address(staking), STAKE_AMOUNT * 2);

        // First stake should succeed
        staking.stake(STAKE_AMOUNT);

        // Second stake within 1 minute should fail
        vm.expectRevert(CalderaStaking.TooManyStakes.selector);
        staking.stake(STAKE_AMOUNT);

        // Fast forward 30 seconds (still under 1 minute)
        vm.warp(block.timestamp + 30);
        vm.expectRevert(CalderaStaking.TooManyStakes.selector);
        staking.stake(STAKE_AMOUNT);

        // Fast forward to just over 1 minute
        vm.warp(block.timestamp + 31);

        // Now stake should succeed
        staking.stake(STAKE_AMOUNT);

        vm.stopPrank();
    }

    function testMaxWithdrawalRequestsLimit() public {
        // Create multiple small stakes
        vm.startPrank(user1);
        token.approve(address(staking), 2 * minimumStakeAmount * staking.MAX_WITHDRAWAL_REQUESTS_COUNT());

        uint256 startTimestamp = block.timestamp;
        for (uint256 i = 0; i < staking.MAX_WITHDRAWAL_REQUESTS_COUNT(); i++) {
            vm.warp(startTimestamp + 2 * i * 60);
            staking.stake(2 * minimumStakeAmount);
        }
        vm.stopPrank();

        // Fast forward past lockup
        vm.startPrank(user1);
        vm.warp(startTimestamp + 2 * staking.MAX_WITHDRAWAL_REQUESTS_COUNT() * 60 + stakeLockupPeriod + 1);

        // Create MAX_WITHDRAWAL_REQUESTS_COUNT withdrawal requests
        for (uint256 i = 0; i < staking.MAX_WITHDRAWAL_REQUESTS_COUNT(); i++) {
            vm.warp(block.timestamp + 2 minutes);
            staking.unstake(minimumStakeAmount);
        }

        // One more should fail
        vm.expectRevert(CalderaStaking.TooManyWithdrawalRequests.selector);
        staking.unstake(minimumStakeAmount);
        vm.stopPrank();
    }

    function testWithdrawTooFast() public {
        // Initial stake
        vm.startPrank(user1);
        token.approve(address(staking), STAKE_AMOUNT * 2);
        staking.stake(STAKE_AMOUNT);

        // Fast forward past lockup period
        vm.warp(block.timestamp + stakeLockupPeriod + 1);

        // First withdrawal request should succeed
        staking.unstake(STAKE_AMOUNT / 2);

        // Second withdrawal request within 1 minute should fail
        vm.expectRevert(CalderaStaking.TooManyWithdrawalRequests.selector);
        staking.unstake(STAKE_AMOUNT / 2);

        // Fast forward 30 seconds (still under 1 minute)
        vm.warp(block.timestamp + 30);
        vm.expectRevert(CalderaStaking.TooManyWithdrawalRequests.selector);
        staking.unstake(STAKE_AMOUNT / 2);

        // Fast forward to just over 1 minute
        vm.warp(block.timestamp + 31);

        // Now withdrawal request should succeed
        staking.unstake(STAKE_AMOUNT / 2);

        vm.stopPrank();
    }

    function testInsufficientWithdrawableAmount() public {
        vm.startPrank(user1);
        vm.expectRevert(CalderaStaking.InsufficientWithdrawableAmount.selector);
        staking.withdraw(STAKE_AMOUNT);
        vm.stopPrank();
    }

    function testAccountingWithMultipleUsers() public {
        // Initial stakes from multiple users
        vm.startPrank(user1);
        token.approve(address(staking), STAKE_AMOUNT * 3);

        staking.stake(STAKE_AMOUNT);

        vm.warp(block.timestamp + 61); // Add 61 more seconds to ensure at least 1 minute between stakes
        staking.stake(STAKE_AMOUNT * 2);

        vm.stopPrank();

        vm.startPrank(user2);
        token.approve(address(staking), STAKE_AMOUNT * 2);
        staking.stake(STAKE_AMOUNT * 2);
        vm.stopPrank();
        // Verify initial state
        assertEq(staking.totalStaked(), STAKE_AMOUNT * 5, "Initial `totalStaked` should be 5");
        assertEq(staking.getUserTotalStakeAmount(user1), STAKE_AMOUNT * 3, "user1 should initially have 3 staked");
        assertEq(staking.getUserTotalStakeAmount(user2), STAKE_AMOUNT * 2, "user2 should initially have 2 staked");
        assertEq(staking.totalRequestedWithdrawals(), 0, "Initial `totalRequestedWithdrawals` should be 0");

        // Fast forward past lockup and do partial unstaking
        vm.warp(block.timestamp + stakeLockupPeriod + 1);

        vm.prank(user1);
        staking.unstake(STAKE_AMOUNT * 2);

        // Verify state after unstaking
        assertEq(staking.totalStaked(), STAKE_AMOUNT * 3, "After `user1` unstakes, `totalStaked` should be 3");
        assertEq(
            staking.totalRequestedWithdrawals(),
            STAKE_AMOUNT * 2,
            "After `user1` unstakes, `totalRequestedWithdrawals` should be 2"
        );

        // Fast forward halfway through cooldown and unstake more
        vm.warp(block.timestamp + withdrawalRequestCooldownPeriod / 2);

        vm.startPrank(user2);
        staking.unstake(STAKE_AMOUNT);
        vm.stopPrank();

        // Verify combined withdrawal requests
        assertEq(
            staking.totalRequestedWithdrawals(),
            STAKE_AMOUNT * 3,
            "After `user2` unstakes, `totalRequestedWithdrawals` should be 3"
        );

        // Complete cooldown and withdraw
        vm.warp(block.timestamp + (withdrawalRequestCooldownPeriod / 2) + 1);

        vm.prank(user1);
        staking.withdraw(STAKE_AMOUNT * 2);

        // Final state verification
        assertEq(staking.totalStaked(), STAKE_AMOUNT * 2, "At the end, `totalStaked` should be 2");
        assertEq(
            staking.totalRequestedWithdrawals(), STAKE_AMOUNT, "At the end, `totalRequestedWithdrawals` should be 1"
        );
        assertEq(staking.getUserTotalStakeAmount(user1), STAKE_AMOUNT, "At the end, `user1` should have 1 stake left");
    }

    function testRewardAccountingWithVaryingStakes() public {
        staking.setStakeLockupPeriod(10);

        // Stake 1000 tokens with user1
        vm.startPrank(user1);
        token.approve(address(staking), STAKE_AMOUNT);
        staking.stake(STAKE_AMOUNT);
        vm.stopPrank();

        // Fast forward 10 seconds
        vm.warp(block.timestamp + 10);

        // By this point, `updateReward` has never been called, so accruedRewards should be 0
        assertEq(staking.accruedRewards(), 0);

        // Stake 3000 tokens with user2
        vm.startPrank(user2);
        token.approve(address(staking), STAKE_AMOUNT * 3);
        staking.stake(STAKE_AMOUNT * 3);
        vm.stopPrank();

        // Fast forward 10 more seconds
        vm.warp(block.timestamp + 10);

        // Calculate expected rewards:
        // User1: 10s * 1 token/s = 10 tokens (solo period)
        //      + 10s * 1 token/s * 1000/4000 = 2.5 tokens (shared period)
        //      = 12.5 tokens total
        // User2: 10s * 1 token/s * 3000/4000 = 7.5 tokens (shared period only)

        // Accrued rewards will only have `user1`'s rewards up to `user2`'s
        // most recent stake, since `updateReward` hasn't been called since
        assertEq(staking.accruedRewards(), 10 ether);

        assertEq(staking.earned(getStake(user1, 0)), 12.5 ether);
        assertEq(staking.earned(getStake(user2, 0)), 7.5 ether);

        // Both claim rewards
        vm.prank(user1);
        staking.getReward();

        // Accrued rewards should be whatever user2 has left over
        assertEq(staking.accruedRewards(), 7.5 ether);

        vm.prank(user2);
        staking.getReward();

        assertEq(staking.accruedRewards(), 0);

        // Fast forward and verify rewards reset
        vm.warp(block.timestamp + 10);

        // New rewards since last claim:
        // User1: 10s * 1 token/s * 1000/4000 = 2.5 tokens
        // User2: 10s * 1 token/s * 3000/4000 = 7.5 tokens
        assertEq(staking.earned(getStake(user1, 0)), 2.5 ether);
        assertEq(staking.earned(getStake(user2, 0)), 7.5 ether);
    }

    function testRewardsAfterStakeUnstake() public {
        staking.setStakeLockupPeriod(10);
        staking.setWithdrawalRequestCooldownPeriod(10);

        // User1 stakes
        vm.startPrank(user1);
        token.approve(address(staking), STAKE_AMOUNT * 2);
        staking.stake(STAKE_AMOUNT);
        vm.stopPrank();

        // Fast forward 10 seconds
        vm.warp(block.timestamp + 10);

        // By this point, `updateReward` has never been called, so accruedRewards should be 0
        assertEq(staking.accruedRewards(), 0);

        // User1 stakes more
        vm.startPrank(user1);
        vm.warp(block.timestamp + 2 minutes);
        staking.stake(STAKE_AMOUNT);
        vm.stopPrank();

        // Accrued rewards as of last `updateReward` call should be 130 *
        // 1 token/s = 130 tokens
        assertEq(staking.accruedRewards(), 130 ether);

        // Fast forward past lockup
        vm.warp(block.timestamp + staking.stakeLockupPeriod() + 1);

        // User1 unstakes first stake
        vm.prank(user1);
        staking.unstake(STAKE_AMOUNT);

        // Fast forward 10 more seconds
        vm.warp(block.timestamp + 10);

        // Should still accrue rewards on remaining stake
        uint256 reward = staking.earned(getStake(user1, 0));
        assertGt(reward, 0);

        // Fast forward past cooldown
        vm.warp(block.timestamp + staking.withdrawalRequestCooldownPeriod() + 1);

        // Withdraw
        vm.prank(user1);
        staking.withdraw(STAKE_AMOUNT);
        assertEq(staking.getUserTotalStakeAmount(user1), STAKE_AMOUNT);

        // Fast forward 10 more seconds
        vm.warp(block.timestamp + 10);

        // Should still accrue rewards on remaining stake
        uint256 newReward = staking.earned(getStake(user1, 0));
        assertGt(newReward, reward);

        // Unstake all, test that rewards still remain
        uint256 remainingAmount = staking.getUserTotalStakeAmount(user1);
        vm.prank(user1);
        staking.unstake(remainingAmount);
        assertEq(staking.getUserStakeCount(user1), 1);
        assertEq(staking.getUserTotalStakeAmount(user1), 0);
        assertEq(staking.earned(getStake(user1, 0)), newReward);

        // Rewards should not accrue after unstaking
        vm.warp(block.timestamp + 10);
        assertEq(staking.earned(getStake(user1, 0)), newReward);
        assertEq(staking.accruedRewards(), newReward);

        // After rewards withdrawn, everything should be cleaned
        vm.prank(user1);
        staking.getReward();
        assertEq(staking.getUserStakeCount(user1), 0);
        assertEq(staking.accruedRewards(), 0);
        assertEq(staking.getUserTotalStakeAmount(user1), 0);
    }

    function testMinimumStakeAmount() public {
        vm.startPrank(user1);
        token.approve(address(staking), minimumStakeAmount);

        // Stake minimum amount
        staking.stake(minimumStakeAmount);

        // Try to stake less than minimum
        token.approve(address(staking), minimumStakeAmount - 1);
        vm.expectRevert(CalderaStaking.StakeAmountTooSmall.selector);
        staking.stake(minimumStakeAmount - 1);
        vm.stopPrank();
    }

    function testMinimumWithdraw() public {
        // User1 stakes
        vm.startPrank(user1);
        token.approve(address(staking), STAKE_AMOUNT);
        staking.stake(STAKE_AMOUNT);
        vm.stopPrank();

        // Fast forward past lockup period
        vm.warp(block.timestamp + stakeLockupPeriod);

        // Try to unstake less than minimum
        vm.prank(user1);
        vm.expectRevert(CalderaStaking.UnstakeAmountTooSmall.selector);
        staking.unstake(minimumStakeAmount - 1);

        // Unstake minimum amount
        vm.prank(user1);
        staking.unstake(minimumStakeAmount);

        // Fast forward past cooldown
        vm.warp(block.timestamp + withdrawalRequestCooldownPeriod);

        // Try to withdraw less than minimum
        vm.prank(user1);
        vm.expectRevert(CalderaStaking.WithdrawAmountTooSmall.selector);
        staking.withdraw(minimumStakeAmount - 1);

        // Withdraw minimum amount should succeed
        vm.prank(user1);
        staking.withdraw(minimumStakeAmount);
    }

    function testRewardsAfterPause() public {
        // User1 stakes
        vm.startPrank(user1);
        token.approve(address(staking), STAKE_AMOUNT);
        staking.stake(STAKE_AMOUNT);
        vm.stopPrank();

        // Fast forward 10 seconds
        vm.warp(block.timestamp + 10);

        // Pause contract
        staking.pause();

        // Try to stake while paused
        vm.startPrank(user1);
        token.approve(address(staking), STAKE_AMOUNT);
        vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
        staking.stake(STAKE_AMOUNT);
        vm.stopPrank();

        // Fast forward 10 more seconds
        vm.warp(block.timestamp + 10);

        // Unpause
        staking.unpause();

        // Rewards should keep accruing even during pause
        assertEq(staking.earned(getStake(user1, 0)), REWARD_RATE * 20);
    }

    function testRewardsVaultDepletion() public {
        // User1 stakes
        vm.startPrank(user1);
        token.approve(address(staking), STAKE_AMOUNT);
        staking.stake(STAKE_AMOUNT);
        vm.stopPrank();

        // Empty the rewards vault
        vm.startPrank(rewardsVault);
        token.transfer(address(0x999), token.balanceOf(rewardsVault));
        vm.stopPrank();

        // Fast forward
        vm.warp(block.timestamp + stakeLockupPeriod + 1);

        // Should still calculate rewards correctly
        assertEq(staking.earned(getStake(user1, 0)), REWARD_RATE * (stakeLockupPeriod + 1));

        // But claiming should fail due to insufficient balance
        vm.startPrank(user1);
        vm.expectRevert(CalderaStaking.InsufficientRewardsVaultBalance.selector);
        staking.getReward();
        vm.stopPrank();
    }

    function testNoRewardsAfterEndTimestamp() public {
        // User1 stakes
        vm.startPrank(user1);
        token.approve(address(staking), STAKE_AMOUNT);
        staking.stake(STAKE_AMOUNT);
        vm.stopPrank();

        // Fast forward to just before rewards end
        vm.warp(rewardsEndTimestamp);
        uint256 rewardsBefore = staking.getUserTotalRewardAmount(user1);
        assertGt(rewardsBefore, 0);

        // Fast forward past rewards end
        vm.warp(rewardsEndTimestamp + 100);

        // No additional rewards after end timestamp
        assertEq(staking.getUserTotalRewardAmount(user1), rewardsBefore);
    }

    function testUnstakeWithExactBalance() public {
        // Create 3 stakes with exact amounts
        vm.startPrank(user1);
        token.approve(address(staking), STAKE_AMOUNT * 3);
        staking.stake(STAKE_AMOUNT); // stake 0

        vm.warp(block.timestamp + 2 minutes);
        staking.stake(STAKE_AMOUNT); // stake 1
        CalderaStaking.Stake memory oldStake1 = getStake(user1, 1);

        vm.warp(block.timestamp + 2 minutes);
        staking.stake(STAKE_AMOUNT); // stake 2
        CalderaStaking.Stake memory oldStake2 = getStake(user1, 2);
        vm.stopPrank();

        // Fast forward past lockup
        vm.warp(block.timestamp + stakeLockupPeriod + 1);

        // Unstake exact amount of stake 1
        vm.prank(user1);
        staking.unstake(STAKE_AMOUNT);

        // Check that stake0 was cleaned up
        assertEq(staking.getUserStakeCount(user1), 2);

        CalderaStaking.Stake memory stake0 = getStake(user1, 0);
        assertEq(stake0.amount, STAKE_AMOUNT);
        assertEq(stake0.depositedTimestamp, oldStake1.depositedTimestamp);

        CalderaStaking.Stake memory stake1 = getStake(user1, 1);
        assertEq(stake1.amount, STAKE_AMOUNT);
        assertEq(stake1.depositedTimestamp, oldStake2.depositedTimestamp);
    }

    function testPartialUnstakeWithMultipleStakes() public {
        // Create 2 stakes with different amounts
        vm.startPrank(user1);
        token.approve(address(staking), STAKE_AMOUNT * 3);
        staking.stake(STAKE_AMOUNT); // stake 0
        vm.warp(block.timestamp + 2 minutes);
        staking.stake(STAKE_AMOUNT * 2); // stake 1
        vm.stopPrank();

        // Fast forward past lockup
        vm.warp(block.timestamp + stakeLockupPeriod + 1);

        // Unstake partial amount from first stake
        vm.prank(user1);
        staking.unstake(STAKE_AMOUNT / 2);

        // Check that first stake was reduced by half
        CalderaStaking.Stake memory stake0 = getStake(user1, 0);
        assertEq(stake0.amount, STAKE_AMOUNT / 2);

        CalderaStaking.Stake memory stake1 = getStake(user1, 1);
        assertEq(stake1.amount, STAKE_AMOUNT * 2);
    }

    function testStakesCleanup() public {
        staking.setStakeLockupPeriod(10);

        // Create 3 stakes
        vm.startPrank(user1);
        token.approve(address(staking), STAKE_AMOUNT * 3);
        staking.stake(STAKE_AMOUNT);
        vm.warp(block.timestamp + 2 minutes);
        staking.stake(STAKE_AMOUNT);
        vm.warp(block.timestamp + 2 minutes);
        staking.stake(STAKE_AMOUNT);

        // Fast forward past lockup
        vm.warp(block.timestamp + 6 minutes + 10 + 1);

        // Unstake all
        staking.unstake(STAKE_AMOUNT * 3);

        // Fast forward past cooldown
        vm.warp(block.timestamp + withdrawalRequestCooldownPeriod + 1);

        // Withdraw
        staking.withdraw(STAKE_AMOUNT * 3);
        staking.getReward();
        vm.stopPrank();

        // Check that all stakes were cleaned up
        uint256 stakesCount = 0;
        try staking.stakes(user1, 0) returns (uint256, uint256, uint256, uint256, uint256) {
            stakesCount++;
        } catch {}

        try staking.stakes(user1, 1) returns (uint256, uint256, uint256, uint256, uint256) {
            stakesCount++;
        } catch {}

        try staking.stakes(user1, 2) returns (uint256, uint256, uint256, uint256, uint256) {
            stakesCount++;
        } catch {}

        assertEq(stakesCount, 0);
    }

    function testWithdrawalRequestsCleanup() public {
        staking.setStakeLockupPeriod(10);

        // Create stake
        vm.startPrank(user1);
        token.approve(address(staking), STAKE_AMOUNT);
        staking.stake(STAKE_AMOUNT);
        vm.stopPrank();

        // Fast forward past lockup
        vm.warp(block.timestamp + 10 + 1);

        // Unstake
        vm.prank(user1);
        staking.unstake(STAKE_AMOUNT);

        // Fast forward past cooldown
        vm.warp(block.timestamp + withdrawalRequestCooldownPeriod + 1);

        // Withdraw
        vm.prank(user1);
        staking.withdraw(STAKE_AMOUNT);

        // Check that withdrawal request was cleaned up
        assertEq(staking.getUserWithdrawalRequestCount(user1), 0);
    }

    function testRaceConditionOnUnstake() public {
        // User1 stakes
        vm.startPrank(user1);
        token.approve(address(staking), STAKE_AMOUNT);
        staking.stake(STAKE_AMOUNT);
        vm.stopPrank();

        // Fast forward past lockup
        vm.warp(block.timestamp + stakeLockupPeriod + 1);

        // User1 and user2 try to unstake user1's stake at the same time
        // (this simulates a race condition)
        vm.prank(user1);
        staking.unstake(STAKE_AMOUNT);

        // User2 shouldn't be able to unstake user1's stake
        vm.prank(user2);
        vm.expectRevert(CalderaStaking.InsufficientUnlockedStake.selector);
        staking.unstake(STAKE_AMOUNT);
    }

    function testSyncRewardRateWithoutAccruedRewards() public {
        staking.syncRewardRate(1e18);

        // User1 stakes
        vm.startPrank(user1);
        token.approve(address(staking), STAKE_AMOUNT);
        staking.stake(STAKE_AMOUNT);
        vm.stopPrank();

        assertApproxEqRel(
            staking.rewardRate(),
            REWARD_AMOUNT / 365 days,
            0.0001e18 // Only allow 0.01% error
        );

        // Fast forward 10 seconds
        vm.warp(block.timestamp + 10);
        assertApproxEqRel(
            staking.earned(getStake(user1, 0)),
            10 * REWARD_AMOUNT / 365 days,
            0.0001e18 // Only allow 0.01% error
        );
    }

    function testSyncRewardRateWithAccruedRewards() public {
        staking.dangerouslySetRewardRate(REWARD_RATE, true);
        staking.setRewardsEndTimestamp(block.timestamp + 1_000_000, false);

        // User1 stakes
        vm.startPrank(user1);
        token.approve(address(staking), STAKE_AMOUNT);
        staking.stake(STAKE_AMOUNT);
        vm.stopPrank();

        // Fast forward 1_000 seconds to accrue rewards
        vm.warp(block.timestamp + 1_000);

        // User has earned but not claimed 1_000 tokens (1 token/s * 1_000s)
        assertEq(staking.getUserTotalRewardAmount(user1), 1000 ether);
        // Accrued rewards since last update should still be 0
        assertEq(staking.accruedRewards(), 0);
        staking.syncRewardRate(1e18);

        // Reward rate should be reduced by the accrued rewards, 1_000 tokens,
        // then divided by the remaining time.
        assertEq(staking.rewardRate(), (REWARD_AMOUNT - 1000 ether) / 999_000);
    }

    function testCompleteStakeCleanupAfterRewardClaim() public {
        staking.setStakeLockupPeriod(10);

        // User stakes minimal amount
        vm.startPrank(user1);
        token.approve(address(staking), minimumStakeAmount);
        staking.stake(minimumStakeAmount);

        // Fast forward past lockup
        vm.warp(block.timestamp + 20);

        // Unstake all tokens
        staking.unstake(minimumStakeAmount);

        // Fast forward past cooldown
        vm.warp(block.timestamp + withdrawalRequestCooldownPeriod + 1);

        // Withdraw tokens
        staking.withdraw(minimumStakeAmount);

        // Get rewards (should clean up any remaining empty stakes)
        staking.getReward();
        vm.stopPrank();

        // Verify user has no stakes left
        assertEq(staking.getUserStakeCount(user1), 0);

        // Try to stake again and ensure no issues
        vm.startPrank(user1);
        token.approve(address(staking), minimumStakeAmount);
        staking.stake(minimumStakeAmount);
        vm.stopPrank();

        assertEq(staking.getUserStakeCount(user1), 1);
    }

    function testSyncRewardRateWithInsufficientVaultBalance() public {
        // Setup with initial balance and reward rate
        staking.dangerouslySetRewardRate(REWARD_RATE, true);

        // User stakes
        vm.startPrank(user1);
        token.approve(address(staking), STAKE_AMOUNT);
        staking.stake(STAKE_AMOUNT);
        vm.stopPrank();

        // Fast forward to accrue rewards
        vm.warp(block.timestamp + 100);

        // Remove tokens from rewards vault, leaving less than accrued
        vm.startPrank(rewardsVault);
        uint256 vaultBalance = token.balanceOf(rewardsVault);
        token.transfer(address(0x999), vaultBalance - 50 ether);
        vm.stopPrank();

        // syncRewardRate should fail because vault balance < accrued rewards
        vm.expectRevert(CalderaStaking.InsufficientRewardsVaultBalance.selector);
        staking.syncRewardRate(1e18);
    }

    function testUnstakeFromMixedLockedAndUnlockedStakes() public {
        // Create 3 stakes with different amounts and timing
        vm.startPrank(user1);
        token.approve(address(staking), STAKE_AMOUNT * 6);

        // First stake (will be unlocked)
        staking.stake(STAKE_AMOUNT);
        vm.warp(block.timestamp + 2 minutes);

        // Second stake (will be unlocked)
        staking.stake(STAKE_AMOUNT * 2);
        vm.warp(block.timestamp + 2 minutes);

        // Third stake (will still be locked)
        staking.stake(STAKE_AMOUNT * 3);
        vm.stopPrank();

        // Fast forward to unlock first two stakes but not the third
        vm.warp(block.timestamp + stakeLockupPeriod - 1 minutes);

        // Should be able to unstake from first two stakes but not third
        uint256 availableToUnstake = staking.getUserUnlockedStakeAmount(user1);
        assertEq(availableToUnstake, STAKE_AMOUNT * 3);

        vm.startPrank(user1);
        // Try to unstake more than available
        vm.expectRevert(CalderaStaking.InsufficientUnlockedStake.selector);
        staking.unstake(STAKE_AMOUNT * 4);

        // Unstake all available
        staking.unstake(STAKE_AMOUNT * 3);
        vm.stopPrank();

        // Verify correct stakes were affected
        assertEq(staking.getUserTotalStakeAmount(user1), STAKE_AMOUNT * 3);

        // Third stake should still be intact
        CalderaStaking.Stake memory lastStake = getStake(user1, 0);
        assertEq(lastStake.amount, STAKE_AMOUNT * 3);
    }

    function testWithdrawalRequestPriority() public {
        staking.setStakeLockupPeriod(10);

        // Create stake
        vm.startPrank(user1);
        token.approve(address(staking), STAKE_AMOUNT * 3);
        staking.stake(STAKE_AMOUNT * 3);
        vm.stopPrank();

        // Fast forward past lockup
        vm.warp(block.timestamp + 20);

        // Create multiple withdrawal requests with different timings
        vm.startPrank(user1);

        // First request
        staking.unstake(STAKE_AMOUNT);
        uint256 firstRequestTime = block.timestamp;

        // Wait half the cooldown period
        vm.warp(block.timestamp + withdrawalRequestCooldownPeriod / 2);

        // Second request
        staking.unstake(STAKE_AMOUNT);

        // Wait full cooldown period for first request only
        vm.warp(firstRequestTime + withdrawalRequestCooldownPeriod + 1);

        // Only first request should be withdrawable
        assertEq(staking.getUserWithdrawableAmount(user1), STAKE_AMOUNT);

        // Partial withdraw should take from first request only
        staking.withdraw(STAKE_AMOUNT / 2);

        // Check remaining withdrawable amount
        assertEq(staking.getUserWithdrawableAmount(user1), STAKE_AMOUNT / 2);

        // Complete first withdrawal
        staking.withdraw(STAKE_AMOUNT / 2);

        // No more withdrawable until second request cooldown completes
        assertEq(staking.getUserWithdrawableAmount(user1), 0);
        vm.stopPrank();
    }

    function testRewardRoundingWithUnevenStakes() public {
        // User1 stakes an uneven amount
        vm.startPrank(user1);
        uint256 unevenAmount = 1234e18;
        token.approve(address(staking), unevenAmount);
        staking.stake(unevenAmount);
        vm.stopPrank();

        // User2 stakes a different uneven amount
        vm.startPrank(user2);
        uint256 differentAmount = 9876e18;
        token.approve(address(staking), differentAmount);
        staking.stake(differentAmount);
        vm.stopPrank();

        // Fast forward
        vm.warp(block.timestamp + 100);

        // Calculate expected rewards (should be proportional to stake amounts)
        uint256 totalStaked = unevenAmount + differentAmount;
        uint256 expectedUser1Reward = REWARD_RATE * 100 * unevenAmount / totalStaked;
        uint256 expectedUser2Reward = REWARD_RATE * 100 * differentAmount / totalStaked;

        // Check actual rewards
        assertApproxEqRel(
            staking.earned(getStake(user1, 0)),
            expectedUser1Reward,
            0.0001e18 // Allow 0.01% error
        );

        assertApproxEqRel(
            staking.earned(getStake(user2, 0)),
            expectedUser2Reward,
            0.0001e18 // Allow 0.01% error
        );

        // Sum of rewards should equal total rewards distributed
        assertApproxEqRel(
            staking.earned(getStake(user1, 0)) + staking.earned(getStake(user2, 0)),
            REWARD_RATE * 100,
            0.0001e18 // Allow 0.01% error
        );
    }

    function testZeroRewardRate() public {
        // Set reward rate to zero
        staking.dangerouslySetRewardRate(0, true);

        // User stakes
        vm.startPrank(user1);
        token.approve(address(staking), STAKE_AMOUNT);
        staking.stake(STAKE_AMOUNT);
        vm.stopPrank();

        // Fast forward
        vm.warp(block.timestamp + 100);

        // Should have zero rewards
        assertEq(staking.earned(getStake(user1, 0)), 0);

        // Try to claim rewards (should fail)
        vm.startPrank(user1);
        vm.expectRevert(CalderaStaking.NoClaimableReward.selector);
        staking.getReward();
        vm.stopPrank();

        // Set reward rate back to non-zero
        staking.dangerouslySetRewardRate(REWARD_RATE, true);

        // Fast forward again
        vm.warp(block.timestamp + 100);

        // Should now have rewards
        assertEq(staking.earned(getStake(user1, 0)), REWARD_RATE * 100);
    }

    function testPauseAndUnpause() public {
        // Pause the contract
        vm.prank(owner);
        staking.pause();

        // Attempt to stake while paused
        vm.startPrank(user1);
        token.approve(address(staking), STAKE_AMOUNT);
        vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
        staking.stake(STAKE_AMOUNT);
        vm.stopPrank();

        // Unpause the contract
        vm.prank(owner);
        staking.unpause();

        // Stake should now succeed
        vm.startPrank(user1);
        staking.stake(STAKE_AMOUNT);
        assertEq(staking.getUserTotalStakeAmount(user1), STAKE_AMOUNT);
        vm.stopPrank();
    }

    function testRewardRateChange() public {
        // Change reward rate
        vm.prank(owner);
        staking.dangerouslySetRewardRate(REWARD_RATE / 2, true);

        // Verify reward rate change
        assertEq(staking.rewardRate(), REWARD_RATE / 2);
    }

    function testRewardAccrualAfterRateChange() public {
        // Stake
        vm.startPrank(user1);
        token.approve(address(staking), STAKE_AMOUNT);
        staking.stake(STAKE_AMOUNT);
        vm.stopPrank();

        // Fast forward 50 seconds
        vm.warp(block.timestamp + 50);

        // Change reward rate
        vm.prank(owner);
        staking.dangerouslySetRewardRate(REWARD_RATE / 2, true);

        // Fast forward another 50 seconds
        vm.warp(block.timestamp + 50);

        // Verify rewards
        uint256 expectedReward = (REWARD_RATE * 50) + (REWARD_RATE / 2 * 50);
        assertEq(staking.earned(getStake(user1, 0)), expectedReward);
    }

    function testUnauthorizedSetRewardsEndTimestamp() public {
        vm.prank(user1);
        vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, user1));
        staking.setRewardsEndTimestamp(block.timestamp + 100 days, false);
    }

    function testUnauthorizedSyncRewardRate() public {
        vm.prank(user1);
        vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, user1));
        staking.syncRewardRate(0.5e18);
    }

    function testUnauthorizedSetRewardRate() public {
        vm.prank(user1);
        vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, user1));
        staking.dangerouslySetRewardRate(REWARD_RATE * 2, true);
    }

    function testUnauthorizedRecoverErc20() public {
        vm.prank(user1);
        vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, user1));
        staking.recoverErc20(address(0), 100);
    }

    function testUnauthorizedPause() public {
        vm.prank(user1);
        vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, user1));
        staking.pause();
    }

    function testUnauthorizedUnpause() public {
        // First pause as owner
        vm.prank(owner);
        staking.pause();

        // Try to unpause as non-owner
        vm.prank(user1);
        vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, user1));
        staking.unpause();
    }

    function testGetEstimatedApr() public {
        // Set up initial state
        token.transfer(user1, STAKE_AMOUNT);
        vm.startPrank(user1);
        token.approve(address(staking), STAKE_AMOUNT);
        staking.stake(STAKE_AMOUNT);
        vm.stopPrank();

        // Calculate expected APR
        // APR = (rewardRate * seconds_per_year * 100) / totalStaked
        uint256 expectedApr = (REWARD_RATE * 365 * 24 * 60 * 60 * 100) / STAKE_AMOUNT;
        assertEq(staking.getEstimatedApr(), expectedApr);

        // Test when totalStaked is 0
        vm.warp(block.timestamp + stakeLockupPeriod);
        vm.startPrank(user1);
        staking.unstake(STAKE_AMOUNT);
        vm.warp(block.timestamp + withdrawalRequestCooldownPeriod);
        staking.withdraw(STAKE_AMOUNT);
        vm.stopPrank();

        assertEq(staking.getEstimatedApr(), 0);
    }

    function testGetUserClaimableRewardAmount() public {
        staking.dangerouslySetRewardRate(REWARD_RATE, true);
        staking.setStakeLockupPeriod(500);

        // Set up initial state with two stakes
        token.transfer(user1, STAKE_AMOUNT * 2);
        vm.startPrank(user1);
        token.approve(address(staking), STAKE_AMOUNT * 2);

        uint256 initialStakeTimestamp = block.timestamp;
        staking.stake(STAKE_AMOUNT);
        vm.warp(block.timestamp + 120); // Wait 2 minutes before second stake
        staking.stake(STAKE_AMOUNT);
        vm.stopPrank();

        // Fast forward past lockup period for first stake only
        vm.warp(initialStakeTimestamp + staking.stakeLockupPeriod());

        // Calculate expected reward for first stake
        uint256 expectedReward = REWARD_RATE * 120 + REWARD_RATE * (500 - 120) * 1 / 2;

        assertEq(staking.getUserClaimableRewardAmount(user1), expectedReward);
    }

    function testGetUserTotalRewardAmount() public {
        staking.dangerouslySetRewardRate(REWARD_RATE, true);

        // Set up stake for user2 first
        token.transfer(user2, STAKE_AMOUNT);
        vm.startPrank(user2);
        token.approve(address(staking), STAKE_AMOUNT);
        staking.stake(STAKE_AMOUNT);
        vm.stopPrank();

        // Fast forward 100 seconds
        vm.warp(block.timestamp + 100);

        // Now set up stake for user1
        token.transfer(user1, STAKE_AMOUNT);
        vm.startPrank(user1);
        token.approve(address(staking), STAKE_AMOUNT);
        staking.stake(STAKE_AMOUNT);
        vm.stopPrank();

        // Fast forward another 100 seconds
        vm.warp(block.timestamp + 100);

        // Add more stake for user2
        token.transfer(user2, STAKE_AMOUNT * 2);
        vm.startPrank(user2);
        token.approve(address(staking), STAKE_AMOUNT * 2);
        staking.stake(STAKE_AMOUNT * 2);
        vm.stopPrank();

        vm.warp(block.timestamp + 100);

        // Calculate expected total rewards for user2
        // For the first 100 seconds, rewards are 100% for user2
        // For the next 100 seconds, rewards are split between user1 and user2
        // For the last 100 seconds, rewards are 75% for user1
        uint256 user2ExpectedReward = REWARD_RATE * 100 + REWARD_RATE * 100 * 1 / 2 + REWARD_RATE * 100 * 3 / 4;

        assertEq(staking.getUserTotalRewardAmount(user2), user2ExpectedReward);
    }

    function testGetUserUnlockedStakeAmount() public {
        // Set up initial state with two stakes
        token.transfer(user1, STAKE_AMOUNT * 2);
        vm.startPrank(user1);
        token.approve(address(staking), STAKE_AMOUNT * 2);

        staking.stake(STAKE_AMOUNT);
        vm.warp(block.timestamp + 60); // Wait 1 minute before second stake
        staking.stake(STAKE_AMOUNT);
        vm.stopPrank();

        // Initially all stakes are locked
        assertEq(staking.getUserUnlockedStakeAmount(user1), 0);

        // Fast forward past lockup period for first stake only
        vm.warp(block.timestamp + stakeLockupPeriod - 60);

        // Only first stake should be unlocked
        assertEq(staking.getUserUnlockedStakeAmount(user1), STAKE_AMOUNT);

        // Fast forward past lockup period for second stake
        vm.warp(block.timestamp + 60);

        // Both stakes should be unlocked
        assertEq(staking.getUserUnlockedStakeAmount(user1), STAKE_AMOUNT * 2);
    }

    function testUpdateRewardModifierWithMultipleStakes() public {
        // User1 stakes first time
        vm.startPrank(user1);
        token.approve(address(staking), STAKE_AMOUNT);
        staking.stake(STAKE_AMOUNT);

        // Fast forward 100 seconds
        vm.warp(block.timestamp + 100);

        // Check first stake rewards after 100 seconds
        uint256 firstStakeInitialReward = staking.earned(getStake(user1, 0));
        assertEq(firstStakeInitialReward, REWARD_RATE * 100);

        // Check accruedRewards
        assertEq(staking.accruedRewards(), 0);

        // Check that all stakes have been updated
        for (uint256 i = 0; i < staking.getUserStakeCount(user1); i++) {
            assertEq(getStake(user1, i).rewardPerTokenPaid, staking.rewardPerTokenStored());
        }

        // Check total rewards matches first stake
        assertEq(staking.getUserTotalRewardAmount(user1), firstStakeInitialReward);

        // Verify stake amounts
        assertEq(staking.getUserTotalStakeAmount(user1), STAKE_AMOUNT);
        assertEq(staking.totalStaked(), STAKE_AMOUNT);

        // User1 stakes second time
        token.approve(address(staking), STAKE_AMOUNT);
        staking.stake(STAKE_AMOUNT);
        vm.stopPrank();

        // Check accruedRewards
        assertEq(staking.accruedRewards(), firstStakeInitialReward);

        // Check that all stakes have been updated
        for (uint256 i = 0; i < staking.getUserStakeCount(user1); i++) {
            assertEq(getStake(user1, i).rewardPerTokenPaid, staking.rewardPerTokenStored());
        }

        // Fast forward another 100 seconds
        vm.warp(block.timestamp + 100);

        // First stake should have rewards for 200 seconds
        uint256 firstStakeReward = staking.earned(getStake(user1, 0));
        assertEq(firstStakeReward, REWARD_RATE * 100 + (REWARD_RATE * 100) / 2);

        // Second stake should have rewards for 100 seconds
        uint256 secondStakeReward = staking.earned(getStake(user1, 1));
        assertEq(secondStakeReward, (REWARD_RATE * 100) / 2);

        // Total rewards should be sum of both stakes
        assertEq(staking.getUserTotalRewardAmount(user1), firstStakeReward + secondStakeReward);
    }

    function testSetRewardsVault() public {
        address oldVault = staking.rewardsVault();
        address newVault = address(0x123);
        staking.setStakeLockupPeriod(1);

        // Only owner can set rewards vault
        vm.prank(user1);
        vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, user1));
        staking.setRewardsVault(newVault);

        // Cannot set rewards vault to zero address
        vm.prank(owner);
        vm.expectRevert(CalderaStaking.InvalidRewardsVault.selector);
        staking.setRewardsVault(address(0));

        // Owner can set rewards vault
        vm.prank(owner);
        vm.expectEmit(true, true, true, true);
        emit CalderaStaking.RewardsVaultSet(oldVault, newVault);
        staking.setRewardsVault(newVault);
        assertEq(address(staking.rewardsVault()), newVault);

        // Rewards should come from new vault
        vm.startPrank(user1);
        token.approve(address(staking), STAKE_AMOUNT);
        staking.stake(STAKE_AMOUNT);
        vm.stopPrank();

        // Fast forward to accrue rewards
        vm.warp(block.timestamp + 100);

        // Fund new vault
        vm.startPrank(owner);
        token.transfer(newVault, REWARD_RATE * 100);
        vm.stopPrank();

        // Approve staking as spender for new vault
        vm.prank(newVault);
        token.approve(address(staking), REWARD_RATE * 100);

        // User should be able to claim rewards from new vault
        vm.startPrank(user1);
        uint256 balanceBefore = token.balanceOf(user1);
        staking.getReward();
        assertEq(token.balanceOf(user1) - balanceBefore, REWARD_RATE * 100);
        vm.stopPrank();
    }

    function testSetStakeLockupPeriod() public {
        vm.prank(user2);
        vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, user2));
        staking.setStakeLockupPeriod(0);

        uint256 maxStakeLockupPeriod = staking.MAX_STAKE_LOCKUP_PERIOD();
        vm.startPrank(owner);
        vm.expectRevert(CalderaStaking.InvalidStakeLockupPeriod.selector);
        staking.setStakeLockupPeriod(maxStakeLockupPeriod + 1);

        vm.expectRevert(CalderaStaking.InvalidStakeLockupPeriod.selector);
        staking.setStakeLockupPeriod(0);

        staking.setStakeLockupPeriod(1);
        assertEq(staking.stakeLockupPeriod(), 1);
        vm.stopPrank();
    }

    function testSetMinimumStakeAmount() public {
        vm.prank(user2);
        vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, user2));
        staking.setMinimumStakeAmount(0);

        vm.startPrank(owner);
        vm.expectRevert(CalderaStaking.InvalidMinimumStakeAmount.selector);
        staking.setMinimumStakeAmount(0);

        uint256 newMinimumStakeAmount = 2 ether;
        vm.expectEmit(true, true, true, true);
        emit CalderaStaking.MinimumStakeAmountSet(1 ether, newMinimumStakeAmount);
        staking.setMinimumStakeAmount(newMinimumStakeAmount);
        assertEq(staking.minimumStakeAmount(), newMinimumStakeAmount);
        vm.stopPrank();

        vm.expectRevert(CalderaStaking.InvalidMinimumStakeAmount.selector);
        staking.setMinimumStakeAmount(1000 ether + 1);
    }

    function testSetWithdrawalRequestCooldownPeriod() public {
        vm.prank(user2);
        vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, user2));
        staking.setWithdrawalRequestCooldownPeriod(0);

        uint256 maxCooldownPeriod = staking.MAX_WITHDRAWAL_REQUEST_COOLDOWN_PERIOD();
        vm.startPrank(owner);
        vm.expectRevert(CalderaStaking.InvalidWithdrawalRequestCooldownPeriod.selector);
        staking.setWithdrawalRequestCooldownPeriod(maxCooldownPeriod + 1);

        vm.expectRevert(CalderaStaking.InvalidWithdrawalRequestCooldownPeriod.selector);
        staking.setWithdrawalRequestCooldownPeriod(0);

        uint256 newCooldownPeriod = 1 days;
        vm.expectEmit(true, true, true, true);
        emit CalderaStaking.WithdrawalRequestCooldownPeriodSet(
            staking.withdrawalRequestCooldownPeriod(), newCooldownPeriod
        );
        staking.setWithdrawalRequestCooldownPeriod(newCooldownPeriod);
        assertEq(staking.withdrawalRequestCooldownPeriod(), newCooldownPeriod);
        vm.stopPrank();
    }

    function testSetRewardsEndTimestamp() public {
        vm.prank(user2);
        vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, user2));
        staking.setRewardsEndTimestamp(block.timestamp + 1, false);

        vm.startPrank(owner);
        vm.expectRevert(CalderaStaking.InvalidRewardsEndTimestamp.selector);
        staking.setRewardsEndTimestamp(0, false);

        vm.expectRevert(CalderaStaking.InvalidRewardsEndTimestamp.selector);
        staking.setRewardsEndTimestamp(block.timestamp - 1, false);

        uint256 newEndTimestamp = block.timestamp + 1 days;
        vm.expectEmit(true, true, true, true);
        emit CalderaStaking.RewardsEndTimestampSet(staking.rewardsEndTimestamp(), newEndTimestamp);
        staking.setRewardsEndTimestamp(newEndTimestamp, false);
        assertEq(staking.rewardsEndTimestamp(), newEndTimestamp);
        vm.stopPrank();
    }

    function testSetRewardsEndTimestampWithStakes() public {
        // User1 stakes
        vm.startPrank(user1);
        token.approve(address(staking), STAKE_AMOUNT);
        staking.stake(STAKE_AMOUNT);
        vm.stopPrank();

        // Fast forward 50 seconds
        vm.warp(block.timestamp + 50);

        // Set rewards end timestamp to current time
        vm.prank(owner);
        staking.setRewardsEndTimestamp(block.timestamp, false);
        assertEq(staking.rewardsEndTimestamp(), block.timestamp);
        assertEq(staking.lastTimeRewardApplicable(), block.timestamp);
        assertEq(staking.getUserTotalRewardAmount(user1), REWARD_RATE * 50);
        assertEq(staking.accruedRewards(), REWARD_RATE * 50);

        // Fast forward another 40 seconds
        vm.warp(block.timestamp + 40);

        // Verify no additional rewards accrued after end timestamp
        assertEq(staking.getUserTotalRewardAmount(user1), REWARD_RATE * 50);

        // Update hasn't been called on this user yet, so reward should be 0.
        // `earned`, however, should be 50.
        assertEq(getStake(user1, 0).reward, 0);
        assertEq(staking.earned(getStake(user1, 0)), REWARD_RATE * 50);

        // Set rewards end timestamp to future time
        uint256 newEndTimestamp = block.timestamp + 70;
        vm.prank(owner);
        staking.setRewardsEndTimestamp(newEndTimestamp, false);

        // Accrued rewards should be the same as before, since it was after the previous end timestamp
        assertEq(staking.accruedRewards(), REWARD_RATE * 50);
        assertEq(getStake(user1, 0).reward, 0);
        assertEq(staking.earned(getStake(user1, 0)), REWARD_RATE * 50);

        // Fast forward 25 seconds
        vm.warp(block.timestamp + 25);

        // Verify rewards accrue again, but only during the new period
        assertEq(staking.earned(getStake(user1, 0)), (REWARD_RATE * 50) + (REWARD_RATE * 25));
    }

    function testSetRewardsEndTimestampWithMultipleStakesAndUsers() public {
        staking.setStakeLockupPeriod(1);

        // User1 stakes
        vm.startPrank(user1);
        token.approve(address(staking), STAKE_AMOUNT * 2);
        staking.stake(STAKE_AMOUNT);
        vm.stopPrank();

        // Fast forward 90 seconds
        vm.warp(block.timestamp + 90);

        // User2 stakes
        vm.startPrank(user2);
        token.approve(address(staking), STAKE_AMOUNT);
        staking.stake(STAKE_AMOUNT);
        vm.stopPrank();

        // Fast forward 90 seconds
        vm.warp(block.timestamp + 90);

        // User1 stakes again
        vm.startPrank(user1);
        staking.stake(STAKE_AMOUNT);
        vm.stopPrank();

        // Fast forward 20 seconds
        vm.warp(block.timestamp + 20);

        // Set rewards end timestamp to current time
        vm.prank(owner);
        staking.setRewardsEndTimestamp(block.timestamp, false);

        // Verify rewards for first period
        // User1's first stake: 90 seconds of full rewards + 90 seconds of 1/2 rewards + 20 seconds of 1/3 rewards
        uint256 user1Stake1Rewards = (REWARD_RATE * 90) + ((REWARD_RATE * 90) / 2) + ((REWARD_RATE * 20) / 3);
        // User2's stake: 90 seconds of 1/2 rewards + 20 seconds of 1/3 rewards
        uint256 user2Stake1Rewards = (REWARD_RATE * 90) / 2 + ((REWARD_RATE * 20) / 3);
        // User1's second stake: 20 seconds of 1/3 rewards
        uint256 user1Stake2Rewards = (REWARD_RATE * 20) / 3;

        assertApproxEqRel(
            staking.earned(getStake(user1, 0)),
            user1Stake1Rewards,
            0.0001e18 // Only allow 0.01% error
        );
        assertApproxEqRel(
            staking.earned(getStake(user2, 0)),
            user2Stake1Rewards,
            0.0001e18 // Only allow 0.01% error
        );
        assertApproxEqRel(
            staking.earned(getStake(user1, 1)),
            user1Stake2Rewards,
            0.0001e18 // Only allow 0.01% error
        );

        // Fast forward 40 seconds - no rewards should accrue
        vm.warp(block.timestamp + 40);

        assertApproxEqRel(
            staking.earned(getStake(user1, 0)),
            user1Stake1Rewards,
            0.0001e18 // Only allow 0.01% error
        );
        assertApproxEqRel(
            staking.earned(getStake(user2, 0)),
            user2Stake1Rewards,
            0.0001e18 // Only allow 0.01% error
        );
        assertApproxEqRel(
            staking.earned(getStake(user1, 1)),
            user1Stake2Rewards,
            0.0001e18 // Only allow 0.01% error
        );

        // Set new rewards end timestamp 60 seconds in future
        vm.prank(owner);
        uint256 newEndTimestamp = block.timestamp + 60;
        staking.setRewardsEndTimestamp(newEndTimestamp, false);

        // Fast forward 30 seconds
        vm.warp(block.timestamp + 30);

        // Each stake should earn 1/3 of rewards for new 30 second period
        uint256 newPeriodRewards = (REWARD_RATE * 30) / 3;

        assertApproxEqRel(
            staking.earned(getStake(user1, 0)),
            user1Stake1Rewards + newPeriodRewards,
            0.0001e18 // Only allow 0.01% error
        );
        assertApproxEqRel(
            staking.earned(getStake(user2, 0)),
            user2Stake1Rewards + newPeriodRewards,
            0.0001e18 // Only allow 0.01% error
        );
        assertApproxEqRel(
            staking.earned(getStake(user1, 1)),
            user1Stake2Rewards + newPeriodRewards,
            0.0001e18 // Only allow 0.01% error
        );

        // User2 unstakes
        vm.startPrank(user2);
        staking.unstake(STAKE_AMOUNT);
        vm.stopPrank();

        // Fast forward remaining 30 seconds
        vm.warp(block.timestamp + 30);

        // User1's stakes should each earn 1/2 of rewards for final 30 second period
        uint256 finalPeriodRewards = (REWARD_RATE * 30) / 2;

        assertApproxEqRel(
            staking.earned(getStake(user1, 0)),
            user1Stake1Rewards + newPeriodRewards + finalPeriodRewards,
            0.0001e18 // Only allow 0.01% error
        );
        assertApproxEqRel(
            staking.earned(getStake(user2, 0)),
            user2Stake1Rewards + newPeriodRewards,
            0.0001e18 // Only allow 0.01% error
        );
        assertApproxEqRel(
            staking.earned(getStake(user1, 1)),
            user1Stake2Rewards + newPeriodRewards + finalPeriodRewards,
            0.0001e18 // Only allow 0.01% error
        );
    }

    function testExtendStakingEndPeriod() public {
        // Set initial reward rate and end timestamp
        staking.dangerouslySetRewardRate(REWARD_RATE, true);
        uint256 initialEndTimestamp = block.timestamp + 100;
        staking.setRewardsEndTimestamp(initialEndTimestamp, false);

        // User1 stakes
        vm.startPrank(user1);
        token.approve(address(staking), STAKE_AMOUNT);
        staking.stake(STAKE_AMOUNT);
        vm.stopPrank();

        // Fast forward 50 seconds (halfway through)
        vm.warp(block.timestamp + 50);

        // Record earned rewards at midpoint
        uint256 midpointRewards = staking.earned(getStake(user1, 0));

        // Extend staking period by another 50 seconds (150 seconds total)
        uint256 newEndTimestamp = initialEndTimestamp + 50;
        staking.setRewardsEndTimestamp(newEndTimestamp, false);

        // Fast forward another 50 seconds
        vm.warp(block.timestamp + 50);

        // Verify rewards continue to accrue at same rate
        uint256 finalRewards = staking.earned(getStake(user1, 0));
        assertApproxEqRel(
            finalRewards,
            midpointRewards * 2,
            0.0001e18 // Only allow 0.01% error
        );

        // Verify rewards end timestamp was updated
        assertEq(staking.rewardsEndTimestamp(), newEndTimestamp);

        // Fast forward another 50 seconds
        vm.warp(block.timestamp + 50);

        // Verify rewards continue to accrue at same rate
        finalRewards = staking.earned(getStake(user1, 0));
        assertApproxEqRel(finalRewards, midpointRewards * 3, 0.0001e18);

        // Verify we're at the end of the staking period
        assertEq(block.timestamp, staking.rewardsEndTimestamp());

        // Fast forward another 50 seconds
        vm.warp(block.timestamp + 50);

        // Verify rewards have stopped accruing
        finalRewards = staking.earned(getStake(user1, 0));
        assertApproxEqRel(finalRewards, midpointRewards * 3, 0.0001e18);
    }

    function testSyncRewardRateWithInvalidPercent() public {
        // Try to sync with 150% (1.5e18)
        vm.expectRevert(CalderaStaking.InvalidRewardsVaultTargetPercent.selector);
        staking.syncRewardRate(1.5e18);

        // Try to sync with 200% (2e18)
        vm.expectRevert(CalderaStaking.InvalidRewardsVaultTargetPercent.selector);
        staking.syncRewardRate(2e18);

        // Try to sync with max uint256
        vm.expectRevert(CalderaStaking.InvalidRewardsVaultTargetPercent.selector);
        staking.syncRewardRate(type(uint256).max);
    }

    function testSyncRewardRatePastEnd() public {
        // Set initial reward rate and end timestamp
        staking.dangerouslySetRewardRate(REWARD_RATE, true);
        uint256 endTimestamp = block.timestamp + 100;
        staking.setRewardsEndTimestamp(endTimestamp, false);

        // Fast forward past end timestamp
        vm.warp(endTimestamp + 1);

        // Sync reward rate
        staking.syncRewardRate(1e18);

        // Verify reward rate is set to 0 since we're past end
        assertEq(staking.rewardRate(), 0);
    }

    function testDangerouslySetRewardRate() public {
        // Try to set reward rate without confirming
        vm.expectRevert();
        staking.dangerouslySetRewardRate(REWARD_RATE, false);

        // Set reward rate with confirmation
        uint256 previousRewardRate = staking.rewardRate();
        vm.expectEmit(true, true, true, true);
        emit CalderaStaking.RewardRateSet(previousRewardRate, REWARD_RATE);
        staking.dangerouslySetRewardRate(REWARD_RATE, true);
        assertEq(staking.rewardRate(), REWARD_RATE);

        // User1 stakes
        vm.startPrank(user1);
        token.approve(address(staking), STAKE_AMOUNT);
        staking.stake(STAKE_AMOUNT);
        vm.stopPrank();

        // Fast forward 10 seconds
        vm.warp(block.timestamp + 10);

        // Verify rewards accrue at new rate
        // Should be REWARD_RATE * 10 seconds
        assertEq(staking.earned(getStake(user1, 0)), REWARD_RATE * 10);

        // Set to zero
        staking.dangerouslySetRewardRate(0, true);
        assertEq(staking.rewardRate(), 0);

        // Fast forward another 10 seconds
        vm.warp(block.timestamp + 10);

        // Verify no additional rewards accrued
        assertEq(staking.earned(getStake(user1, 0)), REWARD_RATE * 10);
    }

    function testUnstakeAllAndWithdrawAll() public {
        uint256 initialBalance = token.balanceOf(user1);

        // User1 stakes
        vm.startPrank(user1);
        token.approve(address(staking), minimumStakeAmount);
        staking.stake(minimumStakeAmount);
        assertEq(token.balanceOf(user1), initialBalance - minimumStakeAmount);
        vm.stopPrank();

        // Fast forward past lockup period
        vm.warp(block.timestamp + staking.stakeLockupPeriod());

        // Double minimum stake amount
        staking.setMinimumStakeAmount(2 * minimumStakeAmount);

        // Initial unstake should fail
        vm.startPrank(user1);
        vm.expectRevert(CalderaStaking.UnstakeAmountTooSmall.selector);
        staking.unstake(minimumStakeAmount);
        vm.stopPrank();

        // User1 unstakes all their tokens
        vm.startPrank(user1);
        assertEq(staking.getUserTotalStakeAmount(user1), minimumStakeAmount);
        staking.unstakeAll();
        assertEq(staking.getUserTotalStakeAmount(user1), 0);
        vm.stopPrank();

        // Fast forward past cooldown period
        vm.warp(block.timestamp + withdrawalRequestCooldownPeriod);

        // Initial withdraw should fail
        vm.startPrank(user1);
        vm.expectRevert(CalderaStaking.WithdrawAmountTooSmall.selector);
        staking.withdraw(minimumStakeAmount);
        vm.stopPrank();

        // User1 withdraws all their tokens
        vm.startPrank(user1);
        assertEq(staking.getUserWithdrawableAmount(user1), minimumStakeAmount);
        staking.withdrawAll();
        assertEq(staking.getUserWithdrawableAmount(user1), 0);
        vm.stopPrank();

        assertEq(token.balanceOf(user1), initialBalance);
    }

    function testSetRewardsEndTimestampWithSyncRewardRate() public {
        uint256 endTimestamp = block.timestamp + 1_000_000;
        staking.setRewardsEndTimestamp(endTimestamp, true);
        uint256 initialRewardRate = staking.rewardRate();

        // User needs to stake for rewards to be paid out
        vm.startPrank(user1);
        token.approve(address(staking), STAKE_AMOUNT);
        staking.stake(STAKE_AMOUNT);
        vm.stopPrank();

        // Pay out half of reward
        vm.warp(block.timestamp + 500_000);
        assertEq(staking.rewardRate(), initialRewardRate);

        // Now set new end date 1 million seconds in future
        staking.setRewardsEndTimestamp(block.timestamp + 1_000_000, true);

        // We are paying out half of the rewards over another 1 million seconds, so reward rate should be halved.
        assertEq(staking.rewardRate(), initialRewardRate / 2);
    }

    function testDangerouslySetRewardRateTooHigh() public {
        uint256 tooHighRate = staking.MAX_REWARD_RATE() + 100;

        vm.expectRevert(CalderaStaking.RewardRateTooHigh.selector);
        staking.dangerouslySetRewardRate(tooHighRate, true);
    }

    function testSyncRewardRateWithDurationTooShort() public {
        staking.dangerouslySetRewardRate(REWARD_RATE, true);

        vm.expectRevert(CalderaStaking.RewardsDurationTooShort.selector);
        staking.setRewardsEndTimestamp(block.timestamp + 100, true);

        staking.setRewardsEndTimestamp(block.timestamp + 100, false);
        uint256 rewardsVaultTargetPercent = 0.25e18;

        vm.expectRevert(CalderaStaking.RewardsDurationTooShort.selector);
        staking.syncRewardRate(rewardsVaultTargetPercent);
    }
}
