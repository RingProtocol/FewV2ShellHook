# Subsidy: a shared protocol-fee refund

**Branch `feat/subsidy`. Not deployed. The Hooks live on mainnet today still carry the
time-locked allowlist; this branch replaces it with one that is fixed at deployment.**

A Shell swap costs 30 bps of FewV2 LP fee plus the Uniswap protocol fee that the Hook collects
for its pool. A plain v4 pool at the same 3000 fee tier costs 30 bps, and carries no protocol fee
unless the fee controller set one on it, so the Shell route is the more expensive of the two by
exactly the protocol fee. The subsidy refunds that fee out of a Ring budget, which puts the Shell
quote back on par with a plain v4 pool.

The Uniswap protocol fee is **not** waived, reduced or redirected. It is still read from the fee
controller, still applied with the Aggregator classification and rounding, and still paid in full
to the current `TokenJar`. Ring pays the same amount back to the trader from its own budget, and
the Shell LP does not carry any of that cost.

## Change and effect

| Item | Before | After | Effect |
|---|---|---|---|
| Uniswap protocol fee | Collected in full to the current `TokenJar` | Collected in full to the current `TokenJar`, then refunded from the shared budget | Uniswap's fee mechanism is unchanged and fully observable |
| Trader's effective cost | 30 bps FewV2 LP fee + the protocol fee | 30 bps FewV2 LP fee | On par with a plain v4 pool at the same tier |
| Subsidy rate | None | At most the protocol fee actually charged | Structurally capped; the Hook cannot become a net extractor |
| Cost bearer | — | Ring treasury | PoolManager inventory is restored and the Shell LP bears nothing |
| Hook token balance | Zero after every swap | Zero after every swap | The zero-residue assertions are unchanged |
| Empty or paused budget | — | Subsidy is zero, the route still executes | Fail-open; a budget problem never takes the route down |
| Fee recipient | `TokenJar` only | `TokenJar` only | No Ring-controlled recipient is introduced |
| Owner powers over user funds | None | None | The Hook owner still cannot move balances; the vault owner moves only the Ring budget |

## Mechanism

The Hook already computes the protocol fee and already pays it. The subsidy adds one call after
that payment:

```text
router opens a v4 swap
  -> Hook takes origin input from PoolManager
  -> Hook wraps the input 1:1 to the canonical FewV2 pair and executes the trade
  -> Hook unwraps the output and settles it with PoolManager
  -> Hook pays the Uniswap protocol fee to the current TokenJar
  -> Hook asks the SubsidyVault to refund that fee
       -> vault transfers its own balance straight into the PoolManager
       -> vault calls settleFor(hook), so the credit lands on the Hook's delta
  -> Hook declares the larger payout to the router
  -> router closes the user's balance delta
```

The vault is a separate contract, not a Hook storage slot or a Hook balance:

- The Hook must never hold a balance. `sweep` is permissionless and would drain a reserve, and the
  Hook asserts it leaves no token residue after every swap.
- The Hook's owner cannot move balances. A funding balance inside the Hook would have to change
  that trust boundary. The vault owner moves only Ring's own budget, which never belonged to the
  Hook or to a Shell LP.
- One budget serves every pair. Subsidy is a product-level budget, not a per-pool one.

The vault address is part of the Hook's init code, so it must exist before the Hook is mined. The
vault therefore takes no Hook address in its constructor; the owner arms it once with `setHook`,
which locks afterwards.

## Accounting

The refund never exceeds the fee, so `amountOut` stays within the gross Pair output and
`amountIn` stays above the required Pair input. The `int128` delta bounds are therefore unchanged.

Exact input, output currency:

| Step | PoolManager output inventory | Router claim |
|---|---|---|
| Hook settles the gross output | `+gross` | — |
| Hook pays the protocol fee `f` to the TokenJar | `-f` | — |
| Vault injects `s ≤ f`, booked to the Hook | `+s` | `+s` |
| Router takes its output | `-gross + f - s` | `-gross + f - s` |
| Net | `0` | `gross - f + s` |

Exact output, input currency:

| Step | PoolManager input inventory | Router claim |
|---|---|---|
| Hook consumes the required Pair input | `-required` | — |
| Hook pays the protocol fee `f` to the TokenJar | `-f` | — |
| Vault injects `s ≤ f`, booked to the Hook | `+s` | `+s` |
| Router settles its input | `-required - f + s` | `-required - f + s` |
| Net | `0` | `required + f - s` |

With a fully funded budget, `s = f`, so the trader receives exactly `gross` on exact input and
pays exactly `required` on exact output: the same numbers as the same swap on a pool with the
protocol fee switched off. That equality, not "the trader receives some refund", is the invariant
the fork tests pin.

The Shell LP is not involved. PoolManager inventory is unchanged by the round trip because the
vault's contribution is exactly what the router takes out again. The subsidy is a Ring treasury
expense.

## Budget currencies

The budget is denominated per currency, and one currency holds one balance that every pool of the
Hook shares. Which currencies need a balance follows from two facts: the subsidy is paid in the
currency the Uniswap protocol fee was charged in, and the protocol fee is always charged in one of
the pool's two endpoints. A pool quoted in both directions therefore needs a balance in both of its
endpoints, and the union over all pools is the set of balances to hold.

The eight recommended Shell Pools cover six currencies:

| Pool | Endpoints | Budget currencies |
|---|---|---|
| ETH-or-WETH/USDC | ETH-or-WETH, USDC | ETH-or-WETH, USDC |
| ETH-or-WETH/USDT | ETH-or-WETH, USDT | ETH-or-WETH, USDT |
| ETH-or-WETH/DAI | ETH-or-WETH, DAI | ETH-or-WETH, DAI |
| ETH-or-WETH/WBTC | ETH-or-WETH, WBTC | ETH-or-WETH, WBTC |
| WBTC/USDC | WBTC, USDC | WBTC, USDC |
| WBTC/USDT | WBTC, USDT | WBTC, USDT |
| WBTC/DAI | WBTC, DAI | WBTC, DAI |
| ETH-or-WETH/USDR | ETH-or-WETH, USDR | ETH-or-WETH, USDR |

One Hook deployment therefore holds six balances: ETH-or-WETH, USDC, USDT, DAI, WBTC and USDR. The
two currencies of a pool are the same two shared balances, not two copies of each: the ETH/USDC pool
and the WBTC/USDC pool draw on the same USDC balance, so a busy pool can starve the other one.

The native ETH balance is keyed by `address(0)`. A native-ETH deployment and a WETH deployment are two
Hook deployments with two vaults and therefore two independent sets of balances: funding the native
one does not fund the WETH one.

A currency only needs a balance while some pool actually charges a protocol fee in it. Uniswap's fee
controller sets that rate per pool and per direction, and a pool with no protocol fee makes the
subsidy structurally zero. The report below shows the rate of every recommended pool, so a balance
held for a pool that charges nothing is visible before it wastes money.

## Checking the budget

`script/ReportSubsidyBudget.s.sol:ReportSubsidyBudget` is a read-only script that prints the whole
budget picture in one run: the vault's arming and pause state, the balance of every currency, and
for every recommended pool its protocol fee rate per direction, the currencies it charges and the
balance that backs each of them.

```sh
HOOK_ADDRESS=0x... SUBSIDY_VAULT_ADDRESS=0x... \
  forge script script/ReportSubsidyBudget.s.sol:ReportSubsidyBudget --rpc-url $ETH_RPC_URL
```

It sends no transaction and needs no owner key. Two warnings matter:

- a pool whose protocol fee is zero in both directions never draws on any balance, so money held for
  it is wasted;
- a currency with a zero balance is not subsidized at all: the vault fails open, the trader pays the
  protocol fee, and the route keeps working.

A pool that the Hook has not registered is reported as `registered: false` and skipped. The lookup
reverts for such a pool, so the report guards it instead of failing: a report that dies on the first
unregistered pool says nothing about the budget, which is the one thing it exists to say.

Because the underlying allowlist is fixed at deployment, the currency set is fixed with it. A new
origin token needs a new Hook deployment, so the report must be repeated for the new vault, and a
balance left behind on the old vault is Ring money that no longer subsidizes anything.

The Hooks live on mainnet today still carry the time-locked allowlist: the owner can add a token
once 48 hours have elapsed, and the guardian can remove one. That governance does not exist in
this branch. A report run against a live address therefore describes the live contract and not
this branch, and the address it reports is not the address this branch will deploy.

## Failure modes

The vault never reverts on an empty budget. It pays what it can and reports the real amount, and
the Hook uses the returned amount, so a quote and the matching execution stay consistent.

| State | Subsidy | Route |
|---|---|---|
| Vault deployed, not armed | 0 | Unchanged, the trader pays the protocol fee |
| Armed, budget empty for that currency | 0 | Unchanged, the trader pays the protocol fee |
| Armed, budget partially funded | The available share only | Unchanged, the trader pays the remainder |
| Armed, vault paused | 0 | Unchanged, the trader pays the protocol fee |
| Budget over-drawn by `drain` | — | Reverts with `InsufficientBudget` |

Only a caller other than the bound Hook is rejected (`NotHook`); the Hook itself is never blocked
by the vault.

## Authority

| Authority | Can do | Cannot do |
|---|---|---|
| Vault owner (Ownable2Step; final = multisig) | Fund the budget per currency, drain it, pause and resume subsidies, arm the vault once | Rename the bound Hook, unbind the Hook, renounce ownership, move Shell LP funds or PoolManager assets |
| Vault owner, before arming | Arm the vault with the Hook address | Arm a second time (`HookAlreadySet`) |
| Hook owner | Nothing on the budget | Fund, drain, pause or re-point the vault |
| Hook guardian | Nothing on the budget | Pause the subsidy |
| Any account | Call `settleSubsidy` on an armed vault and be rejected (`NotHook`) | Draw on the budget |

An unarmed vault returns zero for every caller instead of rejecting it, so a vault that was never
bound cannot be used to probe the Hook or to consume a budget.

The Hook and the vault have separate owners. The Hook's owner cannot touch the budget, and the
vault's owner cannot touch the Hook. The binding is permanent, so a later owner rotation cannot
redirect the budget to a different Hook.

## Deployment order

The vault must exist before the Hook is mined, because the vault address is part of the Hook's
init code. The order is:

1. Deploy the vault with `script/DeploySubsidyVault.s.sol:DeploySubsidyVault`. It deploys
   unarmed. Set `SUBSIDY_VAULT_OWNER_ADDRESS` to the multisig that will own the budget.
2. Put the printed address in `SUBSIDY_VAULT_ADDRESS`.
3. Re-run `script/MineHookAddress.s.sol`. The mined address changes with the vault address.
4. Deploy the Hook with `script/DeployMainnetNativeEth.s.sol` or `script/DeployMainnetWeth.s.sol`,
   and verify it as usual.
5. Arm the vault with `script/ArmSubsidyVault.s.sol:ArmSubsidyVault`, from the vault owner. The
   broadcaster must be the owner, because `setHook` is `onlyOwner`.
6. Fund the budget per currency: `fund(currency, amount)` for ERC20 and `fundNative()` for ETH.
   Budgets are per currency, so a route that settles in USDC needs a USDC budget. `fund` pulls the
   tokens with `safeTransferFrom`, so the owner must approve the vault for the amount first; without
   the allowance the call reverts with `ERC20: transfer amount exceeds allowance`. `fundNative` takes
   the value with the call and needs no allowance.
7. Check a quote against the same pool with the protocol fee switched off. The two must match.
8. Run `script/ReportSubsidyBudget.s.sol:ReportSubsidyBudget` and confirm that every currency that
   the recommended pools charge has a non-zero balance.

Steps 1 to 3 are the only ones that change the Hook address. A vault that is deployed but never
armed behaves exactly like the previous release.

The budget is denominated per currency, and the fee currency follows the swap: exact input is
charged in the output currency, exact output in the input currency. A Shell pool quoted in both
directions therefore needs a budget in both of its currencies.

## Validation

| Check | Result |
|---|---|
| Full fork suite on an anvil mainnet fork | **283 tests, 281 passed, 2 failed, 14 suites.** The 2 failures are in the untracked `test/fork/DeployedHookSmokeFork.t.sol` (price drift on the old deployment). See `docs/ANVIL_VALIDATION.md`. |
| Subsidy suite (`test/fork/SubsidyFork.t.sol`) | **51 passed, 0 failed.** The 28 functions in the file plus the 23 inherited from the protocol-fee suite. |
| Multi-pool subsidy suite (`test/fork/SubsidyMultiPoolFork.t.sol`) | **55 passed, 0 failed.** 4 in the file, the rest inherited. |
| Governance suite (`test/fork/FewV2ShellHookFork.t.sol`) | **16 passed, 0 failed** |
| Deployment rehearsal on an anvil fork | Vault, mined Hook address, CREATE2 deployment, `CheckDeployment`, pool initialization, arming, funding and the budget report all completed. See `docs/ANVIL_VALIDATION.md`. |
| Live subsidy on the deployed Hook | A Universal Router swap with the 0.1% protocol fee on returned the fee-free amount to the trader and drew exactly the fee from the vault. See `docs/ANVIL_VALIDATION.md`. |
| Fee arithmetic fuzz | 10,000 cases against an independent full-precision ceiling reference |
| `FewV2ShellHook` runtime | 23,724 bytes; 852 bytes below the EIP-170 limit |
| `SubsidyVault` runtime | 3,044 bytes |
| Hermetic suite (`forge test --no-match-path "test/fork/*"`) | 20 passed, 0 failed |
| `forge fmt --check` on every tracked source, script and test file | Clean |

The two failures are in `test/fork/DeployedHookSmokeFork.t.sol`, an untracked local file that
exercises the previously deployed mainnet Hook address against live prices. They predate this
branch and are price drift on the old deployment, not a regression: the address under test was
deployed before the subsidy existed and the file is not part of the branch.

This branch changes the Hook bytecode. The underlying allowlist lost its time-locked mutation
paths, so the deployment target is smaller and its constructor takes one argument less, which
changes the mined address. Every fork suite has been re-run against the new code, on an anvil
mainnet fork, and the counts above are the results of that run.

The subsidy tests run against the real PoolManager, the real controller and the real TokenJar on a
mainnet fork. They arm the vault with real funds, then check the trader's balance, the TokenJar's
receipt, the vault's budget and the PoolManager's inventory after the swap. The inherited
protocol-fee suite runs unarmed, which is the state in which "the fee is charged exactly once"
still holds.

Reproduce with an approved RPC available as `ETH_RPC_URL`:

```sh
forge test
forge fmt --check
forge build --skip test --skip script --sizes
git diff --check
```

## Decision record

| Date | Evidence | Decision | Revisit when |
|---|---|---|---|
| 2026-10-23 | A Shell swap costs 30 bps of FewV2 LP fee plus the Uniswap protocol fee, while a plain v4 pool at the same 3000 tier costs 30 bps. The Shell quote is uncompetitive by exactly the protocol fee. | Refund the protocol fee from a Ring budget so the Shell quote matches a plain v4 pool. Keep collecting the fee in full to the TokenJar. | The protocol fee rate, the FewV2 LP fee, or Uniswap's fee policy changes. |
| 2026-10-23 | The Hook must never hold a balance: `sweep` is permissionless and the zero-residue assertions forbid it. The Hook owner cannot move balances. | Hold the budget in a separate vault with its own owner. The Hook only ever calls `settleSubsidy`. | The Hook's balance model or ownership boundary changes. |
| 2026-10-23 | The vault address is part of the Hook init code and the Hook address is not known until after mining. | Deploy the vault first without a Hook address and arm it once with `setHook` afterwards. The binding is permanent. | The Hook address becomes computable before deployment. |
| 2026-10-23 | An empty budget would otherwise block the route, which is a self-inflicted outage for a funding problem. | Fail open: pay what the budget can cover and report the real amount. Quotes and execution stay consistent because both use the reported amount. | Ring prefers a hard failure over a degraded subsidy. |
| 2026-10-23 | The refund is capped by construction: the Hook hands the vault exactly the protocol fee it just charged. | Keep that cap. The subsidy can offset the protocol fee but never exceed it, so the Hook cannot become a net extractor of the protocol fee. | The subsidy is ever allowed to exceed the protocol fee. |

## Appendix: the Uniswap policy reading

This does not change how the protocol fee is charged, and it is not a fee waiver:

- the fee rate still comes from Uniswap's fee controller, and the Hook owner cannot change it;
- the fee is still classified as family 11 and scaled by the Aggregator multiplier of 25;
- the fee is still rounded up with the production helper and paid in the origin token;
- the TokenJar still receives the full fee on every swap, and that receipt is unchanged;
- the refund is paid by Ring, from Ring's budget, in the same origin token.

The structural consequence is that the effective subsidy rate can never exceed the protocol fee
rate, because the Hook hands the vault exactly the fee amount and the vault can pay no more than
it holds. The Shell route therefore cannot be cheaper than the same swap on a pool with the
protocol fee switched off.

That is a commercial statement about Ring's treasury, not a change to Uniswap's fee mechanics. It
is also not an approval: see the [protocol fee release](PROTOCOL_FEE_UPGRADE.md) for the fee
handling itself and the outstanding routing submission.
