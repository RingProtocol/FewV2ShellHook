# Subsidy: a shared protocol-fee refund

**Branch `feat/subsidy`. Not deployed. The deployed Hook addresses are unchanged.**

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
   Budgets are per currency, so a route that settles in USDC needs a USDC budget.
7. Check a quote against the same pool with the protocol fee switched off. The two must match.

Steps 1 to 3 are the only ones that change the Hook address. A vault that is deployed but never
armed behaves exactly like the previous release.

The budget is denominated per currency, and the fee currency follows the swap: exact input is
charged in the output currency, exact output in the input currency. A Shell pool quoted in both
directions therefore needs a budget in both of its currencies.

## Validation

| Check | Result |
|---|---|
| Full Foundry suite against a mainnet fork | 232 tests: 230 passed, 2 failed |
| Subsidy suite (`test/fork/SubsidyFork.t.sol`) | 34 passed, 0 failed, 11 of them subsidy-specific |
| Fee arithmetic fuzz | 10,000 cases against an independent full-precision ceiling reference |
| `FewV2ShellHook` runtime | 24,475 bytes; 101 bytes below the EIP-170 limit |
| `SubsidyVault` runtime | 3,044 bytes |
| `forge fmt --check` on every tracked source, script and test file | Clean |

The two failures are in `test/fork/DeployedHookSmokeFork.t.sol`, an untracked local file that
exercises the previously deployed mainnet Hook address against live prices. They predate this
branch and are price drift on the old deployment, not a regression: the address under test was
deployed before the subsidy existed and the file is not part of the branch.

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
