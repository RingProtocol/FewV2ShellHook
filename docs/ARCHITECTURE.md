# Architecture

## Purpose

The Hook exposes canonical FewV2 liquidity as direct Uniswap v4 routes for origin tokens. A user can trade ETH, WETH or another supported ERC20 that has both a canonical FewToken wrapper and a direct FewV2 pair, without manually wrapping into FewToken.

## Swap path

```text
router opens a v4 swap
  -> Hook takes origin input from PoolManager
  -> Hook wraps the input 1:1 directly to the canonical FewV2 pair
  -> canonical FewV2 pair executes the trade
  -> Hook unwraps ERC20 output directly to PoolManager; native output returns through WETH
  -> Hook settles origin output with PoolManager
  -> Hook pays any configured Uniswap protocol fee to the current TokenJar
  -> router closes the user's balance delta
```

The entire operation is atomic. A non-canonical wrapper, underlying mismatch, incomplete wrapper backing change, recipient balance shortfall, FewV2 execution price beyond the caller's limit, missing PoolManager cash, insufficient output backing or settlement mismatch reverts the FewV2 swap and the v4 operation together.

## Two liquidity positions

| Position | What it supplies | What changes after a Hook swap |
|---|---|---|
| originToken Shell LP | Physical PoolManager inventory used by swap-before-payment quote and settlement paths | Temporary token balance use is restored after a successful swap. Shell tick, active liquidity and fee growth do not move. |
| Ring Swap v2 FewToken pair | Executable price, depth and FewV2 LP fee | Reserves and price move. LPs collect the FewV2 fee. |

The Shell LP is not a second pricing curve. Increasing it can make larger quotes executable, but it does not improve the FewV2 price or reduce FewV2 price impact.

Current public UniRoute source constructs exact-input as settle first, then swap and take. Exact-output cannot pre-settle an unknown input and is constructed as swap first, then open-delta settlement and take. The deployed API's action order has not been verified. The official V4Quoter also simulates the swap before payment. PoolManager origin-token cash therefore remains required for the full quote surface and exact-output route; the Shell LP is the intended recoverable source of that cash.

## Pool registration

Only the current `poolInitializer` may initialize a Hook pool. Registration validates:

1. `fee=3000` and `tickSpacing=1`;
2. the deployment's selected native ETH or WETH representation;
3. both canonical FewToken wrappers and their underlying tokens;
4. the direct canonical FewV2 pair and token ordering;
5. non-zero FewV2 reserves;
6. a supplied initialization price whose tick index differs from the live FewV2 reserve price by at most one;
7. no earlier Shell Pool for the same FewV2 pair inside this Hook deployment.

The wrapper must be the exact address returned by the immutable FewFactory for its underlying token. An arbitrary contract that only imitates the FewToken ABI cannot be registered.

The route is stored once and has no setter. Factory migration, changes to FewV2's venue fee or dependency changes require a new Hook deployment. Uniswap's directional protocol fee can change through its existing fee controller without a Hook redeployment.

The tick-index check is strict by design. The raw price gap can approach two tick intervals at the boundary. Use a private transaction or bundle so a normal FewV2 trade cannot make the public initialization transaction stale.

## Quote and depth

`quote(zeroForOne, amountSpecified, poolId)` calls the official V4Quoter with the registered PoolKey. Negative amounts are exact-input; positive amounts are exact-output.

This simulation includes the same checks used during execution:

- PoolManager input inventory;
- FewToken wrapper backing;
- wrap and unwrap balance movement;
- live FewV2 reserves and fee math;
- v4 settlement.

The Hook adds no Ring fee. The Pair's 30 bps LP fee remains included in FewV2 math. A configured Uniswap protocol fee is read by direction from Shell slot0, scaled by the official Aggregator multiplier of 25, and paid to the current fee controller's TokenJar. Exact-input pays from gross output; exact-output adds the grossed-up fee to input. Full-path V4Quoter simulation includes that fee exactly once.

`pseudoTotalValueLocked()` returns the live FewV2 reserves in the Shell currencies' order. Each side is capped by both the wrapper's available underlying backing and PoolManager's current origin-token cash. PoolManager is a singleton, so this cash is shared rather than reserved for one PoolId. The value is a conservative discovery hint; `quote()` at the requested amount and block is still the final executability check.

## Exact-input accounting

For exact-input, the Hook:

1. takes the exact origin input;
2. gives the canonical wrapper an exact temporary allowance, wraps directly to the FewV2 pair and resets the allowance to zero;
3. measures the FewV2 output balance change;
4. checks the exact wrapper-backing and recipient-balance changes, then unwraps and settles the gross output;
5. pays the configured Uniswap fee from output and returns the net output delta.

## Exact-output accounting

For a requested user output `u`, the Hook asks FewV2 for the input needed to produce exactly `u`, unwraps `u`, and settles it. The Pair's own 30 bps fee is included in the required venue input returned by FewV2 math. The configured Uniswap fee is added to the user's input and paid in origin currency; only the venue input is wrapped into the Pair. PoolManager inventory must cover both amounts. Small raw-unit fork tests cover exact-output rounding and confirm that the Hook retains no dust.

## Price behavior

The Shell `slot0` is an initialization marker. It is checked against FewV2 when the pool is created, then remains static because the Hook absorbs the full swap delta.

Execution price comes from current FewV2 reserves. An indexer that integrates this Hook should use `HookSwap` plus FewV2 data for trades and `quote()` for current execution. Shell `slot0` is not the live market price. Current Uniswap volume display behavior for a newly deployed address remains a production acceptance check.

`executionSqrtPriceX96(poolId)` exposes that live FewV2 reserve price in Shell currency order. For a custom `sqrtPriceLimitX96`, the Hook first checks that the limit is on the valid side of the live price, executes the complete FewV2 trade, and then checks the resulting reserve price. Crossing the limit reverts the whole transaction; the Hook does not partially fill. The official Quoter and Universal Router continue to use their normal extreme limits.

## Permissions and fund access

| Authority | Can do | Cannot do |
|---|---|---|
| `poolInitializer` | Register a new valid canonical pool whose underlyings are on the allowlist | Change a route, pause swaps, transfer balances, remove LP, or register a non-allowlisted underlying |
| `owner` (Ownable2Step; final = multisig) | Propose/commit an allowlist add after the 48h timelock, remove an underlying immediately, `unpause`, replace the guardian, pool initializer and residual recipient, transfer ownership | Renounce ownership, change a registered route, change fees, upgrade, move balances, or remove LP |
| `guardian` (disable-only) | `pause()` swaps, remove or cancel a pending underlying | Enable a token, `unpause`, change routes, move balances, or remove LP |
| Shell Position NFT owner | Add or remove its v4 liquidity | Change Hook logic or FewV2 reserves |
| Any account | Call `sweep()` | Select the recipient; it is always the current `residualRecipient` |

The deployment target `FewV2ShellHook` has an `owner`, a `guardian` and a swap pause, but no upgrade function and no emergency withdrawal: no role can move PoolManager assets or remove another account's LP, and `pause()` does not block LP exit. `sweep()` can only move the Hook's residual balance to the current `residualRecipient`, which only the owner can change. It cannot reach assets held by PoolManager.

There is no numeric dust cap: `sweep(token)` transfers the Hook's entire balance of that token to `residualRecipient`. Do not send LP principal directly to the Hook. This permission boundary also does not remove existing FewCore authority: authorized FewToken minters can mint without adding underlying backing, and governors can grant mint/burn roles or change the factory's Core reference. See [Known Issues](../KNOWN_ISSUES.md#fewcore-privileged-roles-are-a-dependency-trust-assumption).

## Routing boundary

Underlying admission remains a trust boundary. Both factories permit public token/pair creation, so canonical provenance alone does not prove a token is safe. The deployment target enforces a time-locked underlying allowlist in `beforeInitialize`: only allowlisted underlyings can be registered, genesis covers the six recommended underlyings, and anything else must pass the owner's 48h add-timelock. The allowlist is admission control, not a safety proof — an allowlisted token with arbitrary minting, dishonest balances or transfer callbacks still fails closed at swap time rather than being made safe, and exact balance-delta checks do not establish the truth of a malicious token's balance reports. Review underlying behavior before adding any route. The isolated-fork admission counterexamples, the malicious-underlying behavior suite and the governance suite are recorded in [Validation](VALIDATION.md).

The contract exposes one direct pair per pool and does not decode a path from `hookData`. At checked public UniRoute commit `b19fcfbddec820115176dc7a835273461e3975a3`, the existing FewV4ShellHook and Ring FewV2 Hook remain in the ordinary v4 Hook admission registry. UniRoute has separate external-protocol maps for several venues, but Ring is not in them, and `AggHookQuoter` still classifies only Tempo single-hop routes. The current release baseline is therefore ordinary v4 discovery plus the standard V4Quoter, matching the already validated Shell route.

The exact `fee=3000`, `tickSpacing=1` PoolKey must be indexed because this combination is outside the ordinary canonical fee/tick grid. The UniRoute source replay and its limits are in [Validation](VALIDATION.md#uniroute-discovery-replay).

A future direct `hook.quote()` classifier or multi-hop Aggregator Hook path is a separate integration. It would need its own native ETH direction review and production tests.
