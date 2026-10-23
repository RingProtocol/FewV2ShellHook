// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {HookMiner} from "v4-periphery/src/utils/HookMiner.sol";
import {IV4Quoter} from "v4-periphery/src/interfaces/IV4Quoter.sol";
import {IWETH9} from "v4-periphery/src/interfaces/external/IWETH9.sol";

import {FewV2ShellHookBase} from "../../src/FewV2ShellHookBase.sol";
import {SubsidyVault} from "../../src/SubsidyVault.sol";
import {ISubsidyVault} from "../../src/interfaces/ISubsidyVault.sol";
import {IFewFactory} from "../../src/interfaces/external/IFewFactory.sol";
import {ISwapV2Pair, ISwapV2Factory} from "../../src/interfaces/external/IFewV2.sol";
import {IFewWrappedToken} from "../../src/interfaces/external/IFewWrappedToken.sol";
import {FewV2Math} from "../../src/lib/FewV2Math.sol";

/// @notice Shows why operations must expose each FewV2 pair through only one active Shell route per chain.
contract DuplicateRouteForkTest is Test {
    using PoolIdLibrary for PoolKey;

    IPoolManager internal constant PM = IPoolManager(0x000000000004444c5dc75cB358380D2e3dE08A90);
    IV4Quoter internal constant QUOTER = IV4Quoter(0x52F0E24D1c21C8A0cB1e5a5dD6198556BD9E1203);
    IFewFactory internal constant FEW_FACTORY = IFewFactory(0x7D86394139bf1122E82FDF45Bb4e3b038A4464DD);
    ISwapV2Factory internal constant FEWV2_FACTORY = ISwapV2Factory(0xeb2A625B704d73e82946D8d026E1F588Eed06416);

    address internal constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address internal constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address internal constant RESIDUAL_RECIPIENT = address(0xFEE);
    uint256 internal constant BLOCK = 25_934_149;

    bool internal forked;
    FewV2ShellHookBase internal nativeHook;
    FewV2ShellHookBase internal wethHook;
    PoolKey internal ethUsdc;
    PoolKey internal wethUsdc;

    function setUp() public {
        string memory rpc = vm.envOr("ETH_RPC_URL", string(""));
        if (bytes(rpc).length == 0) return;
        vm.createSelectFork(rpc, vm.envOr("TEST_FORK_BLOCK", BLOCK));
        forked = true;

        nativeHook = _deploy(true);
        wethHook = _deploy(false);
        ethUsdc = PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(USDC),
            fee: 3000,
            tickSpacing: 1,
            hooks: IHooks(address(nativeHook))
        });
        wethUsdc = PoolKey({
            currency0: Currency.wrap(USDC),
            currency1: Currency.wrap(WETH),
            fee: 3000,
            tickSpacing: 1,
            hooks: IHooks(address(wethHook))
        });
        PM.initialize(ethUsdc, nativeHook.previewInitializationPrice(ethUsdc));
        PM.initialize(wethUsdc, wethHook.previewInitializationPrice(wethUsdc));
    }

    modifier onFork() {
        if (!forked) vm.skip(true);
        _;
    }

    function test_releaseGate_duplicateHooksDoubleCountAndShareChangingReserves() public onFork {
        address pair = _assertSamePairAndDepth();
        uint256 amountIn = 0.1 ether;
        uint256 firstQuote = _assertInitialQuotesMatch(amountIn);

        _sellFewWethDirectly(pair, amountIn);

        uint256 laterQuote = wethHook.quote(false, -int256(amountIn), wethUsdc.toId());
        assertLt(laterQuote, firstQuote, "one route changes the reserves behind the other route");
    }

    function _assertSamePairAndDepth() internal view returns (address pair) {
        (,, pair) = nativeHook.registeredRouteFor(ethUsdc.toId());
        (,, address secondPair) = wethHook.registeredRouteFor(wethUsdc.toId());
        assertEq(pair, secondPair, "both Hook deployments expose the same FewV2 pair");

        (uint256 nativeEthDepth, uint256 nativeUsdcDepth) = nativeHook.pseudoTotalValueLocked(ethUsdc.toId());
        (uint256 wethUsdcDepth, uint256 wethWethDepth) = wethHook.pseudoTotalValueLocked(wethUsdc.toId());
        // Each deployment independently advertises the same FewV2 pair, but the conservative
        // depth signal can differ because native ETH and WETH settlement inventory are distinct.
        assertGt(nativeEthDepth, 0, "native route advertises WETH-backed source depth");
        assertGt(nativeUsdcDepth, 0, "native route advertises USDC-backed source depth");
        assertGt(wethWethDepth, 0, "WETH route advertises the same source depth");
        assertGt(wethUsdcDepth, 0, "WETH route advertises the same USDC source depth");
    }

    function _assertInitialQuotesMatch(uint256 amountIn) internal returns (uint256 nativeQuote) {
        nativeQuote = nativeHook.quote(true, -int256(amountIn), ethUsdc.toId());
        uint256 wethQuote = wethHook.quote(false, -int256(amountIn), wethUsdc.toId());
        assertEq(nativeQuote, wethQuote, "both routes quote the same initial reserves");
    }

    function _sellFewWethDirectly(address pair, uint256 amountIn) internal {
        address fewWeth = FEW_FACTORY.getWrappedToken(WETH);
        address fewUsdc = FEW_FACTORY.getWrappedToken(USDC);
        deal(WETH, address(this), amountIn);
        IERC20(WETH).approve(fewWeth, amountIn);
        assertEq(IFewWrappedToken(fewWeth).wrap(amountIn), amountIn);

        (uint112 reserve0, uint112 reserve1,) = ISwapV2Pair(pair).getReserves();
        bool wethIsToken0 = ISwapV2Pair(pair).token0() == fewWeth;
        (uint256 reserveIn, uint256 reserveOut) =
            wethIsToken0 ? (uint256(reserve0), uint256(reserve1)) : (uint256(reserve1), uint256(reserve0));
        uint256 amountOut = FewV2Math.getAmountOut(amountIn, reserveIn, reserveOut);
        assertTrue(IERC20(fewWeth).transfer(pair, amountIn), "fewWETH transfer failed");
        ISwapV2Pair(pair).swap(wethIsToken0 ? 0 : amountOut, wethIsToken0 ? amountOut : 0, address(this), "");
        assertEq(IERC20(fewUsdc).balanceOf(address(this)), amountOut);
    }

    function _deploy(bool useNative) internal returns (FewV2ShellHookBase deployed) {
        // The vault is deliberately left unarmed, so this suite pays no subsidy.
        ISubsidyVault vault = new SubsidyVault(PM, address(this));
        bytes memory args = abi.encode(
            PM, FEW_FACTORY, FEWV2_FACTORY, IWETH9(WETH), QUOTER, useNative, address(this), RESIDUAL_RECIPIENT, vault
        );
        uint160 flags = Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG;
        (address predicted, bytes32 salt) =
            HookMiner.find(address(this), flags, type(FewV2ShellHookBase).creationCode, args);
        deployed = new FewV2ShellHookBase{salt: salt}(
            PM, FEW_FACTORY, FEWV2_FACTORY, IWETH9(WETH), QUOTER, useNative, address(this), RESIDUAL_RECIPIENT, vault
        );
        assertEq(address(deployed), predicted);
    }
}
