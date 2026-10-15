# ETH/WBTC release readiness

Updated October 16, 2026. The fee-aware replacement is deployed and source-verified at [`0xbeBc5239e446BC78B46654Ad943b0Fc19A31E088`](https://etherscan.io/address/0xbeBc5239e446BC78B46654Ad943b0Fc19A31E088#code). ETH/WBTC initialization, official fee activation, both mainnet canaries and LP exit/re-mint are complete; the new routing submission is still pending. See the [mainnet release](RELEASE_MAINNET.md). The readiness tests and rehearsal below were completed before deployment and do not change any file under `src/` from candidate `79888296cd692ce199066df6ef81554f258bc8e4`.

## Required sequence

1. Freeze the reviewed source, dependencies, compiler and final constructor roles. Mine the CREATE2 address from that exact configuration. The existing operations-account role set is a rehearsal proposal, not approval of final mainnet roles.
2. Rehearse deployment without Foundry `--broadcast`, then deploy only after the mainnet execution and signing configuration are authorized. Verify source on Etherscan and run `CheckDeployment` with the exact salt and constructor configuration.
3. Initialize native ETH/WBTC only, using `InitializeEthWbtcPool`. Confirm its canonical fwETH/fwWBTC Pair and preview the live initialization price immediately before inclusion.
4. Run `UpdateEthWbtcProtocolFee` in its default preview mode. It reads the current official controller, recipient, policy rate and PoolManager rate, and prints the permissionless `triggerFeeUpdate(PoolKey)` calldata. Execute that update, then read slot0 back. Initialization alone starts at zero; the current pool fee must equal the current official policy before the fee canary.
5. Confirm bounded settlement inventory and wrapper backing. Any Shell LP funding is separate, explicitly capped capital; the rehearsal uses existing singleton cash. `SmokeSwapEthWbtc` stops on a zero policy rate or a rate not synchronized to policy. These are release-evidence requirements, not a Hook-owner override: reconcile an intentional official zero before proceeding, never assign a rate manually.
6. Execute a bounded official-router canary. Record the complete PoolKey, amounts, minimum output, active rate, recipient and actual TokenJar balance increase. Check exact quote/execution parity and a complete LP exit separately. Stop if these checks fail.
7. Submit the newly deployed, verified address under reference `65899411286`, with final source and fee-payment evidence. Include the approved FewV4ShellHook as context. Routing admission, exact PoolKey discovery, production quotes and actual traffic are separate checks.

The fee update is permissionless and uses the official controller. It does not need owner or guardian authority and does not choose either a fee or a recipient. All three operational scripts default to preview; mainnet submission additionally needs Foundry `--broadcast` and a signer.

```sh
forge script script/InitializeEthWbtcPool.s.sol:InitializeEthWbtcPool --rpc-url "$ETH_RPC_URL"
forge script script/UpdateEthWbtcProtocolFee.s.sol:UpdateEthWbtcProtocolFee --rpc-url "$ETH_RPC_URL"
forge script script/SmokeSwapEthWbtc.s.sol:SmokeSwapEthWbtc --rpc-url "$ETH_RPC_URL"
```

Use only the relevant execution toggle when simulating or executing its step: `BROADCAST_INITIALIZATION`, `BROADCAST_PROTOCOL_FEE_UPDATE`, or `BROADCAST_SMOKE`. A toggle alone does not send a transaction without Foundry `--broadcast`. No password, private key or RPC value belongs in this repository.

For a complete unsigned rehearsal, run `RehearseEthWbtcRelease` with the mined salt/address, proposed role configuration and an explicit `--sender`, still without `--broadcast`. The wrapper rejects both broadcast and resume contexts. It simulates deploy, init, fee update and the canary, verifies a positive WBTC TokenJar increment, then runs `CheckDeployment` with the CREATE2 proof. It does not mint Shell LP.

## Validation

| Check | Result |
|---|---|
| Full suite at block 26,197,122 | 191 passed, 0 failed, 0 skipped |
| Full suite at block 25,934,149 | 191 passed, 0 failed, 0 skipped |
| Fee arithmetic fuzz | 10,000 full-precision reference cases per suite |
| Formatting, full `forge build --sizes`, diff check | Passed |
| Production runtime | 24,435 bytes, 141 bytes below EIP-170 |

The suite contains the original 153 cases, 20 fee-specific cases, five historical deployment regressions, one production-Hook policy test and 12 repeated inherited executions. The historical deployment regressions deliberately pin block 26,197,122 independently of `TEST_FORK_BLOCK`, because the old address did not exist at the older global baseline.

`ProtocolPolicyForkTest` deploys the production governance Hook, obtains its family from the actual mainnet policy rules, and calls the actual adapter's permissionless fee update. No controller impersonation is used for activation. At the review snapshot it matches family 11 and resolves raw 40 each direction; multiplied by 25, this is 1,000 pips (10 bps). It verifies the canary gate rejects the initial zero rate, then runs four ETH/WBTC Router modes, confirms ETH and WBTC TokenJar receipts and fully withdraws Shell LP. Rates are a snapshot, not hardcoded release economics.

`DeployedQuoteParityForkTest` targets the old deployed runtime, not the new candidate. It reproduces and isolates the two reported smoke-test issues:

- A native-output wallet increase included 577,021,548,053,172 wei already held by `PoolSwapTest`. The actual PoolManager delta equalled the quote. Clearing the router's initial cash makes the strict wallet equality pass, without a tolerance change.
- USDT approval returns no bytes. A high-level bool-returning ERC20 call can fail decoding before quote or swap. The regression records the empty return and validates optional-return approval handling.
- On the old deployed Hook, official Universal Router execution of 2,000 USDC returns exactly 841,156,910,525,861,546 wei ETH; 2,000 USDT returns exactly 840,325,029,787,950,006 wei ETH. Both equal their same-state quotes, restore PoolManager inventory and leave no Hook origin-token residue. The USDT Shell is initialized only inside the fork.

These test failures do not establish a Hook quote/execution defect or Uniswap's reason for rejection. The protocol-fee compatibility gap is separate and remains the reason for this code change.

## Four-step rehearsal

The complete wrapper passed at block 26,198,549. It generated four unsigned simulated transactions: CREATE2 deployment, ETH/WBTC initialization, official fee update and the official Router canary. At that rehearsal snapshot, `0xbeBc5239e446BC78B46654Ad943b0Fc19A31E088` was undeployed. `CheckDeployment` confirmed its salt, constructor configuration and runtime hash after simulation. Its later deployment and mined transactions are recorded separately in the mainnet release.

The raw packed fee changed from 0 to 163880. The 0.0001 ETH canary quoted and delivered 290 raw WBTC, with minimum 288; the official TokenJar received 1 raw WBTC protocol fee. The tiny trade's fee rounds up to one WBTC base unit; it should not be described as an exact 10 bps realized charge at every amount.

Forge estimated 8,724,170 total gas including its margin, at 1.409438768 gwei, or 0.01229618341662256 ETH gas at that snapshot, plus the 0.0001 ETH swap input. This is a rehearsal estimate, not a fixed mainnet cost. Source verification, LP funding, migration and any additional acceptance trades are outside that estimate. Proposed roles still copy the existing operations account; changing final roles changes the CREATE2 address and requires a new rehearsal.

## CI and review limits

The repository's fork CI requires its own approved `ETH_RPC_URL` secret. At reviewed head `7988829`, it reported success after skipping all 162 fork cases because that secret was missing; 20 hermetic cases did execute. At final tested head `ac873d3849916706eaf0c7eb26472936ac7e5a21`, 20 hermetic cases passed and 171 fork cases were skipped. Its tree matches merged deployment source `928580478ab4eed4f2d25ee0b2aff92ffbc5a97a`. Local zero-skip fork results above must not be presented as executed GitHub fork coverage.

The existing Slither workflow uses `fail-on: none`. Its reviewed output included 12 findings and IR parse errors for `_swapExactOutput`, `_exactInputAmount` and `quote`; it is not a complete static-analysis pass. Those paths were manually checked and covered by local execution tests, but no independent external audit covers this replacement. Later CI status must be tied to its exact commit and read with these limits.

## Evidence and references

The [machine-readable readiness evidence](protocol-fee-evidence/release-readiness-2026-10-15.json) records the pre-deployment test results, production-source hashes and rehearsal scope; its `TESTED_UNDEPLOYED` status applies to that dated snapshot. Earlier three-step rehearsals omitted explicit fee activation and remain historical. Use the separate [mainnet evidence](protocol-fee-evidence/mainnet-2026-10-16.json) for the completed deployment, LP movement, mined canaries and fee payments. A new whitelist submission remains unperformed.

- [Official fee adapter and permissionless update](https://github.com/Uniswap/protocol-fees/blob/main/src/feeAdapters/V4FeeAdapter.sol)
- [Official Aggregator protocol-fee calculation](https://github.com/Uniswap/v4-hooks-public/blob/5b73674d8db8ff9ef4f4a09cfee5f12302d68248/src/aggregator-hooks/ProtocolFees.sol)
- [Official PoolSwapTest refund behavior](https://github.com/Uniswap/v4-core/blob/main/src/test/PoolSwapTest.sol)
- [SafeERC20 and optional-return tokens](https://docs.openzeppelin.com/contracts/5.x/api/token/erc20#SafeERC20)
- [Routing admission criteria](https://support.uniswap.org/hc/en-us/articles/48291859140621-Routing-for-hooked-pools)
