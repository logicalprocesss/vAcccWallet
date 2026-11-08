// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {MySmartWallet} from "./MySmartWallet.sol";

/// @notice Deploys wallets at deterministic (counterfactual) addresses.
/// The EntryPoint calls createAccount via `initCode` on a user's first UserOp.
contract MySmartWalletFactory {
    address public immutable implementation;

    constructor() {
        implementation = address(new MySmartWallet());
    }

    /// @notice Idempotent: returns the existing wallet if it is already deployed.
    function createAccount(address owner, bytes32 salt) external returns (address account) {
        bytes32 s = _salt(owner, salt);
        account = Clones.predictDeterministicAddress(implementation, s, address(this));
        if (account.code.length > 0) return account;

        account = Clones.cloneDeterministic(implementation, s);
        MySmartWallet(payable(account)).initialize(owner);
    }

    /// @notice The wallet address, known BEFORE it is deployed (so you can fund it first).
    function getAddress(address owner, bytes32 salt) external view returns (address) {
        return Clones.predictDeterministicAddress(implementation, _salt(owner, salt), address(this));
    }

    /// @dev Owner is part of the salt, so nobody can squat someone else's address.
    function _salt(address owner, bytes32 salt) internal pure returns (bytes32) {
        return keccak256(abi.encode(owner, salt));
    }
}
