// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {SoothToken} from "../src/SoothToken.sol";

/// @dev Local factory analogue: verifies CREATE2 minting and exact distribution flows.
contract TokenFactoryHarness {
    function deploy(bytes32 salt) external returns (SoothToken) {
        return new SoothToken{salt: salt}();
    }

    function distribute(SoothToken token, address recipient, uint256 amount) external {
        require(token.transfer(recipient, amount), "transfer failed");
    }
}

contract SoothTokenTest is Test {
    uint256 internal constant SUPPLY = 1_000_000_000 * 10 ** 18;

    SoothToken internal token;
    address internal alice;
    address internal bob;
    address internal spender;

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);

    function setUp() public {
        token = new SoothToken();
        alice = makeAddr("alice");
        bob = makeAddr("bob");
        spender = makeAddr("spender");
    }

    function test_MetadataAndWholeSupply() public view {
        assertEq(token.name(), "Sooth Protocol");
        assertEq(token.symbol(), "SOOTH");
        assertEq(token.decimals(), 18);
        assertEq(token.INITIAL_SUPPLY(), SUPPLY);
        assertEq(token.totalSupply(), SUPPLY);
        assertEq(token.balanceOf(address(this)), SUPPLY);
        assertEq(token.balanceOf(alice), 0);
        assertEq(token.balanceOf(address(token)), 0);
        assertEq(token.balanceOf(address(0)), 0);
        assertEq(token.allowance(address(this), spender), 0);
    }

    function test_ConstructorEmitsOneMintToImmediateDeployer() public {
        vm.recordLogs();
        vm.prank(alice);
        SoothToken deployed = new SoothToken();
        Vm.Log[] memory logs = vm.getRecordedLogs();

        assertEq(logs.length, 1);
        assertEq(logs[0].emitter, address(deployed));
        assertEq(logs[0].topics.length, 3);
        assertEq(logs[0].topics[0], keccak256("Transfer(address,address,uint256)"));
        assertEq(logs[0].topics[1], bytes32(0));
        assertEq(logs[0].topics[2], bytes32(uint256(uint160(alice))));
        assertEq(abi.decode(logs[0].data, (uint256)), SUPPLY);
        assertEq(deployed.balanceOf(alice), SUPPLY);
        assertEq(deployed.balanceOf(address(this)), 0);
        assertEq(deployed.totalSupply(), SUPPLY);
    }

    function test_FactoryReceivesEverythingAndLaunchTransfersArriveWhole() public {
        TokenFactoryHarness factory = new TokenFactoryHarness();
        SoothToken launched = factory.deploy(keccak256("sooth launch test"));
        address distributor = makeAddr("distributor");
        address pool = makeAddr("pool");
        address remainder = makeAddr("remainder");
        address trader = makeAddr("trader");

        assertEq(launched.balanceOf(address(factory)), SUPPLY);
        assertEq(launched.balanceOf(address(this)), 0);
        factory.distribute(launched, distributor, SUPPLY / 10);
        factory.distribute(launched, pool, SUPPLY * 8 / 10);
        factory.distribute(launched, remainder, SUPPLY / 10);
        assertEq(launched.balanceOf(address(factory)), 0);
        assertEq(launched.balanceOf(distributor), SUPPLY / 10);
        assertEq(launched.balanceOf(pool), SUPPLY * 8 / 10);
        assertEq(launched.balanceOf(remainder), SUPPLY / 10);

        vm.prank(distributor);
        assertTrue(launched.transfer(alice, SUPPLY / 10));
        assertEq(launched.balanceOf(distributor), 0);
        assertEq(launched.balanceOf(alice), SUPPLY / 10);

        vm.prank(pool);
        assertTrue(launched.transfer(trader, 123e18));
        assertEq(launched.balanceOf(trader), 123e18);
        vm.prank(trader);
        assertTrue(launched.transfer(pool, 123e18));
        assertEq(launched.balanceOf(trader), 0);
        assertEq(launched.balanceOf(pool), SUPPLY * 8 / 10);
        assertEq(launched.totalSupply(), SUPPLY);
    }

    function test_TransferEmitsEventAndMovesExactAmount() public {
        vm.expectEmit(true, true, false, true, address(token));
        emit Transfer(address(this), alice, 123e18);
        assertTrue(token.transfer(alice, 123e18));
        assertEq(token.balanceOf(alice), 123e18);
        assertEq(token.balanceOf(address(this)), SUPPLY - 123e18);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function test_TransferEntireSupply() public {
        assertTrue(token.transfer(alice, SUPPLY));
        assertEq(token.balanceOf(address(this)), 0);
        assertEq(token.balanceOf(alice), SUPPLY);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function test_ZeroTransferFromEmptyAccountEmitsEvent() public {
        vm.expectEmit(true, true, false, true, address(token));
        emit Transfer(alice, bob, 0);
        vm.prank(alice);
        assertTrue(token.transfer(bob, 0));
        assertEq(token.balanceOf(alice), 0);
        assertEq(token.balanceOf(bob), 0);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function test_SelfTransferPreservesBalance() public {
        assertTrue(token.transfer(address(this), SUPPLY));
        assertEq(token.balanceOf(address(this)), SUPPLY);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function test_ApproveEmitsEventAndCanReplaceAndRevoke() public {
        vm.expectEmit(true, true, false, true, address(token));
        emit Approval(address(this), spender, 50e18);
        assertTrue(token.approve(spender, 50e18));
        assertEq(token.allowance(address(this), spender), 50e18);
        assertTrue(token.approve(spender, 20e18));
        assertEq(token.allowance(address(this), spender), 20e18);
        assertTrue(token.approve(spender, 0));
        assertEq(token.allowance(address(this), spender), 0);

        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, spender, 0, 1));
        vm.prank(spender);
        token.transferFrom(address(this), alice, 1);
        assertEq(token.balanceOf(address(this)), SUPPLY);
    }

    function test_TransferFromSpendsOnlyApprovedAmount() public {
        token.approve(spender, 100e18);
        vm.expectEmit(true, true, false, true, address(token));
        emit Transfer(address(this), alice, 40e18);
        vm.prank(spender);
        assertTrue(token.transferFrom(address(this), alice, 40e18));
        assertEq(token.allowance(address(this), spender), 60e18);
        assertEq(token.balanceOf(address(this)), SUPPLY - 40e18);
        assertEq(token.balanceOf(alice), 40e18);
        assertEq(token.balanceOf(spender), 0);

        vm.prank(spender);
        assertTrue(token.transferFrom(address(this), bob, 60e18));
        assertEq(token.allowance(address(this), spender), 0);
        assertEq(token.balanceOf(bob), 60e18);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function test_InfiniteApprovalIsNotDecremented() public {
        token.approve(spender, type(uint256).max);
        vm.prank(spender);
        assertTrue(token.transferFrom(address(this), alice, SUPPLY));
        assertEq(token.allowance(address(this), spender), type(uint256).max);
        assertEq(token.balanceOf(alice), SUPPLY);
        assertEq(token.balanceOf(address(this)), 0);
    }

    function test_ZeroTransferFromWithoutAllowance() public {
        vm.prank(spender);
        assertTrue(token.transferFrom(alice, bob, 0));
        assertEq(token.allowance(alice, spender), 0);
        assertEq(token.balanceOf(alice), 0);
        assertEq(token.balanceOf(bob), 0);
    }

    function test_DelegatedSelfTransferStillConsumesAllowance() public {
        token.approve(spender, 50e18);
        vm.prank(spender);
        assertTrue(token.transferFrom(address(this), address(this), 50e18));
        assertEq(token.allowance(address(this), spender), 0);
        assertEq(token.balanceOf(address(this)), SUPPLY);
    }

    function test_RevertWhenTransferExceedsBalance() public {
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, address(this), SUPPLY, SUPPLY + 1)
        );
        token.transfer(alice, SUPPLY + 1);
        assertEq(token.balanceOf(address(this)), SUPPLY);
        assertEq(token.balanceOf(alice), 0);
    }

    function test_RevertWhenTransferFromExceedsAllowance() public {
        token.approve(spender, 5);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, spender, 5, 6));
        vm.prank(spender);
        token.transferFrom(address(this), alice, 6);
        assertEq(token.allowance(address(this), spender), 5);
        assertEq(token.balanceOf(address(this)), SUPPLY);
        assertEq(token.balanceOf(alice), 0);
    }

    function test_RevertWhenTransferFromExceedsBalanceRestoresAllowance() public {
        vm.prank(alice);
        token.approve(spender, 100);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, alice, 0, 100));
        vm.prank(spender);
        token.transferFrom(alice, bob, 100);
        assertEq(token.allowance(alice, spender), 100);
        assertEq(token.balanceOf(alice), 0);
        assertEq(token.balanceOf(bob), 0);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function test_RevertWhenDeployerTriesToSpendHolderBalanceWithoutApproval() public {
        token.transfer(alice, 100e18);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, address(this), 0, 1));
        token.transferFrom(alice, address(this), 1);
        assertEq(token.balanceOf(alice), 100e18);
    }

    function test_RevertWhenHolderUsesTransferFromWithoutSelfApproval() public {
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, address(this), 0, 1));
        token.transferFrom(address(this), alice, 1);
    }

    function test_RevertWhenTransferToZeroIncludingZeroAmount() public {
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0)));
        token.transfer(address(0), 1);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0)));
        token.transfer(address(0), 0);
        assertEq(token.balanceOf(address(this)), SUPPLY);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function test_RevertWhenTransferFromToZeroRestoresAllowance() public {
        token.approve(spender, 1);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0)));
        vm.prank(spender);
        token.transferFrom(address(this), address(0), 1);
        assertEq(token.allowance(address(this), spender), 1);
        assertEq(token.balanceOf(address(this)), SUPPLY);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function test_RevertWhenApproveZeroSpender() public {
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidSpender.selector, address(0)));
        token.approve(address(0), 1);
        assertEq(token.allowance(address(this), address(0)), 0);
    }

    function test_NoPostDeploymentMintBurnOrAdminEntryPoints() public {
        token.transfer(alice, 100e18);
        bytes[] memory calls = new bytes[](12);
        calls[0] = abi.encodeWithSignature("mint(address,uint256)", alice, SUPPLY);
        calls[1] = abi.encodeWithSignature("mint(uint256)", SUPPLY);
        calls[2] = abi.encodeWithSignature("mint()");
        calls[3] = abi.encodeWithSignature("burn(uint256)", 1);
        calls[4] = abi.encodeWithSignature("burnFrom(address,uint256)", alice, 1);
        calls[5] = abi.encodeWithSignature("pause()");
        calls[6] = abi.encodeWithSignature("blacklist(address)", alice);
        calls[7] = abi.encodeWithSignature("freeze(address)", alice);
        calls[8] = abi.encodeWithSignature("seize(address)", alice);
        calls[9] = abi.encodeWithSignature("transferOwnership(address)", alice);
        calls[10] = abi.encodeWithSignature("upgradeTo(address)", alice);
        calls[11] = abi.encodeWithSignature("initialize(address)", alice);

        for (uint256 i; i < calls.length; ++i) {
            (bool deployerSuccess,) = address(token).call(calls[i]);
            assertFalse(deployerSuccess);
            vm.prank(alice);
            (bool holderSuccess,) = address(token).call(calls[i]);
            assertFalse(holderSuccess);
        }
        assertEq(token.totalSupply(), SUPPLY);
        assertEq(token.balanceOf(alice), 100e18);
        vm.prank(alice);
        assertTrue(token.transfer(bob, 100e18));
        assertEq(token.balanceOf(bob), 100e18);
    }

    function testFuzz_TransferConservesSupply(address recipient, uint256 amount) public {
        vm.assume(recipient != address(0) && recipient != address(this));
        amount = bound(amount, 0, SUPPLY);
        assertTrue(token.transfer(recipient, amount));
        assertEq(token.balanceOf(recipient), amount);
        assertEq(token.balanceOf(address(this)), SUPPLY - amount);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function testFuzz_TransferFromConservesSupplyAndSpendsAllowance(uint256 approved, uint256 amount) public {
        approved = bound(approved, 0, SUPPLY);
        amount = bound(amount, 0, approved);
        token.approve(spender, approved);
        vm.prank(spender);
        assertTrue(token.transferFrom(address(this), alice, amount));
        assertEq(token.balanceOf(address(this)), SUPPLY - amount);
        assertEq(token.balanceOf(alice), amount);
        assertEq(token.allowance(address(this), spender), approved - amount);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function testFuzz_RevertOnOverdraw(uint256 amount) public {
        amount = bound(amount, SUPPLY + 1, type(uint256).max);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, address(this), SUPPLY, amount)
        );
        token.transfer(alice, amount);
        assertEq(token.balanceOf(address(this)), SUPPLY);
        assertEq(token.balanceOf(alice), 0);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function testFuzz_RevertOnAllowanceOverdraw(uint256 approved, uint256 amount) public {
        approved = bound(approved, 0, SUPPLY - 1);
        amount = bound(amount, approved + 1, SUPPLY);
        token.approve(spender, approved);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, spender, approved, amount)
        );
        vm.prank(spender);
        token.transferFrom(address(this), alice, amount);
        assertEq(token.allowance(address(this), spender), approved);
        assertEq(token.balanceOf(address(this)), SUPPLY);
        assertEq(token.balanceOf(alice), 0);
    }
}
