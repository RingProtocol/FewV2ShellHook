// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TransientStateLibrary} from "@uniswap/v4-core/src/libraries/TransientStateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {HookMiner} from "v4-periphery/src/utils/HookMiner.sol";
import {LiquidityAmounts} from "v4-periphery/src/libraries/LiquidityAmounts.sol";
import {Actions} from "v4-periphery/src/libraries/Actions.sol";
import {ActionConstants} from "v4-periphery/src/libraries/ActionConstants.sol";
import {IPositionManager} from "v4-periphery/src/interfaces/IPositionManager.sol";
import {IV4Quoter} from "v4-periphery/src/interfaces/IV4Quoter.sol";
import {IV4Router} from "v4-periphery/src/interfaces/IV4Router.sol";
import {IWETH9} from "v4-periphery/src/interfaces/external/IWETH9.sol";
import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";

import {FewV2ShellHookBase} from "../../src/FewV2ShellHookBase.sol";
import {IFewFactory} from "../../src/interfaces/external/IFewFactory.sol";
import {ISwapV2Pair, ISwapV2Factory} from "../../src/interfaces/external/IFewV2.sol";
import {IV4FeeRecipient} from "../../src/interfaces/external/IV4FeeRecipient.sol";

interface IEthWbtcUniversalRouter {
    function execute(bytes calldata commands, bytes[] calldata inputs, uint256 deadline) external payable;
}

/// @notice Apples-to-apples proof against the deployed FewV4ShellHook market: users see ETH/WBTC,
///         while this candidate executes against the canonical Ring Swap v2 fwWBTC/fwWETH pair.
contract EthWbtcShellParityForkTest is Test {
    using SafeERC20 for IERC20;
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;
    using TransientStateLibrary for IPoolManager;

    IPoolManager internal constant PM = IPoolManager(0x000000000004444c5dc75cB358380D2e3dE08A90);
    IPositionManager internal constant POSM = IPositionManager(0xbD216513d74C8cf14cf4747E6AaA6420FF64ee9e);
    IV4Quoter internal constant QUOTER = IV4Quoter(0x52F0E24D1c21C8A0cB1e5a5dD6198556BD9E1203);
    IAllowanceTransfer internal constant PERMIT2 = IAllowanceTransfer(0x000000000022D473030F116dDEE9F6B43aC78BA3);
    IFewFactory internal constant FEW_FACTORY = IFewFactory(0x7D86394139bf1122E82FDF45Bb4e3b038A4464DD);
    ISwapV2Factory internal constant FEWV2_FACTORY = ISwapV2Factory(0xeb2A625B704d73e82946D8d026E1F588Eed06416);

    address internal constant ROUTER = 0x66a9893cC07D91D95644AEDD05D03f95e1dBA8Af;
    address internal constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address internal constant WBTC = 0x2260FAC5E5542a773Aa44fBCfeDf7C193bc2C599;
    address internal constant USDT = 0xdAC17F958D2ee523a2206206994597C13D831ec7;
    address internal constant FW_ETH = 0xa250CC729Bb3323e7933022a67B52200fE354767;
    address internal constant FW_WBTC = 0x2078f336Fdd260f708BEc4a20c82b063274E1b23;
    address internal constant FW_USDT = 0xef87f4608e601E8564800265AeE1c1FfaDF73283;
    address internal constant FEWV2_PAIR = 0x00B06862dE00a7e67a2d6d3FbEEa592A32460de0;
    address internal constant FEWV2_USDT_PAIR = 0x147D15e009a63Ebed5196EA029679329204f98fd;
    address internal constant USER = address(0xB0B);
    address internal constant LP = address(0xA110C);
    address internal constant RESIDUAL_RECIPIENT = address(0xFEE);

    uint256 internal constant BLOCK = 25_934_149;
    uint128 internal constant ETH_CAP = 0.0025 ether;
    uint128 internal constant WBTC_CAP = 10_000;
    uint128 internal constant USDT_CAP = 5e6;
    int24 internal constant LOWER = -887270;
    int24 internal constant UPPER = 887270;

    bool internal forked;
    FewV2ShellHookBase internal hook;
    PoolKey internal key;
    PoolKey internal usdtKey;
    uint128 internal liquidity;
    uint128 internal usdtLiquidity;
    uint256 internal nft;
    uint256 internal ethDeposited;
    uint256 internal wbtcDeposited;
    uint256 internal usdtDeposited;

    struct ShellSnapshot {
        uint160 price;
        int24 tick;
        uint128 liquidity;
        uint256 fee0;
        uint256 fee1;
        uint112 reserve0;
        uint112 reserve1;
    }

    function setUp() public {
        string memory rpc = vm.envOr("ETH_RPC_URL", string(""));
        if (bytes(rpc).length == 0) return;
        vm.createSelectFork(rpc, vm.envOr("TEST_FORK_BLOCK", BLOCK));
        forked = true;

        hook = _deploy();
        key = PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(WBTC),
            fee: 3000,
            tickSpacing: 1,
            hooks: IHooks(address(hook))
        });
        uint160 initialPrice = hook.previewInitializationPrice(key);
        PM.initialize(key, initialPrice);
        liquidity = LiquidityAmounts.getLiquidityForAmounts(
            initialPrice, TickMath.getSqrtPriceAtTick(LOWER), TickMath.getSqrtPriceAtTick(UPPER), ETH_CAP, WBTC_CAP
        );

        usdtKey = PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(USDT),
            fee: 3000,
            tickSpacing: 1,
            hooks: IHooks(address(hook))
        });
        uint160 usdtInitialPrice = hook.previewInitializationPrice(usdtKey);
        PM.initialize(usdtKey, usdtInitialPrice);
        usdtLiquidity = LiquidityAmounts.getLiquidityForAmounts(
            usdtInitialPrice, TickMath.getSqrtPriceAtTick(LOWER), TickMath.getSqrtPriceAtTick(UPPER), ETH_CAP, USDT_CAP
        );

        vm.deal(LP, 1 ether);
        deal(WBTC, LP, 1e8);
        deal(USDT, LP, 100e6);
        _approveToken(WBTC, LP, address(POSM), WBTC_CAP);
        _approveToken(USDT, LP, address(POSM), USDT_CAP);

        vm.deal(USER, 1 ether);
        deal(WBTC, USER, 1e8);
        deal(USDT, USER, 100e6);
        _approveToken(WBTC, USER, ROUTER, type(uint160).max);
        _approveToken(USDT, USER, ROUTER, type(uint160).max);
    }

    modifier onFork() {
        if (!forked) vm.skip(true);
        _;
    }

    function test_ethWbtc_originShellLp_fourUniversalRouterModes_useFewV2AndRecoverCapital() public onFork {
        _assertRegisteredRoute();
        _mint();
        ShellSnapshot memory beforeState = _snapshot(FEWV2_PAIR);

        _runExactInput(true, 0.0001 ether);
        _runExactOutput(true, 100);
        _runExactInput(false, 500);
        _runExactOutput(false, 0.00002 ether);

        _assertExecutionState(beforeState, FEWV2_PAIR);
        _burnAndCheck();
    }

    function test_ethWbtc_protocolFees_fourUniversalRouterModes_payMainnetJarAndRecoverCapital() public onFork {
        _assertRegisteredRoute();
        address controller = PM.protocolFeeController();
        address jar = IV4FeeRecipient(controller).TOKEN_JAR();
        assertGt(jar.code.length, 0, "real mainnet TokenJar");
        vm.prank(controller);
        PM.setProtocolFee(key, uint24(40) | (uint24(12) << 12));
        _mint();
        ShellSnapshot memory beforeState = _snapshot(FEWV2_PAIR);
        uint256 jarEth = jar.balance;
        uint256 jarWbtc = IERC20(WBTC).balanceOf(jar);

        _runExactInput(true, 0.0001 ether);
        _runExactOutput(true, 100);
        _runExactInput(false, 500);
        _runExactOutput(false, 0.00002 ether);

        assertGt(jar.balance, jarEth, "TokenJar receives native ETH protocol fees");
        assertGt(IERC20(WBTC).balanceOf(jar), jarWbtc, "TokenJar receives WBTC protocol fees");
        _assertExecutionState(beforeState, FEWV2_PAIR);
        _burnAndCheck();
    }

    function test_ethUsdt_nonStandardToken_fourUniversalRouterModes_useFewV2AndRecoverCapital() public onFork {
        key = usdtKey;
        (address few0, address few1, address pair) = hook.registeredRouteFor(key.toId());
        assertEq(few0, FW_ETH, "ETH endpoint wraps to fwWETH");
        assertEq(few1, FW_USDT, "USDT endpoint wraps to fwUSDT");
        assertEq(pair, FEWV2_USDT_PAIR, "execution source is canonical Ring Swap v2 fwWETH/fwUSDT");

        _mintUsdt();
        ShellSnapshot memory beforeState = _snapshot(FEWV2_USDT_PAIR);
        _runExactInput(true, 0.0001 ether);
        _runExactOutput(true, 100_000);
        _runExactInput(false, 500_000);
        _runExactOutput(false, 0.00002 ether);
        _assertExecutionState(beforeState, FEWV2_USDT_PAIR);
        _burnUsdtAndCheck();
    }

    function _assertRegisteredRoute() internal view {
        (address few0, address few1, address pair) = hook.registeredRouteFor(key.toId());
        assertEq(few0, FW_ETH, "ETH endpoint wraps to fwWETH");
        assertEq(few1, FW_WBTC, "WBTC endpoint wraps to fwWBTC");
        assertEq(pair, FEWV2_PAIR, "execution source is canonical Ring Swap v2 fwWBTC/fwWETH");
    }

    function _snapshot(address pair) internal view returns (ShellSnapshot memory state) {
        (state.price, state.tick,,) = PM.getSlot0(key.toId());
        state.liquidity = PM.getLiquidity(key.toId());
        (state.fee0, state.fee1) = PM.getFeeGrowthGlobals(key.toId());
        (state.reserve0, state.reserve1,) = ISwapV2Pair(pair).getReserves();
    }

    function _assertExecutionState(ShellSnapshot memory beforeState, address pair) internal view {
        (uint112 reserve0After, uint112 reserve1After,) = ISwapV2Pair(pair).getReserves();
        assertTrue(
            reserve0After != beforeState.reserve0 || reserve1After != beforeState.reserve1, "FewV2 reserves move"
        );
        (uint160 shellPriceAfter, int24 shellTickAfter,,) = PM.getSlot0(key.toId());
        (uint256 shellFee0After, uint256 shellFee1After) = PM.getFeeGrowthGlobals(key.toId());
        assertEq(shellPriceAfter, beforeState.price, "Shell marker price stays unchanged");
        assertEq(shellTickAfter, beforeState.tick, "Shell marker tick stays unchanged");
        assertEq(PM.getLiquidity(key.toId()), beforeState.liquidity, "originToken Shell LP stays intact");
        assertEq(shellFee0After, beforeState.fee0, "Shell LP earns no Hook trade fee in ETH");
        assertEq(shellFee1After, beforeState.fee1, "Shell LP earns no Hook trade fee in WBTC");
    }

    function _runExactInput(bool zeroForOne, uint128 amountIn) internal {
        Currency input = zeroForOne ? key.currency0 : key.currency1;
        Currency output = zeroForOne ? key.currency1 : key.currency0;
        uint128 amountOut = uint128(hook.quote(zeroForOne, -int256(uint256(amountIn)), key.toId()));
        _assertOfficialQuoter(zeroForOne, false, amountIn, amountOut);

        uint256 userInputBefore = _balance(input, USER);
        uint256 userOutputBefore = _balance(output, USER);
        uint256 pmInputBefore = _balance(input, address(PM));
        uint256 pmOutputBefore = _balance(output, address(PM));

        bytes[] memory params = new bytes[](3);
        params[0] = abi.encode(input, uint256(amountIn), true);
        params[1] = abi.encode(IV4Router.ExactInputSingleParams(key, zeroForOne, amountIn, amountOut, ""));
        params[2] = abi.encode(output, uint256(amountOut));
        _execute(
            abi.encodePacked(uint8(Actions.SETTLE), uint8(Actions.SWAP_EXACT_IN_SINGLE), uint8(Actions.TAKE_ALL)),
            params,
            Currency.unwrap(input) == address(0) ? amountIn : 0
        );

        assertEq(userInputBefore - _balance(input, USER), amountIn, "exact-input origin token spent");
        assertEq(_balance(output, USER) - userOutputBefore, amountOut, "exact-input origin token received");
        _assertClean(pmInputBefore, pmOutputBefore, input, output);
    }

    function _runExactOutput(bool zeroForOne, uint128 amountOut) internal {
        Currency input = zeroForOne ? key.currency0 : key.currency1;
        Currency output = zeroForOne ? key.currency1 : key.currency0;
        uint128 amountIn = uint128(hook.quote(zeroForOne, int256(uint256(amountOut)), key.toId()));
        _assertOfficialQuoter(zeroForOne, true, amountOut, amountIn);

        uint256 userInputBefore = _balance(input, USER);
        uint256 userOutputBefore = _balance(output, USER);
        uint256 pmInputBefore = _balance(input, address(PM));
        uint256 pmOutputBefore = _balance(output, address(PM));

        bytes[] memory params = new bytes[](3);
        params[0] = abi.encode(IV4Router.ExactOutputSingleParams(key, zeroForOne, amountOut, amountIn, ""));
        params[1] = abi.encode(input, ActionConstants.OPEN_DELTA, true);
        params[2] = abi.encode(output, uint256(amountOut));
        _execute(
            abi.encodePacked(uint8(Actions.SWAP_EXACT_OUT_SINGLE), uint8(Actions.SETTLE), uint8(Actions.TAKE_ALL)),
            params,
            Currency.unwrap(input) == address(0) ? amountIn : 0
        );

        assertEq(userInputBefore - _balance(input, USER), amountIn, "exact-output origin token spent");
        assertEq(_balance(output, USER) - userOutputBefore, amountOut, "exact-output origin token received");
        _assertClean(pmInputBefore, pmOutputBefore, input, output);
    }

    function _assertOfficialQuoter(bool zeroForOne, bool exactOutput, uint128 specified, uint128 expected) internal {
        IV4Quoter.QuoteExactSingleParams memory params =
            IV4Quoter.QuoteExactSingleParams(key, zeroForOne, specified, "");
        (uint256 quote,) = exactOutput ? QUOTER.quoteExactOutputSingle(params) : QUOTER.quoteExactInputSingle(params);
        assertEq(quote, expected, "official V4Quoter matches Hook quote");
    }

    function _execute(bytes memory actions, bytes[] memory params, uint256 value) internal {
        bytes[] memory inputs = new bytes[](1);
        inputs[0] = abi.encode(actions, params);
        vm.prank(USER);
        uint256 gasBefore = gasleft();
        IEthWbtcUniversalRouter(ROUTER).execute{value: value}(hex"10", inputs, block.timestamp + 60);
        emit log_named_uint("Universal Router execution gas", gasBefore - gasleft());
    }

    function _assertClean(uint256 pmInputBefore, uint256 pmOutputBefore, Currency input, Currency output)
        internal
        view
    {
        (address few0, address few1,) = hook.registeredRouteFor(key.toId());
        assertEq(_balance(input, address(PM)), pmInputBefore, "PoolManager input working capital restored");
        assertEq(_balance(output, address(PM)), pmOutputBefore, "PoolManager output working capital restored");
        assertEq(_balance(input, address(hook)), 0, "Hook retains no origin input");
        assertEq(_balance(output, address(hook)), 0, "Hook retains no origin output");
        assertEq(IERC20(few0).balanceOf(address(hook)), 0, "Hook retains no FewToken0");
        assertEq(IERC20(few1).balanceOf(address(hook)), 0, "Hook retains no FewToken1");
        assertEq(PM.getNonzeroDeltaCount(), 0, "PoolManager has no open delta");
        assertFalse(PM.isUnlocked(), "PoolManager lock is closed");
    }

    function _mint() internal {
        uint256 ethBefore = LP.balance;
        uint256 wbtcBefore = IERC20(WBTC).balanceOf(LP);
        nft = POSM.nextTokenId();
        bytes[] memory params = new bytes[](3);
        params[0] = abi.encode(key, LOWER, UPPER, uint256(liquidity), ETH_CAP, WBTC_CAP, LP, bytes(""));
        params[1] = abi.encode(key.currency0, key.currency1);
        params[2] = abi.encode(key.currency0, LP);
        bytes memory actions =
            abi.encodePacked(uint8(Actions.MINT_POSITION), uint8(Actions.SETTLE_PAIR), uint8(Actions.SWEEP));
        vm.prank(LP);
        POSM.modifyLiquidities{value: ETH_CAP}(abi.encode(actions, params), block.timestamp + 60);
        ethDeposited = ethBefore - LP.balance;
        wbtcDeposited = wbtcBefore - IERC20(WBTC).balanceOf(LP);
        assertGt(ethDeposited, 0, "origin ETH deposited");
        assertGt(wbtcDeposited, 0, "origin WBTC deposited");
        assertEq(IERC721(address(POSM)).ownerOf(nft), LP, "LP owns the Shell position NFT");
        assertEq(PM.getLiquidity(key.toId()), liquidity, "Shell Pool has nonzero v4 liquidity");
    }

    function _burnAndCheck() internal {
        uint256 ethBefore = LP.balance;
        uint256 wbtcBefore = IERC20(WBTC).balanceOf(LP);
        bytes[] memory params = new bytes[](2);
        params[0] = abi.encode(nft, uint128(0), uint128(0), bytes(""));
        params[1] = abi.encode(key.currency0, key.currency1, LP);
        bytes memory actions = abi.encodePacked(uint8(Actions.BURN_POSITION), uint8(Actions.TAKE_PAIR));
        vm.prank(LP);
        POSM.modifyLiquidities(abi.encode(actions, params), block.timestamp + 60);
        assertApproxEqAbs(LP.balance - ethBefore, ethDeposited, 1, "origin ETH capital recovered");
        assertApproxEqAbs(IERC20(WBTC).balanceOf(LP) - wbtcBefore, wbtcDeposited, 1, "origin WBTC capital recovered");
        assertEq(PM.getLiquidity(key.toId()), 0, "Shell position fully removed");
    }

    function _mintUsdt() internal {
        uint256 ethBefore = LP.balance;
        uint256 usdtBefore = IERC20(USDT).balanceOf(LP);
        nft = POSM.nextTokenId();
        bytes[] memory params = new bytes[](3);
        params[0] = abi.encode(key, LOWER, UPPER, uint256(usdtLiquidity), ETH_CAP, USDT_CAP, LP, bytes(""));
        params[1] = abi.encode(key.currency0, key.currency1);
        params[2] = abi.encode(key.currency0, LP);
        bytes memory actions =
            abi.encodePacked(uint8(Actions.MINT_POSITION), uint8(Actions.SETTLE_PAIR), uint8(Actions.SWEEP));
        vm.prank(LP);
        POSM.modifyLiquidities{value: ETH_CAP}(abi.encode(actions, params), block.timestamp + 60);
        ethDeposited = ethBefore - LP.balance;
        usdtDeposited = usdtBefore - IERC20(USDT).balanceOf(LP);
        assertGt(ethDeposited, 0, "origin ETH deposited");
        assertGt(usdtDeposited, 0, "origin USDT deposited");
        assertEq(IERC721(address(POSM)).ownerOf(nft), LP, "LP owns the USDT Shell position NFT");
        assertEq(PM.getLiquidity(key.toId()), usdtLiquidity, "USDT Shell Pool has nonzero v4 liquidity");
    }

    function _burnUsdtAndCheck() internal {
        uint256 ethBefore = LP.balance;
        uint256 usdtBefore = IERC20(USDT).balanceOf(LP);
        bytes[] memory params = new bytes[](2);
        params[0] = abi.encode(nft, uint128(0), uint128(0), bytes(""));
        params[1] = abi.encode(key.currency0, key.currency1, LP);
        bytes memory actions = abi.encodePacked(uint8(Actions.BURN_POSITION), uint8(Actions.TAKE_PAIR));
        vm.prank(LP);
        POSM.modifyLiquidities(abi.encode(actions, params), block.timestamp + 60);
        assertApproxEqAbs(LP.balance - ethBefore, ethDeposited, 1, "origin ETH capital recovered");
        assertApproxEqAbs(IERC20(USDT).balanceOf(LP) - usdtBefore, usdtDeposited, 1, "origin USDT capital recovered");
        assertEq(PM.getLiquidity(key.toId()), 0, "USDT Shell position fully removed");
    }

    function _approveToken(address token, address owner, address spender, uint160 amount) internal {
        vm.startPrank(owner);
        IERC20(token).forceApprove(address(PERMIT2), amount);
        PERMIT2.approve(token, spender, amount, uint48(block.timestamp + 1 days));
        vm.stopPrank();
    }

    function _balance(Currency currency, address account) internal view returns (uint256) {
        address token = Currency.unwrap(currency);
        return token == address(0) ? account.balance : IERC20(token).balanceOf(account);
    }

    function _deploy() internal returns (FewV2ShellHookBase deployed) {
        bytes memory args =
            abi.encode(PM, FEW_FACTORY, FEWV2_FACTORY, IWETH9(WETH), QUOTER, true, address(this), RESIDUAL_RECIPIENT);
        uint160 flags = Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG;
        (address predicted, bytes32 salt) =
            HookMiner.find(address(this), flags, type(FewV2ShellHookBase).creationCode, args);
        deployed = new FewV2ShellHookBase{salt: salt}(
            PM, FEW_FACTORY, FEWV2_FACTORY, IWETH9(WETH), QUOTER, true, address(this), RESIDUAL_RECIPIENT
        );
        assertEq(address(deployed), predicted, "mined Hook address");
    }
}
