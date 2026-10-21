// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {SoothToken} from "../src/SoothToken.sol";

/// @dev Deploys the token and performs the launch distribution inside a single constructor, i.e. one
/// transaction, the way a factory's launch call does. Records what each step observed.
contract OneTransactionLaunch {
    SoothToken public immutable token;
    uint256 public immutable heldAfterDeploy;
    uint256 public immutable heldAfterDistribution;

    constructor(bytes32 salt, address distributor, address pool, address remainder) {
        SoothToken deployed = new SoothToken{salt: salt}();
        token = deployed;
        heldAfterDeploy = deployed.balanceOf(address(this));
        uint256 supply = deployed.totalSupply();
        require(deployed.transfer(distributor, supply / 10), "swarm transfer failed");
        require(deployed.transfer(pool, supply / 2), "pool transfer failed");
        require(deployed.transfer(remainder, deployed.balanceOf(address(this))), "remainder transfer failed");
        heldAfterDistribution = deployed.balanceOf(address(this));
    }
}

contract SoothTokenEdgesTest is Test {
    uint256 internal constant SUPPLY = 1_000_000_000 * 10 ** 18;

    SoothToken internal token;
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal spender = makeAddr("spender");

    function setUp() public {
        token = new SoothToken();
    }

    // ---------------------------------------------------------------- launch shape

    function test_OneTransactionLaunchDistributesExactly() public {
        address distributor = makeAddr("distributor");
        address pool = makeAddr("pool");
        address remainder = makeAddr("remainder");
        OneTransactionLaunch launch = new OneTransactionLaunch(bytes32(uint256(7)), distributor, pool, remainder);
        SoothToken launched = launch.token();

        assertEq(launch.heldAfterDeploy(), SUPPLY);
        assertEq(launch.heldAfterDistribution(), 0);
        assertEq(launched.balanceOf(distributor), SUPPLY / 10);
        assertEq(launched.balanceOf(pool), SUPPLY / 2);
        assertEq(launched.balanceOf(remainder), SUPPLY - SUPPLY / 10 - SUPPLY / 2);
        assertEq(launched.totalSupply(), SUPPLY);
        // The deploying EOA/test never touched the supply.
        assertEq(launched.balanceOf(address(this)), 0);
        assertEq(launched.balanceOf(tx.origin), 0);
    }

    function test_IndependentLaunchesAreIndependentTokens() public {
        address distributor = makeAddr("distributor");
        OneTransactionLaunch first =
            new OneTransactionLaunch(bytes32(uint256(1)), distributor, distributor, distributor);
        OneTransactionLaunch second = new OneTransactionLaunch(bytes32(uint256(1)), alice, alice, alice);
        assertTrue(address(first.token()) != address(second.token()));
        assertEq(first.token().totalSupply(), SUPPLY);
        assertEq(first.token().balanceOf(distributor), SUPPLY);
        assertEq(first.token().balanceOf(alice), 0);
        assertEq(second.token().totalSupply(), SUPPLY);
        assertEq(second.token().balanceOf(alice), SUPPLY);
    }

    function test_DeployingAgainstAnExistingAddressFails() public {
        Create2Deployer deployer = new Create2Deployer();
        deployer.deploy(bytes32(uint256(42)));
        vm.expectRevert();
        deployer.deploy(bytes32(uint256(42)));
    }

    function test_RuntimeHasNoDelegatecallCallcodeOrSelfdestruct() public view {
        bytes memory runtime = address(token).code;
        assertGt(runtime.length, 0);
        assertLe(runtime.length, 24_576);
        bool reachable = true;
        for (uint256 i; i < runtime.length; ++i) {
            uint8 op = uint8(runtime[i]);
            if (op == 0x5B) reachable = true;
            if (op >= 0x60 && op <= 0x7F) {
                i += op - 0x5F;
                continue;
            }
            if (reachable) {
                assertTrue(op != 0xF4, "DELEGATECALL");
                assertTrue(op != 0xF2, "CALLCODE");
                assertTrue(op != 0xFF, "SELFDESTRUCT");
            }
            if (op == 0x00 || op == 0x56 || op == 0xF3 || op == 0xFD || op == 0xFE || op == 0xFF) reachable = false;
        }
    }

    // ---------------------------------------------------------------- ABI conformance

    function test_TransferAndApproveReturnAbiEncodedTrue() public {
        (bool ok, bytes memory ret) = address(token).call(abi.encodeCall(token.transfer, (alice, 1)));
        assertTrue(ok);
        assertEq(ret.length, 32);
        assertEq(abi.decode(ret, (uint256)), 1);

        (ok, ret) = address(token).call(abi.encodeCall(token.approve, (spender, 1)));
        assertTrue(ok);
        assertEq(ret.length, 32);
        assertEq(abi.decode(ret, (uint256)), 1);

        vm.prank(spender);
        (ok, ret) = address(token).call(abi.encodeCall(token.transferFrom, (address(this), bob, 1)));
        assertTrue(ok);
        assertEq(ret.length, 32);
        assertEq(abi.decode(ret, (uint256)), 1);
    }

    function test_RejectsEtherAndUnknownSelectors() public {
        vm.deal(alice, 1 ether);
        vm.prank(alice);
        (bool ok,) = address(token).call{value: 1}("");
        assertFalse(ok);
        vm.prank(alice);
        (ok,) = address(token).call{value: 1}(abi.encodeCall(token.transfer, (bob, 0)));
        assertFalse(ok, "non-payable transfer accepted ether");
        (ok,) = address(token).call(hex"deadbeef");
        assertFalse(ok);
        assertEq(address(token).balance, 0);
    }

    function test_TruncatedCalldataReverts() public {
        // transfer(address,uint256) with the amount word missing.
        (bool ok,) = address(token).call(abi.encodePacked(token.transfer.selector, abi.encode(alice)));
        assertFalse(ok);
        assertEq(token.balanceOf(alice), 0);
    }

    // ---------------------------------------------------------------- failure paths

    function test_RevertWhenTransferFromZeroSender() public {
        // Zero allowance covers a zero amount; OZ v5 then rewrites the allowance, so the approver check stops it.
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidApprover.selector, address(0)));
        vm.prank(spender);
        token.transferFrom(address(0), alice, 0);
    }

    function test_RevertWhenEmptyAccountTransfersOneWei() public {
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, alice, 0, 1));
        vm.prank(alice);
        token.transfer(bob, 1);
    }

    function test_AllowanceOneBelowMaxIsFiniteAndDecrements() public {
        token.approve(spender, type(uint256).max - 1);
        vm.prank(spender);
        token.transferFrom(address(this), alice, 1);
        assertEq(token.allowance(address(this), spender), type(uint256).max - 2);
    }

    function test_AllowanceIsPerSpenderAndPerOwner() public {
        token.transfer(alice, 10);
        token.approve(spender, 5);
        // An allowance from this holder does not let the spender move alice's tokens.
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, spender, 0, 1));
        vm.prank(spender);
        token.transferFrom(alice, bob, 1);
        // And it does not let bob spend on spender's behalf.
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, bob, 0, 1));
        vm.prank(bob);
        token.transferFrom(address(this), bob, 1);
        assertEq(token.allowance(address(this), spender), 5);
        assertEq(token.balanceOf(alice), 10);
    }

    function test_SecondSpendAfterExhaustionReverts() public {
        token.approve(spender, 3);
        vm.prank(spender);
        token.transferFrom(address(this), alice, 3);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, spender, 0, 1));
        vm.prank(spender);
        token.transferFrom(address(this), alice, 1);
        assertEq(token.balanceOf(alice), 3);
    }

    function test_TokensSentToTheTokenContractAreStuck() public {
        token.transfer(address(token), 1e18);
        assertEq(token.balanceOf(address(token)), 1e18);
        // No rescue path: the contract never approves anyone, so nothing can pull them out.
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, address(this), 0, 1));
        token.transferFrom(address(token), address(this), 1);
        assertEq(token.totalSupply(), SUPPLY);
    }

    // ---------------------------------------------------------------- properties

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_TransferBetweenHoldersConserves(uint256 seed, uint256 amount, address from, address to) public {
        from = address(uint160(bound(uint160(from), 1, type(uint160).max)));
        to = address(uint160(bound(uint160(to), 1, type(uint160).max)));
        uint256 funded = bound(seed, 0, SUPPLY);
        if (from != address(this)) token.transfer(from, funded);
        else funded = SUPPLY;
        uint256 fromBefore = token.balanceOf(from);
        uint256 toBefore = token.balanceOf(to);
        amount = bound(amount, 0, fromBefore);

        vm.prank(from);
        assertTrue(token.transfer(to, amount));

        if (from == to) {
            assertEq(token.balanceOf(from), fromBefore);
        } else {
            assertEq(token.balanceOf(from), fromBefore - amount);
            assertEq(token.balanceOf(to), toBefore + amount);
        }
        assertEq(token.totalSupply(), SUPPLY);
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_ApproveOverwritesRegardlessOfPrevious(uint256 first, uint256 second) public {
        token.approve(spender, first);
        assertEq(token.allowance(address(this), spender), first);
        token.approve(spender, second);
        assertEq(token.allowance(address(this), spender), second);
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_HolderOverdrawRevertsWithExactError(uint256 held, uint256 amount) public {
        held = bound(held, 0, SUPPLY - 1);
        amount = bound(amount, held + 1, type(uint256).max);
        token.transfer(alice, held);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, alice, held, amount));
        vm.prank(alice);
        token.transfer(bob, amount);
        assertEq(token.balanceOf(alice), held);
        assertEq(token.balanceOf(bob), 0);
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_TransferFromBalanceShortfallKeepsAllowance(uint256 held, uint256 approved, uint256 amount)
        public
    {
        held = bound(held, 0, SUPPLY - 1);
        amount = bound(amount, held + 1, SUPPLY);
        approved = bound(approved, amount, type(uint256).max);
        token.transfer(alice, held);
        vm.prank(alice);
        token.approve(spender, approved);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, alice, held, amount));
        vm.prank(spender);
        token.transferFrom(alice, bob, amount);
        assertEq(token.allowance(alice, spender), approved);
        assertEq(token.balanceOf(alice), held);
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_StrangerCannotMoveAHoldersTokens(address stranger, uint256 amount) public {
        vm.assume(stranger != address(this));
        amount = bound(amount, 1, SUPPLY);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, stranger, 0, amount));
        vm.prank(stranger);
        token.transferFrom(address(this), stranger, amount);
        assertEq(token.balanceOf(address(this)), SUPPLY);
    }
}

contract Create2Deployer {
    function deploy(bytes32 salt) external returns (SoothToken) {
        return new SoothToken{salt: salt}();
    }
}
