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
import {Actions} from "v4-periphery/src/libraries/Actions.sol";
import {ActionConstants} from "v4-periphery/src/libraries/ActionConstants.sol";
import {IV4Quoter} from "v4-periphery/src/interfaces/IV4Quoter.sol";
import {IV4Router} from "v4-periphery/src/interfaces/IV4Router.sol";
import {IWETH9} from "v4-periphery/src/interfaces/external/IWETH9.sol";
import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";

import {FewV2ShellHookBase} from "../../src/FewV2ShellHookBase.sol";
import {SubsidyVault} from "../../src/SubsidyVault.sol";
import {ISubsidyVault} from "../../src/interfaces/ISubsidyVault.sol";
import {IFewFactory} from "../../src/interfaces/external/IFewFactory.sol";
import {ISwapV2Factory} from "../../src/interfaces/external/IFewV2.sol";
import {IFewWrappedToken} from "../../src/interfaces/external/IFewWrappedToken.sol";

interface IUniversalRouterWethTest {
    function execute(bytes calldata commands, bytes[] calldata inputs, uint256 deadline) external payable;
}

interface IRouterFeeManagerOwner {
    function owner() external view returns (address);
}

contract RouterFeeAdapterMock {
    address public constant TOKEN_JAR = address(0xCAFE);
}

/// @notice WETH-mode coverage through the official Universal Router V4_SWAP command.
/// @dev Uses the action order in the reviewed public UniRoute source: settle-first exact-input,
///      and swap-first plus open-delta settlement for exact-output.
contract UniversalRouterWethForkTest is Test {
    using PoolIdLibrary for PoolKey;

    IPoolManager internal constant PM = IPoolManager(0x000000000004444c5dc75cB358380D2e3dE08A90);
    IV4Quoter internal constant QUOTER = IV4Quoter(0x52F0E24D1c21C8A0cB1e5a5dD6198556BD9E1203);
    IAllowanceTransfer internal constant PERMIT2 = IAllowanceTransfer(0x000000000022D473030F116dDEE9F6B43aC78BA3);
    address internal constant ROUTER = 0x66a9893cC07D91D95644AEDD05D03f95e1dBA8Af;
    IFewFactory internal constant FEW_FACTORY = IFewFactory(0x7D86394139bf1122E82FDF45Bb4e3b038A4464DD);
    ISwapV2Factory internal constant FEWV2_FACTORY = ISwapV2Factory(0xeb2A625B704d73e82946D8d026E1F588Eed06416);

    address internal constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address internal constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address internal constant USER = address(0xBEEF);
    address internal constant RESIDUAL_RECIPIENT = address(0xFEE);
    uint256 internal constant BLOCK = 25_934_149;

    bool internal forked;
    FewV2ShellHookBase internal hook;
    PoolKey internal key;

    function setUp() public {
        string memory rpc = vm.envOr("ETH_RPC_URL", string(""));
        if (bytes(rpc).length == 0) return;
        vm.createSelectFork(rpc, vm.envOr("TEST_FORK_BLOCK", BLOCK));
        forked = true;
        hook = _deploy();
        key = PoolKey({
            currency0: Currency.wrap(USDC),
            currency1: Currency.wrap(WETH),
            fee: 3000,
            tickSpacing: 1,
            hooks: IHooks(address(hook))
        });
        PM.initialize(key, hook.previewInitializationPrice(key));

        deal(USDC, USER, 100_000e6);
        deal(WETH, USER, 100 ether);
        vm.startPrank(USER);
        IERC20(USDC).approve(address(PERMIT2), type(uint256).max);
        IERC20(WETH).approve(address(PERMIT2), type(uint256).max);
        PERMIT2.approve(USDC, ROUTER, type(uint160).max, uint48(block.timestamp + 1 days));
        PERMIT2.approve(WETH, ROUTER, type(uint160).max, uint48(block.timestamp + 1 days));
        vm.stopPrank();
    }

    modifier onFork() {
        if (!forked) vm.skip(true);
        _;
    }

    function test_universalRouter_WETH_to_USDC_exactInput() public onFork {
        _runExactInput(false, 0.001 ether);
    }

    function test_universalRouter_WETH_to_USDC_exactOutput() public onFork {
        _runExactOutput(false, 1e6);
    }

    function test_universalRouter_USDC_to_WETH_exactInput() public onFork {
        _runExactInput(true, 1e6);
    }

    function test_universalRouter_USDC_to_WETH_exactOutput() public onFork {
        _runExactOutput(true, 0.0001 ether);
    }

    function _enableProtocolFee() internal {
        RouterFeeAdapterMock adapter = new RouterFeeAdapterMock();
        vm.prank(IRouterFeeManagerOwner(address(PM)).owner());
        PM.setProtocolFeeController(address(adapter));
        vm.prank(address(adapter));
        PM.setProtocolFee(key, uint24(40) | (uint24(40) << 12));
    }

    function test_universalRouter_protocolFee_WETH_to_USDC_exactInput() public onFork {
        _enableProtocolFee();
        uint256 before = IERC20(USDC).balanceOf(address(0xCAFE));
        _runExactInput(false, 0.001 ether);
        assertGt(IERC20(USDC).balanceOf(address(0xCAFE)), before);
    }

    function test_universalRouter_protocolFee_WETH_to_USDC_exactOutput() public onFork {
        _enableProtocolFee();
        uint256 before = IERC20(WETH).balanceOf(address(0xCAFE));
        _runExactOutput(false, 1e6);
        assertGt(IERC20(WETH).balanceOf(address(0xCAFE)), before);
    }

    function test_universalRouter_protocolFee_USDC_to_WETH_exactInput() public onFork {
        _enableProtocolFee();
        uint256 before = IERC20(WETH).balanceOf(address(0xCAFE));
        _runExactInput(true, 1e6);
        assertGt(IERC20(WETH).balanceOf(address(0xCAFE)), before);
    }

    function test_universalRouter_protocolFee_USDC_to_WETH_exactOutput() public onFork {
        _enableProtocolFee();
        uint256 before = IERC20(USDC).balanceOf(address(0xCAFE));
        _runExactOutput(true, 0.0001 ether);
        assertGt(IERC20(USDC).balanceOf(address(0xCAFE)), before);
    }

    function test_universalRouter_protocolFee_inputCapRevertsPayment() public onFork {
        _enableProtocolFee();
        uint128 amountIn = uint128(hook.quote(false, int256(1e6), key.toId()));
        uint256 jarBefore = IERC20(WETH).balanceOf(address(0xCAFE));
        uint256 userInput = IERC20(WETH).balanceOf(USER);
        uint256 userOutput = IERC20(USDC).balanceOf(USER);
        bytes[] memory params = new bytes[](3);
        params[0] = abi.encode(IV4Router.ExactOutputSingleParams(key, false, 1e6, amountIn - 1, ""));
        params[1] = abi.encode(key.currency1, ActionConstants.OPEN_DELTA, true);
        params[2] = abi.encode(key.currency0, uint256(1e6));
        bytes[] memory inputs = new bytes[](1);
        inputs[0] = abi.encode(
            abi.encodePacked(uint8(Actions.SWAP_EXACT_OUT_SINGLE), uint8(Actions.SETTLE), uint8(Actions.TAKE_ALL)),
            params
        );
        vm.prank(USER);
        vm.expectRevert();
        IUniversalRouterWethTest(ROUTER).execute(hex"10", inputs, block.timestamp + 60);
        assertEq(IERC20(WETH).balanceOf(address(0xCAFE)), jarBefore);
        assertEq(IERC20(WETH).balanceOf(USER), userInput);
        assertEq(IERC20(USDC).balanceOf(USER), userOutput);
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
            params
        );

        assertEq(userInputBefore - _balance(input, USER), amountIn, "exact-input spent");
        assertEq(_balance(output, USER) - userOutputBefore, amountOut, "exact-input received");
        _assertClean(zeroForOne, pmInputBefore, pmOutputBefore);
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
            params
        );

        assertEq(userInputBefore - _balance(input, USER), amountIn, "exact-output spent");
        assertEq(_balance(output, USER) - userOutputBefore, amountOut, "exact-output received");
        _assertClean(zeroForOne, pmInputBefore, pmOutputBefore);
    }

    function _assertOfficialQuoter(bool zeroForOne, bool exactOut, uint128 specified, uint128 expected) internal {
        IV4Quoter.QuoteExactSingleParams memory params =
            IV4Quoter.QuoteExactSingleParams(key, zeroForOne, specified, "");
        (uint256 quote,) = exactOut ? QUOTER.quoteExactOutputSingle(params) : QUOTER.quoteExactInputSingle(params);
        assertEq(quote, expected, "official V4Quoter and Hook quote");
    }

    function _execute(bytes memory actions, bytes[] memory params) internal {
        bytes[] memory inputs = new bytes[](1);
        inputs[0] = abi.encode(actions, params);
        vm.prank(USER);
        uint256 gasBefore = gasleft();
        IUniversalRouterWethTest(ROUTER).execute(hex"10", inputs, block.timestamp + 60);
        emit log_named_uint("Universal Router execution gas", gasBefore - gasleft());
    }

    function _assertClean(bool zeroForOne, uint256 pmInputBefore, uint256 pmOutputBefore) internal view {
        Currency input = zeroForOne ? key.currency0 : key.currency1;
        Currency output = zeroForOne ? key.currency1 : key.currency0;
        (address few0, address few1,) = hook.registeredRouteFor(key.toId());
        address fewIn = zeroForOne ? few0 : few1;
        address inputUnderlying = IFewWrappedToken(fewIn).token();

        assertEq(_balance(input, address(PM)), pmInputBefore, "PoolManager input restored");
        assertEq(_balance(output, address(PM)), pmOutputBefore, "PoolManager output restored");
        assertEq(_balance(input, address(hook)), 0, "Hook input residue");
        assertEq(_balance(output, address(hook)), 0, "Hook output residue");
        assertEq(IERC20(few0).balanceOf(address(hook)), 0, "Hook few0 residue");
        assertEq(IERC20(few1).balanceOf(address(hook)), 0, "Hook few1 residue");
        assertEq(IERC20(inputUnderlying).allowance(address(hook), fewIn), 0, "wrapper allowance reset");
    }

    function _balance(Currency currency, address account) internal view returns (uint256) {
        return IERC20(Currency.unwrap(currency)).balanceOf(account);
    }

    function _deploy() internal returns (FewV2ShellHookBase deployed) {
        // The vault is deliberately left unarmed, so this suite pays no subsidy.
        ISubsidyVault vault = new SubsidyVault(PM, address(this));
        bytes memory args = abi.encode(
            PM, FEW_FACTORY, FEWV2_FACTORY, IWETH9(WETH), QUOTER, false, address(this), RESIDUAL_RECIPIENT, vault
        );
        uint160 flags = Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG;
        (address predicted, bytes32 salt) =
            HookMiner.find(address(this), flags, type(FewV2ShellHookBase).creationCode, args);
        deployed = new FewV2ShellHookBase{salt: salt}(
            PM, FEW_FACTORY, FEWV2_FACTORY, IWETH9(WETH), QUOTER, false, address(this), RESIDUAL_RECIPIENT, vault
        );
        assertEq(address(deployed), predicted);
    }
}
