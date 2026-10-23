# FewV2ShellHook

`FewV2ShellHook` is a Uniswap v4 Hook that lets users trade origin tokens through canonical Ring Swap v2 (FewV2) FewToken liquidity from an ordinary v4 pool.

```text
origin token A
  -> FewToken A
  -> canonical FewV2 pair
  -> FewToken B
  -> origin token B
```

The v4 pool is the route and settlement entry point. The FewV2 pair supplies the real price, depth and 30 bps LP fee. It uses the same Shell model as Ring's `FewV4ShellHook`, with Ring Swap v2 as the execution source.

## Contracts

| Contract | Role |
|---|---|
| [`FewV2ShellHook`](src/FewV2ShellHook.sol) | **Deployment target.** `FewV2ShellHookBase` plus an underlying allowlist fixed at deployment, a swap pause, a two-step owner that cannot be renounced and a disable-only guardian. The owner can replace the pool initializer and residual recipient. The swap and settlement path is inherited unchanged |
| [`FewV2ShellHookBase`](src/FewV2ShellHookBase.sol) | Execution, quoting and settlement. No owner and no admin functions. Not deployed on its own |

## Status

The protocol-fee replacement is **deployed and source-verified on Ethereum mainnet** at [`0xbeBc5239e446BC78B46654Ad943b0Fc19A31E088`](https://etherscan.io/address/0xbeBc5239e446BC78B46654Ad943b0Fc19A31E088#code). The deployed source is pinned to [`9285804`](https://github.com/RingProtocol/FewV2ShellHook/tree/928580478ab4eed4f2d25ee0b2aff92ffbc5a97a); the documentation update does not change contract source. See [Mainnet Release](docs/RELEASE_MAINNET.md) and [Protocol Fee Upgrade](docs/PROTOCOL_FEE_UPGRADE.md).

- The initialized pool is **native ETH/WBTC**, bound to canonical FewV2 fwETH/fwWBTC Pair `0x00B06862dE00a7e67a2d6d3FbEEa592A32460de0`. The official protocol-fee update, two Universal Router canaries and a complete Shell LP withdrawal/re-mint were executed. At the recorded mainnet snapshot, both canaries exactly matched their quotes and the effective official fee was 1,000 pips (10 bps) per direction, subject to integer rounding.
- PositionManager NFT #462837 retains a small Shell position funded with approximately 0.0025 ETH and 0.00007403 WBTC. This is settlement inventory, not the FewV2 execution reserves, and earns no FewV2 LP fee.
- The new address has **not been submitted or approved for routing** as of this record. Default Uniswap App / Quote API route selection is unverified. Local validation at global fork blocks 26,197,122 and 25,934,149 passed 191 tests each, with no failures or skips; this is separate from the mainnet canaries.
- The previous ETH/USDC Hook at `0x59255CbC688e402eF980B84668bA1d1c708b6088` remains unchanged. Its deployment is archived in [October 12 release](docs/RELEASE_MAINNET_2026-10-12.md); the replacement does not inherit its PoolId, LP position or routing approval.
- Not audited. An earlier, materially different implementation was reviewed by ABDK; that review does not cover this code.
- The original pre-fee release passed 153 tests. The replacement's 191-test validation and test/CI limits are recorded in [Release Readiness](docs/RELEASE_READINESS.md).

## How it works

| Component | Job |
|---|---|
| originToken Shell LP | Keeps origin-token inventory in Uniswap v4 `PoolManager` for swap-before-payment settlement and gives routing discovery a non-zero v4 position. |
| Ring Swap v2 FewToken pair | Sets the executable price and depth. Its reserves move and its LPs collect the FewV2 fee. |
| `FewV2ShellHook` | Wraps directly into the FewV2 pair, swaps, unwraps directly into PoolManager where possible and settles the v4 balance delta atomically. It adds no Ring fee; configured Uniswap protocol fees are paid in origin currency to the controller's TokenJar. |
| `SubsidyVault` | Holds the shared Ring budget that refunds the Uniswap protocol fee to traders. A separate contract with its own owner. Not part of the deployed addresses above |

Hook swaps bypass the Shell Pool curve. Its `slot0`, active liquidity and fee growth do not move during those swaps. Shell LPs do not earn swap fees from this path, but the position remains owned and withdrawable through the standard v4 PositionManager, including while swaps are paused.

The `feat/subsidy` branch adds the optional `SubsidyVault` subsidy: it refunds the Uniswap protocol fee to the trader out of a shared Ring budget, which brings the Shell quote back on par with a plain v4 pool at the same fee tier. The refund is capped at the protocol fee that was just charged, costs the Shell LP nothing, and fails open to zero when the vault is unarmed, paused or empty. It is not part of the deployed addresses above: it needs its own vault deployment, address mining, Hook deployment and routing review. See [Subsidy](docs/SUBSIDY.md) and [Anvil Validation](docs/ANVIL_VALIDATION.md).

## Same Shell, different execution source

| | `FewV4ShellHook` | `FewV2ShellHook` |
|---|---|---|
| User-facing pool | originToken v4 Shell Pool | originToken v4 Shell Pool |
| Shell LP job | Non-zero v4 liquidity signal and PoolManager working inventory | Same |
| Real execution source | Uniswap v4 FewToken LP | Ring Swap v2 FewToken pair |
| Atomic path | wrap -> v4 FewToken swap -> unwrap | wrap -> FewV2 swap -> unwrap |

The core Shell accounting is the same, but this is not a one-line venue replacement. The real execution source changes to Ring Swap v2, and each pool is bound immutably to its canonical direct pair through a bounded initializer. A caller may set a price limit on the valid side of the live FewV2 price and within the v4 TickMath bounds. The Hook checks that limit before the swap and against the resulting FewV2 reserve price afterward; it fills completely or reverts completely.

## Governance

| Power | Holder | Notes |
|---|---|---|
| Register a Shell Pool | `poolInitializer` | Only for allowlisted underlyings. The price must be within one tick of FewV2, and each FewV2 pair can back only one pool |
| Pause swaps | Guardian or owner | Blocks swaps in every pool. Never blocks LP withdrawals |
| Unpause, replace guardian, transfer ownership | Owner | Ownership transfer is two-step. Ownership cannot be renounced, so a pause can always be lifted |
| Replace the pool initializer or residual recipient | Owner | Immediate. A new initializer can only register new pools; registered routes never change |

There is no upgrade path, route setter or owner withdrawal. The allowlist is WETH, USDC, USDT, DAI, WBTC and USDR, which covers the eight recommended pools. It is fixed at deployment: no role can add an underlying or remove one, and a different token set needs a new Hook deployment. The allowlist controls admission; it does not make a token safe. See [Known Issues](KNOWN_ISSUES.md).

## Routing interface

The Hook implements Uniswap's public Aggregator Hook ABI:

- `quote()` simulates the complete swap through the official v4 Quoter;
- `pseudoTotalValueLocked()` reports FewV2 reserves, capped by wrapper backing and current PoolManager origin-token cash, as a conservative routing-depth signal;
- `AggregatorPoolRegistered` and `HookSwap` are available for indexers that choose to consume them. `HookSwap.swapFee` reports the effective Uniswap protocol fee in pips. The FewV2 pair's 30 bps LP fee is already reflected in executed amounts; it is not added to that event field.

Each Shell Pool maps to one canonical direct FewV2 pair. The Hook does not search connector tokens or accept a caller-supplied pair.

At the checked public UniRoute commit `b19fcfbd`, Ring's existing FewV2 direct-routing Hook and FewV4ShellHook are ordinary v4 Hooks quoted through the standard V4Quoter path. UniRoute's direct `hook.quote()` branch still classifies only Tempo pools, and Ring is not in its external-protocol maps. This repository therefore mines only the `0x2088` v4 permission bits and uses the ordinary v4 path as the release baseline.

References:

- [Uniswap Aggregator Hooks](https://github.com/Uniswap/v4-hooks-public/tree/main/src/aggregator-hooks)
- [UniswapV2Aggregator reference implementation](https://github.com/Uniswap/v4-hooks-public/blob/main/src/aggregator-hooks/implementations/UniswapV2/UniswapV2Aggregator.sol)
- [UniRoute public source at checked commit `b19fcfb`](https://github.com/Uniswap/uniroute-public/tree/b19fcfbddec820115176dc7a835273461e3975a3)

## Fixed decisions

| Item | Value | Reason |
|---|---:|---|
| Shell Pool fee field | `3000` | Mirrors the FewV2 pair's 30 bps fee for pool metadata. The v4 curve itself is bypassed and does not charge this fee. |
| Tick spacing | `1` | Keeps the initialization marker close to the live FewV2 reserve price. The exact non-canonical fee/tick PoolKey must be indexed in production. |
| Additional Ring fee | `0` | No Ring output fee is added. |
| Uniswap protocol fee | Per-pool directional rate × `25` | Follows Uniswap's Aggregator family. Exact-input pays from output; exact-output pays from grossed-up input. The fee controller supplies the TokenJar recipient. |
| Initialization tolerance | Tick-index difference at most `1` | Prevents a misleading Shell marker price. Initialization should use a private transaction because a normal FewV2 trade can make a public transaction revert. |
| WETH representation | Native ETH or WETH, fixed at deployment | Prevents two Shell Pools on one Hook from reporting the same FewV2 reserves. Deploy only one mode. |
| Underlying add delay | `172800` seconds, immutable | Gives the guardian and observers time to react before a new underlying becomes usable. |

## Validation

The fee-aware release passed the full local suite at two global mainnet fork blocks before deployment. Historical-deployment regressions independently pin block 26,197,122 because the old Hook did not exist at the older global baseline.

| Check | Result |
| --- | --- |
| Local suite, global block 26,197,122 | 191 passed, 0 failed, 0 skipped |
| Local suite, global block 25,934,149 | 191 passed, 0 failed, 0 skipped |
| Fee arithmetic fuzz | 10,000 full-precision reference cases per local run |
| Mainnet canaries | Both ETH/WBTC directions matched their quotes and paid the official TokenJar |
| Mainnet Shell LP | Full withdrawal, burn and re-mint checked |

The original pre-fee release's 153 tests are historical. Final implementation CI executed 20 hermetic cases and skipped 171 RPC-dependent cases; those skips are not fork coverage. No independent external audit covers this release. See [Release Readiness](docs/RELEASE_READINESS.md) for test scope and [Mainnet Release](docs/RELEASE_MAINNET.md) for mined transactions. This documentation refresh does not rerun the suite or establish Uniswap approval or production traffic.

## Build and test

```sh
git submodule update --init --recursive
forge fmt --check
forge build --sizes
forge test --no-match-path "test/fork/*" --summary
```

Fork tests need an archive RPC endpoint in the local environment. Do not commit it.

```sh
export ETH_RPC_URL=<archive RPC URL>
TEST_FORK_BLOCK=25934149 forge test --summary
```

## Deployment

[Mainnet Release](docs/RELEASE_MAINNET.md) records the deployed configuration and transactions, and shows how to check the live contract against this repository. The scripts for salt mining, deployment, that check, pool initialization, Shell liquidity and the canary swap are in [`script/`](script/).

## Review order

1. [`src/FewV2ShellHookBase.sol`](src/FewV2ShellHookBase.sol)
2. [`src/FewV2ShellHook.sol`](src/FewV2ShellHook.sol)
3. [`src/lib/FewV2Price.sol`](src/lib/FewV2Price.sol)
4. [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md)
5. [`KNOWN_ISSUES.md`](KNOWN_ISSUES.md)
6. [`AUDIT_SCOPE.md`](AUDIT_SCOPE.md)

## Provenance

This code was developed in Ring's internal repository as `RingAggregatorHook` and `GovernedRingAggregatorHook`, and is published here as `FewV2ShellHookBase` and `FewV2ShellHook`, so the deployed contract's name matches `FewV4ShellHook`.

## Security

See [SECURITY.md](SECURITY.md) for the disclosure channel and trust boundary.

## License

GPL-2.0-or-later.
