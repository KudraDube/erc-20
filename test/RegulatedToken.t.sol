// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {ERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {RegulatedToken} from "../src/RegulatedToken.sol";

/// @dev Stands in for a FUTURE function that calls _mint directly. The cap must still hold.
contract RegulatedHarness is RegulatedToken {
    constructor(string memory n, string memory s, uint256 cap_, address admin) RegulatedToken(n, s, cap_, admin) {}

    function unsafeMint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function unsafeBurn(address from, uint256 amount) external {
        _burn(from, amount);
    }
}

/// @dev Drives random mints, burns, transfers, pauses and blacklisting for the invariant tests.
contract RegulatedHandler is Test {
    RegulatedHarness public token;
    address[] public actors;
    uint256 public constant CAP = 10_000 ether;

    constructor() {
        token = new RegulatedHarness("Handler", "HND", CAP, address(this)); // the handler holds every role
        for (uint256 i = 0; i < 3; i++) {
            actors.push(makeAddr(string.concat("regActor", vm.toString(i))));
        }
    }

    function mint(uint256 toSeed, uint256 amount) external {
        amount = bound(amount, 1, 3000 ether); // often large enough to hit the cap
        try token.unsafeMint(actors[toSeed % actors.length], amount) {} catch {}
    }

    function burn(uint256 fromSeed, uint256 amount) external {
        address from = actors[fromSeed % actors.length];
        uint256 balance = token.balanceOf(from);
        if (balance == 0) return;
        amount = bound(amount, 1, balance);
        try token.unsafeBurn(from, amount) {} catch {}
    }

    function transferTokens(uint256 fromSeed, uint256 toSeed, uint256 amount) external {
        address from = actors[fromSeed % actors.length];
        address to = actors[toSeed % actors.length];
        amount = bound(amount, 0, token.balanceOf(from));
        vm.prank(from);
        try token.transfer(to, amount) {} catch {}
    }

    function togglePause() external {
        if (token.paused()) token.unpause();
        else token.pause();
    }

    function toggleBlacklist(uint256 seed) external {
        address account = actors[seed % actors.length];
        if (token.isBlacklisted(account)) token.unblacklist(account);
        else token.blacklist(account);
    }

    function sumOfBalances() external view returns (uint256 sum) {
        for (uint256 i = 0; i < actors.length; i++) {
            sum += token.balanceOf(actors[i]);
        }
    }
}

contract RegulatedTokenTest is Test {
    RegulatedToken token;
    RegulatedHarness harness;
    RegulatedHandler handler;

    address admin = address(this); // holds every role, as in the contract's constructor
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address carol = makeAddr("carol");

    uint256 constant CAP = 1_000_000 ether;

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Blacklisted(address indexed account);
    event Unblacklisted(address indexed account);

    function setUp() public {
        token = new RegulatedToken("Regulated ZAR", "rZAR", CAP, admin);
        harness = new RegulatedHarness("Regulated ZAR", "rZAR", CAP, admin);
        token.mint(alice, 1000 ether);
        harness.unsafeMint(alice, 1000 ether);

        handler = new RegulatedHandler();
        targetContract(address(handler));
    }

    function _unauthorized(address account, bytes32 role) internal pure returns (bytes memory) {
        return abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, account, role);
    }

    // constructor and metadata

    function test_constructor_setsMetadataAndCap() public view {
        assertEq(token.name(), "Regulated ZAR");
        assertEq(token.symbol(), "rZAR");
        assertEq(token.decimals(), 18);
        assertEq(token.cap(), CAP);
    }

    function test_constructor_adminHoldsEveryRole() public view {
        assertTrue(token.hasRole(token.DEFAULT_ADMIN_ROLE(), admin));
        assertTrue(token.hasRole(token.MINTER_ROLE(), admin));
        assertTrue(token.hasRole(token.PAUSER_ROLE(), admin));
        assertTrue(token.hasRole(token.COMPLIANCE_ROLE(), admin));
        assertFalse(token.hasRole(token.MINTER_ROLE(), alice));
    }

    function test_constructor_startsUnpausedWithNoBlacklist() public view {
        assertFalse(token.paused());
        assertFalse(token.isBlacklisted(alice));
    }

    function test_supportsInterface() public view {
        assertTrue(token.supportsInterface(0x7965db0b)); // AccessControl
        assertTrue(token.supportsInterface(0x01ffc9a7)); // ERC165
        assertFalse(token.supportsInterface(0xffffffff));
    }

    // mint and the cap

    function test_mint_creditsBalanceAndSupplyAndEmits() public {
        vm.expectEmit(true, true, false, true);
        emit Transfer(address(0), bob, 50 ether);
        token.mint(bob, 50 ether);

        assertEq(token.balanceOf(bob), 50 ether);
        assertEq(token.totalSupply(), 1050 ether);
    }

    function test_mint_onlyMinterRole() public {
        bytes32 role = token.MINTER_ROLE();
        vm.prank(bob);
        vm.expectRevert(_unauthorized(bob, role));
        token.mint(bob, 1 ether);
    }

    function test_mint_revertsToZeroAddress() public {
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0)));
        token.mint(address(0), 1 ether);
    }

    function test_cap_mintUpToTheCapIsAllowed() public {
        token.mint(bob, CAP - 1000 ether);

        assertEq(token.totalSupply(), CAP);
    }

    function test_cap_oneWeiOverTheCapReverts() public {
        // This is the check the old test could not make: it must fail by exactly one wei.
        uint256 room = CAP - token.totalSupply();

        vm.expectRevert(abi.encodeWithSelector(RegulatedToken.CapExceeded.selector, CAP + 1, CAP));
        token.mint(bob, room + 1);
    }

    function test_cap_failedMintLeavesSupplyUnchanged() public {
        uint256 room = CAP - token.totalSupply();

        vm.expectRevert();
        token.mint(bob, room + 1);

        assertEq(token.totalSupply(), 1000 ether);
        assertEq(token.balanceOf(bob), 0);
    }

    function test_cap_zeroCapMeansNothingCanBeMinted() public {
        RegulatedToken capped = new RegulatedToken("Zero", "ZRO", 0, admin);

        vm.expectRevert(abi.encodeWithSelector(RegulatedToken.CapExceeded.selector, 1, 0));
        capped.mint(bob, 1);
    }

    function test_cap_isBasedOnCurrentSupplySoBurningFreesRoom() public {
        harness.unsafeMint(bob, CAP - 1000 ether); // supply is now at the cap
        harness.unsafeBurn(bob, 10 ether);

        harness.unsafeMint(bob, 10 ether); // allowed again
        assertEq(harness.totalSupply(), CAP);
    }

    // the patch: the cap lives in _update, so it holds on every mint path

    function test_update_aNewMintPathStillRespectsTheCap() public {
        uint256 room = CAP - harness.totalSupply();

        vm.expectRevert(abi.encodeWithSelector(RegulatedToken.CapExceeded.selector, CAP + 1, CAP));
        harness.unsafeMint(bob, room + 1); // bypasses mint(), so only _update can stop it
    }

    function test_update_aNewMintPathMayMintUpToTheCap() public {
        harness.unsafeMint(bob, CAP - harness.totalSupply());

        assertEq(harness.totalSupply(), CAP);
    }

    function test_update_failedUncheckedMintLeavesNothingBehind() public {
        uint256 room = CAP - harness.totalSupply();

        vm.expectRevert();
        harness.unsafeMint(bob, room + 1);

        assertEq(harness.totalSupply(), 1000 ether);
        assertEq(harness.balanceOf(bob), 0);
    }

    function test_update_transfersAreNotTreatedAsMints() public {
        harness.unsafeMint(bob, CAP - harness.totalSupply()); // supply exactly at the cap

        vm.prank(alice);
        harness.transfer(carol, 100 ether); // from is not the zero address, so no cap check

        assertEq(harness.balanceOf(carol), 100 ether);
    }

    function test_update_burnsAreNotTreatedAsMints() public {
        harness.unsafeMint(bob, CAP - harness.totalSupply());

        harness.unsafeBurn(alice, 100 ether);
        assertEq(harness.totalSupply(), CAP - 100 ether);
    }

    // transfers

    function test_transfer_movesBalance() public {
        vm.prank(alice);
        token.transfer(bob, 400 ether);

        assertEq(token.balanceOf(alice), 600 ether);
        assertEq(token.balanceOf(bob), 400 ether);
    }

    function test_transfer_revertsAboveBalance() public {
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, alice, 1000 ether, 1000 ether + 1)
        );
        token.transfer(bob, 1000 ether + 1);
    }

    function test_transferFrom_worksWithAllowance() public {
        vm.prank(alice);
        token.approve(bob, 100 ether);

        vm.prank(bob);
        token.transferFrom(alice, carol, 60 ether);

        assertEq(token.balanceOf(carol), 60 ether);
        assertEq(token.allowance(alice, bob), 40 ether);
    }

    // pause

    function test_pause_onlyPauserRole() public {
        bytes32 role = token.PAUSER_ROLE();
        vm.prank(bob);
        vm.expectRevert(_unauthorized(bob, role));
        token.pause();

        token.pause();
        vm.prank(bob);
        vm.expectRevert(_unauthorized(bob, role));
        token.unpause();
    }

    function test_pause_blocksTransfers() public {
        token.pause();

        vm.prank(alice);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        token.transfer(bob, 100 ether);
    }

    function test_pause_blocksTransferFrom() public {
        vm.prank(alice);
        token.approve(bob, 100 ether);
        token.pause();

        vm.prank(bob);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        token.transferFrom(alice, carol, 10 ether);
    }

    function test_pause_blocksMintingAndBurning() public {
        harness.pause();

        vm.expectRevert(Pausable.EnforcedPause.selector);
        harness.unsafeMint(bob, 1 ether);

        vm.expectRevert(Pausable.EnforcedPause.selector);
        harness.unsafeBurn(alice, 1 ether);
    }

    function test_pause_unpauseRestoresTransfers() public {
        token.pause();
        token.unpause();

        vm.prank(alice);
        token.transfer(bob, 100 ether);
        assertEq(token.balanceOf(bob), 100 ether);
    }

    function test_pause_cannotPauseTwiceOrUnpauseWhenRunning() public {
        vm.expectRevert(Pausable.ExpectedPause.selector);
        token.unpause();

        token.pause();
        vm.expectRevert(Pausable.EnforcedPause.selector);
        token.pause();
    }

    function test_pause_doesNotStopApprovals() public {
        // Documents current behaviour: pause only freezes balance movements.
        token.pause();

        vm.prank(alice);
        token.approve(bob, 100 ether);
        assertEq(token.allowance(alice, bob), 100 ether);
    }

    // blacklist

    function test_blacklist_onlyComplianceRole() public {
        bytes32 role = token.COMPLIANCE_ROLE();
        vm.prank(bob);
        vm.expectRevert(_unauthorized(bob, role));
        token.blacklist(alice);

        vm.prank(bob);
        vm.expectRevert(_unauthorized(bob, role));
        token.unblacklist(alice);
    }

    function test_blacklist_setsFlagAndEmits() public {
        vm.expectEmit(true, false, false, false);
        emit Blacklisted(alice);
        token.blacklist(alice);
        assertTrue(token.isBlacklisted(alice));

        vm.expectEmit(true, false, false, false);
        emit Unblacklisted(alice);
        token.unblacklist(alice);
        assertFalse(token.isBlacklisted(alice));
    }

    function test_blacklist_senderCannotTransfer() public {
        token.blacklist(alice);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(RegulatedToken.AccountBlacklisted.selector, alice));
        token.transfer(bob, 100 ether);
    }

    function test_blacklist_receiverCannotBePaid() public {
        token.blacklist(bob);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(RegulatedToken.AccountBlacklisted.selector, bob));
        token.transfer(bob, 100 ether);
    }

    function test_blacklist_cannotBeMintedTo() public {
        token.blacklist(bob);

        vm.expectRevert(abi.encodeWithSelector(RegulatedToken.AccountBlacklisted.selector, bob));
        token.mint(bob, 1 ether);
    }

    function test_blacklist_cannotBeBurnedFrom() public {
        harness.blacklist(alice);

        vm.expectRevert(abi.encodeWithSelector(RegulatedToken.AccountBlacklisted.selector, alice));
        harness.unsafeBurn(alice, 1 ether);
    }

    function test_blacklist_keepsTheBalanceFrozenNotRemoved() public {
        token.blacklist(alice);

        assertEq(token.balanceOf(alice), 1000 ether);
    }

    function test_blacklist_unblacklistRestoresTransfers() public {
        token.blacklist(alice);
        token.unblacklist(alice);

        vm.prank(alice);
        token.transfer(bob, 100 ether);
        assertEq(token.balanceOf(bob), 100 ether);
    }

    function test_blacklist_ownersTokensCannotBeMovedByASpender() public {
        vm.prank(alice);
        token.approve(bob, 100 ether);
        token.blacklist(alice);

        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(RegulatedToken.AccountBlacklisted.selector, alice));
        token.transferFrom(alice, carol, 10 ether);
    }

    function test_blacklist_aBlacklistedSpenderCanStillMoveAnOwnersTokens() public {
        // Documents a gap: only `from` and `to` are checked, not the caller of transferFrom.
        vm.prank(alice);
        token.approve(bob, 100 ether);
        token.blacklist(bob);

        vm.prank(bob);
        token.transferFrom(alice, carol, 10 ether);
        assertEq(token.balanceOf(carol), 10 ether);
    }

    function test_blacklist_blacklistingTheZeroAddressFreezesMintsAndBurns() public {
        // Documents a footgun: mints have from == 0 and burns have to == 0.
        token.blacklist(address(0));

        vm.expectRevert(abi.encodeWithSelector(RegulatedToken.AccountBlacklisted.selector, address(0)));
        token.mint(bob, 1 ether);

        vm.prank(alice);
        token.transfer(bob, 1 ether); // ordinary transfers still work
        assertEq(token.balanceOf(bob), 1 ether);
    }

    // roles

    function test_roles_aMinterCannotPauseOrBlacklist() public {
        bytes32 minter = token.MINTER_ROLE();
        bytes32 pauser = token.PAUSER_ROLE();
        bytes32 compliance = token.COMPLIANCE_ROLE();
        token.grantRole(minter, bob);

        vm.startPrank(bob);
        token.mint(carol, 1 ether); // allowed
        vm.expectRevert(_unauthorized(bob, pauser));
        token.pause();
        vm.expectRevert(_unauthorized(bob, compliance));
        token.blacklist(alice);
        vm.stopPrank();
    }

    function test_roles_revokedMinterCanNoLongerMint() public {
        bytes32 minter = token.MINTER_ROLE();
        token.grantRole(minter, bob);
        token.revokeRole(minter, bob);

        vm.prank(bob);
        vm.expectRevert(_unauthorized(bob, minter));
        token.mint(bob, 1 ether);
    }

    function test_roles_onlyAdminCanGrantRoles() public {
        bytes32 minter = token.MINTER_ROLE();
        bytes32 adminRole = token.DEFAULT_ADMIN_ROLE();

        vm.prank(bob);
        vm.expectRevert(_unauthorized(bob, adminRole));
        token.grantRole(minter, bob);
    }

    // permit (EIP-2612)

    function _permitDigest(address owner, address spender, uint256 value, uint256 nonce, uint256 deadline)
        internal
        view
        returns (bytes32)
    {
        bytes32 typehash =
            keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)");
        bytes32 structHash = keccak256(abi.encode(typehash, owner, spender, value, nonce, deadline));
        return keccak256(abi.encodePacked("\x19\x01", token.DOMAIN_SEPARATOR(), structHash));
    }

    function test_permit_setsAllowanceWithoutTheOwnerSendingATransaction() public {
        (address owner, uint256 pk) = makeAddrAndKey("permitOwner");
        uint256 deadline = block.timestamp + 1 hours;
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, _permitDigest(owner, bob, 100 ether, 0, deadline));

        vm.prank(carol); // anyone can submit the signature
        token.permit(owner, bob, 100 ether, deadline, v, r, s);

        assertEq(token.allowance(owner, bob), 100 ether);
        assertEq(token.nonces(owner), 1);
    }

    function test_permit_cannotBeReplayed() public {
        (address owner, uint256 pk) = makeAddrAndKey("permitOwner");
        uint256 deadline = block.timestamp + 1 hours;
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, _permitDigest(owner, bob, 100 ether, 0, deadline));

        token.permit(owner, bob, 100 ether, deadline, v, r, s);

        vm.expectRevert(); // the nonce moved on, so the same signature no longer matches
        token.permit(owner, bob, 100 ether, deadline, v, r, s);
    }

    function test_permit_expiredSignatureReverts() public {
        (address owner, uint256 pk) = makeAddrAndKey("permitOwner");
        uint256 deadline = block.timestamp + 100;
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, _permitDigest(owner, bob, 100 ether, 0, deadline));

        vm.warp(deadline + 1);
        vm.expectRevert(abi.encodeWithSelector(ERC20Permit.ERC2612ExpiredSignature.selector, deadline));
        token.permit(owner, bob, 100 ether, deadline, v, r, s);
    }

    function test_permit_signatureFromSomeoneElseReverts() public {
        (address owner,) = makeAddrAndKey("permitOwner");
        (, uint256 attackerPk) = makeAddrAndKey("attacker");
        uint256 deadline = block.timestamp + 1 hours;
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(attackerPk, _permitDigest(owner, bob, 100 ether, 0, deadline));

        vm.expectRevert();
        token.permit(owner, bob, 100 ether, deadline, v, r, s);
    }

    function test_permit_changedValueInvalidatesTheSignature() public {
        (address owner, uint256 pk) = makeAddrAndKey("permitOwner");
        uint256 deadline = block.timestamp + 1 hours;
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, _permitDigest(owner, bob, 100 ether, 0, deadline));

        vm.expectRevert();
        token.permit(owner, bob, 200 ether, deadline, v, r, s);
    }

    // fuzz tests

    function testFuzz_mintUpToTheCapAlwaysWorks(uint256 amount) public {
        amount = bound(amount, 0, CAP - token.totalSupply());

        token.mint(bob, amount);

        assertLe(token.totalSupply(), CAP);
        assertEq(token.balanceOf(bob), amount);
    }

    function testFuzz_mintOverTheCapAlwaysReverts(uint256 extra) public {
        extra = bound(extra, 1, type(uint128).max);
        uint256 amount = CAP - token.totalSupply() + extra;

        vm.expectRevert(abi.encodeWithSelector(RegulatedToken.CapExceeded.selector, token.totalSupply() + amount, CAP));
        token.mint(bob, amount);
    }

    function testFuzz_uncheckedMintOverTheCapAlwaysReverts(uint256 extra) public {
        extra = bound(extra, 1, type(uint128).max);
        uint256 amount = CAP - harness.totalSupply() + extra;

        vm.expectRevert();
        harness.unsafeMint(bob, amount);
    }

    function testFuzz_blacklistedSenderNeverMovesTokens(uint256 amount) public {
        amount = bound(amount, 0, 1000 ether);
        token.blacklist(alice);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(RegulatedToken.AccountBlacklisted.selector, alice));
        token.transfer(bob, amount);
    }

    function testFuzz_pausedTokenNeverMovesBalances(uint256 amount) public {
        amount = bound(amount, 0, 1000 ether);
        token.pause();

        vm.prank(alice);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        token.transfer(bob, amount);
    }

    // invariants (run against the handler's own token)

    function invariant_supplyNeverExceedsTheCap() public view {
        assertLe(handler.token().totalSupply(), handler.CAP());
    }

    function invariant_balancesAddUpToTotalSupply() public view {
        assertEq(handler.sumOfBalances(), handler.token().totalSupply());
    }
}
