// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {MyVault} from "../src/MyVault.sol";
import {MySmartWallet} from "../src/MySmartWallet.sol";
import {MySmartWalletFactory} from "../src/MySmartWalletFactory.sol";

contract MockToken is ERC20 {
    constructor() ERC20("Mock USD", "mUSD") {}
    function mint(address to, uint256 amt) external { _mint(to, amt); }
}

contract WalletVaultTest is Test {
    MySmartWalletFactory factory;
    MockToken token;
    MyVault vault;
    MySmartWallet wallet;
    address owner = makeAddr("owner");

    function setUp() public {
        factory = new MySmartWalletFactory();
        token = new MockToken();
        vault = new MyVault(IERC20(address(token)), "My Vault", "mvUSD");

        address predicted = factory.getAddress(owner, bytes32(0));
        wallet = MySmartWallet(payable(factory.createAccount(owner, bytes32(0))));
        assertEq(address(wallet), predicted);
    }

    function test_batchApproveAndDeposit() public {
        token.mint(address(wallet), 1_000e18);

        MySmartWallet.Call[] memory calls = new MySmartWallet.Call[](2);
        calls[0] = MySmartWallet.Call(address(token), 0, abi.encodeCall(IERC20.approve, (address(vault), 1_000e18)));
        calls[1] = MySmartWallet.Call(address(vault), 0, abi.encodeCall(vault.deposit, (1_000e18, address(wallet))));

        // Pretend to be the EntryPoint (a real UserOp would arrive through it).
        vm.prank(address(wallet.entryPoint()));
        wallet.executeBatch(calls);

        assertEq(token.balanceOf(address(wallet)), 0);
        assertEq(vault.maxWithdraw(address(wallet)), 1_000e18 - 1); // tiny rounding is normal in 4626
        assertGt(vault.balanceOf(address(wallet)), 0);
    }

    function test_randomCallerCannotExecute() public {
        vm.expectRevert();
        wallet.execute(address(token), 0, "");
    }

    function test_cannotReinitialize() public {
        vm.expectRevert();
        wallet.initialize(address(0xBEEF));
    }
}
