# Anvil validation report

**Branch `feat/subsidy`. Date 2026-10-23. Nothing in this report was deployed to mainnet.**

This report records what was executed against a local [anvil](https://book.getfoundry.sh/anvil/)
instance forking Ethereum mainnet. It covers three things the CI fork job does not:

1. the whole fork test suite, run against an anvil fork rather than a raw RPC;
2. the deployment scripts, run end to end on a fork, including the vault, the mined Hook address
   and the budget;
3. a live swap on the freshly deployed Hook, through the official Uniswap Universal Router, with
   the protocol fee switched on, to confirm the subsidy reaches the trader.

## Environment

| Item | Value |
|---|---|
| Upstream RPC | `https://eth.drpc.org` (an archive node; it serves state at historical blocks) |
| Anvil instance A | port 8601, forked at the latest block, used for the test suite |
| Anvil instance B | port 8603, forked at block `25934149`, used for the deployment rehearsal |
| Fork block used by the suites | `25934149`, the same block the CI fork job pins |
| Foundry | `forge` from the pinned toolchain, `solc 0.8.26`, `via_ir = true` |

Two anvil instances were used because the suites need two different baselines. Most suites pin
`TEST_FORK_BLOCK=25934149`, but `DeployedQuoteParityFork` hard-codes block `26197122`, so instance
A was forked at the tip to keep that historical block reachable.

Anvil preserves the upstream archive capability, so `vm.createSelectFork` against it still serves
the historical state each suite asks for.

## 1. The fork test suite

```sh
ETH_RPC_URL=http://127.0.0.1:8601 TEST_FORK_BLOCK=25934149 \
  forge test --match-path "test/fork/*" -vv
```

**Result: 276 passed, 0 failed, 0 skipped (276 tests, 13 suites).**

| Suite | Result |
|---|---|
| `FewV2ShellHookBaseFork.t.sol` | 71 passed, 0 failed |
| `SubsidyMultiPoolFork.t.sol` | 55 passed, 0 failed |
| `SubsidyFork.t.sol` | 51 passed, 0 failed |
| `ProtocolFeesFork.t.sol` | 23 passed, 0 failed |
| `NativeLiquidityFork.t.sol` | 20 passed, 0 failed |
| `FewV2ShellHookFork.t.sol` | 16 passed, 0 failed |
| `UniversalRouterWethFork.t.sol` | 9 passed, 0 failed |
| `ExecutionMatrixFork.t.sol` | 9 passed, 0 failed |
| `MaliciousUnderlyingFork.t.sol` | 9 passed, 0 failed |
| `DeployedQuoteParityFork.t.sol` | 5 passed, 0 failed |
| `ProtocolPolicyFork.t.sol` | 4 passed, 0 failed |
| `EthWbtcShellParityFork.t.sol` | 3 passed, 0 failed |
| `DuplicateRouteFork.t.sol` | 1 passed, 0 failed |

An earlier run of this report recorded 283 tests with 2 failures. Both failures were in
`test/fork/DeployedHookSmokeFork.t.sol`, a local file that was never tracked and never ran in CI.
It exercised the October 12 Hook at `0x59255CbC688e402eF980B84668bA1d1c708b6088`, which the
October 16 protocol-fee replacement at `0xbeBc5239e446BC78B46654Ad943b0Fc19A31E088` superseded and
which this branch will replace again. It forked at the latest block instead of a pinned one, so its
price assertions drifted with the market:

```text
[FAIL: exact-in USDC->ETH pays live FewV2 price: 829252318717884374 != 828675297169831202]
        test_fork_pair1_swap_USDC_to_ETH_passes()
[FAIL: EvmError: Revert] test_fork_pair2_swap_USDT_to_ETH_passes()
```

The file has been deleted. Every case it held is covered by a tracked suite that pins its block:
`DeployedQuoteParityFork` tests the same deployed Hook address through the official Universal
Router and asserts that the quote and the fill match exactly, `FewV2ShellHookFork` covers the
allowlist and the deployment configuration against this branch's own bytecode, and
`EthWbtcShellParityFork` covers the ETH/USDT route and USDT's non-standard ERC20 behaviour.

The Hook the subsidy suites exercise is deployed by the suite itself (`nativeHook = _deployHook(...)`),
so those 51 + 55 cases test this branch's bytecode, not any mainnet deployment.

The hermetic suite was run separately and is green:

```sh
forge test --no-match-path "test/fork/*"   # 20 passed, 0 failed
```

## 2. Deployment rehearsal

Every step below ran against anvil instance B, which was forked at block `25934149`.

| Step | Script | Result |
|---|---|---|
| 1 | `DeploySubsidyVault.s.sol` | Vault at `0x2874c594737542e3021CADE3929D64e04055C8f2`; state asserts passed |
| 2 | `MineHookAddress.s.sol` | Salt `0x0000000000000000000000000000000000000000000000000000000000000e12`, Hook at `0x2C4a6eb79b8F0062d2e574f4fb7fCE9C610CA088`, genesis allowlist of 6 |
| 3 | `DeployMainnetNativeEth.s.sol` | Deployed through the canonical CREATE2 deployer; the on-chain address equals the mined address; state asserts passed |
| 4 | `CheckDeployment.s.sol` | `=== FewV2ShellHook check: PASS ===` |
| 5a | `ReportSubsidyBudget.s.sol` | Full report; `WARNING: the vault is not armed`; all 8 recommended pools reported as skipped |
| 5b | `ArmSubsidyVault.s.sol` | `=== SubsidyVault armed ===`; state asserts passed |
| 5c | `cast send` | `approve` + `fund(USDC, 1e12)` + `fundNative()(5 ETH)` |
| 5d | `ReportSubsidyBudget.s.sol` | ETH-or-WETH and USDC `funded`; USDT, DAI, WBTC and USDR `EMPTY` |

`CheckDeployment` confirmed the deployment independently of the deploy script:

```text
  === FewV2ShellHook check: PASS ===
  Hook:              0x2C4a6eb79b8F0062d2e574f4fb7fCE9C610CA088
  CREATE2 verified:  true
  Native ETH mode:   true
  Owner:             0x3C44CdDdB6a900fa2b585dd299e03d12FA4293BC
  Guardian:          0x90F79bf6EB2c4f870365E785982E1f101E93b906
  Runtime codehash:
  0x5e2a4836717518e64b8450eafff56273dad9f4bfe3784afd22182dd0216860d1
  Genesis allowlist:
     0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2 true
     0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48 true
     0xdAC17F958D2ee523a2206206994597C13D831ec7 true
     0x6B175474E89094C44Da98b954EedeAC495271d0F true
     0x2260FAC5E5542a773Aa44fBCfeDf7C193bc2C599 true
     0x4EA40dcee961675683e0a2e1721Bd49CB9bca913 true
```

The vault state after funding:

```text
vault.balance(USDC) = 1000000000000 [1e12]
vault.balance(ETH)  = 5000000000000000000 [5e18]
vault.hookLocked()  = true
vault.hook()        = 0x2C4a6eb79b8F0062d2e574f4fb7fCE9C610CA088
vault.owner()       = 0x70997970C51812dc3A010C7d01b50e0d17dc79C8
```

### Pool initialization

`InitializeEthUsdcPool.s.sol` initialized the ETH/USDC Shell pool of the freshly deployed Hook:

```text
  === Initialized ===
  sqrtPriceX96: 3958422794981353689134847
  tick:         -198095
```

The Hook registered the route on that pool and mirrors the FewV2 pair's reserves:

```text
registeredRouteFor = fwETH  0xa250CC729Bb3323e7933022a67B52200fE354767
                     fwUSDC 0x0492560FA7Cfd6A85E50D8bE3F77318994F8f429
                     pair   0x54222F404dcfAc705322045F01D100380b871450
protocolFeeMultiplier = 25
protocolFeeFlags      = 2048 (1 << 11, AFTER_SWAP_RETURNS_DELTA)
pseudoTotalValueLocked = 3499251908562742151384 wei (3499.25 ETH)
                          1751105239772 (1,751,105.24 USDC)
```

## 3. End-to-end subsidy on the deployed Hook

This is the part that no existing test covered: the subsidy was exercised on the Hook that the
deployment scripts had just created, against the real PoolManager, the real protocol-fee
controller and the real TokenJar.

The protocol fee was switched on per pool with `PoolManager.setProtocolFee`, signed by the
protocol-fee controller, at raw rate `forward = 40` and `reverse = 12`. The Hook's multiplier of
25 turns those into `1000` and `300` on the Uniswap scale, which is **0.1%** and **0.03%**.

The trader swapped `0.0001 ETH` for USDC through the official Uniswap Universal Router
(`0x66a9893cC07D91D95644AEDD05D03f95e1dBA8Af`), using `SmokeSwapEthUsdc.s.sol` as the canary.
That script also asserts that the Hook's own quote equals the official `V4Quoter` quote, so the
numbers below are the numbers a router would quote.

### The quote is the same with the protocol fee on and off

| Protocol fee | Vault budget | Quote for 0.0001 ETH in |
|---|---|---|
| Off | Funded | 248,874 USDC |
| On (0.1%) | Funded | **248,874 USDC** |
| On (0.1%) | Empty | 248,625 USDC |

The subsidy absorbs the protocol fee exactly: with a funded vault the trader is quoted the same
amount whether or not the protocol fee is charged. With an empty vault the quote drops by
**249 USDC**, which is 0.1% of 248,874 rounded up.

### The swap

| | Trader receives | Vault USDC after | Vault ETH after |
|---|---|---|---|
| Before | 0 | 1,000,000,000,000 | 5 ETH |
| Swap 1, funded vault | **248,874** | 999,999,999,751 | 5 ETH |
| Swap 2, empty vault | **248,625** | 0 | 5 ETH |

Swap 1 charged `minOut = 248,874` and still cleared, so the trader received the full
fee-free amount, and the vault paid exactly 249 USDC. Swap 2 ran with an empty vault: the trade
**did not revert**, the trader received 248,625 USDC, and the vault spent nothing. That is the
fail-open behaviour in the failure-mode table of `docs/SUBSIDY.md`, observed on chain.

The ETH budget was untouched because the fee for an exact-input swap is charged in the output
currency, USDC. A reverse-direction swap charges the ETH budget instead; that direction is
covered by the fork suite (`test_subsidy_exactInputReverseDirectionRefundsTheProtocolFee` and
`test_subsidy_exactOutputReverseDirectionRefundsTheProtocolFee`), not by this rehearsal.

## 4. Defects found by this rehearsal

Both were found only because the work ran against a real fork with real state, not in a mock.

### 4.1 `ReportSubsidyBudget` crashed on a pool without a registered route

`hook.registeredRouteFor(poolId)` reverts with `PoolDoesNotExist()` when the pool has no route
(`src/FewV2ShellHookBase.sol`, `_registeredRoute`). The report called it unguarded for every
recommended pool, so on a fresh deployment the whole script died before printing anything:

```text
Error: script failed: PoolDoesNotExist()
```

Fixed by guarding the lookup and skipping the fee warning for a pool that was never registered.
`CheckDeployment.s.sol` had the correct order already (read `slot0` first, skip an
uninitialized pool, only then look up the route); the report did not.

### 4.2 `fund` needs an ERC20 allowance first

`SubsidyVault.fund` moves the money with `safeTransferFrom(msg.sender, ...)`, so the owner must
approve the vault first. Calling `fund` straight after deployment fails:

```text
Error: Failed to estimate gas: server returned an error response: error code 3:
execution reverted: ERC20: transfer amount exceeds allowance, ... "ERC20: transfer amount exceeds allowance"
```

`docs/SUBSIDY.md` did not say so. The deployment order now states the approval explicitly.

### 4.3 Three assertions in the new subsidy suite were wrong

Found while running the suite for the first time on a fork:

- the two reverse-direction cases subtracted the trader's USDC balance in the wrong direction. In
  a reverse swap the trader *pays* USDC, so the delta is `balanceBefore - balanceOf(USER)`; the
  original expression underflowed.
- `vm.expectPartialRevert` did not match the price-limit revert. Uniswap wraps a hook error in
  `CustomRevert.WrappedError`, and a partial match tests the **outer** selector, not the inner
  `FewV2PriceLimitExceeded`. The suite now asserts the wrapped error exactly, the same way
  `test/fork/ExecutionMatrixFork.t.sol` already did.

## 5. Reproducing this

```sh
# instance A: the suite, forked at the tip
anvil --fork-url https://eth.drpc.org --port 8601 --host 127.0.0.1 --silent &
ETH_RPC_URL=http://127.0.0.1:8601 TEST_FORK_BLOCK=25934149 \
  forge test --match-path "test/fork/*" -vv

# instance B: the rehearsal, forked at the CI block
anvil --fork-url https://eth.drpc.org --fork-block-number 25934149 --port 8603 --host 127.0.0.1 --silent &
```

The deployment rehearsal then runs the scripts in the order of the "Deployment order" section of
`docs/SUBSIDY.md`: `DeploySubsidyVault` → `MineHookAddress` → `DeployMainnetNativeEth` →
`CheckDeployment` → `InitializeEthUsdcPool` → `ArmSubsidyVault` → `approve` + `fund` →
`ReportSubsidyBudget`. The end-to-end swap uses `SmokeSwapEthUsdc.s.sol` with
`BROADCAST_SMOKE=true`.

## 6. What this report does not cover

- **No mainnet deployment.** Anvil forks mainnet state, but the Hook, the vault and the pool
  created here exist only on the local chain. The addresses in this report are anvil addresses.
- **One swap direction.** Only exact-input ETH→USDC was run on the deployed Hook. Exact output
  and the reverse direction are covered by the fork suite against the same branch code, not by
  this rehearsal.
- **The protocol fee was set by impersonating the controller.** On mainnet the controller is a
  contract; the rate was set with `setProtocolFee` on the forked PoolManager exactly as the
  Uniswap controller would.
- **The deployed-contract fixtures are not part of this branch.** `DeployedQuoteParityFork` pins the
  October 12 Hook at block `26197122` and tests it through the official Universal Router. It is
  green, but it describes a contract this branch will replace, not the branch's own code. The
  branch's code is covered by the suites that deploy it themselves.
- **The upstream RPC is a third-party archive node.** `https://eth.drpc.org` was reachable from
  this environment; the CI job uses a repository secret instead.
