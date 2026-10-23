// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {TrackerFixture, BurnTracker, MockToken, MockIntake, LaunchParameters} from "./helpers/TrackerFixture.sol";

contract AdministrationTest is TrackerFixture {
    function testAllAdministrationAndManualActionsAreOwnerOnly() public {
        vm.startPrank(alice);
        vm.expectRevert(BurnTracker.NotOwner.selector);
        tracker.open(OPEN_BODY);
        vm.expectRevert(BurnTracker.NotOwner.selector);
        tracker.recover(PARENT);
        vm.expectRevert(BurnTracker.NotOwner.selector);
        tracker.setResultHash(keccak256("h"));
        vm.expectRevert(BurnTracker.NotOwner.selector);
        tracker.setBody("prefix", "suffix");
        vm.expectRevert(BurnTracker.NotOwner.selector);
        tracker.setActions("open", "continue");
        vm.expectRevert(BurnTracker.NotOwner.selector);
        tracker.setIntake(alice, bob);
        vm.expectRevert(BurnTracker.NotOwner.selector);
        tracker.setTiming(3600, 3600);
        vm.expectRevert(BurnTracker.NotOwner.selector);
        tracker.withdraw(address(token), alice, 1);
        vm.expectRevert(BurnTracker.NotOwner.selector);
        tracker.transferOwnership(alice);
        vm.expectRevert(BurnTracker.NotPendingOwner.selector);
        tracker.acceptOwnership();
        vm.stopPrank();
    }

    function testOwnershipRequiresNewOwnerAcceptanceAndCanReplaceNominee() public {
        vm.prank(owner);
        tracker.transferOwnership(alice);
        assertEq(tracker.owner(), owner);
        assertEq(tracker.pendingOwner(), alice);
        vm.prank(bob);
        vm.expectRevert(BurnTracker.NotPendingOwner.selector);
        tracker.acceptOwnership();
        vm.prank(owner);
        tracker.transferOwnership(bob);
        vm.prank(alice);
        vm.expectRevert(BurnTracker.NotPendingOwner.selector);
        tracker.acceptOwnership();
        vm.prank(bob);
        tracker.acceptOwnership();
        assertEq(tracker.owner(), bob);
        assertEq(tracker.pendingOwner(), address(0));
        vm.prank(owner);
        vm.expectRevert(BurnTracker.NotOwner.selector);
        tracker.setTiming(3600, 3600);
        vm.prank(bob);
        tracker.open(OPEN_BODY);
    }

    function testConfigurationIsUsedForFutureOrders() public {
        MockToken nextToken = new MockToken();
        MockIntake nextIntake = new MockIntake(writer, treasury);
        bytes32 openAction = "job.open@job-2";
        bytes32 continueAction = "job.continue@job-2";
        nextIntake.setPrice(openAction, address(nextToken), 3);
        nextIntake.setPrice(continueAction, address(nextToken), 7);
        nextToken.mint(owner, 10);
        nextToken.mint(alice, 10);
        vm.prank(owner);
        nextToken.approve(address(tracker), 10);
        vm.prank(alice);
        nextToken.approve(address(tracker), 10);
        vm.startPrank(owner);
        tracker.setIntake(address(nextIntake), address(nextToken));
        tracker.setActions(openAction, continueAction);
        tracker.setBody('{"parentJobId":"', '","objective":"new template"}');
        tracker.setTiming(3600, 3601);
        bytes32 id = tracker.open(OPEN_BODY);
        vm.stopPrank();
        assertEq(tracker.price(), 7);
        vm.prank(writer);
        assertTrue(nextIntake.complete(id, 0, keccak256(_proof()), "", ""));
        assertEq(tracker.nextUpdateAt(), vm.getBlockTimestamp() + 3600);
        vm.warp(tracker.nextUpdateAt());
        vm.recordLogs();
        vm.prank(alice);
        tracker.updateBurntracker(_proof(), 7);
        intake = nextIntake;
        assertEq(
            _requestBody(vm.getRecordedLogs(), continueAction),
            bytes(string.concat('{"parentJobId":"', PARENT, '","objective":"new template"}'))
        );
        assertEq(nextToken.balanceOf(treasury), 10);
    }

    function testWithdrawOnlyMovesNamedTokenAndAmount() public {
        token.mint(address(tracker), 123);
        vm.prank(owner);
        tracker.withdraw(address(token), bob, 23);
        assertEq(token.balanceOf(address(tracker)), 100);
        assertEq(token.balanceOf(bob), 100 ether + 23);
    }

    function testRejectsZeroAddressesAndActions() public {
        vm.startPrank(owner);
        vm.expectRevert(BurnTracker.InvalidAddress.selector);
        tracker.setIntake(address(0), address(token));
        vm.expectRevert(BurnTracker.InvalidAddress.selector);
        tracker.setIntake(address(intake), address(0));
        vm.expectRevert(BurnTracker.InvalidAddress.selector);
        tracker.transferOwnership(address(0));
        vm.expectRevert(BurnTracker.InvalidAddress.selector);
        tracker.withdraw(address(0), bob, 1);
        vm.expectRevert(BurnTracker.InvalidAddress.selector);
        tracker.withdraw(address(token), address(0), 1);
        vm.expectRevert(BurnTracker.InvalidActions.selector);
        tracker.setActions(0, CONTINUE);
        vm.expectRevert(BurnTracker.InvalidActions.selector);
        tracker.setActions(OPEN, 0);
        vm.stopPrank();
    }

    function testTimingBoundsInclusiveAndCurrentCooldownChangesImmediately() public {
        _complete(_open(), keccak256(_proof()));
        uint256 done = vm.getBlockTimestamp();
        vm.startPrank(owner);
        tracker.setTiming(3600, 30 days);
        assertEq(tracker.nextUpdateAt(), done + 3600);
        tracker.setTiming(30 days, 3600);
        assertEq(tracker.nextUpdateAt(), done + 30 days);
        vm.expectRevert(BurnTracker.InvalidTiming.selector);
        tracker.setTiming(3599, 3600);
        vm.expectRevert(BurnTracker.InvalidTiming.selector);
        tracker.setTiming(3600, 3599);
        vm.expectRevert(BurnTracker.InvalidTiming.selector);
        tracker.setTiming(30 days + 1, 3600);
        vm.expectRevert(BurnTracker.InvalidTiming.selector);
        tracker.setTiming(3600, 30 days + 1);
        vm.stopPrank();
    }

    function testBodyBoundsAndMalformedRecoveryParent() public {
        vm.startPrank(owner);
        vm.expectRevert(BurnTracker.InvalidBody.selector);
        tracker.open("");
        vm.expectRevert(BurnTracker.InvalidBody.selector);
        tracker.open(new bytes(16_385));
        vm.expectRevert(BurnTracker.InvalidBody.selector);
        tracker.setBody("", "suffix");
        vm.expectRevert(BurnTracker.InvalidBody.selector);
        tracker.setBody("prefix", "");
        vm.expectRevert(BurnTracker.InvalidBody.selector);
        tracker.setBody(new bytes(16_348), "x");
        tracker.setBody(new bytes(16_347), "x");
        tracker.setBody(LaunchParameters.prefix(), LaunchParameters.suffix());
        vm.stopPrank();
        _ready(_proof());
        vm.prank(owner);
        vm.expectRevert(BurnTracker.InvalidParentJobId.selector);
        tracker.recover("abc\"}");
    }

    function testConstructorRejectsInvalidParameters() public {
        vm.expectRevert(BurnTracker.InvalidAddress.selector);
        new BurnTracker(address(0), address(intake), address(token), OPEN, CONTINUE, "a", "b", 3600, 3600);
        vm.expectRevert(BurnTracker.InvalidAddress.selector);
        new BurnTracker(owner, address(0), address(token), OPEN, CONTINUE, "a", "b", 3600, 3600);
        vm.expectRevert(BurnTracker.InvalidAddress.selector);
        new BurnTracker(owner, address(intake), address(0), OPEN, CONTINUE, "a", "b", 3600, 3600);
        vm.expectRevert(BurnTracker.InvalidActions.selector);
        new BurnTracker(owner, address(intake), address(token), 0, CONTINUE, "a", "b", 3600, 3600);
        vm.expectRevert(BurnTracker.InvalidActions.selector);
        new BurnTracker(owner, address(intake), address(token), OPEN, 0, "a", "b", 3600, 3600);
        vm.expectRevert(BurnTracker.InvalidBody.selector);
        new BurnTracker(owner, address(intake), address(token), OPEN, CONTINUE, "", "b", 3600, 3600);
        vm.expectRevert(BurnTracker.InvalidTiming.selector);
        new BurnTracker(owner, address(intake), address(token), OPEN, CONTINUE, "a", "b", 0, 3600);
    }

    function testFuzzTimingRange(uint32 cooldown, uint32 staleAfter) public {
        vm.prank(owner);
        bool valid = cooldown >= 3600 && cooldown <= 30 days && staleAfter >= 3600 && staleAfter <= 30 days;
        if (!valid) vm.expectRevert(BurnTracker.InvalidTiming.selector);
        tracker.setTiming(cooldown, staleAfter);
    }
}
