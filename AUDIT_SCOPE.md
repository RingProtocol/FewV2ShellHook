# Audit Scope

## Review target

| Item | Value |
|---|---|
| Repository | `https://github.com/RingProtocol/FewV2ShellHook` |
| Source | Current `src/`: undeployed fee-aware candidate based on public main `730c6fdade1fb2bd0a1b9e0e38a1c353de3ad8a8`. The earlier source matches the existing mainnet deployment; this candidate requires a new address |
| Compiler | Solidity `0.8.26`, optimizer 200 runs, `via_ir = true`, Cancun |
| Framework | Foundry |
| Test snapshot | Original release: 153 passed. Fee candidate: see [Protocol Fee Upgrade](docs/PROTOCOL_FEE_UPGRADE.md) for current results |

No previous audit covers this target.

## Production code in scope

| File | Role | Priority |
|---|---|---|
| `src/FewV2ShellHook.sol` | Deployment target: underlying allowlist enforced in `beforeInitialize`, immutable add-timelock, swap pause, non-renounceable `Ownable2Step` owner, disable-only guardian and owner-replaceable pool initializer and residual recipient over the inherited swap path | Critical |
| `src/FewV2ShellHookBase.sol` | v4 settlement, wrap, FewV2 execution, unwrap, quote and routing-depth interface | Critical |
| `src/lib/FewV2Math.sol` | FewV2 exact-input and exact-output math | High |
| `src/lib/FewV2Price.sol` | Reserve ordering and overflow-safe v4 initialization price | High |
| `src/interfaces/**` | Minimal external and Aggregator Hook ABIs | Supporting |

Pinned third-party dependencies, scripts, tests and documents are outside production-code scope. Their assumptions and interactions still need review where they affect the in-scope contracts.

## Architecture under review

1. One v4 Shell Pool maps to one canonical direct FewV2 pair.
2. originToken Shell LP supplies PoolManager settlement inventory.
3. The Hook takes the full v4 swap delta, wraps input directly to the FewV2 pair, swaps, unwraps ERC20 output directly to PoolManager where possible and settles atomically. It adds no Ring fee. Configured Uniswap fees are collected in the unspecified origin currency, with quote and settlement using the same path.
4. Shell `slot0`, liquidity and fee growth are not execution state.
5. `quote()` simulates the full v4 path. `pseudoTotalValueLocked()` reports FewV2 depth capped by wrapper backing and current PoolManager origin-token cash.
6. In the base `FewV2ShellHookBase`, `poolInitializer` is the only role and can only register new pools. `FewV2ShellHook` adds an owner (allowlist adds after the timelock, immediate removals, unpause, and replacing the guardian, pool initializer and residual recipient) and a disable-only guardian (pause, remove/cancel underlyings); neither can change a route, move PoolManager balances or withdraw LP.
7. PoolKey uses `fee=3000` and `tickSpacing=1`. The fee field mirrors the external FewV2 venue; the v4 curve is bypassed. Production indexing must retain this exact non-canonical fee/tick combination.

## Main changes from the historical build

- Shell LP is allowed and used as settlement inventory.
- Full-path V4Quoter checks replace reserve-only quote claims.
- PoolManager cash and wrapper backing are checked before execution.
- Custom v4 price limits are checked against the live and post-swap FewV2 reserve price; crossing a limit reverts atomically.
- Initialization derives the marker price from live FewV2 reserves and accepts a tick-index difference of at most one.
- Initialization is restricted to a bounded signer; in `FewV2ShellHook` only the owner can replace it.
- Native ETH and WETH modes are mutually exclusive per deployment.
- Exact-output requests the user's target amount directly from FewV2 and leaves no Hook dust in tested boundaries.
- FewV2 price conversion handles reversed pairs, token decimals and high reserve ratios without overflow.
- One FewV2 pair may back only one Shell Pool per Hook deployment.
- PoolKey moved to `fee=3000`, `tickSpacing=1` so metadata mirrors FewV2's 30 bps fee and the Shell marker can stay close to the reserve price.
- Wrapper registration now rechecks the immutable FewFactory canonical mapping.
- Wrap and unwrap enforce exact wrapper-backing and recipient-balance changes, including fee-on-transfer-style shortfall tests.
- Direct `wrapTo/unwrapTo` settlement reduces measured full Universal Router gas by roughly 6%–15% on the tested routes without leaving permanent approvals.

## Directed questions

1. Are all `BeforeSwapDelta` signs and PoolManager take/settle operations correct for both directions and both amount modes?
2. Can shared PoolManager physical balances create an unsafe state, rather than a clean quote or execution failure, under batched or concurrent routes?
3. Are FewV2 exact-output rounding and settlement minimal and complete for every token decimal layout?
4. Do balance-delta checks close lying wrapper, fee-on-transfer, callback and partial-transfer paths?
5. Can any external wrapper, pair, token or residual-balance recipient reenter a value-moving path?
6. Does the one-tick initialization check prevent bad registration without creating an unacceptable deployment failure mode?
7. Is `pseudoTotalValueLocked()` safe and useful as a routing signal when wrapper backing or shared PoolManager cash is lower than pair reserves?
8. Can the pool initializer, or an owner who replaces it, affect user principal or Shell LP withdrawal rights?
9. Are forced ETH, allowance reset, sweep and failed-settlement rollback handled completely?
10. Can any path register a pool whose underlying is not allowlisted, including native ETH mapped to WETH and either currency ordering?
11. Can the owner shorten or bypass the add-timelock, or can the guardian enable a token or unpause through any sequence?
12. Does `whenNotPaused` on `_beforeSwap` cover every swap entry point while leaving LP add/remove unaffected?
13. Are the inherited `Ownable2Step` and `Pausable` integrations correct with the hook's constructor and permission bits, and does any path to a zero owner remain after the `renounceOwnership()` override?
14. Can replacing `poolInitializer` or `residualRecipient` change an existing route, redirect anything beyond the Hook's own residual balance, or leave either role at the zero address?
15. Do the directional fee, Aggregator multiplier, ceiling rounding and input gross-up match Uniswap's current public fee rules, including the signed-int128 arithmetic bound?
16. Are quote and Universal Router execution charged exactly once, with complete rollback on a bad recipient or a failed user amount limit?
17. Does resolving `TOKEN_JAR()` from the current controller on each nonzero payment handle controller/recipient rotation and fail closed without granting Ring authority over fees?

The release baseline is the ordinary v4 Hook registry and standard V4Quoter path used by the existing FewV4ShellHook at checked public UniRoute commit `b19fcfbd`. Uniswap review must confirm the new address and exact PoolKey are admitted and indexed on that path.

The candidate already exposes Aggregator fee classification for protocol-fee policy. If Uniswap instead asks Ring to enter the separate direct Aggregator Hook routing path, that becomes a new review item: `aggregatorHookVersion`, protocol/type address ID, native ETH direction handling and the official base class's LP prohibition would all need to be resolved. Fee classification alone does not establish routing admission.

## Evidence

- [Architecture](docs/ARCHITECTURE.md)
- [Validation](docs/VALIDATION.md)
- [Known Issues](KNOWN_ISSUES.md)
- [Security Policy](SECURITY.md)
- `test/unit/` and `test/fork/`

The requested deliverable is a report against the final commit plus one post-fix review pass.
