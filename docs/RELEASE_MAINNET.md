# Mainnet Release: ETH/WBTC Protocol-Fee Replacement

October 16, 2026. FewV2ShellHook is deployed and source-verified on Ethereum mainnet at [`0xbeBc5239e446BC78B46654Ad943b0Fc19A31E088`](https://etherscan.io/address/0xbeBc5239e446BC78B46654Ad943b0Fc19A31E088#code). Native ETH/WBTC initialization, canonical Pair registration, the official protocol-fee update, two Universal Router canaries and a complete Shell LP withdrawal/re-mint have passed. The replacement is **not yet submitted or approved for Uniswap routing**; default App / Quote API route selection is unverified.

The [October 12 ETH/USDC deployment](RELEASE_MAINNET_2026-10-12.md) remains a separate, unchanged contract. Its PoolId and LP position are not migrated into this release.

## Release facts

| Field | Verified value |
| --- | --- |
| Chain | Ethereum mainnet, chain ID 1 |
| Hook | `0xbeBc5239e446BC78B46654Ad943b0Fc19A31E088` |
| Deployed source | [`928580478ab4eed4f2d25ee0b2aff92ffbc5a97a`](https://github.com/RingProtocol/FewV2ShellHook/tree/928580478ab4eed4f2d25ee0b2aff92ffbc5a97a), merged in [PR #1](https://github.com/RingProtocol/FewV2ShellHook/pull/1) |
| Runtime codehash | `0x5b46ba3a6e4c8fcd62d275ea7bb0fbfef08c6975c74df59596ff6350557b8d28` |
| Runtime size | 24,435 bytes; 141 bytes below EIP-170 |
| Compiler | Solidity 0.8.26, via-IR, optimizer 200 runs, Cancun |
| Deployment | [CREATE2 transaction](https://etherscan.io/tx/0x9e77106cc26cf7e1d72b5d25e54fca7e0ebd6115675ba5cfd0f7c50ecb0a5be5), block 26,198,967 |
| CREATE2 salt | `0x0000000000000000000000000000000000000000000000000000000000000fce` |
| Hook permissions | `0x2088`: beforeInitialize, beforeSwap, beforeSwapReturnsDelta |
| Source verification | Etherscan verified source read back through its API; live runtime and production-source hashes match the release evidence |
| Original mainnet acceptance | Block 26,199,057 |
| Read-only reconciliation | Block 26,199,283; runtime, PoolId, Pair, roles, LP, official policy and all 16 recorded receipts matched |
| Independent external audit | None for this release; earlier reviews of materially different code do not cover it |

Documentation-only commits after the deployed source revision do not change the contract. The [machine-readable evidence](protocol-fee-evidence/mainnet-2026-10-16.json) contains production-source SHA-256 hashes, transactions, fee receipts and the exact live-read snapshot.

## Pool and permissions

| Field | Value |
| --- | --- |
| PoolKey | Native ETH / WBTC, fee 3000, tickSpacing 1, new Hook above |
| PoolId | `0x504a3b31c9cca7d5f66ae7ef3e94a845473b61b67b7061e1c48541f65280a08d` |
| Execution Pair | `0x00B06862dE00a7e67a2d6d3FbEEa592A32460de0` |
| Canonical fwETH | `0xa250CC729Bb3323e7933022a67B52200fE354767` |
| Canonical fwWBTC | `0x2078f336Fdd260f708BEc4a20c82b063274E1b23` |
| PoolManager | `0x000000000004444c5dc75cB358380D2e3dE08A90` |
| PositionManager | `0xbD216513d74C8cf14cf4747E6AaA6420FF64ee9e` |
| Owner / guardian / initializer / residual recipient | All `0x61E75d5c5deE4205a5bBCD9fBc40498b693197ad`, the existing operations account |
| Swap state | Unpaused at the reconciliation block |
| New-underlying add delay | 172,800 seconds (48 hours) |

Initialization registered the canonical direct Pair automatically. There is no owner route setter. The existing operations account still holds the roles; this record does not claim a Safe migration. Pausing swaps does not prevent standard LP withdrawals.

The shell supplies the v4 entry point and PoolManager working inventory. Execution price, depth and the 30 bps venue fee come from FewV2. The shell curve is bypassed and its LP position does not earn the FewV2 LP fee.

## Official protocol fees

The Hook classifies as Aggregator (`1 << 11`) and uses multiplier 25, following Uniswap's public reference. It reads the directional PoolManager rate and pays the current controller's TokenJar; Ring roles cannot set either the protocol rate or recipient. There is no additional Ring Hook fee.

| Field | Reconciliation snapshot |
| --- | --- |
| Official controller | `0x89A5D5bF00a27D55c02951E49078a5C5771051dB` |
| Official TokenJar | `0xf38521f130fcCF29dB1961597bc5d2B60F995f85` |
| Packed PoolManager fee / official policy | Both 163880 |
| Effective directional rate | 1,000 pips (10 bps) each direction |
| Rounding | Up to whole token base units; tiny trades need not realize exactly 10 bps |

The [permissionless official fee update](https://etherscan.io/tx/0x3e0df04066b12c318aeece8c464546b2ca7a5652c80d9cde94455009cf9e063f) was executed after initialization. Fee rates are policy snapshots, not fixed future charges. A nonzero fee with an unusable recipient reverts. These implementation checks do not establish Uniswap Labs acceptance of this fee treatment.

## Mainnet canaries and LP exit

Both swaps used the official Universal Router. Their actual outputs equalled their recorded quotes for those executions.

| Direction | Input | Quote and actual output | Official TokenJar receipt | Transaction |
| --- | --- | --- | --- | --- |
| ETH → WBTC | 0.0001 ETH | 294 WBTC base units (0.00000294 WBTC) | 1 WBTC base unit | [ETH to WBTC](https://etherscan.io/tx/0x5ba91870aa57fd65bf54f677798e3e8e9c143833a59fe278a0d0b5ab45729830) |
| WBTC → ETH | 500 WBTC base units (0.000005 WBTC) | 168196165941456 wei ETH | 168364530472 wei ETH | [WBTC to ETH](https://etherscan.io/tx/0x743c2dfcb0acbb52f2fcfc9afe0732453d292c33a72852fb3c0f414f7cf08ce4) |

Token transfers and Hook fee events confirm the WBTC fee; the native ETH payments to TokenJar and the trader were also checked in the transaction call trace. Quote equality applies to these executions and does not promise unchanged cross-block prices.

Position #462830 was [fully withdrawn and burned](https://etherscan.io/tx/0x53d08ea80b3607a8f7c6ed4658ef4f4bf7b99bf5e33508095207074a356ae6e0). It returned the deposit less 1 wei ETH and 1 WBTC base unit due to rounding. The [replacement position #462837](https://etherscan.io/tx/0xf93d225d4624f054cf361cb80465d56cc357a7aae59be28af38150ed7cb15b20) remains owned by the operations account, with liquidity 4,301,771,009. It was funded with 0.002499999999788130 ETH and 0.00007403 WBTC. Its nonzero liquidity and owner were read back at the reconciliation block.

All 16 release transactions, including approvals and cleanup, have successful receipts. Total gas cost was 0.003841662987349744 ETH. This is execution cost, not a forecast or additional LP capital. Full transaction hashes and raw units are in the evidence JSON.

## Validation and remaining checks

- Before deployment, two local fixed-block runs at global fork blocks 26,197,122 and 25,934,149 each passed 191 tests, with 0 failures and 0 skips. Fee arithmetic used 10,000 fuzz cases per run. Historical-deployment fixtures independently pin block 26,197,122. See [Release Readiness](RELEASE_READINESS.md).
- The tested tree at `ac873d3849916706eaf0c7eb26472936ac7e5a21` matches the merged deployment source. GitHub CI on that head executed 20 hermetic cases and skipped 171 RPC-dependent cases. It is not evidence that GitHub ran the full fork suite.
- This documentation refresh re-read existing chain state and receipts; it did not broadcast a new transaction or rerun the full test suite.
- The new-address allowlist application is prepared, not submitted. The previous rejection's precise reason is unknown. Labs confirmation of fee compatibility, allowlisting, exact PoolKey discovery and unforced production quote selection remain separate checks.

## Reproduce the deployment check

Use the pinned deployed source, its submodules and the constructor configuration below. Set an RPC only in the local environment. This command is read-only; do not add a broadcast flag.

```sh
git checkout 928580478ab4eed4f2d25ee0b2aff92ffbc5a97a
git submodule update --init --recursive
export HOOK_ADDRESS=0xbeBc5239e446BC78B46654Ad943b0Fc19A31E088
export HOOK_SALT=0x0000000000000000000000000000000000000000000000000000000000000fce
export POOL_INITIALIZER_ADDRESS=0x61E75d5c5deE4205a5bBCD9fBc40498b693197ad
export RESIDUAL_RECIPIENT_ADDRESS=0x61E75d5c5deE4205a5bBCD9fBc40498b693197ad
export HOOK_OWNER_ADDRESS=0x61E75d5c5deE4205a5bBCD9fBc40498b693197ad
export GUARDIAN_ADDRESS=0x61E75d5c5deE4205a5bBCD9fBc40498b693197ad
export EXPECT_NATIVE_ETH=true
forge script script/CheckDeployment.s.sol:CheckDeployment --rpc-url "$ETH_RPC_URL"
```
