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

/// @notice Sepolia adapter that wires Vesta's liquidity lifecycle into the
///         Uniswap v4 PositionManager deployed on Ethereum Sepolia.
///
/// Sepolia deployment addresses (immutable, baked in at construction):
///   Uniswap v4 PositionManager : 0x429ba70129df741B2Ca2a85BC3A2a3328e5c09b4
///
/// Interface mapping (IVestaLiquidityAdapter → v4 PositionManager):
///   initializePool  → IPoolInitializer_v4.initializePool(poolKey, sqrtPriceX96)
///   addLiquidity    → modifyLiquidities(MINT_POSITION + SETTLE_PAIR + SWEEP)
///   removeLiquidity → modifyLiquidities(BURN_POSITION + TAKE_PAIR)
///
/// @dev Price conversion: the CCA clearing price is a Q96 fixed-point number
///      representing (token / ETH) as `price * 2^96`.  Uniswap v4 expresses
///      the pool price as sqrtPriceX96 = sqrt(price) * 2^96.  Converting:
///
///        sqrtPriceX96 = sqrt(clearingPriceQ96 * 2^96) * 2^48
///                     = sqrt(clearingPriceQ96) * 2^48
///
///      Because currency0 must be the lower address, we detect whether ETH
///      (address(0)) or the token comes first and invert the price when needed.
///
/// @dev Shares: the vault stores the v4 ERC-721 position token ID as its
///      `shares` value.  The adapter is the NFT owner for the lifetime of the
///      locked position.  removeLiquidity burns the NFT and returns the
///      underlying tokens + ETH to the recipient.
///
/// @dev LP range: a single full-range tick window is used (tickLower =
///      TickMath.MIN_TICK rounded to spacing, tickUpper = MAX_TICK rounded).
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

    /// @notice Approximate full-range tick bounds, rounded to TICK_SPACING.
    int24 public constant TICK_LOWER = -887_220;
    int24 public constant TICK_UPPER = 887_220;

    // -------------------------------------------------------------------------
    // State
    // -------------------------------------------------------------------------

    /// @notice The PoolKey for the token/ETH pool created by initializePool.
    PoolKey public poolKey;

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

    // -------------------------------------------------------------------------
    // IVestaLiquidityAdapter
    // -------------------------------------------------------------------------

    /// @inheritdoc IVestaLiquidityAdapter
    /// @dev clearingPrice is a Q96 value from the CCA.  We convert it to
    ///      sqrtPriceX96 before calling PositionManager.initializePool().
    ///
    ///      Currency ordering: v4 requires currency0 < currency1.
    ///      ETH is represented as address(0), so it is always currency0.
    function initializePool(address token, uint256 clearingPriceQ96) external {
        if (initialized) revert AlreadyInitialized();

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

        // Convert Q96 clearing price (token/ETH) to sqrtPriceX96.
        // clearingPriceQ96 = (tokenAmount / ethAmount) * 2^96
        // sqrtPriceX96     = sqrt(clearingPriceQ96) * 2^48
        //
        // Because currency0=ETH and currency1=token, v4's price is (token/ETH),
        // which matches the CCA price convention directly.
        uint160 sqrtPriceX96 = _toSqrtPriceX96(clearingPriceQ96);

        IPositionManager(POSITION_MANAGER).initializePool(poolKey, sqrtPriceX96);
        initialized = true;
    }

    /// @inheritdoc IVestaLiquidityAdapter
    /// @dev Mints a full-range v4 LP position.  ETH must be passed as msg.value.
    ///      The token must already be in this contract (sent by the vault via safeTransfer).
    ///      Returns the v4 ERC-721 position token ID as `shares`.
    function addLiquidity(address token, uint256 tokenAmount, uint256 ethAmount)
        external
        payable
        returns (uint256 shares)
    {
        if (!initialized) revert NotInitialized();
        if (Currency.unwrap(poolKey.currency1) != token) revert InvalidToken();
        if (msg.value != ethAmount || ethAmount == 0) revert InvalidValue();

        // Approve PositionManager to spend the token held by this adapter.
        IERC20(token).forceApprove(POSITION_MANAGER, tokenAmount);

        // Record the next position token ID before minting.
        uint256 nextId = IPositionManager(POSITION_MANAGER).nextTokenId();

        // Encode: MINT_POSITION → SETTLE_PAIR → SWEEP (return unused ETH)
        bytes memory actions = abi.encodePacked(
            uint8(Actions.MINT_POSITION), uint8(Actions.SETTLE_PAIR), uint8(Actions.SWEEP)
        );

        bytes[] memory params = new bytes[](3);
        // MINT_POSITION params: poolKey, tickLower, tickUpper, liquidity, amount0Max, amount1Max, recipient, hookData
        // We pass type(uint256).max as slippage bounds (no MEV on testnet demo) and
        // address(this) as recipient so the adapter holds the NFT.
        params[0] = abi.encode(
            poolKey,
            TICK_LOWER,
            TICK_UPPER,
            _liquidityForAmounts(ethAmount, tokenAmount),
            ethAmount, // amount0Max (ETH)
            tokenAmount, // amount1Max (token)
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
    ///      underlying ETH + tokens directly to `recipient`.
    function removeLiquidity(address recipient, uint256 shares)
        external
        returns (uint256 tokenAmount, uint256 ethAmount)
    {
        if (!initialized) revert NotInitialized();
        if (shares == 0) revert InvalidShares();

        uint128 liquidity = IPositionManager(POSITION_MANAGER).getPositionLiquidity(shares);

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

        // Silence the unused variable warning; liquidity is queried for potential future use.
        liquidity;
    }

    // -------------------------------------------------------------------------
    // Internal helpers
    // -------------------------------------------------------------------------

    /// @dev Integer square-root of x, using Babylonian method.
    function _sqrt(uint256 x) internal pure returns (uint256 result) {
        if (x == 0) return 0;
        result = x;
        uint256 k = (x >> 1) + 1;
        while (k < result) {
            result = k;
            k = (x / k + k) >> 1;
        }
    }

    /// @dev Converts a Q96 clearing price (token/ETH * 2^96) to sqrtPriceX96.
    ///      sqrtPriceX96 = sqrt(priceQ96) * 2^48
    ///      Uses 256-bit intermediate arithmetic to avoid overflow.
    function _toSqrtPriceX96(uint256 priceQ96) internal pure returns (uint160) {
        // sqrt(priceQ96 * 2^96) = sqrt(priceQ96) * 2^48
        // We compute sqrt(priceQ96) first (result is Q48 already scaled).
        uint256 sqrtPriceQ48 = _sqrt(priceQ96);
        // Shift left 48 bits to express as sqrtPriceX96.
        return uint160(sqrtPriceQ48 << 48);
    }

    /// @dev Approximate liquidity from ETH and token amounts for a full-range position.
    ///      For a full-range position the simplest approximation is to use the
    ///      geometric-mean approach, which is sufficient for a testnet demo.
    ///      Production adapters should use the v4 LiquidityAmounts library.
    function _liquidityForAmounts(uint256 ethAmount, uint256 tokenAmount)
        internal
        pure
        returns (uint128)
    {
        // Simple heuristic: use the smaller amount (in their native units) as
        // the liquidity approximation, capped to uint128.
        uint256 liq = ethAmount < tokenAmount ? ethAmount : tokenAmount;
        return uint128(liq > type(uint128).max ? type(uint128).max : liq);
    }

    receive() external payable { }
}
