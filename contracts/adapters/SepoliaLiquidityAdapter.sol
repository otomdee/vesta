// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { IVestaLiquidityAdapter } from "../interfaces/IVestaLiquidityAdapter.sol";
import { IPositionManager } from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import { Actions } from "@uniswap/v4-periphery/src/libraries/Actions.sol";
import { PoolKey } from "@uniswap/v4-core/src/types/PoolKey.sol";
import { Currency, CurrencyLibrary } from "@uniswap/v4-core/src/types/Currency.sol";
import { IHooks } from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import { TickMath } from "@uniswap/v4-core/src/libraries/TickMath.sol";
import { LiquidityAmounts } from "@uniswap/v4-periphery/src/libraries/LiquidityAmounts.sol";
import { TokenPricing } from "liquidity-launcher/src/libraries/TokenPricing.sol";
import { IAllowanceTransfer } from "permit2/src/interfaces/IAllowanceTransfer.sol";

/// @notice Reads the Permit2 address bound to the Sepolia PositionManager.
/// @dev PositionManager inherits Permit2Forwarder which exposes
///      `permit2()` as a public immutable. Reading it on-chain avoids
///      hardcoding the wrong (mainnet) Permit2 address on Sepolia.
interface IPositionManagerPermit2 {
    function permit2() external view returns (IAllowanceTransfer);
}

/// @notice Sepolia adapter that wires Vesta's liquidity lifecycle into the
///         Uniswap v4 PositionManager deployed on Ethereum Sepolia.
///
/// Sepolia deployment addresses (immutable, baked in at construction):
///   Uniswap v4 PositionManager : 0x429ba70129df741B2Ca2a85BC3A2a3328e5c09b4
///   Permit2 is NOT hardcoded: it is read from PositionManager.permit2()
///   (Sepolia uses 0x000000000022D473030F116dDEE9F6B43aC78BA3, NOT the
///   mainnet 0x...BA2 — hardcoding BA2 silently breaks settlement).
///
/// Interface mapping (IVestaLiquidityAdapter → v4 PositionManager):
///   initializePool  → IPoolInitializer_v4.initializePool(poolKey, sqrtPriceX96)
///   addLiquidity    → modifyLiquidities(MINT_POSITION + SETTLE_PAIR + SWEEP)
///   removeLiquidity → modifyLiquidities(BURN_POSITION + TAKE_PAIR)
///
/// @dev Price conversion: the CCA clearing price is a Q96 fixed-point number
///      representing CURRENCY-per-token (`price * 2^96`, i.e. ETH per token).
///      Uniswap v4 expresses the pool price as currency1/currency0.
///      Because ETH (address(0)) is always currency0 here, the price must be
///      INVERTED. This adapter reuses Uniswap's own TokenPricing library
///      (same code path as LiquidityLauncher's LBPStrategy) so the pool opens
///      at exactly the discovered price.
///
/// @dev Positions: ONE v4 ERC-721 position is minted PER addLiquidity call.
///      The vault calls addLiquidity once per participant, so each participant
///      gets their own NFT. The adapter holds the NFT; the returned token ID
///      is stored by the vault as the position identifier. removeLiquidity
///      burns exactly that token ID (full burn, no partial decreases).
///
/// @dev LP range: a single full-range tick window is used (tickLower =
///      MIN_TICK rounded to spacing, tickUpper = MAX_TICK rounded).
///      This keeps the adapter simple; production deployments should use a
///      tighter range around the clearing price.
contract SepoliaLiquidityAdapter is IVestaLiquidityAdapter {
    using SafeERC20 for IERC20;
    using CurrencyLibrary for Currency;

    // -------------------------------------------------------------------------
    // Constants
    // -------------------------------------------------------------------------

    /// @notice Uniswap v4 PositionManager on Ethereum Sepolia.
    address public constant POSITION_MANAGER = 0x429ba70129df741B2Ca2a85BC3A2a3328e5c09b4;

    /// @notice Pool fee tier: 0.30 % (3000 bps), same as Uniswap v3 default.
    uint24 public constant POOL_FEE = 3000;

    /// @notice Tick spacing that corresponds to the 0.30% fee tier.
    int24 public constant TICK_SPACING = 60;

    /// @notice Full-range tick bounds, rounded to TICK_SPACING
    ///         (887272 / 60 = 14787 rem 52, so ±14787*60 = ±887220).
    int24 public constant TICK_LOWER = -887_220;
    int24 public constant TICK_UPPER = 887_220;

    // -------------------------------------------------------------------------
    // State
    // -------------------------------------------------------------------------

    /// @notice The PoolKey for the token/ETH pool created by initializePool.
    PoolKey public poolKey;

    /// @notice The sqrtPriceX96 the pool was initialized at (for liquidity math).
    uint160 public sqrtPriceX96Stored;

    /// @notice True after initializePool has been called.
    bool public initialized;

    // -------------------------------------------------------------------------
    // Errors
    // -------------------------------------------------------------------------

    error AlreadyInitialized();
    error NotInitialized();
    error InvalidToken();
    error InvalidShares();
    error InvalidValue();
    error PriceOutOfRange();

    /// @notice The Permit2 contract bound to the Sepolia PositionManager.
    /// @dev Read on-chain (NOT hardcoded): Sepolia's Permit2 differs from mainnet's.
    function _permit2() internal view returns (IAllowanceTransfer) {
        return IPositionManagerPermit2(POSITION_MANAGER).permit2();
    }

    // -------------------------------------------------------------------------
    // IVestaLiquidityAdapter
    // -------------------------------------------------------------------------

    /// @inheritdoc IVestaLiquidityAdapter
    /// @dev clearingPrice is a Q96 value from the CCA. We convert it to
    ///      sqrtPriceX96 before calling PositionManager.initializePool().
    ///      Currency ordering: v4 requires currency0 < currency1.
    ///      ETH is represented as address(0), so it is always currency0.
    function initializePool(address token, uint256 clearingPriceQ96) external {
        if (initialized) revert AlreadyInitialized();
        if (token == address(0)) revert InvalidToken();
        if (clearingPriceQ96 == 0) revert InvalidValue();

        // ETH (address 0) is always the lower currency in v4.
        Currency currency0 = CurrencyLibrary.ADDRESS_ZERO; // ETH
        Currency currency1 = Currency.wrap(token);

        poolKey = PoolKey({
            currency0: currency0,
            currency1: currency1,
            fee: POOL_FEE,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(address(0)) // no hooks
        });

        // Convert Q96 currency-per-token clearing price to sqrtPriceX96.
        // Same conversion as LiquidityLauncher LBPStrategy: invert because
        // currency (ETH) is currency0, then sqrt with bounds checking.
        uint160 sqrtPriceX96 = TokenPricing.convertToSqrtPriceX96(
            TokenPricing.convertToPriceX192(clearingPriceQ96, true)
        );

        sqrtPriceX96Stored = sqrtPriceX96;
        IPositionManager(POSITION_MANAGER).initializePool(poolKey, sqrtPriceX96);
        initialized = true;
    }

    /// @inheritdoc IVestaLiquidityAdapter
    /// @dev Mints ONE full-range v4 LP position per call. ETH must be passed
    ///      as msg.value. The token must already be in this contract (sent by
    ///      the vault via safeTransfer). Returns the v4 ERC-721 token ID.
    /// @dev ERC20 settlement goes through Permit2: the adapter approves the
    ///      canonical Permit2 contract, then grants the PositionManager a
    ///      Permit2 allowance. PositionManager pulls via transferFrom(payer).
    function addLiquidity(address token, uint256 tokenAmount, uint256 ethAmount)
        external
        payable
        returns (uint256 shares)
    {
        if (!initialized) revert NotInitialized();
        if (Currency.unwrap(poolKey.currency1) != token) revert InvalidToken();
        if (msg.value != ethAmount || ethAmount == 0) revert InvalidValue();
        if (tokenAmount == 0) revert InvalidValue();

        // Approve Permit2 to pull tokens from this adapter, then grant the
        // PositionManager a Permit2 allowance for exactly tokenAmount.
        // Permit2 address is read from the PositionManager itself.
        IAllowanceTransfer permit2 = _permit2();
        IERC20(token).forceApprove(address(permit2), tokenAmount);
        permit2.approve(
            token, POSITION_MANAGER, uint160(tokenAmount), uint48(block.timestamp + 1 hours)
        );

        // Record the next position token ID before minting.
        uint256 nextId = IPositionManager(POSITION_MANAGER).nextTokenId();

        uint128 liquidity = _liquidityForAmounts(ethAmount, tokenAmount);

        // Encode: MINT_POSITION → SETTLE_PAIR → SWEEP (return unused ETH)
        bytes memory actions = abi.encodePacked(
            uint8(Actions.MINT_POSITION), uint8(Actions.SETTLE_PAIR), uint8(Actions.SWEEP)
        );

        bytes[] memory params = new bytes[](3);
        // MINT_POSITION params: poolKey, tickLower, tickUpper, liquidity,
        // amount0Max, amount1Max, recipient, hookData.
        // amount0 = ETH, amount1 = token. Recipient is this adapter (NFT owner).
        params[0] = abi.encode(
            poolKey,
            TICK_LOWER,
            TICK_UPPER,
            liquidity,
            uint128(ethAmount),
            uint128(tokenAmount),
            address(this), // LP NFT recipient
            bytes("") // hookData
        );
        // SETTLE_PAIR params: currency0, currency1
        params[1] = abi.encode(poolKey.currency0, poolKey.currency1);
        // SWEEP params: currency, recipient — sweeps leftover ETH back to vault
        params[2] = abi.encode(CurrencyLibrary.ADDRESS_ZERO, msg.sender);

        IPositionManager(POSITION_MANAGER).modifyLiquidities{ value: ethAmount }(
            abi.encode(actions, params), block.timestamp
        );

        // The token ID that was minted is `nextId`; return it as shares.
        shares = nextId;
    }

    /// @inheritdoc IVestaLiquidityAdapter
    /// @dev Burns the v4 ERC-721 position (shares = tokenId) and sends the
    ///      underlying ETH + tokens directly to `recipient` via TAKE_PAIR.
    function removeLiquidity(address recipient, uint256 shares)
        external
        returns (uint256 tokenAmount, uint256 ethAmount)
    {
        if (!initialized) revert NotInitialized();
        if (shares == 0) revert InvalidShares();

        // Encode: BURN_POSITION → TAKE_PAIR
        bytes memory actions = abi.encodePacked(uint8(Actions.BURN_POSITION), uint8(Actions.TAKE_PAIR));

        bytes[] memory params = new bytes[](2);
        // BURN_POSITION: tokenId, amount0Min, amount1Min, hookData (0 slippage for demo)
        params[0] = abi.encode(shares, uint128(0), uint128(0), bytes(""));
        // TAKE_PAIR: currency0 (ETH), currency1 (token), recipient
        params[1] = abi.encode(poolKey.currency0, poolKey.currency1, recipient);

        // Snapshot balances at recipient before the call to calculate deltas.
        uint256 ethBefore = recipient.balance;
        uint256 tokenBefore = IERC20(Currency.unwrap(poolKey.currency1)).balanceOf(recipient);

        IPositionManager(POSITION_MANAGER).modifyLiquidities(
            abi.encode(actions, params), block.timestamp
        );

        ethAmount = recipient.balance - ethBefore;
        tokenAmount = IERC20(Currency.unwrap(poolKey.currency1)).balanceOf(recipient) - tokenBefore;
    }

    // -------------------------------------------------------------------------
    // Internal helpers
    // -------------------------------------------------------------------------

    /// @dev Liquidity for a full-range position from both sides, using the
    ///      canonical LiquidityAmounts library and the stored pool price.
    function _liquidityForAmounts(uint256 ethAmount, uint256 tokenAmount)
        internal
        view
        returns (uint128)
    {
        uint160 sqrtA = TickMath.getSqrtPriceAtTick(TICK_LOWER);
        uint160 sqrtB = TickMath.getSqrtPriceAtTick(TICK_UPPER);
        return LiquidityAmounts.getLiquidityForAmounts(
            sqrtPriceX96Stored, sqrtA, sqrtB, ethAmount, tokenAmount
        );
    }

    receive() external payable { }
}
