// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import {PackedUserOperation} from "@openzeppelin/contracts/interfaces/draft-IERC4337.sol";

interface IEntryPointFunds {
    function depositTo(address account) external payable;
    function withdrawTo(address payable to, uint256 amount) external;
    function balanceOf(address account) external view returns (uint256);
    function addStake(uint32 unstakeDelaySec) external payable;
}

/// @notice ERC-4337 v0.8 paymaster. Sponsors gas for UserOps that a trusted off-chain `verifier` has signed.
///
/// paymasterAndData layout (v0.7+):
///   [0:20]   paymaster address
///   [20:36]  paymasterVerificationGasLimit (uint128)
///   [36:52]  paymasterPostOpGasLimit      (uint128)
///   [52:58]  validUntil (uint48)
///   [58:64]  validAfter (uint48)
///   [64:129] verifier signature (65 bytes) over getHash(...), eth-signed-message style
contract VerifyingPaymaster is Ownable {
    address public constant ENTRY_POINT = 0x4337084D9E255Ff0702461CF8895CE9E3b5Ff108; // v0.8
    uint256 private constant PAYMASTER_DATA_OFFSET = 52;

    address public verifier;

    error NotEntryPoint();

    event VerifierChanged(address indexed oldVerifier, address indexed newVerifier);

    modifier onlyEntryPoint() {
        if (msg.sender != ENTRY_POINT) revert NotEntryPoint();
        _;
    }

    constructor(address verifier_, address owner_) Ownable(owner_) {
        verifier = verifier_;
    }

    // ───────── Funding (the paymaster's gas money lives INSIDE the EntryPoint) ─────────

    function deposit() external payable {
        IEntryPointFunds(ENTRY_POINT).depositTo{value: msg.value}(address(this));
    }

    function getDeposit() external view returns (uint256) {
        return IEntryPointFunds(ENTRY_POINT).balanceOf(address(this));
    }

    function withdrawTo(address payable to, uint256 amount) external onlyOwner {
        IEntryPointFunds(ENTRY_POINT).withdrawTo(to, amount);
    }

    /// @dev Some bundlers require paymasters to be staked.
    function addStake(uint32 unstakeDelaySec) external payable onlyOwner {
        IEntryPointFunds(ENTRY_POINT).addStake{value: msg.value}(unstakeDelaySec);
    }

    function setVerifier(address verifier_) external onlyOwner {
        emit VerifierChanged(verifier, verifier_);
        verifier = verifier_;
    }

    // ───────── Validation ─────────

    /// @notice The hash your backend signs. It covers the op fields but NOT the paymaster signature itself
    /// (userOpHash can't be used: in v0.7+ it includes the whole paymasterAndData, signature and all).
    function getHash(PackedUserOperation calldata op, uint48 validUntil, uint48 validAfter)
        public
        view
        returns (bytes32)
    {
        bytes32 opHash = keccak256(
            abi.encode(
                op.sender,
                op.nonce,
                keccak256(op.initCode),
                keccak256(op.callData),
                op.accountGasLimits,
                op.preVerificationGas,
                op.gasFees,
                bytes32(op.paymasterAndData[20:PAYMASTER_DATA_OFFSET]) // paymaster gas limits
            )
        );
        return keccak256(abi.encode(opHash, block.chainid, address(this), validUntil, validAfter));
    }

    function validatePaymasterUserOp(PackedUserOperation calldata userOp, bytes32, /* userOpHash */ uint256 /* maxCost */ )
        external
        view
        onlyEntryPoint
        returns (bytes memory context, uint256 validationData)
    {
        bytes calldata data = userOp.paymasterAndData;
        uint48 validUntil = uint48(bytes6(data[PAYMASTER_DATA_OFFSET:PAYMASTER_DATA_OFFSET + 6]));
        uint48 validAfter = uint48(bytes6(data[PAYMASTER_DATA_OFFSET + 6:PAYMASTER_DATA_OFFSET + 12]));
        bytes calldata sig = data[PAYMASTER_DATA_OFFSET + 12:];

        bytes32 digest = MessageHashUtils.toEthSignedMessageHash(getHash(userOp, validUntil, validAfter));
        (address recovered, ECDSA.RecoverError err,) = ECDSA.tryRecover(digest, sig);
        bool ok = err == ECDSA.RecoverError.NoError && recovered == verifier;

        // sigFailed (bit 0) | validUntil (bits 160-207) | validAfter (bits 208-255)
        validationData = (ok ? 0 : 1) | (uint256(validUntil) << 160) | (uint256(validAfter) << 208);
        context = ""; // empty context => EntryPoint skips postOp
    }

    /// @dev Only called if validatePaymasterUserOp returns a non-empty context. Add ERC-20 charging here later.
    function postOp(uint8, bytes calldata, uint256, uint256) external onlyEntryPoint {}
}
