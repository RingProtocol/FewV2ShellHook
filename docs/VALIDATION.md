# Validation

Snapshot date: October 12, 2026.

## Result

All 153 tests pass at Ethereum mainnet block `25,934,149`, the block pinned in CI, and at block `26,176,789`, with every fork suite honoring `TEST_FORK_BLOCK`. The fork suites run against the real Uniswap v4 PoolManager, PositionManager, V4Quoter and Universal Router plus live Ring factories, wrappers and FewV2 pairs. No transaction was broadcast to mainnet.

| Suite | Tests | Main coverage |
|---|---:|---|
| `test/unit/FewV2Math.t.sol` | 7 | V2 exact-input and exact-output math |
| `test/unit/FewV2Price.t.sol` | 13 | Decimal-aware price, reversed order, high ratios and fuzz cases |
| `test/fork/FewV2ShellHookBaseFork.t.sol` | 71 | Core execution, quote, accounting, backing, price limits, roles and adversarial cases, including input/output transfer shortfalls and five malicious-token registration, route and callback scenarios |
| `test/fork/NativeLiquidityFork.t.sol` | 20 | PositionManager lifecycle, Shell/FewV2 separation, events, inventory, settlement, donation, poisoning, rounding and custody boundaries |
| `test/fork/FewV2ShellHookFork.t.sol` | 17 | Genesis seeding, allowlist gating, 48h add-timelock, immediate removal with a live pool still swapping, guardian/owner pause with owner-only unpause, disable-only guardian, two-step ownership, disabled renouncement, owner replacement of the pool initializer and residual recipient, defense in depth |
| `test/fork/MaliciousUnderlyingFork.t.sol` | 9 | Fee-on-transfer, phantom-balance, transfer-callback/reentrancy and negative-rebase origin tokens: they pass registration, fail closed at swap time and stay isolated; an allowlist prototype blocks the bad token but admits canonical ones |
| `test/fork/ExecutionMatrixFork.t.sol` | 9 | ETH/token, WETH/token and token/token execution matrix, small exact-output boundaries and custom price limits |
| `test/fork/UniversalRouterWethFork.t.sol` | 4 | WETH/USDC both directions and amount modes through the Universal Router |
| `test/fork/EthWbtcShellParityFork.t.sol` | 2 | ETH/WBTC Shell parity and ETH/USDT non-standard ERC20 through the official Universal Router |
| `test/fork/DuplicateRouteFork.t.sol` | 1 | Cross-deployment duplicate depth and stale-quote counterexample |
| **Total** | **153** | |

## Disabled renouncement

`FewV2ShellHook` overrides the inherited `renounceOwnership()` to revert with `RenounceDisabled`, as Uniswap's governed v4 component [`PermissionsAdapter`](https://github.com/Uniswap/v4-periphery/blob/main/src/hooks/permissionedPools/PermissionsAdapter.sol) does. `Ownable2Step` makes transfers two-step but leaves renouncement one-step, and without an owner a guardian pause could never be lifted.

## Replaceable pool initializer and residual recipient

`poolInitializer` and `residualRecipient` are storage variables instead of immutables. `FewV2ShellHookBase` still has no setter for either. `FewV2ShellHook` lets the owner replace both through `setPoolInitializer` and `setResidualRecipient`, which reject the zero address and emit `PoolInitializerUpdated` and `ResidualRecipientUpdated`. This follows how established protocols handle the same kind of role: Uniswap v2's [`UniswapV2Factory`](https://github.com/Uniswap/v2-core/blob/master/contracts/UniswapV2Factory.sol) lets `feeToSetter` change the fee recipient, and Morpho Blue's [`setFeeRecipient`](https://github.com/morpho-org/morpho-blue/blob/main/src/Morpho.sol) is owner-only. A lost initializer key no longer forces a redeployment, and either role can move from an interim key to its final key.

A replaced initializer can only register new pools for allowlisted underlyings; registered routes never change. A replaced recipient only receives the Hook's own residual balance through `sweep()`. The swap path reads neither variable, so swap gas is unchanged; pool initialization and `sweep()` each pay one more cold storage read, about 2,100 gas. Because the role addresses are not embedded in the runtime code, the runtime codehash does not depend on them.

## Deployment rehearsal

Before the mainnet deployment, the full sequence ran with the scripts in `script/` on Anvil forks of mainnet without private keys, most recently at block `26,176,825` with the release role addresses. Together the runs covered salt mining, deployment through the canonical CREATE2 deployer, `CheckDeployment` with the CREATE2 proof, initialization of all eight recommended pools at the previewed FewV2 price, an ETH/USDC Shell position minted through PositionManager with exact-amount Permit2 approvals, and a Universal Router canary that returned exactly the V4Quoter quote. Governance ran end to end: a rejected early commit and a commit after 48 hours, guardian removal and pause, a rejected guardian unpause, owner unpause, rejected renouncement, two-step ownership transfer, and replacement of the guardian, pool initializer and residual recipient. `CheckDeployment` failed as intended on a wrong salt and on stale role expectations. With swaps paused, the Shell position was fully withdrawn, losing at most one raw unit of rounding per side.

The rehearsal also exposed one operator-script issue, which is now fixed. On mainnet, EOAs with an EIP-7702 delegation have a 23-byte code designator, and the pool-initialization scripts had treated them as contract wallets. The scripts now accept a plain EOA or a delegated EOA for direct broadcast, and still print calldata for real contract wallets.

## Execution matrix

The fork suite executes these 12 base swap modes:

| Token shape | Direction | Amount mode |
|---|---|---|
| ETH/token | both | exact-input and exact-output |
| WETH/token | both | exact-input and exact-output |
| token/token | both | exact-input and exact-output |

For each token shape and both directions, a separate loop executes small raw-unit exact-output values. This checks FewV2 rounding, exact user output and zero Hook dust without relying on a separate Hook fee.

Every individual matrix swap checks:

- Hook quote equals the user's balance change;
- v4 deltas use the correct sign and amount;
- PoolManager input and output balances return to their pre-swap values;
- Hook origin-token and FewToken balances return to zero;
- wrapper allowance returns to zero.

The optimized path uses `wrapTo()` to mint the input FewToken directly to the FewV2 pair. For ERC20 outputs, `unwrapTo()` sends the origin token directly to PoolManager after `sync()`. The contract verifies the exact recipient balance change and the exact change in wrapper backing. The input allowance remains exact per swap and is reset to zero; no permanent unlimited approval was introduced.

After each complete four-swap group, the matrix also confirms that FewV2 reserves moved while the Shell `slot0` stayed unchanged.

The matrix executes exact-input and exact-output in both directions with non-extreme price limits for native ETH, WETH and token/token routes. Separate rollback checks cover the same 12 combinations, assert the precise wrapped `FewV2PriceLimitExceeded` error, and confirm that FewV2 reserves and the effective price remain unchanged after each revert.

## Shell LP checks

The native-liquidity suite uses the official v4 PositionManager and Universal Router. It verifies:

- originToken liquidity can be added and fully removed;
- the Position NFT owner keeps withdrawal control;
- an unapproved account cannot remove the position;
- `sweep()` cannot touch PoolManager capital;
- missing payment, insufficient inventory, insufficient wrapper backing and slippage failure revert atomically;
- successful swaps restore the PoolManager balances used during execution.

The test Router actions are valid official Universal Router calldata, but some tests deliberately use swap-first settlement to exercise the strict inventory requirement. Current public UniRoute source constructs settle-first exact-input, while exact-output and V4Quoter simulations are swap-first. The deployed API's action order has not been verified.

The WETH-mode suite separately executes WETH/USDC and USDC/WETH, exact-input and exact-output, through the deployed Universal Router contract. It uses settle-first exact-input and swap-first, open-delta exact-output action sequences from reviewed public UniRoute commit `2961efa8d44b80d353ee3af82cf868702bb6ab6a`.

The focused Shell-parity test starts with zero Shell liquidity, adds an originToken position through the official PositionManager, and then executes a swap-first exact-output trade through the deployed Universal Router. It asserts one non-zero `Swap` from the canonical Ring Swap v2 pair, one Shell `Swap(0,0)` from PoolManager and one `HookSwap` with the real origin-token amounts and `swapFee=0`. FewV2 reserves and reported depth move, while Shell `slot0`, active liquidity and fee growth remain unchanged. PoolManager inventory is restored and the originToken position is then fully removed.

A separate lifecycle starts with both PoolManager token balances set to zero. Quotes fail in both directions, minting the originToken Shell LP makes both directions executable, and burning the position removes that capacity again apart from at most one raw unit of PositionManager rounding dust.

The ETH/WBTC parity test uses the same public market already exercised by FewV4ShellHook. It adds origin ETH/WBTC liquidity, executes all four direction/amount modes through the deployed Universal Router, confirms the real pair is Ring Swap v2 `fwWBTC/fwWETH`, and removes the complete position. The ETH/USDT test repeats all four modes with mainnet USDT and its no-boolean transfer behavior.

Adversarial coverage verifies that unsynced FewV2 donations do not change reserve-based quotes, synced donations remain quote/execution consistent, preloaded Hook balances do not leak into user output, permissionless sweeping cannot reward its caller, and minimal plus mixed swaps never reduce the FewV2 constant-product invariant.

Two fault-injection tests model fee-on-transfer-style shortfalls. A wrapper that mints the requested FewToken while receiving one unit less backing is rejected before the FewV2 swap. An unwrap that credits PoolManager one unit less than requested is rejected before settlement. Both transactions revert atomically and leave no Hook balance or approval.

The duplicate-route test deploys native ETH and WETH Hook modes that expose the same FewV2 pair. Both routes advertise non-zero depth from that source, although their conservative depth can differ because PoolManager's native ETH and WETH cash are separate. Their initial quotes match, and changing the shared pair reserves makes the other route's earlier quote stale. The contract cannot enforce this across deployments, so it remains a routing and migration gate.

## Governance and malicious-underlying checks

`FewV2ShellHook` adds a time-locked underlying allowlist and a swap pause on top of the unchanged base logic.

Malicious-underlying behavior (`MaliciousUnderlyingFork`, 9 tests). Each origin token first obtains a canonical FewFactory wrapper and a real FewV2 pair and is registered as a Shell pool, so canonical-identity checks pass. The suite then shows:

- fee-on-transfer registers but the first swap reverts closed on the per-swap balance-delta check (`TokenBalanceMismatch`); no cross-pool leak;
- a phantom `balanceOf` inflates the backing view but settles only real value, and cannot extract real ETH against a fake balance;
- a reentrant `sweep` during a token callback is blocked by `nonReentrant`, and a cross-pool `take` during a callback leaves an unsettled delta and reverts at unlock with `CurrencyNotSettled`;
- a negative rebase under-backs the wrapper and strands that pool's LP, but the loss stays isolated to the bad token's own pool;
- the root cause is that value paired against a bad token is drainable by a direct FewV2 swap even without the Hook, so the Hook's role is admission control and fail-closed settlement, not making an unsafe token safe;
- an immutable-allowlist prototype blocks the bad underlying at `beforeInitialize` while still admitting canonical ones.

Governance behavior (`FewV2ShellHookFork`, 17 tests):

- genesis underlyings register and seed; a non-allowlisted underlying is rejected at `beforeInitialize` with `UnderlyingNotAllowlisted`;
- `proposeUnderlying` then `commitUnderlying` is blocked before the 48h delay (`AddTimelockNotElapsed`) and allowed after; committing without a proposal reverts;
- `removeUnderlying` is immediate and blocks new registration, but a pool already registered keeps swapping; removal also cancels a pending proposal;
- `pause()` is callable by guardian or owner and blocks swaps, only the owner can `unpause`, and a stranger cannot pause;
- the guardian has disable-only powers: it can remove an active underlying and cancel a pending add, but cannot enable a token or unpause;
- two-step ownership transfer works and the old owner loses owner-only powers;
- `renounceOwnership()` reverts with `RenounceDisabled` for every caller, including the owner during a pause, and the owner can still unpause;
- the owner can replace the pool initializer: the previous initializer is rejected at `beforeInitialize` even though it is still the owner, the new one registers a pool, and existing routes keep swapping;
- the owner can replace the residual recipient: later ETH and USDC sweeps pay only the new recipient; for both setters, guardian, stranger and zero-address calls revert;
- defense in depth: even an allowlisted fee-on-transfer token still fails closed at swap time.

This does not prove that any allowlisted token is economically safe, or that the final owner and guardian keys are correctly controlled. The allowlist is admission control only; underlying-token due diligence (transfer semantics, mint authority, upgradeability, backing) is still required before adding any origin token.

## Initialization and price checks

- `FewV2Price` returns the exact floor of `sqrt(reserve1 / reserve0) * 2^96` across 10,000 fuzzed uint112 reserve pairs.
- Maximum high and low reserve ratios are covered.
- Reversed pair-token order is covered.
- Wrong wrapper, wrong underlying, wrong pair token, zero reserve, duplicate route, wrong fee, stale price and unauthorized initializer all revert.

## UniRoute discovery replay

The candidate PoolKey was replayed through public UniRoute commit [`2961efa8`](https://github.com/Uniswap/uniroute-public/tree/2961efa8d44b80d353ee3af82cf868702bb6ab6a) using the non-zero originToken LP snapshot produced by the fork test. On September 29, 2026, the relevant source was diffed against main commit [`b19fcfbd`](https://github.com/Uniswap/uniroute-public/tree/b19fcfbddec820115176dc7a835273461e3975a3); the intervening changes added unrelated Hook addresses and zero-TVL exemptions and did not change the Ring addresses or the tested ordinary-v4 admission path.

- after temporarily registering the local Hook address in the in-memory fixture, the pool was fetched, admitted, cached and selected in all 8 tested combinations: `HOOKS_INCLUSIVE` and `HOOKS_ONLY`, each at top-N `1`, `2`, `4` and `8`;
- without that registration, the same pool was fetched but removed by the Hook admission filter in all 8 cases;
- the reviewed source places the existing FewV4ShellHook and Ring FewV2 Hook in the ordinary v4 Hook registry, while mainnet's direct Aggregator Hook list is empty.

This is a deterministic source replay, not a production API test. The public source snapshot omits the private canonical-pool implementation, so the harness used an identity stub for that stage. Its six competitor pools are a bounded fixture. It proves the tested intake and ranking behavior, not production registration, a globally best quote, frontend selection or traffic. Because `fee=3000`, `tickSpacing=1` is outside the ordinary canonical fee/tick grid, deployment acceptance must confirm that the exact PoolKey is indexed and retained.

## Universal Router gas

Gas was measured around the deployed Universal Router `execute()` call at the same fixed block, before and after the direct `wrapTo/unwrapTo` settlement change. The amount, pool and route were unchanged.

| Route mode | Before | Current | Change |
|---|---:|---:|---:|
| WETH/USDC, four direction/amount modes | 370,111–379,362 | 330,553–340,390 | about 39,000 lower per swap |
| ETH/WBTC, ETH input exact-in | 350,788 | 310,422 | 40,366 lower |
| ETH/WBTC, ETH input exact-out | 275,385 | 235,026 | 40,359 lower |
| ETH/WBTC, WBTC input exact-in | 280,384 | 263,046 | 17,338 lower |
| ETH/WBTC, WBTC input exact-out | 272,965 | 255,634 | 17,331 lower |

Savings are about 6%–15% for the measured ETH/WBTC cases and about 10%–11% for WETH/USDC. Native ETH output still needs WETH withdrawal inside the Hook, so its saving is smaller. These are fork measurements, not a promise of a fixed mainnet transaction cost.

Permanent wrapper approvals were considered and rejected. They would save more storage writes, but direct transfers already provide a material reduction without leaving an unlimited allowance between swaps.

## Static analysis

The CI Slither run on October 12, 2026 (`crytic/slither-action` v0.4.0, excluding `lib/`, `test/` and `script/`) analyzed 51 contracts with 97 detectors. Its ten reported items were triaged as follows:

- three ignored return values, two FewV2 reserve timestamps and one V4Quoter gas estimate, are intentional;
- the `block.timestamp` comparison in `commitUnderlying` enforces the 48-hour add delay, so validator timestamp drift of seconds is immaterial;
- three helpers reported as dead code are reachable: `_executeFewV2ExactOutput` and `_quoteAmountInForHop` are called from `_swapExactOutput`, for which Slither could not generate IR, and `_pay()` is an override reached by the inherited settlement path;
- the native-token low-level call exists only in permissionless `sweep()`, is protected by `nonReentrant` and can send only to the current residual recipient, which only the owner can change;
- two unindexed event address parameters come from OpenZeppelin `Pausable`'s `Paused` and `Unpaused` events.

Slither could not generate IR for three functions, `_swapExactOutput`, `_exactInputAmount` and `quote`, so the run is supporting evidence rather than complete static-analysis coverage. CI runs Slither on every push to `main` and every pull request.

## What this proves

The tests show that the intended flows work on the fixed fork and that covered failures revert without leaving the Hook with user funds or approvals.

They do not prove:

- safety of unbounded capital;
- absence of an undiscovered contract or dependency bug;
- Uniswap review or production routing acceptance;
- current frontend selection or traffic;
- safe behavior for tokens with untested semantics;
- profitability of the Shell LP or Ring Swap v2 FewToken LP.

## Reproduce

```sh
forge fmt --check
forge build --sizes
forge test --no-match-path "test/fork/*" --summary
TEST_FORK_BLOCK=25934149 forge test --summary
```

Supply `ETH_RPC_URL` (an archive endpoint) through the local environment. Do not store the RPC credential in the repository.
