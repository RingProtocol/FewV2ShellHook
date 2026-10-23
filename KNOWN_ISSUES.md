# Known Issues and Release Constraints

This file separates known limits from claims that the code or tests have already closed. It is not an exhaustive security assessment.

## Production admission gates

### Protocol-fee candidate requires a new deployment and review

Current `src/` adds Uniswap Aggregator-family fee accounting and is not deployed. The existing mainnet address still runs the original implementation. Fee classification (`1 << 11`), 25× scaling, exact-input/output settlement, current TokenJar discovery and failure behavior require review before release. A corrected fee path does not establish Labs' rejection reason or guarantee allowlisting. See [Protocol Fee Upgrade](docs/PROTOCOL_FEE_UPGRADE.md).

### Current code has no independent external audit

No independent audit covers this code: not the contracts, constructors, governance layer, Shell LP accounting, quote path, price library or permission model. An earlier, materially different implementation was reviewed by ABDK; that review does not apply here. Fork tests are not proof of safety. Shell inventory should stay capped, with a rehearsed full withdrawal and explicit stop conditions.

### Production admission and exact PoolKey indexing are not confirmed

At public UniRoute main commit `b19fcfbddec820115176dc7a835273461e3975a3` (checked September 29, 2026), the existing FewV4ShellHook and Ring FewV2 direct-routing Hook remain in the ordinary v4 Hook admission list and use the standard V4Quoter path. Ring is not in UniRoute's separate external-protocol maps, and the direct `hook.quote()` branch still classifies only Tempo pools.

A local replay at commit `2961efa8` retained this candidate in all eight tested Hook-mode/top-N combinations after temporarily registering its local address. Without registration it was fetched, then removed by the admission filter. A source diff from that commit to `b19fcfbd` showed no change to the Ring addresses or the tested ordinary-v4 admission path, but production still requires the deployed address to be admitted and its exact `fee=3000`, `tickSpacing=1` PoolKey to be indexed. That fee/tick combination is outside the ordinary canonical grid, so manual fallback must not be assumed.

### Multi-hop Aggregator Hook composition is not established

The Hook maps one Shell Pool to one direct FewV2 pair. The reviewed public UniRoute source does not establish a production path that composes multiple FewV2ShellHook hops. A direct pair can be evaluated; an `A -> X -> B` route through two FewV2ShellHook Shell Pools is not a current production assumption.

### Direct Aggregator Hook classification is not the release baseline

The Hook implements the public `IAggregatorHook` quote, depth and event surface, but the validated Ethereum Shell route is an ordinary `0x2088` v4 Hook. Deployment scripts therefore mine only the v4 permission bits. They do not require an Aggregator protocol/type first byte.

The candidate exposes Aggregator fee classification, which is separate from routing admission. If Uniswap later asks Ring to enter the direct Aggregator routing path, that is a new integration: address ID, `aggregatorHookVersion` and native ETH direction handling must be reviewed and tested. The public `BaseAggregatorHook` also rejects LP additions, while this Shell design intentionally allows originToken LP for PoolManager working inventory. Do not describe this candidate as equivalent to that base class.

## Accounting and liquidity constraints

### PoolManager cash is shared

Shell LP puts physical origin tokens in the singleton PoolManager. Those balances are not reserved for one PoolId or Position NFT.

`quote()` checks the current balance, but two quotes can each succeed against the same cash. A later combined or split execution can fail if the total requirement exceeds the remaining balance. Failure is expected to revert atomically, but quote availability is not a cash reservation.

### The same FewV2 pair must have one active Shell route per chain

The contract prevents duplicate registration inside one Hook address. It cannot stop a native-mode Hook, WETH-mode Hook, old deployment or new deployment from exposing the same FewV2 pair again.

Running two active routes would double-count routing depth. Split quotes would also read the same initial reserves even though the first executed leg changes them. Operations must keep one active Shell route per FewV2 pair per chain and remove the old route from discovery before enabling a replacement.

### Shell LP does not set price or earn Hook swap fees

The originToken Shell Pool is settlement inventory. Hook swaps bypass its curve, so its `slot0`, active liquidity and fee growth stay unchanged. Real price movement and LP fees occur in the Ring Swap v2 FewToken pair.

Shell LP still carries token risk, Position NFT custody risk, dependency risk and opportunity cost. Tests do not justify an unlimited deposit.

### `pseudoTotalValueLocked()` is a routing signal

It reports canonical FewV2 reserves in Shell token order, capped by each wrapper's underlying backing and PoolManager's current origin-token cash. PoolManager cash is shared across the singleton, is not reserved for this PoolId, and can change before execution. It is not an accounting TVL and must not be added to Shell LP balances as if the assets were separate capital. `quote()` remains the final check for a requested trade.

## Initialization constraints

### One-tick validation can make public initialization fail

Only the current `poolInitializer` can register pools. The submitted price and live FewV2 price may have a tick-index difference of at most one. Their raw price gap can approach two tick intervals at the boundary. A normal FewV2 trade between preview and inclusion can make initialization revert. This is fail-closed, not a fund-loss path.

Use a private transaction or bundle, and generate the price immediately before execution. The tolerance is fixed in the deployed contract.

If the initializer key is lost or compromised, the owner replaces it with `setPoolInitializer`; existing pools keep working either way. Until it is replaced, a compromised key can initialize an otherwise valid canonical pair at a live price (only for allowlisted underlyings); it cannot change an existing route, pause swaps, withdraw LP positions or move balances.

## Fee reporting and dependency constraints

### LP fees, Ring fees and Uniswap protocol fees are separate

FewV2 charges its 30 bps LP fee. The Hook adds no Ring fee. The candidate pays configured Uniswap protocol fees directly to the current controller's TokenJar: from output for exact-input, and from grossed-up input for exact-output. Nonzero fees with no usable recipient revert atomically. Fee rates and recipients are not controlled by the Hook owner.

`HookSwap.swapFee` reports the effective Uniswap protocol-fee rate in pips, or zero when no fee is configured. It does not include FewV2's LP fee, which is already reflected in the Pair execution.

The current public v4 subgraph [`HookSwap` handler](https://github.com/Uniswap/v4-subgraph/blob/main/src/mappings/swap.ts) uses `swapFee` as the pool fee tier when calculating fee statistics, and only handles addresses included in its configured Hook set. If that handler is used for this deployment, volume can be recorded from the real `HookSwap` amounts but fee statistics would omit the FewV2 30 bps. It is not yet confirmed how Uniswap's production indexer represents the underlying venue fee, or whether it handles the deployed address. This is a reporting issue, not a settlement or custody issue.

### External contracts remain dependencies

Execution depends on Uniswap v4, FewToken wrappers, the FewV2 pair and factory, ERC20 behavior and V4Quoter. The Hook requires the factory's canonical wrapper, checks exact wrapper-backing and recipient balance changes, and resets the exact temporary wrapper allowance after every wrap. These checks reject observed shortfalls but do not remove bugs or governance risk in those systems.

### FewCore privileged roles are a dependency trust assumption

FewToken wrappers are governed by Few Protocol's Core contract, independently of this Hook:

- an authorized minter can mint FewTokens without depositing underlying, and minted tokens can be unwrapped while the wrapper still holds underlying;
- a governor can grant minter and burner roles, pause the factory, or change the factory's Core reference;
- a burner can burn FewTokens from any account, including a FewV2 pair, without an allowance;
- the factory pause gates privileged mint/burn, not ordinary `wrap`/`unwrap`, so it is not a swap kill switch for this Hook.

As a result, wrapper backing (underlying held by the wrapper divided by FewToken supply) is typically well below 1:1. The Hook only pays out from actual backing: it checks available backing before execution and caps `pseudoTotalValueLocked()` by it, so FewV2 reserves above backing are not redeemable through the Hook. A compromised minter key is bounded by the underlying held by FewToken wrappers, not by one wrapper: unbacked tokens can be unwrapped directly or sold into FewV2 pairs for other FewTokens that are then unwrapped. This Hook cannot reduce that exposure. Review the current Core role holders and their key management before funding a route.

### The allowlist is admission control, not token safety

`FewFactory.createToken()` and the FewV2 factory's `createPair()` are permissionless, so a malicious origin token can obtain a genuine canonical wrapper and pair. Canonical identity proves provenance, not safety. `FewV2ShellHook` therefore filters registration through an underlying allowlist. An allowlisted token with arbitrary minting, dishonest balance reports, transfer callbacks or rebasing still fails closed at swap time in the tested cases, but the allowlist does not make such a token safe. Review transfer semantics, mint and upgrade authority, and backing before admitting any underlying, and re-review after any token upgrade.

### Governance keys

- The underlying allowlist is fixed at deployment. No role can add an underlying or remove one, so there is no `UnderlyingAddProposed` to monitor; the set of admitted tokens is decided once, before the Hook is deployed.
- `pause()` is global for the deployment; there is no per-pool pause.
- Because the allowlist cannot be narrowed, `pause()` is the only in-place response to a bad underlying. It stops every pool of that deployment, so plan for a new Hook deployment if the token set has to change.
- The guardian should be a different key from the owner, otherwise the disable-only emergency role adds no independent protection.
- `owner`, `guardian`, `poolInitializer` and `residualRecipient` are storage, so they can be rotated after deployment without redeploying (`transferOwnership` plus `acceptOwnership`, `setGuardian`, `setPoolInitializer` and `setResidualRecipient`).
- A compromised owner can make itself the pool initializer and the residual recipient. The first lets it register allowlisted canonical pairs at a live price; the second redirects only the Hook's residual balance. Monitor `PoolInitializerUpdated` and `ResidualRecipientUpdated`.
- Ownership cannot be renounced (`renounceOwnership()` reverts), so a pause can always be lifted unless the owner key itself is lost. That is another reason for a multisig owner.

## Operational response

`FewV2ShellHook` has an emergency swap pause but no upgrade path, route setter or withdrawal path. If a route is unsafe: pause swaps through the guardian or owner, stop exposing the Hook and PoolIds through routing and discovery, withdraw Shell LP through PositionManager (pausing never blocks LP exit), and migrate to a newly reviewed Hook if needed. The underlying allowlist cannot be changed, so a new deployment with a different token set is the only way to stop admitting a token. Only the owner can unpause.

The base `FewV2ShellHookBase` has no pause; the same response applies without the first two steps.
