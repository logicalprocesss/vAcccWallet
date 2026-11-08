// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {Ownable, Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title WalletVault
/// @notice ERC-4626 vault template. Users deposit one ERC-20 and receive shares.
///
/// Features
///  - Optional yield: idle funds are invested in ANY other ERC-4626 vault (the "strategy").
///    Set strategy = address(0) for a plain vault that just holds the asset.
///  - Deposit cap, and a pause switch that stops DEPOSITS only. Withdrawals are never blocked.
///  - Two-step ownership transfer, reentrancy protection, safe token transfers,
///    and virtual-share protection against the first-depositor "inflation" attack.
///
/// Trust model: the owner can change the strategy. A malicious or compromised owner could point it at a
/// harmful contract, so use a multisig (ideally behind a timelock) as the owner in production.
contract WalletVault is ERC4626, Ownable2Step, Pausable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    /// @notice Where idle funds earn yield. address(0) = none.
    IERC4626 public strategy;
    /// @notice Max total assets the vault will accept. type(uint256).max = no cap.
    uint256 public depositCap;

    event StrategyChanged(address indexed oldStrategy, address indexed newStrategy);
    event DepositCapChanged(uint256 newCap);

    error StrategyAssetMismatch();

    constructor(
        IERC20 asset_,
        string memory name_,
        string memory symbol_,
        address owner_,
        uint256 depositCap_,
        IERC4626 strategy_
    ) ERC20(name_, symbol_) ERC4626(asset_) Ownable(owner_) {
        depositCap = depositCap_;
        _attachStrategy(strategy_);
    }

    // ───────────────────────── Accounting ─────────────────────────

    /// @notice Idle tokens + what the strategy would pay out if we redeemed everything now.
    function totalAssets() public view override returns (uint256) {
        uint256 total = IERC20(asset()).balanceOf(address(this));
        if (address(strategy) != address(0)) {
            total += strategy.previewRedeem(strategy.balanceOf(address(this)));
        }
        return total;
    }

    /// @dev Extra decimals on shares make the empty-vault donation attack uneconomical.
    function _decimalsOffset() internal pure override returns (uint8) {
        return 6;
    }

    // ───────────────────────── Limits ─────────────────────────

    function maxDeposit(address) public view override returns (uint256) {
        if (paused()) return 0;
        if (depositCap == type(uint256).max) return type(uint256).max;
        uint256 total = totalAssets();
        return total >= depositCap ? 0 : depositCap - total;
    }

    function maxMint(address receiver) public view override returns (uint256) {
        uint256 maxAssets = maxDeposit(receiver);
        return maxAssets == type(uint256).max ? type(uint256).max : previewDeposit(maxAssets);
    }

    // ───────────────────────── Deposit / withdraw hooks ─────────────────────────

    function _deposit(address caller, address receiver, uint256 assets, uint256 shares)
        internal
        override
        nonReentrant
    {
        super._deposit(caller, receiver, assets, shares);
        _invest();
    }

    function _withdraw(address caller, address receiver, address owner_, uint256 assets, uint256 shares)
        internal
        override
        nonReentrant
    {
        uint256 idle = IERC20(asset()).balanceOf(address(this));
        if (idle < assets && address(strategy) != address(0)) {
            strategy.withdraw(assets - idle, address(this), address(this));
        }
        super._withdraw(caller, receiver, owner_, assets, shares);
    }

    /// @dev Put idle funds to work, respecting the strategy's own deposit limit.
    function _invest() internal {
        if (address(strategy) == address(0)) return;
        uint256 idle = IERC20(asset()).balanceOf(address(this));
        uint256 room = strategy.maxDeposit(address(this));
        uint256 amount = idle < room ? idle : room;
        if (amount > 0) strategy.deposit(amount, address(this));
    }

    // ───────────────────────── Admin ─────────────────────────

    /// @notice Stops new deposits. Users can still withdraw.
    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }

    function setDepositCap(uint256 newCap) external onlyOwner {
        depositCap = newCap;
        emit DepositCapChanged(newCap);
    }

    /// @notice Move everything out of the current strategy and into a new one (or none).
    function setStrategy(IERC4626 newStrategy) external onlyOwner nonReentrant {
        IERC4626 old = strategy;
        if (address(old) != address(0)) {
            uint256 shares = old.balanceOf(address(this));
            if (shares > 0) old.redeem(shares, address(this), address(this));
            IERC20(asset()).forceApprove(address(old), 0);
        }
        _attachStrategy(newStrategy);
        _invest();
    }

    function _attachStrategy(IERC4626 s) internal {
        if (address(s) != address(0)) {
            if (s.asset() != asset()) revert StrategyAssetMismatch();
            IERC20(asset()).forceApprove(address(s), type(uint256).max);
        }
        emit StrategyChanged(address(strategy), address(s));
        strategy = s;
    }
}
