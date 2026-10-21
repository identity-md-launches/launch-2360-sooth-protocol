// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {SoothToken} from "../src/SoothToken.sol";

/// @dev Drives the token from a growing set of holders, including the token contract itself, and
/// mixes rejected calls (zero receiver, zero spender, zero sender, overdrawn allowance) into the
/// sequence. Every rejected call must revert with the exact error and change nothing.
contract OpenSoothHandler is Test {
    SoothToken public immutable token;
    address[] public holders;
    mapping(address => bool) public known;
    mapping(address => uint256) public expectedBalance;
    mapping(address => mapping(address => uint256)) public expectedAllowance;
    uint256 public rejected;

    constructor(SoothToken token_, address seedHolder) {
        token = token_;
        _track(seedHolder);
        _track(address(token_));
        expectedBalance[seedHolder] = token_.totalSupply();
    }

    function holderCount() external view returns (uint256) {
        return holders.length;
    }

    function _track(address who) internal {
        if (!known[who]) {
            known[who] = true;
            holders.push(who);
        }
    }

    function _pick(uint256 seed) internal view returns (address) {
        return holders[seed % holders.length];
    }

    function _recipient(uint256 seed, address fresh) internal returns (address to) {
        if (fresh != address(0) && fresh != address(this) && seed % 4 == 0 && holders.length < 24) {
            to = fresh;
        } else {
            to = _pick(seed);
        }
        _track(to);
    }

    function transfer(uint256 fromSeed, uint256 toSeed, address fresh, uint256 amount) external {
        address from = _pick(fromSeed);
        address to = _recipient(toSeed, fresh);
        amount = bound(amount, 0, expectedBalance[from]);
        vm.prank(from);
        assertTrue(token.transfer(to, amount));
        expectedBalance[from] -= amount;
        expectedBalance[to] += amount;
    }

    function approve(uint256 ownerSeed, uint256 spenderSeed, address fresh, uint256 amount) external {
        address owner = _pick(ownerSeed);
        address spender = _recipient(spenderSeed, fresh);
        vm.prank(owner);
        assertTrue(token.approve(spender, amount));
        expectedAllowance[owner][spender] = amount;
    }

    function transferFrom(uint256 ownerSeed, uint256 spenderSeed, uint256 toSeed, address fresh, uint256 amount)
        external
    {
        address owner = _pick(ownerSeed);
        address spender = _pick(spenderSeed);
        address to = _recipient(toSeed, fresh);
        uint256 approved = expectedAllowance[owner][spender];
        uint256 maximum = expectedBalance[owner] < approved ? expectedBalance[owner] : approved;
        amount = bound(amount, 0, maximum);
        vm.prank(spender);
        assertTrue(token.transferFrom(owner, to, amount));
        expectedBalance[owner] -= amount;
        expectedBalance[to] += amount;
        if (approved != type(uint256).max) expectedAllowance[owner][spender] -= amount;
    }

    function rejectZeroReceiver(uint256 fromSeed, uint256 amount) external {
        address from = _pick(fromSeed);
        amount = bound(amount, 0, expectedBalance[from]);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0)));
        vm.prank(from);
        token.transfer(address(0), amount);
        ++rejected;
    }

    function rejectZeroSpender(uint256 ownerSeed, uint256 amount) external {
        address owner = _pick(ownerSeed);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidSpender.selector, address(0)));
        vm.prank(owner);
        token.approve(address(0), amount);
        ++rejected;
    }

    function rejectZeroSender(uint256 spenderSeed, uint256 toSeed) external {
        address spender = _pick(spenderSeed);
        address to = _pick(toSeed);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidApprover.selector, address(0)));
        vm.prank(spender);
        token.transferFrom(address(0), to, 0);
        ++rejected;
    }

    function rejectAllowanceOverdraw(uint256 ownerSeed, uint256 spenderSeed, uint256 toSeed, uint256 excess) external {
        address owner = _pick(ownerSeed);
        address spender = _pick(spenderSeed);
        address to = _pick(toSeed);
        uint256 approved = expectedAllowance[owner][spender];
        if (approved == type(uint256).max) return;
        uint256 amount = approved + bound(excess, 1, type(uint256).max - approved);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, spender, approved, amount)
        );
        vm.prank(spender);
        token.transferFrom(owner, to, amount);
        ++rejected;
    }
}

contract SoothTokenOpenInvariantTest is Test {
    uint256 internal constant SUPPLY = 1_000_000_000 * 10 ** 18;

    SoothToken internal token;
    OpenSoothHandler internal handler;
    address internal deployer;

    function setUp() public {
        deployer = makeAddr("deployer");
        vm.prank(deployer);
        token = new SoothToken();
        handler = new OpenSoothHandler(token, deployer);

        bytes4[] memory selectors = new bytes4[](7);
        selectors[0] = handler.transfer.selector;
        selectors[1] = handler.approve.selector;
        selectors[2] = handler.transferFrom.selector;
        selectors[3] = handler.rejectZeroReceiver.selector;
        selectors[4] = handler.rejectZeroSpender.selector;
        selectors[5] = handler.rejectZeroSender.selector;
        selectors[6] = handler.rejectAllowanceOverdraw.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
        targetContract(address(handler));
    }

    /// forge-config: default.invariant.runs = 256
    /// forge-config: default.invariant.depth = 64
    function invariant_SupplyFixedAndHeldOnlyByTrackedHolders() public view {
        assertEq(token.totalSupply(), SUPPLY);
        uint256 sum;
        uint256 count = handler.holderCount();
        for (uint256 i; i < count; ++i) {
            sum += token.balanceOf(handler.holders(i));
        }
        assertEq(sum, SUPPLY, "value appeared outside the tracked holders");
        assertEq(token.balanceOf(address(0)), 0);
        assertEq(token.balanceOf(address(handler)), 0);
    }

    /// forge-config: default.invariant.runs = 256
    /// forge-config: default.invariant.depth = 64
    function invariant_StateMatchesModel() public view {
        uint256 count = handler.holderCount();
        for (uint256 i; i < count; ++i) {
            address a = handler.holders(i);
            assertEq(token.balanceOf(a), handler.expectedBalance(a));
            for (uint256 j; j < count; ++j) {
                address b = handler.holders(j);
                assertEq(token.allowance(a, b), handler.expectedAllowance(a, b));
            }
            assertEq(token.allowance(a, address(0)), 0);
        }
    }

    /// forge-config: default.invariant.runs = 256
    /// forge-config: default.invariant.depth = 64
    function invariant_MetadataNeverChanges() public view {
        assertEq(token.name(), "Sooth Protocol");
        assertEq(token.symbol(), "SOOTH");
        assertEq(token.decimals(), 18);
        assertEq(token.INITIAL_SUPPLY(), SUPPLY);
    }
}
