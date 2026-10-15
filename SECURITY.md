# Security Policy

## Current status

Current `src/` is an undeployed fee-aware candidate; see [Protocol Fee Upgrade](docs/PROTOCOL_FEE_UPGRADE.md). The earlier `FewV2ShellHook` is deployed on Ethereum mainnet at [`0x59255CbC688e402eF980B84668bA1d1c708b6088`](https://etherscan.io/address/0x59255cbc688e402ef980b84668ba1d1c708b6088#code); see [Mainnet Release](docs/RELEASE_MAINNET.md). The code has not received an independent external audit. Only the ETH/USDC Shell Pool is open, with a small Shell position.

## Reporting a vulnerability

Do not open a public GitHub issue for a suspected vulnerability. Send the affected contract, commit, impact and a minimal proof of concept to `contact@ring.exchange`. A Foundry test is preferred when practical.

Do not test against third-party funds or broadcast an exploit to mainnet. Use a local fork or Anvil.

## In scope

- `src/FewV2ShellHook.sol` (deployment target)
- `src/FewV2ShellHookBase.sol`
- `src/lib/FewV2Math.sol`
- `src/lib/FewV2Price.sol`

Upstream Uniswap, OpenZeppelin and Ring Few Protocol contracts are separate projects, but a new interaction bug caused by this integration is in scope.

## Trust boundary

Deployment target `FewV2ShellHook`:

- `owner` (`Ownable2Step`) can propose and, after the immutable add-timelock, commit a new allowlisted underlying; remove an underlying immediately; `unpause`; replace the guardian, the pool initializer and the residual recipient; transfer ownership in two steps. Ownership cannot be renounced.
- `guardian` is disable-only: it can `pause()` swaps and remove or cancel an underlying. It can never enable a token or unpause.
- `poolInitializer` may register new pools whose underlyings are allowlisted. It cannot change an existing route or move funds.
- No role can upgrade the contract, change a registered route, move PoolManager assets or remove another account's liquidity. `pause()` only blocks swaps; it never blocks LP withdrawal.
- Factories, WETH, V4Quoter, the native ETH mode and the add-timelock delay are immutable.

The inherited base `FewV2ShellHookBase` has no owner, pause, allowlist or route setter; `poolInitializer` is its only role, and the base never changes it or `residualRecipient`.

In both contracts, Shell LP positions are owned through PositionManager NFTs and their owners control withdrawal, and permissionless `sweep()` can only send the Hook's own residual balance to the current `residualRecipient`.

Fork tests reduce regression risk but do not make large deposits safe. Funding requires review of the exact commit, bytecode and constructor values, a full withdrawal rehearsal, monitoring and a staged capital cap. See [Known Issues](KNOWN_ISSUES.md) for dependency and governance-key assumptions.
