// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {MyToken} from "../src/MyToken.sol";

/// @dev MyToken's _mint and _burn are internal. This exposes them so they can be tested.
contract TokenHarness is MyToken {
    constructor(string memory n, string memory s, uint256 supply) MyToken(n, s, supply) {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function burn(address from, uint256 amount) external {
        _burn(from, amount);
    }
}

/// @dev Drives random transfers, approvals, spends, mints and burns for the invariant tests.
contract TokenHandler is Test {
    TokenHarness public token;
    address[] public actors;
    uint256 public constant INITIAL = 1_000_000 ether;
    uint256 public ghostMinted;
    uint256 public ghostBurned;

    constructor() {
        token = new TokenHarness("Handler Token", "HTK", INITIAL);
        for (uint256 i = 0; i < 3; i++) {
            address actor = makeAddr(string.concat("tokenActor", vm.toString(i)));
            actors.push(actor);
            token.transfer(actor, 100_000 ether);
        }
    }

    function transferTokens(uint256 fromSeed, uint256 toSeed, uint256 amount) external {
        address from = actors[fromSeed % actors.length];
        address to = actors[toSeed % actors.length];
        amount = bound(amount, 0, token.balanceOf(from));
        vm.prank(from);
        token.transfer(to, amount);
    }

    function approveSpender(uint256 ownerSeed, uint256 spenderSeed, uint256 amount, bool useMax) external {
        address owner = actors[ownerSeed % actors.length];
        address spender = actors[spenderSeed % actors.length];
        amount = useMax ? type(uint256).max : bound(amount, 0, 1_000_000 ether);
        vm.prank(owner);
        token.approve(spender, amount);
    }

    function spendAllowance(uint256 spenderSeed, uint256 ownerSeed, uint256 toSeed, uint256 amount) external {
        address spender = actors[spenderSeed % actors.length];
        address owner = actors[ownerSeed % actors.length];
        address to = actors[toSeed % actors.length];
        amount = bound(amount, 0, token.balanceOf(owner));
        vm.prank(spender);
        try token.transferFrom(owner, to, amount) {} catch {}
    }

    function mint(uint256 toSeed, uint256 amount) external {
        amount = bound(amount, 1, 1000 ether);
        token.mint(actors[toSeed % actors.length], amount);
        ghostMinted += amount;
    }

    function burn(uint256 fromSeed, uint256 amount) external {
        address from = actors[fromSeed % actors.length];
        uint256 balance = token.balanceOf(from);
        if (balance == 0) return;
        amount = bound(amount, 1, balance);
        token.burn(from, amount);
        ghostBurned += amount;
    }

    function sumOfBalances() external view returns (uint256 sum) {
        sum = token.balanceOf(address(this)); // the handler holds the rest of the initial supply
        for (uint256 i = 0; i < actors.length; i++) {
            sum += token.balanceOf(actors[i]);
        }
    }
}

contract MyTokenTest is Test {
    TokenHarness token;
    TokenHandler handler;

    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address carol = makeAddr("carol");

    uint256 constant SUPPLY = 1_000_000 ether;

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);

    function setUp() public {
        token = new TokenHarness("My Token", "MTK", SUPPLY); // this test contract holds the whole supply
        token.transfer(alice, 1000 ether);

        handler = new TokenHandler();
        targetContract(address(handler));
    }

    // constructor and metadata

    function test_constructor_setsMetadata() public view {
        assertEq(token.name(), "My Token");
        assertEq(token.symbol(), "MTK");
        assertEq(token.decimals(), 18);
    }

    function test_constructor_mintsWholeSupplyToDeployer() public {
        MyToken fresh = new MyToken("Fresh", "FRS", 500 ether);

        assertEq(fresh.totalSupply(), 500 ether);
        assertEq(fresh.balanceOf(address(this)), 500 ether);
    }

    function test_constructor_emitsMintTransfer() public {
        vm.expectEmit(true, true, false, true);
        emit Transfer(address(0), address(this), 500 ether);
        new MyToken("Fresh", "FRS", 500 ether);
    }

    function test_constructor_allowsZeroInitialSupply() public {
        MyToken empty = new MyToken("Empty", "EMP", 0);
        assertEq(empty.totalSupply(), 0);
    }

    // transfer

    function test_transfer_movesBalance() public {
        vm.prank(alice);
        bool ok = token.transfer(bob, 400 ether);

        assertTrue(ok);
        assertEq(token.balanceOf(alice), 600 ether);
        assertEq(token.balanceOf(bob), 400 ether);
    }

    function test_transfer_doesNotChangeTotalSupply() public {
        vm.prank(alice);
        token.transfer(bob, 400 ether);

        assertEq(token.totalSupply(), SUPPLY);
    }

    function test_transfer_emitsEvent() public {
        vm.expectEmit(true, true, false, true);
        emit Transfer(alice, bob, 400 ether);
        vm.prank(alice);
        token.transfer(bob, 400 ether);
    }

    function test_transfer_wholeBalanceIsAllowed() public {
        vm.prank(alice);
        token.transfer(bob, 1000 ether);

        assertEq(token.balanceOf(alice), 0);
        assertEq(token.balanceOf(bob), 1000 ether);
    }

    function test_transfer_zeroAmountIsAllowed() public {
        vm.expectEmit(true, true, false, true);
        emit Transfer(alice, bob, 0);
        vm.prank(alice);
        token.transfer(bob, 0);

        assertEq(token.balanceOf(alice), 1000 ether);
    }

    function test_transfer_toSelfKeepsBalance() public {
        vm.prank(alice);
        token.transfer(alice, 400 ether);

        assertEq(token.balanceOf(alice), 1000 ether);
    }

    function test_transfer_revertsAboveBalance() public {
        vm.prank(alice);
        vm.expectRevert(MyToken.InsufficientBalance.selector);
        token.transfer(bob, 1000 ether + 1);
    }

    function test_transfer_revertsForSenderWithNothing() public {
        vm.prank(bob);
        vm.expectRevert(MyToken.InsufficientBalance.selector);
        token.transfer(alice, 1);
    }

    function test_transfer_revertsToZeroAddress() public {
        vm.prank(alice);
        vm.expectRevert(MyToken.ZeroAddress.selector);
        token.transfer(address(0), 1 ether);
    }

    // approve

    function test_approve_setsAllowance() public {
        vm.prank(alice);
        bool ok = token.approve(bob, 50 ether);

        assertTrue(ok);
        assertEq(token.allowance(alice, bob), 50 ether);
    }

    function test_approve_emitsEvent() public {
        vm.expectEmit(true, true, false, true);
        emit Approval(alice, bob, 50 ether);
        vm.prank(alice);
        token.approve(bob, 50 ether);
    }

    function test_approve_setsAndDoesNotAdd() public {
        vm.startPrank(alice);
        token.approve(bob, 50 ether);
        token.approve(bob, 30 ether);
        vm.stopPrank();

        assertEq(token.allowance(alice, bob), 30 ether); // not 80
    }

    function test_approve_canResetToZero() public {
        vm.startPrank(alice);
        token.approve(bob, 50 ether);
        token.approve(bob, 0);
        vm.stopPrank();

        assertEq(token.allowance(alice, bob), 0);
    }

    function test_approve_doesNotMoveTokens() public {
        vm.prank(alice);
        token.approve(bob, 50 ether);

        assertEq(token.balanceOf(alice), 1000 ether);
        assertEq(token.balanceOf(bob), 0);
    }

    function test_approve_isPerSpender() public {
        vm.startPrank(alice);
        token.approve(bob, 50 ether);
        token.approve(carol, 10 ether);
        vm.stopPrank();

        assertEq(token.allowance(alice, bob), 50 ether);
        assertEq(token.allowance(alice, carol), 10 ether);
        assertEq(token.allowance(bob, alice), 0); // the reverse direction is separate
    }

    // transferFrom

    function test_transferFrom_movesTokensAndSpendsAllowance() public {
        vm.prank(alice);
        token.approve(bob, 50 ether);

        vm.prank(bob); // bob is msg.sender and the spender
        bool ok = token.transferFrom(alice, carol, 20 ether);

        assertTrue(ok);
        assertEq(token.balanceOf(alice), 980 ether);
        assertEq(token.balanceOf(carol), 20 ether);
        assertEq(token.balanceOf(bob), 0); // the spender received nothing
        assertEq(token.allowance(alice, bob), 30 ether);
    }

    function test_transferFrom_emitsTransferFromOwner() public {
        vm.prank(alice);
        token.approve(bob, 50 ether);

        vm.expectEmit(true, true, false, true);
        emit Transfer(alice, carol, 20 ether);
        vm.prank(bob);
        token.transferFrom(alice, carol, 20 ether);
    }

    function test_transferFrom_canSpendTheWholeAllowance() public {
        vm.prank(alice);
        token.approve(bob, 50 ether);

        vm.prank(bob);
        token.transferFrom(alice, carol, 50 ether);

        assertEq(token.allowance(alice, bob), 0);
    }

    function test_transferFrom_revertsOnceAllowanceIsUsedUp() public {
        vm.prank(alice);
        token.approve(bob, 50 ether);
        vm.startPrank(bob);
        token.transferFrom(alice, carol, 50 ether);

        vm.expectRevert(MyToken.InsufficientAllowance.selector);
        token.transferFrom(alice, carol, 1);
        vm.stopPrank();
    }

    function test_transferFrom_revertsAboveAllowance() public {
        vm.prank(alice);
        token.approve(bob, 50 ether);

        vm.prank(bob);
        vm.expectRevert(MyToken.InsufficientAllowance.selector);
        token.transferFrom(alice, carol, 50 ether + 1);
    }

    function test_transferFrom_revertsForSomeoneNotApproved() public {
        vm.prank(alice);
        token.approve(bob, 50 ether);

        // carol reads allowance[alice][carol], which is zero
        vm.prank(carol);
        vm.expectRevert(MyToken.InsufficientAllowance.selector);
        token.transferFrom(alice, carol, 10 ether);
    }

    function test_transferFrom_ownerNeedsAllowanceForTheirOwnTokensToo() public {
        // transfer moves your own tokens. transferFrom always checks allowance, even for the owner.
        vm.prank(alice);
        vm.expectRevert(MyToken.InsufficientAllowance.selector);
        token.transferFrom(alice, bob, 1 ether);
    }

    function test_transferFrom_revertsWhenOwnerBalanceIsTooLow() public {
        vm.prank(alice);
        token.approve(bob, 5000 ether); // allowance is larger than the balance

        vm.prank(bob);
        vm.expectRevert(MyToken.InsufficientBalance.selector);
        token.transferFrom(alice, carol, 1000 ether + 1);
    }

    function test_transferFrom_failedCallKeepsAllowanceUnchanged() public {
        vm.prank(alice);
        token.approve(bob, 5000 ether);

        vm.prank(bob);
        vm.expectRevert(MyToken.InsufficientBalance.selector);
        token.transferFrom(alice, carol, 2000 ether);

        assertEq(token.allowance(alice, bob), 5000 ether); // the revert undid the allowance change
    }

    function test_transferFrom_revertsToZeroAddress() public {
        vm.prank(alice);
        token.approve(bob, 50 ether);

        vm.prank(bob);
        vm.expectRevert(MyToken.ZeroAddress.selector);
        token.transferFrom(alice, address(0), 10 ether);
    }

    function test_transferFrom_maxAllowanceIsNeverReduced() public {
        vm.prank(alice);
        token.approve(bob, type(uint256).max);

        vm.startPrank(bob);
        token.transferFrom(alice, carol, 100 ether);
        token.transferFrom(alice, carol, 200 ether);
        vm.stopPrank();

        assertEq(token.allowance(alice, bob), type(uint256).max);
        assertEq(token.balanceOf(carol), 300 ether);
    }

    function test_transferFrom_maxAllowanceStillCannotOverspendBalance() public {
        vm.prank(alice);
        token.approve(bob, type(uint256).max);

        vm.prank(bob);
        vm.expectRevert(MyToken.InsufficientBalance.selector);
        token.transferFrom(alice, carol, 1000 ether + 1);
    }

    function test_approveRace_documentedWeakness() public {
        // Alice lowers bob's allowance from 50 to 30. Bob sees it coming and spends 50 first.
        // Then the new allowance of 30 lands and he spends that too. Total taken: 80.
        vm.prank(alice);
        token.approve(bob, 50 ether);

        vm.prank(bob);
        token.transferFrom(alice, bob, 50 ether); // bob front-runs

        vm.prank(alice);
        token.approve(bob, 30 ether); // alice's change lands afterwards

        vm.prank(bob);
        token.transferFrom(alice, bob, 30 ether);

        assertEq(token.balanceOf(bob), 80 ether);
    }

    function test_approveRace_resettingToZeroFirstGivesTheSpenderASignal() public {
        // The standard mitigation is to approve 0 first and only then the new value.
        vm.startPrank(alice);
        token.approve(bob, 50 ether);
        token.approve(bob, 0);
        vm.stopPrank();

        vm.prank(bob);
        vm.expectRevert(MyToken.InsufficientAllowance.selector);
        token.transferFrom(alice, bob, 1);
    }

    // internal _mint and _burn (through the harness)

    function test_mint_increasesSupplyAndBalanceAndEmits() public {
        vm.expectEmit(true, true, false, true);
        emit Transfer(address(0), bob, 25 ether);
        token.mint(bob, 25 ether);

        assertEq(token.balanceOf(bob), 25 ether);
        assertEq(token.totalSupply(), SUPPLY + 25 ether);
    }

    function test_mint_revertsToZeroAddress() public {
        vm.expectRevert(MyToken.ZeroAddress.selector);
        token.mint(address(0), 1 ether);
    }

    function test_burn_decreasesSupplyAndBalanceAndEmits() public {
        vm.expectEmit(true, true, false, true);
        emit Transfer(alice, address(0), 400 ether);
        token.burn(alice, 400 ether);

        assertEq(token.balanceOf(alice), 600 ether);
        assertEq(token.totalSupply(), SUPPLY - 400 ether);
    }

    function test_burn_revertsAboveBalance() public {
        vm.expectRevert(MyToken.InsufficientBalance.selector);
        token.burn(alice, 1000 ether + 1);
    }

    // fuzz tests

    function testFuzz_transferConservesTotal(uint256 amount) public {
        amount = bound(amount, 0, 1000 ether);

        vm.prank(alice);
        token.transfer(bob, amount);

        assertEq(token.balanceOf(alice) + token.balanceOf(bob), 1000 ether);
        assertEq(token.balanceOf(bob), amount);
    }

    function testFuzz_transferAboveBalanceAlwaysReverts(uint256 extra) public {
        extra = bound(extra, 1, type(uint128).max);

        vm.prank(alice);
        vm.expectRevert(MyToken.InsufficientBalance.selector);
        token.transfer(bob, 1000 ether + extra);
    }

    function testFuzz_approveOverwritesAnyPreviousValue(uint256 first, uint256 second) public {
        vm.startPrank(alice);
        token.approve(bob, first);
        token.approve(bob, second);
        vm.stopPrank();

        assertEq(token.allowance(alice, bob), second);
    }

    function testFuzz_transferFromReducesAllowanceByExactlyTheAmount(uint256 allowed, uint256 spent) public {
        allowed = bound(allowed, 0, 1000 ether);
        spent = bound(spent, 0, allowed);

        vm.prank(alice);
        token.approve(bob, allowed);
        vm.prank(bob);
        token.transferFrom(alice, carol, spent);

        assertEq(token.allowance(alice, bob), allowed - spent);
        assertEq(token.balanceOf(carol), spent);
    }

    function testFuzz_transferFromAboveAllowanceReverts(uint256 allowed, uint256 extra) public {
        allowed = bound(allowed, 0, 1000 ether - 1);
        extra = bound(extra, 1, 1000 ether - allowed);

        vm.prank(alice);
        token.approve(bob, allowed);
        vm.prank(bob);
        vm.expectRevert(MyToken.InsufficientAllowance.selector);
        token.transferFrom(alice, carol, allowed + extra);
    }

    // invariants (run against the handler's own token)

    function invariant_balancesAddUpToTotalSupply() public view {
        assertEq(handler.sumOfBalances(), handler.token().totalSupply());
    }

    function invariant_totalSupplyEqualsInitialPlusMintedMinusBurned() public view {
        assertEq(
            handler.token().totalSupply(), handler.INITIAL() + handler.ghostMinted() - handler.ghostBurned()
        );
    }
}
