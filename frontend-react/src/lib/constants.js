export const CHAIN_ID = 11155111n;
export const CHAIN_HEX = "0xaa36a7";
export const EXPLORER = "https://sepolia.etherscan.io";
export const Q96 = 2n ** 96n;
export const MAX_BID_SCAN = 500;
export const DEFAULT_RPC = "https://ethereum-sepolia-rpc.publicnode.com";

export const LIFECYCLE_LABELS = [
  "Configured",
  "EnrollmentOpen",
  "Finalized",
  "Migrated",
  "Closed",
];

export const ABI_STRATEGY = [
  "function owner() view returns (address)",
  "function auction() view returns (address)",
  "function vault() view returns (address)",
  "function launchToken() view returns (address)",
  "function auctionAdapter() view returns (address)",
  "function liquidityAdapter() view returns (address)",
  "function openEnrollment()",
  "function finalizeCovenants()",
  "function migrate()",
];

export const ABI_VAULT = [
  "function lifecycle() view returns (uint8)",
  "function lockDuration() view returns (uint64)",
  "function earlyExitPenaltyBps() view returns (uint16)",
  "function totalEscrowedEth() view returns (uint256)",
  "function totalCommittedTokens() view returns (uint256)",
  "function totalPositionShares() view returns (uint256)",
  "function rewardPot() view returns (uint256)",
  "function participants() view returns (address[])",
  "function commitmentOf(address) view returns (uint16 commitmentBps, uint256 escrowedEth, bool active)",
  "function positionOf(address) view returns (uint256 shares, uint256 tokenId, uint256 tokenAmount, uint256 ethAmount, uint64 finalizedAt, uint64 unlockTime, bool exited)",
  "function pendingRewards(address) view returns (uint256)",
  "function enrollCovenant(uint16 commitmentBps) payable",
  "function updateCovenant(uint16 commitmentBps) payable",
  "function cancelCovenant()",
  "function fundRewards() payable",
  "function claimRewards()",
  "function withdrawAfterUnlock()",
  "function earlyExit()",
];

export const ABI_ADAPTER = [
  "function pokeCheckpoint(address auction) returns (uint256)",
  "function isAuctionComplete(address) view returns (bool)",
  "function claimableAllocation(address,address) view returns (uint256)",
  "function clearingPrice(address) view returns (uint256)",
];

export const ABI_CCA = [
  "function endBlock() view returns (uint64)",
  "function claimBlock() view returns (uint64)",
  "function floorPrice() view returns (uint256)",
  "function tickSpacing() view returns (uint256)",
  "function currency() view returns (address)",
  "function token() view returns (address)",
  "function isGraduated() view returns (bool)",
  "function clearingPrice() view returns (uint256)",
  "function nextBidId() view returns (uint256)",
  "function bids(uint256) view returns (uint64 startBlock, uint24 startCumulativeMps, uint64 exitedBlock, uint256 maxPrice, address owner, uint256 amountQ96, uint256 tokensFilled)",
  "function submitBid(uint256 maxPriceQ96, uint128 amount, address owner, bytes hookData) payable returns (uint256)",
  "function exitBid(uint256 bidId)",
  "function claimTokens(uint256 bidId)",
];

export const ABI_LIQ = ["function POSITION_MANAGER() view returns (address)"];

export const ABI_TOKEN = [
  "function symbol() view returns (string)",
  "function decimals() view returns (uint8)",
  "function balanceOf(address) view returns (uint256)",
];
