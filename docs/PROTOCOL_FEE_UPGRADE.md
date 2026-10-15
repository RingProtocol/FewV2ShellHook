# Protocol fee compatibility candidate

**October 15, 2026 — implemented locally; not deployed or submitted.**

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
| Full Foundry suite | Ethereum block 26,196,892 | 181 passed, 0 failed, 0 skipped |
| Full Foundry suite | Original CI fork block 25,934,149 | 181 passed, 0 failed, 0 skipped |
| Fee arithmetic fuzz | Each suite above | 10,000 cases against independent full-precision ceiling calculations |
| CREATE2 deployment rehearsal | Ethereum block 26,197,052 | Passed; no broadcast or wallet used |
| Production runtime | `FewV2ShellHook` | 24,435 bytes; 141 bytes below EIP-170 limit |

One additional test pays the real deployed mainnet TokenJar through the real controller ABI on each fork, in all four native ETH/USDC swap modes. PoolManager fee activation is simulated locally; this does not prove governance will enable fees or admit the route.

The fee tests cover native ETH, WETH and token/token routes, both directions, exact input/output, asymmetric rates, maximum PoolManager-supported rates, small raw-unit rounding, recipient/controller rotation, zero fee, invalid recipients, full settlement inventory and dust. The official Universal Router tests cover both WETH/USDC directions and amount modes with nonzero fees, plus atomic failure when the exact-output input cap is insufficient.

The original 153-test release is historical. The candidate suite adds 19 fee-specific tests and repeats 9 inherited execution tests, yielding 181 executed tests. Passing fork tests is not an independent security audit or a mainnet deployment.

Production runtime is close to the size limit. Rebuild and recheck it after any source, dependency or compiler change; do not remove balance or permission checks merely to make room.

Reproduce with an approved RPC available as `ETH_RPC_URL`:

```sh
TEST_FORK_BLOCK=26196892 forge test -vv
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
4. Initialize the bounded ETH/USDC canary with the existing canonical Pair. Keep price and route checks. Additional pools remain a separate decision. Confirm quotes and actual router execution on the new address, recording amount limits, fee configuration and recipient.
5. Before directing traffic to the replacement, plan the old Shell position and routing entry separately. Its Position NFT remains withdrawable through the normal PositionManager; a new Hook cannot inherit it. Do not count the same FewV2 reserves twice across old/new Shells. Pausing an old route does not withdraw its LP.
6. Resubmit the **new deployed, verified address**, final source revision and fee proof under the existing reference. Ask Uniswap to confirm the Aggregator classification, multiplier and TokenJar settlement satisfy their current policy. Include the already approved FewV4ShellHook as context, not as proof of approval for FewV2.
7. Approval, routing discovery, executable API quotes and a bounded live swap are separate acceptance checks. Stop activation if source verification, role readback, fee collection, quote parity, LP withdrawal or router amount limits fail.

No deployment, funding transaction, LP movement, canary transaction or external submission has been performed for this candidate. The local `fewv2-ops` keystore requires an interactive unlock or a local password-file configuration before signing. Do not send a password or private key through chat.

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

## Decision record

| Date | Evidence | Decision | Revisit when |
|---|---|---|---|
| 2026-10-15 | Original FewV2 custom accounting cancels the native swap; nonzero Shell fees were not collected in controlled fork tests. Uniswap's routing criteria prohibit bypassing AMM protocol fees. | Add a narrow fee settlement layer; retain canonical Pair execution and Shell LP design. Do not claim this was the confirmed rejection reason. | Uniswap provides the actual rejection reason or a different fee-policy requirement. |
| 2026-10-15 | Public Aggregator reference uses classification `1 << 11`, multiplier 25 and unspecified-currency fee collection. | Use the same classification and fee math; resolve the current TokenJar on every nonzero payment and fail closed if unavailable. | Upstream fee policy, adapter ABI or governance classification changes. |
| 2026-10-15 | Both fixed-block suites pass; runtime is within EIP-170 with limited headroom. | Candidate is ready for code review and deployment rehearsal. Mainnet and external submission remain distinct steps. | Any source/configuration change or failed rehearsal/acceptance check. |

## Appendix: calculation and sources

Let `r` be the directional raw Shell protocol fee multiplied by 25, with denominator `D = 1,000,000`:

- Exact input: `fee = ceil(gross Pair output * r / D)`; user receives `gross output - fee`.
- Exact output: `fee = ceil(required Pair input * r / (D - r))`; user pays `required input + fee`.

The implementation bounds the pre-fee amount to positive `int128` before multiplication. Its product with a `uint24` rate plus the rounding term is below `2^152`, so the bounded arithmetic cannot overflow. An independent `Math.mulDiv` reference validates rounding across the supported rate and signed-delta domain.

Official references checked on October 15, 2026:

- [Routing criteria](https://support.uniswap.org/hc/en-us/articles/48291859140621-Routing-for-hooked-pools)
- [ProtocolFees calculation and collection](https://github.com/Uniswap/v4-hooks-public/blob/5b73674d8db8ff9ef4f4a09cfee5f12302d68248/src/base/ProtocolFees.sol)
- [BaseAggregatorHook classification and multiplier](https://github.com/Uniswap/v4-hooks-public/blob/5b73674d8db8ff9ef4f4a09cfee5f12302d68248/src/base/BaseAggregatorHook.sol)
- [Public UniswapV2Aggregator example](https://github.com/Uniswap/v4-hooks-public/blob/5b73674d8db8ff9ef4f4a09cfee5f12302d68248/src/aggregator-hooks/implementations/UniswapV2/UniswapV2Aggregator.sol)

The upstream reference revision is `5b73674d8db8ff9ef4f4a09cfee5f12302d68248`. Recheck current policy before a later deployment.
