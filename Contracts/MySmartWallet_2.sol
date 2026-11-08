// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {Account} from "@openzeppelin/contracts/account/Account.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {Initializable} from "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import {Address} from "@openzeppelin/contracts/utils/Address.sol";
import {ERC721Holder} from "@openzeppelin/contracts/token/ERC721/utils/ERC721Holder.sol";
import {ERC1155Holder} from "@openzeppelin/contracts/token/ERC1155/utils/ERC1155Holder.sol";

/// @notice ERC-4337 smart wallet owned by a single ECDSA key, deployed as an EIP-1167 clone.
/// - Account  -> validateUserOp / nonce / EntryPoint plumbing (the 4337 part)
/// - _rawSignatureValidation (below) -> "did the owner sign this?"
/// - execute* -> what the wallet can actually do
contract MySmartWallet is Account, Initializable, ERC721Holder, ERC1155Holder {
    struct Call {
        address target;
        uint256 value;
        bytes data;
    }

    address private _owner;

    error InvalidOwner();

    /// @dev Locks the implementation so nobody can initialize it. Clones don't run this constructor.
    constructor() {
        _disableInitializers();
    }

    /// @notice Called once by the factory, in the same tx that creates the clone.
    function initialize(address owner_) external initializer {
        if (owner_ == address(0)) revert InvalidOwner();
        _owner = owner_;
    }

    function owner() public view returns (address) {
        return _owner;
    }

    /// @dev Account calls this with the userOpHash. The client must sign that hash RAW (no "Ethereum Signed Message" prefix).
    function _rawSignatureValidation(bytes32 hash, bytes calldata signature) internal view override returns (bool) {
        (address recovered, ECDSA.RecoverError err,) = ECDSA.tryRecover(hash, signature);
        return err == ECDSA.RecoverError.NoError && recovered == _owner;
    }

    /// @notice Run a single call. Callable by the EntryPoint (via a UserOp) or by the wallet itself.
    function execute(address target, uint256 value, bytes calldata data) external onlyEntryPointOrSelf {
        Address.functionCallWithValue(target, data, value);
    }

    /// @notice Run several calls atomically, e.g. approve + deposit in ONE user operation.
    function executeBatch(Call[] calldata calls) external onlyEntryPointOrSelf {
        for (uint256 i = 0; i < calls.length; ++i) {
            Address.functionCallWithValue(calls[i].target, calls[i].data, calls[i].value);
        }
    }
}
