// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { ReentrancyGuard } from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import { IVestaAuctionAdapter } from "./interfaces/IVestaAuctionAdapter.sol";
import { IVestaLiquidityAdapter } from "./interfaces/IVestaLiquidityAdapter.sol";

/// @notice Escrows covenant ETH, creates locked positions, and distributes deterministic pro-rata rewards.
contract VestaCovenantVault is ReentrancyGuard {
    using SafeERC20 for IERC20;

    uint16 public constant BPS = 10_000;

    enum Lifecycle {
        Configured,
        EnrollmentOpen,
        Finalized,
        Migrated,
        Closed
    }

    struct Commitment {
        uint16 commitmentBps;
        uint256 escrowedEth;
        bool active;
    }

    struct Position {
        uint256 shares;
        uint256 tokenId;
        uint256 tokenAmount;
        uint256 ethAmount;
        uint64 finalizedAt;
        uint64 unlockTime;
        bool exited;
    }

    address public immutable strategy;
    address public immutable auction;
    IERC20 public immutable launchToken;
    IVestaAuctionAdapter public immutable auctionAdapter;
    IVestaLiquidityAdapter public immutable liquidityAdapter;
    uint64 public immutable lockDuration;
    uint16 public immutable earlyExitPenaltyBps;

    Lifecycle public lifecycle;
    uint256 public totalEscrowedEth;
    uint256 public totalCommittedTokens;
    uint256 public totalPositionShares;
    uint256 public rewardPot;
    uint256 public totalClaimedRewards;
    address[] private _participants;
    mapping(address participant => Commitment) private _commitments;
    mapping(address participant => Position) private _positions;
    mapping(address participant => uint256) public claimedRewards;

    error OnlyStrategy();
    error InvalidLifecycle(Lifecycle expected, Lifecycle actual);
    error InvalidCommitmentBps();
    error ZeroEthContribution();
    error NoActiveCommitment();
    error AuctionIncomplete();
    error AlreadyExited();
    error PositionStillLocked(uint256 unlockTime);
    error PositionNotLocked();
    error TransferFailed();
    error InvalidRewardFunding();
    error EmptyMigration();

    event LifecycleChanged(Lifecycle indexed lifecycle);
    event CovenantEnrolled(address indexed user, uint16 commitmentBps, uint256 escrowedEth);
    event CovenantUpdated(
        address indexed user, uint16 commitmentBps, uint256 addedEth, uint256 totalEscrowedEth
    );
    event CovenantCancelled(address indexed user, uint256 refundedEth);
    event CovenantsFinalized(uint256 totalTokens, uint256 totalEth, uint256 participants);
    event PositionCreated(
        address indexed user,
        uint256 shares,
        uint256 tokenAmount,
        uint256 ethAmount,
        uint256 unlockTime
    );
    event PoolMigrated(uint256 totalTokens, uint256 totalEth, uint256 shares);
    event RewardsFunded(address indexed funder, uint256 amount, uint256 rewardPot);
    event RewardsClaimed(address indexed user, uint256 amount);
    event PositionWithdrawn(address indexed user, uint256 tokenAmount, uint256 ethAmount);
    event EarlyExit(address indexed user, uint256 tokenAmount, uint256 ethAmount, uint256 penalty);

    modifier onlyStrategy() {
        if (msg.sender != strategy) revert OnlyStrategy();
        _;
    }

    constructor(
        address strategy_,
        address auction_,
        IERC20 launchToken_,
        IVestaAuctionAdapter auctionAdapter_,
        IVestaLiquidityAdapter liquidityAdapter_,
        uint64 lockDuration_,
        uint16 earlyExitPenaltyBps_
    ) {
        if (earlyExitPenaltyBps_ > BPS) revert InvalidCommitmentBps();
        strategy = strategy_;
        auction = auction_;
        launchToken = launchToken_;
        auctionAdapter = auctionAdapter_;
        liquidityAdapter = liquidityAdapter_;
        lockDuration = lockDuration_;
        earlyExitPenaltyBps = earlyExitPenaltyBps_;
        lifecycle = Lifecycle.Configured;
    }

    /// @notice Opens the pre-auction covenant enrollment period. Callable only by the strategy.
    function openEnrollment() external onlyStrategy {
        _requireLifecycle(Lifecycle.Configured);
        lifecycle = Lifecycle.EnrollmentOpen;
        emit LifecycleChanged(lifecycle);
    }

    /// @notice Escrow ETH and select the percentage of the eventual CCA allocation to lock as liquidity.
    //commitmentBps is this percentage
    function enrollCovenant(uint16 commitmentBps) external payable nonReentrant {
        _requireLifecycle(Lifecycle.EnrollmentOpen);
        if (commitmentBps > BPS) revert InvalidCommitmentBps();
        if (msg.value == 0) revert ZeroEthContribution();
        Commitment storage commitment = _commitments[msg.sender];
        if (!commitment.active) {
            commitment.active = true;
            _participants.push(msg.sender);
        }
        commitment.commitmentBps = commitmentBps;
        commitment.escrowedEth += msg.value;
        totalEscrowedEth += msg.value;
        emit CovenantEnrolled(msg.sender, commitmentBps, commitment.escrowedEth);
    }

    /// @notice Updates commitment bps; supplied ETH is additive to the prior escrow, never a replacement.
    function updateCovenant(uint16 commitmentBps) external payable nonReentrant {
        _requireLifecycle(Lifecycle.EnrollmentOpen);
        if (commitmentBps > BPS) revert InvalidCommitmentBps();
        Commitment storage commitment = _commitments[msg.sender];
        if (!commitment.active) revert NoActiveCommitment();
        commitment.commitmentBps = commitmentBps;
        commitment.escrowedEth += msg.value;
        totalEscrowedEth += msg.value;
        emit CovenantUpdated(msg.sender, commitmentBps, msg.value, commitment.escrowedEth);
    }

    /// @notice Cancels an enrollment and refunds all attributable ETH before finalization.
    function cancelCovenant() external nonReentrant {
        _requireLifecycle(Lifecycle.EnrollmentOpen);
        Commitment storage commitment = _commitments[msg.sender];
        if (!commitment.active) revert NoActiveCommitment();
        uint256 refund = commitment.escrowedEth;
        commitment.active = false;
        commitment.escrowedEth = 0;
        totalEscrowedEth -= refund;
        _sendEth(msg.sender, refund);
        emit CovenantCancelled(msg.sender, refund);
    }

    /// @notice Reads a participant's recorded escrow commitment for frontend consumption.
    function commitmentOf(address participant) external view returns (Commitment memory) {
        return _commitments[participant];
    }

    /// @notice Reads a participant's locked position for frontend consumption.
    function positionOf(address participant) external view returns (Position memory) {
        return _positions[participant];
    }

    function participants() external view returns (address[] memory) {
        return _participants;
    }

    /// @notice Calculates the participant's claimable pro-rata reward; rewards use LP share, not an oracle.
    function pendingRewards(address participant) public view returns (uint256) {
        if (totalPositionShares == 0) return 0;
        uint256 entitlement = rewardPot * _positions[participant].shares / totalPositionShares;
        return entitlement - claimedRewards[participant];
    }

    /// @notice Records actual CCA allocations and the token split after the external auction completes.
    function finalizeCovenants() external onlyStrategy nonReentrant {
        _requireLifecycle(Lifecycle.EnrollmentOpen);
        if (!auctionAdapter.isAuctionComplete(auction)) revert AuctionIncomplete();
        uint256 length = _participants.length;
        for (uint256 i; i < length; ++i) {
            address participant = _participants[i];
            Commitment memory commitment = _commitments[participant];
            if (!commitment.active) continue;
            totalCommittedTokens += auctionAdapter.claimableAllocation(auction, participant)
                * commitment.commitmentBps / BPS;
        }
        lifecycle = Lifecycle.Finalized;
        emit LifecycleChanged(lifecycle);
        emit CovenantsFinalized(totalCommittedTokens, totalEscrowedEth, length);
    }

    /// @notice Initializes the configured pool, then mints ONE locked LP
    ///         position PER participant and begins the lock.
    /// @dev Each participant gets their own adapter position: for the mock
    ///      adapter `shares` is a fungible amount (tokenId == 0); for the
    ///      Sepolia/v4 adapter each call mints a distinct ERC-721 whose token
    ///      ID is stored as `tokenId`. Reward weight (`shares`) is always the
    ///      participant's escrowed ETH, so rewards stay pro-rata by escrow
    ///      regardless of adapter type.
    function migrate() external onlyStrategy nonReentrant {
        _requireLifecycle(Lifecycle.Finalized);
        uint256 totalEth = totalEscrowedEth;
        if (totalEth == 0 || totalCommittedTokens == 0) revert EmptyMigration();
        launchToken.safeTransfer(address(liquidityAdapter), totalCommittedTokens);
        liquidityAdapter.initializePool(address(launchToken), auctionAdapter.clearingPrice(auction));
        uint256 length = _participants.length;
        for (uint256 i; i < length; ++i) {
            address participant = _participants[i];
            Commitment memory commitment = _commitments[participant];
            if (!commitment.active) continue;
            if (commitment.escrowedEth == 0) continue;
            uint256 tokenAmount = auctionAdapter.claimableAllocation(auction, participant)
                * commitment.commitmentBps / BPS;
            if (tokenAmount == 0) continue;
            // One adapter position per participant. The vault forwards exactly
            // this participant's escrowed ETH with the call.
            // `adapterId` is adapter-defined: a fungible amount for the mock
            // adapter (which returns ethAmount), an ERC-721 token ID for the
            // Sepolia/v4 adapter. Reward weight is always the escrowed ETH so
            // rewards stay pro-rata by escrow regardless of adapter type.
            uint256 adapterId = liquidityAdapter.addLiquidity{ value: commitment.escrowedEth }(
                address(launchToken), tokenAmount, commitment.escrowedEth
            );
            _positions[participant] = Position({
                shares: commitment.escrowedEth,
                tokenId: adapterId,
                tokenAmount: tokenAmount,
                ethAmount: commitment.escrowedEth,
                finalizedAt: uint64(block.timestamp),
                unlockTime: uint64(block.timestamp) + lockDuration,
                exited: false
            });
            totalPositionShares += commitment.escrowedEth;
            emit PositionCreated(
                participant,
                commitment.escrowedEth,
                tokenAmount,
                commitment.escrowedEth,
                block.timestamp + lockDuration
            );
        }
        if (totalPositionShares == 0) revert EmptyMigration();
        lifecycle = Lifecycle.Migrated;
        emit LifecycleChanged(lifecycle);
        emit PoolMigrated(totalCommittedTokens, totalEth, totalPositionShares);
    }

    /// @notice Adds ETH to the deterministic reward pot once positions exist.
    function fundRewards() external payable nonReentrant {
        _requireLifecycle(Lifecycle.Migrated);
        if (msg.value == 0) revert InvalidRewardFunding();
        rewardPot += msg.value;
        emit RewardsFunded(msg.sender, msg.value, rewardPot);
    }

    /// @notice Claims the caller's one-time-per-amount pro-rata ETH rewards.
    function claimRewards() external nonReentrant {
        _requireLifecycle(Lifecycle.Migrated);
        uint256 amount = pendingRewards(msg.sender);
        if (amount == 0) revert InvalidRewardFunding();
        claimedRewards[msg.sender] += amount;
        totalClaimedRewards += amount;
        _sendEth(msg.sender, amount);
        emit RewardsClaimed(msg.sender, amount);
    }

    /// @notice Redeems a position after the configured lock without penalty.
    function withdrawAfterUnlock() external nonReentrant {
        _requireLifecycle(Lifecycle.Migrated);
        Position storage position = _activePosition(msg.sender);
        if (block.timestamp < position.unlockTime) revert PositionStillLocked(position.unlockTime);
        _redeem(msg.sender, position, false);
    }

    /// @notice Redeems a locked position early and retains the ETH penalty in the reward pot.
    function earlyExit() external nonReentrant {
        _requireLifecycle(Lifecycle.Migrated);
        Position storage position = _activePosition(msg.sender);
        if (block.timestamp >= position.unlockTime) revert PositionNotLocked();
        _redeem(msg.sender, position, true);
    }

    function _redeem(address participant, Position storage position, bool early) private {
        // tokenId is the adapter-defined position identifier (fungible amount
        // for the mock adapter, ERC-721 ID for Sepolia/v4). It is always set
        // by migrate(); shares carries the reward weight.
        uint256 adapterId = position.tokenId;
        position.exited = true;
        (uint256 tokenAmount, uint256 ethAmount) =
            liquidityAdapter.removeLiquidity(address(this), adapterId);
        launchToken.safeTransfer(participant, tokenAmount);
        uint256 penalty;
        if (early) {
            penalty = ethAmount * earlyExitPenaltyBps / BPS;
            rewardPot += penalty;
            _sendEth(participant, ethAmount - penalty);
            emit EarlyExit(participant, tokenAmount, ethAmount, penalty);
        } else {
            _sendEth(participant, ethAmount);
            emit PositionWithdrawn(participant, tokenAmount, ethAmount);
        }
    }

    function _activePosition(address participant)
        private
        view
        returns (Position storage position)
    {
        position = _positions[participant];
        if (position.shares == 0 || position.exited) revert AlreadyExited();
    }

    function _requireLifecycle(Lifecycle expected) private view {
        if (lifecycle != expected) revert InvalidLifecycle(expected, lifecycle);
    }

    function _sendEth(address to, uint256 amount) private {
        (bool sent,) = to.call{ value: amount }("");
        if (!sent) revert TransferFailed();
    }

    receive() external payable { }
}
