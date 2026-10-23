// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.26;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";

import {ISubsidyVault} from "./interfaces/ISubsidyVault.sol";

/// @title SubsidyVault
/// @notice Holds one shared subsidy budget for every Shell pool served by a single Hook, and
///         pays the Uniswap protocol fee back to the trader out of that budget.
///
/// @dev Why this lives outside the Hook:
///      - The Hook must never hold a balance. `sweep` is permissionless and would drain a
///        reserve, and the Hook asserts that it leaves no token residue after every swap.
///      - The Hook's owner cannot move balances. A funding balance would have to change that
///        trust boundary. Here the owner can only move the vault's own budget, which is Ring
///        money that never belonged to the Hook or to a Shell LP.
///      - One budget serves every pair. Subsidy is a product-level budget, not a per-pool one.
///
///      How the money reaches the trader:
///      The Hook settles the Uniswap protocol fee into the PoolManager exactly as it already
///      does, then asks this vault for the same amount back. The vault transfers that amount
///      straight into the PoolManager and calls `settleFor(hook)`, so the credit lands on the
///      Hook's delta. The Hook then declares a larger payout to the router, and the trader
///      receives the protocol fee back. PoolManager inventory is unchanged by the round trip:
///      the vault's contribution is exactly what the router takes out again.
///
///      Failure mode:
///      The vault never reverts on an empty budget. It pays what it can and reports the real
///      amount, so an underfunded vault degrades the subsidy to zero instead of taking the
///      whole route down. The Hook uses the returned amount, so quotes and execution stay
///      consistent.
///
///      Deployment order:
///      The vault address must be known before the Hook is deployed, and the Hook address
///      before the vault can be armed. The vault therefore takes no Hook address in its
///      constructor; the owner arms it once with `setHook`, which locks afterwards.
contract SubsidyVault is ISubsidyVault, Ownable2Step, ReentrancyGuard {
    error NotHook(address caller);
    error HookAlreadySet();
    error ZeroAddress();
    error NativeTransferFailed();
    error InsufficientBudget(address currency, uint256 available, uint256 requested);

    event HookSet(address indexed hook);
    event SubsidyPaused(bool paused);
    event BudgetFunded(address indexed currency, uint256 amount, address indexed from);
    event BudgetDrained(address indexed currency, uint256 amount, address indexed to);
    event SubsidyPaid(PoolId indexed poolId, address indexed currency, uint256 feeAmount, uint256 subsidyAmount);

    /// @notice The PoolManager the bound Hook settles against.
    IPoolManager public immutable poolManager;

    /// @notice The only account allowed to draw on this budget.
    address public hook;

    /// @notice True once `hook` has been armed. The binding is permanent afterwards.
    bool public hookLocked;

    /// @notice When true, every subsidy request returns zero.
    bool public paused;

    /// @notice Remaining budget per token. `address(0)` is the native ETH budget.
    mapping(address => uint256) public balance;

    constructor(IPoolManager _poolManager, address _owner) Ownable(_owner) {
        if (address(_poolManager) == address(0)) revert ZeroAddress();
        if (_owner == address(0)) revert ZeroAddress();
        poolManager = _poolManager;
    }

    /// @notice Arm this vault with the Hook that may draw on it. Callable once.
    /// @dev The Hook address is only known after the vault exists, because the Hook's init code
    ///      references the vault address. The binding is permanent so that a later owner change
    ///      cannot redirect the budget.
    function setHook(address newHook) external onlyOwner {
        if (hookLocked) revert HookAlreadySet();
        if (newHook == address(0)) revert ZeroAddress();
        hook = newHook;
        hookLocked = true;
        emit HookSet(newHook);
    }

    /// @notice Stop or resume paying subsidies without undeploying.
    function setPaused(bool newPaused) external onlyOwner {
        paused = newPaused;
        emit SubsidyPaused(newPaused);
    }

    /// @inheritdoc ISubsidyVault
    function settleSubsidy(PoolId poolId, address currency, uint256 feeAmount)
        external
        override
        nonReentrant
        returns (uint256 subsidyAmount)
    {
        if (msg.sender != hook) revert NotHook(msg.sender);
        if (paused) return 0;

        uint256 available = balance[currency];
        subsidyAmount = feeAmount < available ? feeAmount : available;
        if (subsidyAmount == 0) return 0;

        balance[currency] = available - subsidyAmount;
        _creditPoolManager(currency, subsidyAmount);
        emit SubsidyPaid(poolId, currency, feeAmount, subsidyAmount);
    }

    /// @notice Add ERC20 to the shared budget.
    function fund(address currency, uint256 amount) external onlyOwner nonReentrant {
        if (currency == address(0)) revert ZeroAddress();
        if (amount == 0) return;
        SafeERC20.safeTransferFrom(IERC20(currency), msg.sender, address(this), amount);
        balance[currency] += amount;
        emit BudgetFunded(currency, amount, msg.sender);
    }

    /// @notice Add native ETH to the shared budget.
    function fundNative() external payable onlyOwner nonReentrant {
        uint256 amount = msg.value;
        if (amount == 0) return;
        balance[address(0)] += amount;
        emit BudgetFunded(address(0), amount, msg.sender);
    }

    /// @notice Move ERC20 out of the shared budget.
    function drain(address currency, uint256 amount, address to) external onlyOwner nonReentrant {
        if (to == address(0)) revert ZeroAddress();
        uint256 available = balance[currency];
        if (amount > available) revert InsufficientBudget(currency, available, amount);
        balance[currency] = available - amount;
        SafeERC20.safeTransfer(IERC20(currency), to, amount);
        emit BudgetDrained(currency, amount, to);
    }

    /// @notice Move native ETH out of the shared budget.
    function drainNative(uint256 amount, address to) external onlyOwner nonReentrant {
        if (to == address(0)) revert ZeroAddress();
        uint256 available = balance[address(0)];
        if (amount > available) revert InsufficientBudget(address(0), available, amount);
        balance[address(0)] = available - amount;
        (bool ok,) = payable(to).call{value: amount}("");
        if (!ok) revert NativeTransferFailed();
        emit BudgetDrained(address(0), amount, to);
    }

    /// @notice Disabled. Without an owner the budget could never be funded, drained or paused.
    function renounceOwnership() public pure override {
        revert OwnableInvalidOwner(address(0));
    }

    /// @dev Put `amount` of `currency` into the PoolManager and book the credit to the Hook.
    ///      Native ETH can only enter the PoolManager through a payable settle call, so the
    ///      value travels with the call; ERC20 is transferred first and settled afterwards.
    function _creditPoolManager(address currency, uint256 amount) internal {
        poolManager.sync(Currency.wrap(currency));
        if (currency == address(0)) {
            poolManager.settleFor{value: amount}(hook);
        } else {
            SafeERC20.safeTransfer(IERC20(currency), address(poolManager), amount);
            poolManager.settleFor(hook);
        }
    }
}
