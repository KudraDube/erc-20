// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {RegulatedToken} from "../src/RegulatedToken.sol";

contract RegulatedTokenTest is Test {
    RegulatedToken token;
    address admin = address(this);
    address alice = address(0xA11CE);
    address bob = address(0xB0B);

    function setUp() public {
        token = new RegulatedToken("Regulated ZAR", "rZAR", 1_000_000e18, admin);
        token.mint(alice, 1000e18);
    }

    function test_mint_revertsAboveCap() public {
        vm.expectRevert();
        token.mint(alice, 999_999_000e18 + 1);
    }

    function test_blacklistedSender_cannotTransfer() public {
        token.blacklist(alice);
        vm.prank(alice);
        vm.expectRevert();
        token.transfer(bob, 100e18);
    }

    function test_paused_blocksTransfer() public {
        token.pause();
        vm.prank(alice);
        vm.expectRevert();
        token.transfer(bob, 100e18);
    }

    function test_nonMinter_cannotMint() public {
        vm.prank(bob);
        vm.expectRevert();
        token.mint(bob, 1e18);
    }
}