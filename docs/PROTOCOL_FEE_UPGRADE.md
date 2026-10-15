# Protocol fee compatibility candidate

**October 15, 2026 — fee-aware replacement; not deployed or submitted.**

The candidate preserves `origin token -> FewToken -> canonical FewV2 Pair -> FewToken -> origin token` and adds Uniswap protocol-fee accounting around settlement. It follows the fee calculation and Aggregator classification in Uniswap's public contracts. Pair pricing, its 30 bps LP fee, wrapper checks, route registration, Shell LP ownership and governance permissions remain unchanged.

This addresses a concrete compatibility gap. It does **not** establish why Uniswap rejected submission `65899411286`, or guarantee approval of the replacement.

## Change and effect

| Item | Original deployed implementation | Candidate | Effect |
|---|---|---|---|
| Execution liquidity | Canonical FewV2 Pair | Same Pair | No liquidity migration into native v4 pricing |
| FewV2 LP fee | 30 bps, included in Pair math | Same | Existing LP economics preserved |
| Additional Ring fee | Zero | Zero | No voluntary fixed donation added |
| Uniswap protocol fee | Shell rate is ignored by the custom swap path | Read current directional Shell rate and multiply by 25 | Uniswap controls the applicable rate |
| Exact-input user output | Gross Pair output | Gross output less protocol fee | Quoted output includes the fee |
| Exact-output user input | Required Pair input | Required Pair input plus grossed-up protocol fee | Quoted input includes the fee |
| Protocol recipient | No payment | Current controller's `TOKEN_JAR()` | No Ring-controlled recipient |
| Nonzero fee, unusable recipient | No collection | Whole transaction reverts | No silent fee bypass |
| Zero configured fee | No fee | No fee | Recipient lookup is unnecessary |
| Upgrade existing address | Unsupported | Unsupported | New deployment and new PoolIds required |

`protocolFeeFlags()` returns `1 << 11`, the classification used by Uniswap's public `BaseAggregatorHook`. `protocolFeeMultiplier()` returns `25`. The effective fee is variable: these constants do not impose a fixed 5 or 10 bps charge.

For example, a raw directional rate of 40 becomes 1,000 pips, or 10 bps. This example is a test configuration, not the current live rate or a promise about future Uniswap policy.

## Settlement and authority

For exact input, the entire Pair output is unwrapped and settled, the protocol fee is taken to TokenJar, and the user receives the net output. For exact output, only the Pair's required input is wrapped; the additional input fee goes directly from PoolManager to TokenJar. The inventory precheck covers the full required input, including this fee.

The existing full-path V4Quoter simulates this exact execution path, so the fee is included once. Failed user amount limits, missing cash or invalid recipient configuration roll back the Pair trade and payment atomically.

Every nonzero payment resolves the current controller and recipient. Neither owner, guardian, initializer nor residual recipient can select the protocol recipient or override the rate. There is no cached recipient to become stale after a rotation. A nonzero fee without a usable `TOKEN_JAR()` fails closed; this intentionally differs from the public reference's optional missing-recipient fallback.

The public `BaseAggregatorHook` is a reference for fees, not a new parent contract. Inheriting it would prohibit Shell LP additions and change the existing design. The candidate keeps permission bits `0x2088`, the ordinary v4 routing path, and standard router calldata. Fee classification alone does not establish routing admission or a separate direct Aggregator routing integration.

## Validation

Compiler settings remain Solidity 0.8.26, via-IR, optimizer 200 runs, Cancun.

| Check | Snapshot | Result |
|---|---|---|
| Full Foundry suite, including the ETH/WBTC fee canary | Ethereum block 26,197,122 | 191 passed, 0 failed, 0 skipped |
| Full Foundry suite | Original CI fork block 25,934,149 | 191 passed, 0 failed, 0 skipped |
| Fee arithmetic fuzz | Each suite above | 10,000 cases against independent full-precision ceiling calculations |
| CREATE2 deployment rehearsal | Ethereum block 26,197,052 | Passed; no broadcast or wallet used |
| Deploy + ETH/WBTC init + official-router canary rehearsal | Ethereum block 26,197,122 | Passed; 3 simulated transactions, no signing/broadcast |
| Production runtime | `FewV2ShellHook` | 24,435 bytes; 141 bytes below EIP-170 limit |

Fee tests pay the real deployed mainnet TokenJar through the real controller ABI. The production-Hook policy test additionally uses the actual policy classification and permissionless adapter.triggerFeeUpdate, with no fee-controller impersonation; it then runs all four ETH/WBTC modes and fully withdraws Shell LP. These local forks do not activate mainnet fees or establish routing admission.

The fee tests cover native ETH, WETH and token/token routes, both directions, exact input/output, asymmetric rates, maximum PoolManager-supported rates, small raw-unit rounding, recipient/controller rotation, zero fee, invalid recipients, full settlement inventory and dust. The official Universal Router tests cover both WETH/USDC directions and amount modes with nonzero fees, plus atomic failure when the exact-output input cap is insufficient.

The ETH/WBTC canary test also runs all four official-router swap modes with nonzero asymmetric fees, confirms real TokenJar receipts in ETH and WBTC, and fully withdraws the Shell LP position afterward.

The original 153-test release is historical. The final suite adds 20 fee-specific tests, five historical-deployment quote/approval regressions, and one production-Hook policy activation test; 12 inherited executions repeat existing cases, yielding 191 executed tests. The historical-deployment fixture always pins block 26,197,122 because that Hook did not exist at the older global baseline. See [Release Readiness](RELEASE_READINESS.md) for scope and CI limitations. Passing fork tests is not an independent security audit or a mainnet deployment.

Production runtime is close to the size limit. Rebuild and recheck it after any source, dependency or compiler change; do not remove balance or permission checks merely to make room.

Reproduce with an approved RPC available as `ETH_RPC_URL`:

```sh
TEST_FORK_BLOCK=26197122 forge test -vv
TEST_FORK_BLOCK=25934149 forge test -vv
forge fmt --check
forge build --skip test --skip script --sizes
git diff --check
```

## Deployment and submission

The source base is public main commit `730c6fdade1fb2bd0a1b9e0e38a1c353de3ad8a8`. The local branch is `fix/uniswap-protocol-fees`. The existing address `0x59255CbC688e402eF980B84668bA1d1c708b6088` remains unchanged and must not be described as patched.

1. Review this candidate and freeze its source, dependencies, compiler and constructor configuration. Confirm final owner, guardian, initializer and residual recipient. A rehearsal that copies existing roles does not approve those roles for a new release.
2. Mine a new CREATE2 salt with `script/MineHookAddress.s.sol`, using the final native ETH mode and constructor values. Rehearse `DeployMainnetNativeEth` without `--broadcast`; check the predicted address is empty and deployment assertions pass. A changed init code or role changes the address.
3. Deploy only the reviewed candidate. Verify source and constructor arguments on Etherscan, then run `CheckDeployment` with the new salt/address. Both deployment scripts now check fee classification and multiplier.
4. Initialize **native ETH/WBTC** with `script/InitializeEthWbtcPool.s.sol:InitializeEthWbtcPool`, using the existing canonical fwETH/fwWBTC Pair confirmed below. Keep price and route checks. Run `script/UpdateEthWbtcProtocolFee.s.sol:UpdateEthWbtcProtocolFee` to preview the current controller, TokenJar, policy fee and update calldata; execute its permissionless `triggerFeeUpdate` before the canary. Read slot0 back and require it to equal the current nonzero official policy. Initialization alone leaves the fee at zero. Stop and reconcile any intentional zero policy with Uniswap; never invent a rate. For Shell LP, use the existing `ShellLiquidity` script with native ETH as `LP_TOKEN_A` and WBTC as `LP_TOKEN_B`, retaining explicit amount caps. Use `script/SmokeSwapEthWbtc.s.sol:SmokeSwapEthWbtc` for the bounded official-router canary. Additional pools remain a separate decision. Confirm quotes and actual router execution on the new address, recording amount limits, fee configuration and recipient. The older ETH/USDC deployment and scripts are not changed.
5. Before directing traffic to the replacement, plan the old Shell position and routing entry separately. Its Position NFT remains withdrawable through the normal PositionManager; a new Hook cannot inherit it. Do not count the same FewV2 reserves twice across old/new Shells. Pausing an old route does not withdraw its LP.
6. Resubmit the **new deployed, verified address**, final source revision and fee proof under the existing reference. Ask Uniswap to confirm the Aggregator classification, multiplier and TokenJar settlement satisfy their current policy. Include the already approved FewV4ShellHook as context, not as proof of approval for FewV2.
7. Approval, routing discovery, executable API quotes and a bounded live swap are separate acceptance checks. Stop activation if source verification, role readback, fee collection, quote parity, LP withdrawal or router amount limits fail.

No deployment, funding transaction, LP movement, canary transaction or external submission has been performed for this candidate. The local `fewv2-ops` keystore requires an interactive unlock or a local password-file configuration before signing. Do not send a password or private key through chat.

## Initial pool: native ETH/WBTC

The selected replacement pool is native ETH (`address(0)`) / WBTC (`0x2260FAC5E5542a773Aa44fBCfeDf7C193bc2C599`), fee 3000, tickSpacing 1, using the replacement Hook. The Hook wraps ETH through WETH; its FewV2 execution source is the existing canonical fwETH/fwWBTC Pair.

Mainnet snapshot at block 26,197,122:

| Check | Result |
|---|---|
| FewFactory canonical fwETH | `0xa250CC729Bb3323e7933022a67B52200fE354767` |
| FewFactory canonical fwWBTC | `0x2078f336Fdd260f708BEc4a20c82b063274E1b23` |
| FewV2 factory Pair | `0x00B06862dE00a7e67a2d6d3FbEEa592A32460de0` |
| Wrapper underlying and Pair token checks | Match WETH/WBTC and the canonical wrappers |
| Pair reserves | 34,136.003906264733215024 fwETH; 996.62932171 fwWBTC |
| Underlying held by the wrappers | 4,800.820429413599223462 WETH; 161.54218034 WBTC |

Pair reserves are FewToken units and exceed the immediately redeemable underlying balances. They are not a promise of executable origin-token depth. Quote the requested amount again before any transaction. The raw snapshot and validation are in [ETH/WBTC evidence](protocol-fee-evidence/eth-wbtc-2026-10-15.json).

After deployment and source verification, set `HOOK_ADDRESS` to the new address and preview only the selected pool:

```sh
forge script script/InitializeEthWbtcPool.s.sol:InitializeEthWbtcPool --rpc-url "$ETH_RPC_URL"
```

After initialization, preview the official fee update:

```sh
forge script script/UpdateEthWbtcProtocolFee.s.sol:UpdateEthWbtcProtocolFee --rpc-url "$ETH_RPC_URL"
```

The script prints the current controller as target and its permissionless update calldata. To execute in a rehearsal, set `BROADCAST_PROTOCOL_FEE_UPDATE=true` while still omitting Foundry `--broadcast`. Only an explicitly authorized mainnet execution adds `--broadcast` and a signer. Once the fee is synchronized and the separate Shell LP setup is complete, preview the small official-router canary:

```sh
forge script script/SmokeSwapEthWbtc.s.sol:SmokeSwapEthWbtc --rpc-url "$ETH_RPC_URL"
```

An earlier three-transaction fork rehearsal, before explicit fee activation was added, deployed the exact candidate, initialized this PoolKey and executed the canary successfully. This historical run is not the final fee-payment proof; use the four-step rehearsal in [Release Readiness](RELEASE_READINESS.md). At the snapshot, 0.0001 ETH quoted 291 raw WBTC (0.00000291 WBTC), with minimum output 289 raw WBTC. Estimated total gas including Forge margin was 8,576,458. This rehearsal used existing singleton PoolManager cash and did not mint a Shell LP; the separate LP deposit/withdrawal tests cover that operation. Nothing was broadcast.

Initialization, fee update and canary scripts default to preview mode. The canary now rejects unsynchronized or zero policy fees before quoting or sending a swap. The canary defaults to 0.0001 ETH input and quotes WBTC in raw units (8 decimals); `SMOKE_MIN_WBTC_OUT` sets the minimum output. Use the single-pool initialization script for this release, rather than the batch script that initializes all recommended pools. The earlier ETH/USDC pool and release record remain historical facts.

## Rehearsal snapshot

The rehearsal copies the four existing roles solely to validate deployment and produce a concrete review target. At block 26,197,052, all four were still the existing operations account. These are not approved final release roles.

| Item | Simulation result |
|---|---|
| Candidate address | `0xbeBc5239e446BC78B46654Ad943b0Fc19A31E088` — undeployed |
| Salt | `0x0000000000000000000000000000000000000000000000000000000000000fce` |
| Permission bits | `0x2088` |
| Estimated deployment gas | 7,799,730 including Forge estimation margin |
| Estimated deployment cost | 0.00116812740582084 ETH at the snapshot estimate of 0.149765108 gwei; excludes initialization, LP and live canary |
| Fee controller | `0x89A5D5bF00a27D55c02951E49078a5C5771051dB` |
| Current TokenJar | `0xf38521f130fcCF29dB1961597bc5d2B60F995f85` |

A source hash manifest, constructor roles, test summaries and rehearsal code hash are retained in [the evidence snapshot](protocol-fee-evidence/2026-10-15.json). The predicted address changes if production source, dependency metadata, compiler settings or constructor values change.

## Submission note

Use only after replacing the placeholders with a deployed and verified release:

> We have updated FewV2ShellHook to support Uniswap protocol fees while preserving its existing FewV2 execution path. The replacement reads the configured directional fee, applies the Aggregator multiplier and rounding used in Uniswap's public contracts, and pays the current fee controller's TokenJar in the original token. Quotes and Universal Router execution include the fee, and a configured fee cannot be silently skipped.
>
> New deployed hook: [new address and explorer link]
>
> Reviewed source and validation: [final revision and evidence]
>
> This replaces the hook in submission 65899411286. Our FewV4ShellHook at 0xADEf200B8E8b66e27D5bd11C87D789D4D6E82088 was previously approved. Could you confirm whether the protocol-fee handling was the issue with FewV2ShellHook, and whether any other changes are needed for this replacement?

The replacement submission's initial PoolKey is native ETH/WBTC, fee 3000, tickSpacing 1, with the new Hook address. Its execution Pair is the canonical FewV2 fwETH/fwWBTC Pair, not a new Pair or native v4 pricing pool.

## Decision record

| Date | Evidence | Decision | Revisit when |
|---|---|---|---|
| 2026-10-15 | Original FewV2 custom accounting cancels the native swap; nonzero Shell fees were not collected in controlled fork tests. Uniswap's routing criteria prohibit bypassing AMM protocol fees. | Add a narrow fee settlement layer; retain canonical Pair execution and Shell LP design. Do not claim this was the confirmed rejection reason. | Uniswap provides the actual rejection reason or a different fee-policy requirement. |
| 2026-10-15 | Public Aggregator reference uses classification `1 << 11`, multiplier 25 and unspecified-currency fee collection. | Use the same classification and fee math; resolve the current TokenJar on every nonzero payment and fail closed if unavailable. | Upstream fee policy, adapter ABI or governance classification changes. |
| 2026-10-15 | Both fixed-block suites pass; runtime is within EIP-170 with limited headroom. | Candidate is ready for code review and deployment rehearsal. Mainnet and external submission remain distinct steps. | Any source/configuration change or failed rehearsal/acceptance check. |
| 2026-10-15 | Fresh pools start with protocol fee zero; real policy recognizes family 11 and resolves raw 40 each way at the review snapshot. | Add an explicit permissionless fee-update script and a canary gate requiring current policy synchronization. | Controller, policy, classification or token pair changes. |
| 2026-10-15 | Historical native-output and USDT smoke failures were reproduced and isolated to test-router refunds and optional-return approval decoding. | Add exact official-router balance regressions; preserve Hook execution code. | A same-state official-router execution diverges from its quote. |
| 2026-10-15 | Michael selected ETH/WBTC if a canonical FewToken Pair exists. Mainnet factory, wrapper underlyings, Pair tokens, nonzero reserves and underlying balances were verified at block 26,197,122. | Replace ETH/USDC as the new release's first initialization and canary target with native ETH/WBTC. Keep the original deployment record unchanged. | Pair, backing or initialization/quote preflight fails at execution time. |

## Appendix: calculation and sources

Let `r` be the directional raw Shell protocol fee multiplied by 25, with denominator `D = 1,000,000`:

- Exact input: `fee = ceil(gross Pair output * r / D)`; user receives `gross output - fee`.
- Exact output: `fee = ceil(required Pair input * r / (D - r))`; user pays `required input + fee`.

The implementation bounds the pre-fee amount to positive `int128` before multiplication. Its product with a `uint24` rate plus the rounding term is below `2^152`, so the bounded arithmetic cannot overflow. An independent `Math.mulDiv` reference validates rounding across the supported rate and signed-delta domain.

Official references checked on October 15, 2026:

- [Routing criteria](https://support.uniswap.org/hc/en-us/articles/48291859140621-Routing-for-hooked-pools)
- [ProtocolFees calculation and collection](https://github.com/Uniswap/v4-hooks-public/blob/5b73674d8db8ff9ef4f4a09cfee5f12302d68248/src/aggregator-hooks/ProtocolFees.sol)
- [BaseAggregatorHook classification and multiplier](https://github.com/Uniswap/v4-hooks-public/blob/5b73674d8db8ff9ef4f4a09cfee5f12302d68248/src/aggregator-hooks/BaseAggregatorHook.sol)
- [Public UniswapV2Aggregator example](https://github.com/Uniswap/v4-hooks-public/blob/5b73674d8db8ff9ef4f4a09cfee5f12302d68248/src/aggregator-hooks/implementations/UniswapV2/UniswapV2Aggregator.sol)

The upstream reference revision is `5b73674d8db8ff9ef4f4a09cfee5f12302d68248`. Recheck current policy before a later deployment.
