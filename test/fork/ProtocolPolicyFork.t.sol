// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.26;

import {EthWbtcShellParityForkTest} from "./EthWbtcShellParityFork.t.sol";
import {FewV2ShellHook} from "../../src/FewV2ShellHook.sol";
import {FewV2ShellHookBase} from "../../src/FewV2ShellHookBase.sol";
import {SubsidyVault} from "../../src/SubsidyVault.sol";
import {ISubsidyVault} from "../../src/interfaces/ISubsidyVault.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IWETH9} from "v4-periphery/src/interfaces/external/IWETH9.sol";
import {UpdateEthWbtcProtocolFee} from "../../script/UpdateEthWbtcProtocolFee.s.sol";
import {HookMiner} from "v4-periphery/src/utils/HookMiner.sol";

interface IReviewFeeAdapter {
    function policy() external view returns (address);
    function TOKEN_JAR() external view returns (address);
    function getFee(PoolKey memory key) external view returns (uint24);
    function triggerFeeUpdate(PoolKey calldata key) external;
}

interface IReviewFeePolicy {
    function flagRulesLength() external view returns (uint256);
    function flagRules(uint256 index) external view returns (uint256, uint8);
    function hookFamilyId(address hook) external view returns (uint8);
}

/// @notice Real policy classification and permissionless activation, using the production Hook.
contract ProtocolPolicyForkTest is EthWbtcShellParityForkTest {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    function test_policy_productionHook_feeUpdateAndFourRouterModesRecoverCapital() public onFork {
        address[] memory allowed = new address[](3);
        allowed[0] = WETH;
        allowed[1] = WBTC;
        allowed[2] = USDT;
        // The vault is deliberately left unarmed, so this suite pays no subsidy.
        ISubsidyVault vault = new SubsidyVault(PM, address(this));
        bytes memory args = abi.encode(
            PM,
            FEW_FACTORY,
            FEWV2_FACTORY,
            IWETH9(WETH),
            QUOTER,
            true,
            address(this),
            RESIDUAL_RECIPIENT,
            vault,
            address(this),
            address(this),
            allowed
        );
        uint160 flags = Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG;
        (address predicted, bytes32 salt) =
            HookMiner.find(address(this), flags, type(FewV2ShellHook).creationCode, args);
        FewV2ShellHook candidate = new FewV2ShellHook{salt: salt}(
            PM,
            FEW_FACTORY,
            FEWV2_FACTORY,
            IWETH9(WETH),
            QUOTER,
            true,
            address(this),
            RESIDUAL_RECIPIENT,
            vault,
            address(this),
            address(this),
            allowed
        );
        assertEq(address(candidate), predicted);
        hook = FewV2ShellHookBase(payable(address(candidate)));
        key.hooks = IHooks(address(candidate));
        PM.initialize(key, hook.previewInitializationPrice(key));

        IReviewFeeAdapter adapter = IReviewFeeAdapter(PM.protocolFeeController());
        IReviewFeePolicy policy = IReviewFeePolicy(adapter.policy());
        assertEq(policy.hookFamilyId(address(candidate)), 0, "no manual family assignment for fresh candidate");
        uint8 family;
        for (uint256 i; i < policy.flagRulesLength(); ++i) {
            (uint256 required, uint8 matchedFamily) = policy.flagRules(i);
            if (candidate.protocolFeeFlags() & required == required) {
                family = matchedFamily;
                break;
            }
        }
        assertGt(family, 0, "live governance recognizes candidate flags");
        uint24 expected = adapter.getFee(key);
        assertGt(expected & 0xFFF, 0, "live directional fee is nonzero");
        assertGt(expected >> 12, 0, "live reverse fee is nonzero");
        (,, uint24 initial,) = PM.getSlot0(key.toId());
        emit log_named_address("controller", address(adapter));
        emit log_named_address("policy", address(policy));
        emit log_named_uint("matched family", family);
        emit log_named_uint("initial packed fee", initial);
        emit log_named_uint("resolved packed fee", expected);

        UpdateEthWbtcProtocolFee checker = new UpdateEthWbtcProtocolFee();
        UpdateEthWbtcProtocolFee.FeeUpdatePlan memory beforePlan =
            checker.preview(address(candidate), address(PM), WBTC);
        assertEq(beforePlan.currentFee, 0, "fresh pool does not activate policy fees automatically");
        assertEq(beforePlan.policyFee, expected);
        vm.expectRevert(bytes("official fee update required before canary"));
        checker.requireCurrentPolicy(beforePlan);

        // This permissionless official call is the only fee activation in the test.
        adapter.triggerFeeUpdate(key);
        (,, uint24 actual,) = PM.getSlot0(key.toId());
        assertEq(actual, expected, "official adapter writes resolved fee to PoolManager");
        UpdateEthWbtcProtocolFee.FeeUpdatePlan memory activePlan =
            checker.preview(address(candidate), address(PM), WBTC);
        checker.requireCurrentPolicy(activePlan);
        address jar = adapter.TOKEN_JAR();
        uint256 jarEth = jar.balance;
        uint256 jarWbtc = IERC20(WBTC).balanceOf(jar);
        _mint();
        ShellSnapshot memory beforeState = _snapshot(FEWV2_PAIR);
        _runExactInput(true, 0.0001 ether);
        _runExactOutput(true, 100);
        _runExactInput(false, 500);
        _runExactOutput(false, 0.00002 ether);
        assertGt(jar.balance, jarEth, "real Jar receives ETH");
        assertGt(IERC20(WBTC).balanceOf(jar), jarWbtc, "real Jar receives WBTC");
        _assertExecutionState(beforeState, FEWV2_PAIR);
        _burnAndCheck();
        emit log_named_uint("effective forward fee pips", uint256(actual & 0xFFF) * 25);
        emit log_named_uint("effective reverse fee pips", uint256(actual >> 12) * 25);
    }
}
