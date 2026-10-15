// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.26;

import {VmSafe} from "forge-std/Vm.sol";
import {console2} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {FewV2ShellHook} from "../src/FewV2ShellHook.sol";
import {DeployMainnetBase} from "./DeployMainnetBase.sol";
import {InitializeEthWbtcPool} from "./InitializeEthWbtcPool.s.sol";
import {UpdateEthWbtcProtocolFee} from "./UpdateEthWbtcProtocolFee.s.sol";
import {SmokeSwapEthWbtc} from "./SmokeSwapEthWbtc.s.sol";
import {CheckDeployment} from "./CheckDeployment.s.sol";

/// @notice Simulation-only deploy -> init -> official fee update -> Router canary.
/// @dev Rejects --broadcast and --resume. Does not mint LP or reserve singleton cash.
contract RehearseEthWbtcRelease is DeployMainnetBase {
    function run() external {
        require(vm.isContext(VmSafe.ForgeContext.ScriptDryRun), "rehearsal must never broadcast or resume");
        require(block.chainid == 1, "Ethereum mainnet fork required");
        address expected = vm.envAddress("NATIVE_ETH_EXPECTED_HOOK_ADDRESS");
        require(expected.code.length == 0, "candidate address already has code");
        _deploy(true, "NATIVE_ETH_HOOK_SALT", "NATIVE_ETH_EXPECTED_HOOK_ADDRESS");

        vm.setEnv("HOOK_ADDRESS", vm.toString(expected));
        vm.setEnv("BROADCAST_INITIALIZATION", "true");
        new InitializeEthWbtcPool().run();
        vm.setEnv("BROADCAST_PROTOCOL_FEE_UPDATE", "true");
        UpdateEthWbtcProtocolFee feeUpdate = new UpdateEthWbtcProtocolFee();
        feeUpdate.run();
        UpdateEthWbtcProtocolFee.FeeUpdatePlan memory plan =
            feeUpdate.preview(expected, vm.envOr("V4_POOL_MANAGER", V4_PM_DEFAULT), WBTC);
        feeUpdate.requireCurrentPolicy(plan);
        uint256 jarBefore = IERC20(WBTC).balanceOf(plan.recipient);
        uint256 userWbtcBefore = IERC20(WBTC).balanceOf(msg.sender);
        uint256 smokeInput = vm.envOr("SMOKE_ETH_IN", uint256(0.0001 ether));
        require(smokeInput <= uint256(type(int256).max), "smoke input out of range");
        uint256 quoted =
            FewV2ShellHook(payable(expected)).quote(true, -int256(smokeInput), PoolIdLibrary.toId(plan.key));
        vm.setEnv("BROADCAST_SMOKE", "true");
        new SmokeSwapEthWbtc().run();
        uint256 actualOutput = IERC20(WBTC).balanceOf(msg.sender) - userWbtcBefore;
        require(actualOutput == quoted, "canary actual output differs from quote");
        uint256 feePaid = IERC20(WBTC).balanceOf(plan.recipient) - jarBefore;
        require(feePaid > 0, "canary paid no WBTC protocol fee");
        vm.setEnv("HOOK_SALT", vm.envString("NATIVE_ETH_HOOK_SALT"));
        vm.setEnv("EXPECT_NATIVE_ETH", "true");
        new CheckDeployment().run();
        console2.log("=== Rehearsal complete: no mainnet broadcast ===");
        console2.log("WBTC protocol fee paid in raw units:", feePaid);
        console2.log("Actual WBTC canary output in raw units:", actualOutput);
        console2.log("No Shell LP was minted; four-mode LP recovery is tested separately.");
    }
}
