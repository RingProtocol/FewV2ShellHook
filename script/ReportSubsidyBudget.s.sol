// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.26;

import {console2} from "forge-std/Script.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {ProtocolFeeLibrary} from "@uniswap/v4-core/src/libraries/ProtocolFeeLibrary.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";

import {DeployMainnetBase} from "./DeployMainnetBase.sol";
import {FewV2ShellHook} from "../src/FewV2ShellHook.sol";
import {SubsidyVault} from "../src/SubsidyVault.sol";

/// @notice Read-only report of the shared subsidy budget. Sends no transaction.
/// @dev Answers three questions in one run:
///      - Which currencies need a budget at all. The subsidy is paid in the currency the
///        Uniswap protocol fee was charged in, and that currency is always one of the pool's
///        two endpoints, so the union of all pool endpoints is the set of budgets to hold.
///      - What protocol fee each recommended pool actually charges. The rate is set per pool
///        and per direction by Uniswap's fee controller, so a pool with no protocol fee would
///        silently waste any budget assigned to it.
///      - Which budgets are empty. An empty budget is not an error: the vault fails open and
///        the trader simply pays the protocol fee instead of receiving the refund.
///
///      Required:
///        HOOK_ADDRESS=0x...            deployed Hook
///        SUBSIDY_VAULT_ADDRESS=0x...  the vault that serves that Hook
///
///      Optional:
///        V4_POOL_MANAGER=0x...         defaults to the Ethereum mainnet PoolManager
///
///      forge script script/ReportSubsidyBudget.s.sol:ReportSubsidyBudget --rpc-url $ETH_RPC_URL
contract ReportSubsidyBudget is DeployMainnetBase {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    struct PoolSpec {
        string label;
        address tokenA;
        address tokenB;
    }

    function run() external view {
        address hookAddr = vm.envAddress("HOOK_ADDRESS");
        address vaultAddr = vm.envAddress("SUBSIDY_VAULT_ADDRESS");
        require(hookAddr.code.length > 0, "HOOK_ADDRESS has no code");
        require(vaultAddr.code.length > 0, "SUBSIDY_VAULT_ADDRESS has no code");

        FewV2ShellHook hook = FewV2ShellHook(payable(hookAddr));
        SubsidyVault vault = SubsidyVault(payable(vaultAddr));
        IPoolManager poolManager = IPoolManager(vm.envOr("V4_POOL_MANAGER", V4_PM_DEFAULT));
        require(address(hook.poolManager()) == address(poolManager), "V4_POOL_MANAGER does not match the Hook");

        bool nativeEth = hook.useNativeCurrencyForWeth();
        address ethCurrency = nativeEth ? address(0) : WETH_DEFAULT;

        console2.log("=== Subsidy budget report ===");
        console2.log("Hook:             ", hookAddr);
        console2.log("Vault:            ", vaultAddr);
        console2.log("Pool manager:     ", address(poolManager));
        console2.log("Native ETH mode:  ", nativeEth);
        console2.log("Vault armed:      ", vault.hookLocked());
        console2.log("Vault hook:       ", vault.hook());
        console2.log("Vault paused:     ", vault.paused());

        if (!vault.hookLocked()) {
            console2.log("WARNING: the vault is not armed. Every subsidy request returns zero.");
        } else if (vault.hook() != hookAddr) {
            console2.log("WARNING: the vault is armed to another Hook. This Hook cannot draw on it.");
        }
        if (vault.paused()) {
            console2.log("WARNING: the vault is paused. Every subsidy request returns zero.");
        }

        _reportCurrencies(vault, ethCurrency);
        _reportPools(hook, vault, poolManager, ethCurrency);
    }

    /// @dev One shared budget per currency, used by every pool of this Hook. The native ETH
    ///      budget is keyed by address(0); the WETH budget is keyed by the WETH address.
    function _reportCurrencies(SubsidyVault vault, address ethCurrency) internal view {
        address[6] memory currencies = [ethCurrency, USDC, USDT, DAI, WBTC, USDR];
        string[6] memory labels = ["ETH-or-WETH", "USDC", "USDT", "DAI", "WBTC", "USDR"];

        console2.log("");
        console2.log("=== Budget by currency (one shared budget per currency) ===");
        for (uint256 i = 0; i < currencies.length; i++) {
            address currency = currencies[i];
            uint256 amount = vault.balance(currency);

            console2.log("  ", labels[i]);
            console2.log("    address: ", currency);
            console2.log("    balance: ", amount);
            if (amount == 0) {
                console2.log(
                    "    status:  EMPTY - the subsidy fails open to zero on every pool that charges this currency"
                );
            } else {
                console2.log("    status:  funded");
            }
        }
    }

    /// @dev The recommended pool set. Keep in sync with CheckDeployment.s.sol.
    function _reportPools(FewV2ShellHook hook, SubsidyVault vault, IPoolManager poolManager, address ethCurrency)
        internal
        view
    {
        PoolSpec[8] memory specs = [
            PoolSpec({label: "ETH-or-WETH/USDC", tokenA: ethCurrency, tokenB: USDC}),
            PoolSpec({label: "ETH-or-WETH/USDT", tokenA: ethCurrency, tokenB: USDT}),
            PoolSpec({label: "ETH-or-WETH/DAI", tokenA: ethCurrency, tokenB: DAI}),
            PoolSpec({label: "ETH-or-WETH/WBTC", tokenA: ethCurrency, tokenB: WBTC}),
            PoolSpec({label: "WBTC/USDC", tokenA: WBTC, tokenB: USDC}),
            PoolSpec({label: "WBTC/USDT", tokenA: WBTC, tokenB: USDT}),
            PoolSpec({label: "WBTC/DAI", tokenA: WBTC, tokenB: DAI}),
            PoolSpec({label: "ETH-or-WETH/USDR", tokenA: ethCurrency, tokenB: USDR})
        ];

        uint24 multiplier = hook.protocolFeeMultiplier();

        console2.log("");
        console2.log("=== Recommended Shell Pools ===");
        for (uint256 i = 0; i < specs.length; i++) {
            (address currency0, address currency1) = uint160(specs[i].tokenA) < uint160(specs[i].tokenB)
                ? (specs[i].tokenA, specs[i].tokenB)
                : (specs[i].tokenB, specs[i].tokenA);
            PoolKey memory key = PoolKey({
                currency0: Currency.wrap(currency0),
                currency1: Currency.wrap(currency1),
                fee: 3000,
                tickSpacing: 1,
                hooks: IHooks(address(hook))
            });
            PoolId poolId = key.toId();
            (uint160 sqrtPriceX96,, uint24 packed,) = poolManager.getSlot0(poolId);

            console2.log("");
            console2.log(specs[i].label);
            console2.logBytes32(PoolId.unwrap(poolId));

            // A pool without a registered route reverts on lookup, so the lookup is guarded.
            address pair = address(0);
            try hook.registeredRouteFor(poolId) returns (address, address, address registeredPair) {
                pair = registeredPair;
            } catch {
                pair = address(0);
            }

            console2.log("  registered: ", pair != address(0));
            console2.log("  initialized:", sqrtPriceX96 != 0);
            if (pair == address(0)) {
                console2.log("  skipped: no registered route, so this pool never settles a protocol fee");
                continue;
            }
            if (sqrtPriceX96 == 0) {
                console2.log("  NOTE: registered but not initialized, so it cannot trade yet");
            }

            uint256 rawZeroForOne = ProtocolFeeLibrary.getZeroForOneFee(packed);
            uint256 rawOneForZero = ProtocolFeeLibrary.getOneForZeroFee(packed);

            console2.log("  zeroForOne (currency0 -> currency1):");
            console2.log("    raw fee: ", rawZeroForOne);
            console2.log("    pips:    ", rawZeroForOne * multiplier);
            console2.log("    bps:     ", rawZeroForOne * multiplier / 100);
            console2.log("    charged in currency1 on exact input, in currency0 on exact output");

            console2.log("  oneForZero (currency1 -> currency0):");
            console2.log("    raw fee: ", rawOneForZero);
            console2.log("    pips:    ", rawOneForZero * multiplier);
            console2.log("    bps:     ", rawOneForZero * multiplier / 100);
            console2.log("    charged in currency0 on exact input, in currency1 on exact output");

            console2.log("  budget currency0:");
            console2.log("    address: ", currency0);
            console2.log("    balance: ", vault.balance(currency0));
            console2.log("  budget currency1:");
            console2.log("    address: ", currency1);
            console2.log("    balance: ", vault.balance(currency1));

            if (sqrtPriceX96 == 0) {
                console2.log("  NOTE: the pool is not initialized, so it has no protocol fee yet.");
            } else if (rawZeroForOne == 0 && rawOneForZero == 0) {
                console2.log("  WARNING: the protocol fee is zero in both directions. The subsidy is");
                console2.log("           structurally zero, so a budget for this pool only wastes money.");
            } else {
                if (rawZeroForOne == 0) {
                    console2.log("  NOTE: the zeroForOne direction charges no protocol fee and is never subsidized.");
                }
                if (rawOneForZero == 0) {
                    console2.log("  NOTE: the oneForZero direction charges no protocol fee and is never subsidized.");
                }
            }
            if (vault.balance(currency0) == 0) {
                console2.log("  WARNING: no budget for currency0, so that direction is not subsidized.");
            }
            if (vault.balance(currency1) == 0) {
                console2.log("  WARNING: no budget for currency1, so that direction is not subsidized.");
            }
        }
    }
}
