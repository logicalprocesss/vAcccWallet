// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";

/// @notice Minimal ERC-4626 vault. Shares are an ERC-20 that represent a claim on the underlying asset.
contract MyVault is ERC4626 {
    constructor(IERC20 asset_, string memory name_, string memory symbol_)
        ERC20(name_, symbol_)
        ERC4626(asset_)
    {}

    /// @dev Virtual shares offset: makes the classic "donation / inflation" attack on an empty vault uneconomical.
    function _decimalsOffset() internal pure override returns (uint8) {
        return 6;
    }
}
