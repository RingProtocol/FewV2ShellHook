// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.26;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {BeforeSwapDelta} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";

import {IWETH9} from "v4-periphery/src/interfaces/external/IWETH9.sol";
import {IV4Quoter} from "v4-periphery/src/interfaces/IV4Quoter.sol";
import {IFewFactory} from "./interfaces/external/IFewFactory.sol";
import {ISwapV2Factory} from "./interfaces/external/IFewV2.sol";
import {ISubsidyVault} from "./interfaces/ISubsidyVault.sol";
import {FewV2ShellHookBase} from "./FewV2ShellHookBase.sol";

/// @title FewV2ShellHook
/// @notice FewV2ShellHookBase plus a minimal, least-privilege governance layer modeled on Uniswap's
///         Permissioned Pools: a deployment-time underlying allowlist (checked at registration) and a
///         swap pause. The permissionless FewFactory cannot express "which origin tokens are trusted"
///         (createToken is open to anyone), so this layer is what actually filters the token set.
///
/// @dev Deliberate trust boundaries, mirroring the admin-less base contract:
///      - The underlying allowlist is fixed at deployment. There is no add, no remove and no timelock,
///        so a compromised owner key cannot widen the token set after the fact, and no role can strand
///        a live pool by removing one of its endpoints.
///      - The owner can unpause, and can replace the pool initializer and the residual recipient. The
///        owner cannot change a registered route, move balances, or withdraw LP positions — those
///        remain impossible for every role.
///      - A separate guardian handles disable-only emergency actions: pause swaps. The guardian can
///        never enable a token or unpause, so it adds no theft surface.
///      - The owner can replace the pool initializer and the residual recipient, so losing either key
///        does not force a redeploy. A new initializer can only register new pools.
///      - Ownership moves only by two-step transfer and cannot be renounced, so an owner always exists
///        to lift a guardian pause.
///      - There is no external allowlist-checker and no upgrade path; changing the supported token
///        set or changing dependencies requires a new Hook deployment.
///
///      The allowlist is enforced in `beforeInitialize` only. It gates future registrations; it does
///      not disable a pool that is already registered. Use `pause()` for a live incident, and migrate
///      team liquidity out of the affected pool.
contract FewV2ShellHook is FewV2ShellHookBase, Ownable2Step, Pausable {
    error UnderlyingNotAllowlisted(address underlying);
    error NotGuardianOrOwner(address caller);
    error ZeroGuardian();
    error RenounceDisabled();

    /// @notice Account allowed to pause swaps (owner unpauses). Fast incident-response role only.
    address public guardian;

    /// @notice Origin tokens (WETH for native ETH) that may be registered as a Shell pool endpoint.
    /// @dev Fixed at deployment: no role can add or remove an entry. Widening the token set requires
    ///      a new Hook deployment, which also means new pool ids and a new route submission.
    mapping(address => bool) public allowedUnderlying;

    event UnderlyingAllowed(address indexed underlying, address indexed deployer);
    event GuardianUpdated(address indexed previousGuardian, address indexed newGuardian);
    event PoolInitializerUpdated(address indexed previousInitializer, address indexed newInitializer);
    event ResidualRecipientUpdated(address indexed previousRecipient, address indexed newRecipient);

    modifier onlyGuardianOrOwner() {
        if (msg.sender != owner() && msg.sender != guardian) revert NotGuardianOrOwner(msg.sender);
        _;
    }

    constructor(
        IPoolManager _pm,
        IFewFactory _fewFactory,
        ISwapV2Factory _fewV2Factory,
        IWETH9 _weth,
        IV4Quoter _v4Quoter,
        bool _useNativeCurrencyForWeth,
        address _poolInitializer,
        address _residualRecipient,
        ISubsidyVault _subsidyVault,
        address _owner,
        address _guardian,
        address[] memory _initialAllowed
    )
        FewV2ShellHookBase(
            _pm,
            _fewFactory,
            _fewV2Factory,
            _weth,
            _v4Quoter,
            _useNativeCurrencyForWeth,
            _poolInitializer,
            _residualRecipient,
            _subsidyVault
        )
        Ownable(_owner)
    {
        if (_guardian == address(0)) revert ZeroGuardian();
        guardian = _guardian;

        // The allowlist is the complete, immutable token set of this deployment. It is trusted
        // deploy-time configuration, so it needs no timelock and no owner action afterwards.
        for (uint256 i = 0; i < _initialAllowed.length; i++) {
            address underlying = _initialAllowed[i];
            if (underlying == address(0)) revert ZeroAddress();
            allowedUnderlying[underlying] = true;
            emit UnderlyingAllowed(underlying, msg.sender);
        }
    }

    // ============ Hook overrides ============

    function _beforeInitialize(address sender, PoolKey calldata key, uint160 sqrtPriceX96)
        internal
        override
        returns (bytes4)
    {
        _requireUnderlyingAllowed(Currency.unwrap(key.currency0));
        _requireUnderlyingAllowed(Currency.unwrap(key.currency1));
        return super._beforeInitialize(sender, key, sqrtPriceX96);
    }

    function _beforeSwap(address sender, PoolKey calldata key, SwapParams calldata params, bytes calldata hookData)
        internal
        override
        whenNotPaused
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        return super._beforeSwap(sender, key, params, hookData);
    }

    function _requireUnderlyingAllowed(address currency) internal view {
        address underlying = currency == address(0) ? address(weth) : currency;
        if (!allowedUnderlying[underlying]) revert UnderlyingNotAllowlisted(underlying);
    }

    // ============ Pause (guardian or owner pauses, only owner unpauses) ============

    function pause() external onlyGuardianOrOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }

    function setGuardian(address newGuardian) external onlyOwner {
        if (newGuardian == address(0)) revert ZeroGuardian();
        emit GuardianUpdated(guardian, newGuardian);
        guardian = newGuardian;
    }

    // ============ Pool initializer and residual recipient (owner) ============

    /// @notice Replace the only account allowed to register new Shell Pools. Registered routes are unchanged.
    function setPoolInitializer(address newInitializer) external onlyOwner {
        if (newInitializer == address(0)) revert ZeroAddress();
        emit PoolInitializerUpdated(poolInitializer, newInitializer);
        poolInitializer = newInitializer;
    }

    /// @notice Replace the destination of the permissionless `sweep`.
    function setResidualRecipient(address newRecipient) external onlyOwner {
        if (newRecipient == address(0)) revert ZeroAddress();
        emit ResidualRecipientUpdated(residualRecipient, newRecipient);
        residualRecipient = newRecipient;
    }

    // ============ Ownership ============

    /// @notice Disabled. Without an owner, a guardian pause could never be lifted, and the guardian,
    ///         pool initializer and residual recipient could not be replaced.
    function renounceOwnership() public pure override {
        revert RenounceDisabled();
    }
}
