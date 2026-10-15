# Historical Mainnet Release: October 12, 2026

This records the **original pre-protocol-fee deployment**, with its original snapshots and outstanding actions preserved below. Its source is pinned to public commit `730c6fdade1fb2bd0a1b9e0e38a1c353de3ad8a8`. Use the pinned revision to reproduce this historical release. The fee-aware ETH/WBTC replacement is now deployed at a different address; see the [current mainnet release](RELEASE_MAINNET.md).

`FewV2ShellHook` is live on Ethereum mainnet at [`0x59255CbC688e402eF980B84668bA1d1c708b6088`](https://etherscan.io/address/0x59255cbc688e402ef980b84668ba1d1c708b6088#code), in native ETH mode, with verified source. It was deployed on October 12, 2026, together with one Shell Pool, ETH/USDC, which holds a small Shell position and passed a canary swap at the quoted amount.

Not done yet:

- The other seven recommended Shell Pools are not initialized. They wait for Uniswap's routing review.
- The owner, guardian, `poolInitializer` and `residualRecipient` are still the operations account that deployed the Hook. Ownership moves to a Safe next; role changes will be recorded below.

## Release record

Configuration was read back from the contract at block 26,177,142.

| Field | Value |
|---|---|
| Source | `src/` at public commit `730c6fdade1fb2bd0a1b9e0e38a1c353de3ad8a8`; see [Verify the deployment](#verify-the-deployment) |
| Toolchain | forge 1.5.1-stable, solc 0.8.26, via-IR, 200 runs, cancun |
| Tests | All passed at blocks 25,934,149 and 26,176,789 |
| Mode | Native ETH (`useNativeCurrencyForWeth = true`) |
| PoolManager | `0x000000000004444c5dc75cB358380D2e3dE08A90` |
| FewFactory | `0x7D86394139bf1122E82FDF45Bb4e3b038A4464DD` |
| FewV2Factory | `0xeb2A625B704d73e82946D8d026E1F588Eed06416` |
| WETH | `0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2` |
| V4Quoter | `0x52F0E24D1c21C8A0cB1e5a5dD6198556BD9E1203` |
| Owner, guardian, `poolInitializer`, `residualRecipient` | All `0x61E75d5c5deE4205a5bBCD9fBc40498b693197ad`, the operations account. No pending owner |
| Role changes | None |
| `addTimelockDelay` | 172,800 s (48 hours) |
| Genesis allowlist | WETH `0xC02a…6Cc2`, USDC `0xA0b8…eB48`, USDT `0xdAC1…1ec7`, DAI `0x6B17…1d0F`, WBTC `0x2260…C599`, USDR `0x4EA4…a913` |
| Salt | `0x0000000000000000000000000000000000000000000000000000000000007072`, permission bits `0x2088` |
| Deployment | [`0x3492eb23…ba914a`](https://etherscan.io/tx/0x3492eb2383b6706c775835db8e47720e0973cc907cf1df663b9a6fd87aba914a), block 26,177,040, through the CREATE2 deployer `0x4e59b44847b379578588920cA78FbF26c0B4956C` |
| Runtime | 23,219 bytes, codehash `0x1e96d6f2e2ff6e91fec4c8d1a0e3750e9736f5618743621ec9eb5ebc69bcbdd7` |
| Constructor args | 608 bytes, listed in the [appendix](#appendix-constructor-arguments) |
| CheckDeployment | PASS with the CREATE2 recomputation, right after deployment and again after the canary |
| Etherscan | [Verified source](https://etherscan.io/address/0x59255cbc688e402ef980b84668ba1d1c708b6088#code), on the second, identical submission |

## Transactions

All five transactions came from the operations account. Together they used 6,369,686 gas, about 0.00232 ETH.

| Step | Transaction | Block | Gas |
|---|---|---|---|
| Deploy the Hook | [`0x3492eb23…ba914a`](https://etherscan.io/tx/0x3492eb2383b6706c775835db8e47720e0973cc907cf1df663b9a6fd87aba914a) | 26,177,040 | 5,384,019 |
| Initialize ETH/USDC, sent privately through MEV Blocker | [`0x0a25929e…8cef11`](https://etherscan.io/tx/0x0a25929eb9995f39739ee56e60422c1b928de5d4d9f017f057976f9d198cef11) | 26,177,071 | 247,528 |
| Permit2 approval of USDC to PositionManager | [`0x233328c1…1c46a2`](https://etherscan.io/tx/0x233328c1cfdcf089910bc31ae8d3f4dce59400e955b86552bbdb97ab471c46a2) | 26,177,081 | 47,590 |
| Mint the Shell position | [`0xef2a8db2…8d3180`](https://etherscan.io/tx/0xef2a8db2dd01689f5a60bbacbbaaa755bfef984235c402e83e975cfef48d3180) | 26,177,083 | 381,503 |
| Canary swap | [`0xcdd39cd7…084ecd`](https://etherscan.io/tx/0xcdd39cd789bceae5a4989690816e864b7e657c93f0bcaa21719700c7e7084ecd) | 26,177,094 | 309,046 |

## ETH/USDC Shell Pool

| Field | Value |
|---|---|
| PoolKey | native ETH / USDC, fee 3000, tick spacing 1, Hook above |
| PoolId | `0xbb417423a73e9d59747fe72f402f185765b09f177b2839728cb8845896890749` |
| FewV2 pair | `0x54222F404dcfAc705322045F01D100380b871450` (fwETH `0xa250CC729Bb3323e7933022a67B52200fE354767` / fwUSDC `0x0492560FA7Cfd6A85E50D8bE3F77318994F8f429`) |
| Initial price | `sqrtPriceX96` 3979124211960882247824424, tick −197,991, the FewV2 price when the transaction was built |
| Advertised depth after the canary | 3,483.94 ETH and 542,884.34 USDC, limited by the FewToken wrappers' backing |
| PoolManager balances | 52,521.27 ETH and 46,661,899.28 USDC |

The Shell position is tokenId 455796, owned by the operations account. It covers the full range with liquidity 502,236,084,453, funded with 0.009999999999990262 ETH and 25.224109 USDC.

The canary sold 0.0001 ETH for 251,451 raw USDC (0.251451 USDC), the amount V4Quoter quoted, and was executed against the FewV2 pair above.

## Verify the deployment

The source files verified on Etherscan are byte-identical to `src/` at the pinned original-release revision above. Check out that revision before using the commands below; the fee-aware candidate produces different init code and a different address. `CheckDeployment` sends no transaction: it builds the init code from this repository, recomputes the CREATE2 address from the salt and the constructor values, and checks every immutable, role and allowlist entry against the live contract.

```sh
git submodule update --init --recursive
export ETH_RPC_URL=<Ethereum mainnet RPC URL>
export POOL_INITIALIZER_ADDRESS=0x61E75d5c5deE4205a5bBCD9fBc40498b693197ad
export RESIDUAL_RECIPIENT_ADDRESS=0x61E75d5c5deE4205a5bBCD9fBc40498b693197ad
export HOOK_OWNER_ADDRESS=0x61E75d5c5deE4205a5bBCD9fBc40498b693197ad
export GUARDIAN_ADDRESS=0x61E75d5c5deE4205a5bBCD9fBc40498b693197ad
export HOOK_ADDRESS=0x59255CbC688e402eF980B84668bA1d1c708b6088
export HOOK_SALT=0x0000000000000000000000000000000000000000000000000000000000007072
export EXPECT_NATIVE_ETH=true
forge script script/CheckDeployment.s.sol:CheckDeployment --rpc-url "$ETH_RPC_URL"
```

A match ends with `PASS` and `CREATE2 verified: true`. The four role variables are constructor inputs, so keep them as above after a role changes and set `EXPECT_OWNER`, `EXPECT_GUARDIAN`, `EXPECT_POOL_INITIALIZER` or `EXPECT_RESIDUAL_RECIPIENT` to the current holder instead.

## Appendix: constructor arguments

ABI-encoded in constructor order: the five dependencies, the native ETH flag, `poolInitializer`, `residualRecipient`, owner, guardian, `addTimelockDelay`, then the genesis allowlist array.

```text
000000000000000000000000000000000004444c5dc75cb358380d2e3de08a90
0000000000000000000000007d86394139bf1122e82fdf45bb4e3b038a4464dd
000000000000000000000000eb2a625b704d73e82946d8d026e1f588eed06416
000000000000000000000000c02aaa39b223fe8d0a0e5c4f27ead9083c756cc2
00000000000000000000000052f0e24d1c21c8a0cb1e5a5dd6198556bd9e1203
0000000000000000000000000000000000000000000000000000000000000001
00000000000000000000000061e75d5c5dee4205a5bbcd9fbc40498b693197ad
00000000000000000000000061e75d5c5dee4205a5bbcd9fbc40498b693197ad
00000000000000000000000061e75d5c5dee4205a5bbcd9fbc40498b693197ad
00000000000000000000000061e75d5c5dee4205a5bbcd9fbc40498b693197ad
000000000000000000000000000000000000000000000000000000000002a300
0000000000000000000000000000000000000000000000000000000000000180
0000000000000000000000000000000000000000000000000000000000000006
000000000000000000000000c02aaa39b223fe8d0a0e5c4f27ead9083c756cc2
000000000000000000000000a0b86991c6218b36c1d19d4a2e9eb0ce3606eb48
000000000000000000000000dac17f958d2ee523a2206206994597c13d831ec7
0000000000000000000000006b175474e89094c44da98b954eedeac495271d0f
0000000000000000000000002260fac5e5542a773aa44fbcfedf7c193bc2c599
0000000000000000000000004ea40dcee961675683e0a2e1721bd49cb9bca913
```
