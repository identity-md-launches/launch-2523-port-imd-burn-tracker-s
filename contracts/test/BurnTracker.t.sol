// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {
    TrackerFixture,
    BurnTracker,
    BurnTrackerTest,
    MockIntake,
    MockToken,
    LaunchParameters,
    RealResults
} from "./helpers/TrackerFixture.sol";
import {Vm} from "../vendor/forge-std/src/Vm.sol";
import {SafeERC20} from "../vendor/openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

contract BurnTrackerBehaviorTest is TrackerFixture {
    event Ordered(bytes32 indexed requestId, uint8 kind, address indexed payer, uint256 amount, string parentJobId);
    event Updated(bytes32 indexed requestId, bytes32 resultHash, string uri);
    event Failed(bytes32 indexed requestId, uint8 status, bytes32 reason, uint8 newState);

    function testExactLaunchTemplateMatchesPinnedBytes() public pure {
        // Independently pinned from the assignment's exact UTF-8 text, including apostrophes.
        assertEq(
            keccak256(LaunchParameters.template()), 0x2c06600da333a3194294e32ce207aa2152a27883d1fcd9291b856fbc560d3178
        );
        assertEq(
            keccak256(bytes.concat(LaunchParameters.prefix(), bytes(PARENT), LaunchParameters.suffix())),
            0xdb5b0fd398f189b4b81bffe0965050c8556b0e4a0dcce52bc1b8bc444ff4755b
        );
    }

    function testConstructorWorksOnEmptyChainAndUsesExplicitOwner() public {
        BurnTracker t = new BurnTracker(
            owner,
            LaunchParameters.INTAKE,
            LaunchParameters.ASSET,
            OPEN,
            CONTINUE,
            LaunchParameters.prefix(),
            LaunchParameters.suffix(),
            86400,
            172800
        );
        assertEq(t.owner(), owner);
        assertEq(t.intake(), LaunchParameters.INTAKE);
        assertEq(t.asset(), LaunchParameters.ASSET);
        assertEq(t.openAction(), OPEN);
        assertEq(t.continueAction(), CONTINUE);
        assertEq(t.bodyPrefix(), LaunchParameters.prefix());
        assertEq(t.bodySuffix(), LaunchParameters.suffix());
        (uint8 state, uint8 kind, uint40 lastDone, uint40 ordered, uint40 stale, uint32 cd, uint32 sa) = t.status();
        assertEq(state, 1);
        assertEq(kind, 0);
        assertEq(lastDone, 0);
        assertEq(ordered, 0);
        assertEq(stale, 0);
        assertEq(cd, 86400);
        assertEq(sa, 172800);
    }

    function testTestDeploymentHasIdenticalRuntimeBytecode() public {
        BurnTrackerTest t = new BurnTrackerTest(
            owner,
            address(intake),
            address(token),
            OPEN,
            CONTINUE,
            LaunchParameters.prefix(),
            LaunchParameters.suffix(),
            86400,
            172800
        );
        // With this project's pinned settings these are full-byte equality checks.
        // An external compiler can enable IPFS metadata; only that target-specific
        // hash may then differ. All executable bytes and the CBOR envelope still match.
        assertEq(_normalizeMetadataHash(address(t).code), _normalizeMetadataHash(address(tracker).code));
        assertEq(
            _normalizeMetadataHash(type(BurnTracker).runtimeCode),
            _normalizeMetadataHash(type(BurnTrackerTest).runtimeCode)
        );
    }

    function _normalizeMetadataHash(bytes memory code) private pure returns (bytes memory) {
        uint256 n = code.length;
        if (n < 53) return code;
        bytes10 header;
        bytes11 trailer;
        assembly ("memory-safe") {
            header := mload(add(add(code, 32), sub(n, 53)))
            trailer := mload(add(add(code, 32), sub(n, 11)))
        }
        // Recognize the entire Solidity 0.8.26 default CBOR layout, including its
        // encoded length. Never truncate arbitrary trailing instructions/data.
        if (header != hex"a2646970667358221220" || trailer != hex"64736f6c634300081a0033") return code;
        for (uint256 i = n - 43; i < n - 11; ++i) {
            code[i] = 0;
        }
        return code;
    }

    function testOpenPaysOwnerLivePriceAndRegistersTrackerAsPayer() public {
        intake.setPrice(OPEN, address(token), 0.8 ether);
        vm.recordLogs();
        bytes32 id = _open();
        assertEq(_requestBody(vm.getRecordedLogs(), OPEN), OPEN_BODY);
        (address payer, address callback, bytes4 selector, bool done) = intake.requests(id);
        assertEq(payer, address(tracker));
        assertEq(callback, address(tracker));
        assertEq(selector, tracker.onResult.selector);
        assertFalse(done);
        assertEq(intake.failureSelectorOf(id), tracker.onFailure.selector);
        assertEq(token.balanceOf(owner), 99.2 ether);
        assertEq(token.balanceOf(treasury), 0.8 ether);
        assertEq(token.balanceOf(address(tracker)), 0);
        assertEq(token.allowance(address(tracker), address(intake)), 0);
        assertEq(tracker.lastRequestId(), id);
        _state(3);
        (, uint8 kind,, uint40 orderedAt, uint40 staleAt,,) = tracker.status();
        assertEq(kind, 1);
        assertEq(orderedAt, vm.getBlockTimestamp());
        assertEq(staleAt, vm.getBlockTimestamp() + 172800);
    }

    function testUpdateAuthenticatesProofPaysExactlyLivePriceAndUsesExactTemplate() public {
        bytes memory document = _proof();
        _ready(document);
        intake.setPrice(CONTINUE, address(token), 0.75 ether);
        assertEq(tracker.price(), 0.75 ether);
        vm.expectCall(address(token), abi.encodeCall(token.transferFrom, (alice, address(tracker), 0.75 ether)));
        vm.expectCall(address(token), abi.encodeCall(token.approve, (address(intake), 0.75 ether)));
        vm.recordLogs();
        vm.prank(alice);
        bytes32 id = tracker.updateBurntracker(document, 0.75 ether);
        assertEq(
            _requestBody(vm.getRecordedLogs(), CONTINUE),
            bytes.concat(LaunchParameters.prefix(), bytes(PARENT), LaunchParameters.suffix())
        );
        assertEq(token.balanceOf(alice), 99.25 ether);
        assertEq(token.balanceOf(owner), 99.5 ether);
        assertEq(token.balanceOf(treasury), PRICE + 0.75 ether);
        assertEq(token.balanceOf(address(tracker)), 0);
        assertEq(token.allowance(address(tracker), address(intake)), 0);
        (address payer,,,) = intake.requests(id);
        assertEq(payer, address(tracker));
        (, uint8 kind,,,,,) = tracker.status();
        assertEq(kind, 2);
    }

    function testPriceCeilingRevertsBeforeAnyTokenCall() public {
        bytes memory document = _proof();
        _ready(document);
        intake.setPrice(CONTINUE, address(token), PRICE + 1);
        // Even balanceOf must not be called before rejecting the price.
        vm.expectCall(address(token), abi.encodeWithSelector(token.balanceOf.selector), uint64(0));
        vm.expectCall(address(token), abi.encodeWithSelector(token.transferFrom.selector), uint64(0));
        vm.expectCall(address(token), abi.encodeWithSelector(token.approve.selector), uint64(0));
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(BurnTracker.PriceTooHigh.selector, PRICE + 1, PRICE));
        tracker.updateBurntracker(document, PRICE);
        _state(2);
    }

    function testZeroPriceCannotMoveTokens() public {
        intake.setPrice(OPEN, address(token), 0);
        vm.prank(owner);
        vm.expectRevert(BurnTracker.NotSold.selector);
        tracker.open(OPEN_BODY);
        _state(1);
        assertEq(token.balanceOf(owner), 100 ether);
        intake.setPrice(OPEN, address(token), PRICE);
        _ready(_proof());
        intake.setPrice(CONTINUE, address(token), 0);
        assertEq(tracker.price(), 0);
        vm.prank(alice);
        vm.expectRevert(BurnTracker.NotSold.selector);
        tracker.updateBurntracker(_proof(), PRICE);
    }

    function testWrongProofAndAnyByteChangeAreRejected() public {
        bytes memory document = _proof();
        _ready(document);
        document[10] = "x";
        vm.prank(alice);
        vm.expectRevert(BurnTracker.InvalidProof.selector);
        tracker.updateBurntracker(document, PRICE);
        vm.prank(alice);
        vm.expectRevert(BurnTracker.InvalidProof.selector);
        tracker.updateBurntracker(bytes.concat(_proof(), "\n"), PRICE);
        _state(2);
        assertEq(token.balanceOf(alice), 100 ether);
    }

    function testHashMatchedInvalidJsonStillCannotOrder() public {
        bytes memory document = bytes('{"jobId":"injection"}');
        _ready(document);
        vm.prank(alice);
        vm.expectRevert(bytes4(keccak256("InvalidResultJson()")));
        tracker.updateBurntracker(document, PRICE);
    }

    function testAuthenticatedDuplicateAndEscapedFakeKeysCannotOrder() public {
        bytes memory duplicate = bytes(string.concat('{"jobId":"', PARENT, '","jobId":"', PARENT, '"}'));
        _ready(duplicate);
        vm.prank(alice);
        vm.expectRevert(bytes4(keccak256("InvalidResultJson()")));
        tracker.updateBurntracker(duplicate, PRICE);
        bytes memory fake = bytes(string.concat('{"note":"\\\"jobId\\\":\\\"', PARENT, '\\\""}'));
        vm.prank(owner);
        tracker.setResultHash(keccak256(fake));
        vm.warp(tracker.nextUpdateAt());
        vm.prank(alice);
        vm.expectRevert(bytes4(keccak256("InvalidResultJson()")));
        tracker.updateBurntracker(fake, PRICE);
    }

    function testAnOlderCompletedProofCannotBeReusedAfterANewCompletion() public {
        _ready(_proof());
        vm.prank(alice);
        bytes32 id = tracker.updateBurntracker(_proof(), PRICE);
        (bytes memory document, bytes32 hash,) = RealResults.get(0);
        _complete(id, hash);
        vm.warp(tracker.nextUpdateAt());
        vm.prank(bob);
        vm.expectRevert(BurnTracker.InvalidProof.selector);
        tracker.updateBurntracker(_proof(), PRICE);
        vm.prank(bob);
        tracker.updateBurntracker(document, PRICE);
    }

    function testCooldownInclusiveBoundaryAndRestartsAtCompletion() public {
        bytes32 id = _open();
        vm.warp(vm.getBlockTimestamp() + 300);
        uint256 completedAt = vm.getBlockTimestamp();
        _complete(id, keccak256(_proof()));
        assertEq(tracker.nextUpdateAt(), completedAt + 86400);
        vm.warp(completedAt + 86400 - 1);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(BurnTracker.CooldownNotPassed.selector, completedAt + 86400));
        tracker.updateBurntracker(_proof(), PRICE);
        vm.warp(completedAt + 86400);
        vm.prank(bob);
        id = tracker.updateBurntracker(_proof(), PRICE);
        vm.warp(vm.getBlockTimestamp() + 100);
        _complete(id, keccak256(_proof()));
        assertEq(tracker.nextUpdateAt(), vm.getBlockTimestamp() + 86400);
    }

    function testOneOrderAtATimeAndOpenUnavailableWhenIdle() public {
        vm.prank(alice);
        vm.expectRevert(BurnTracker.InvalidState.selector);
        tracker.updateBurntracker(_proof(), PRICE);
        bytes32 id = _open();
        vm.prank(owner);
        vm.expectRevert(BurnTracker.InvalidState.selector);
        tracker.open(OPEN_BODY);
        vm.prank(owner);
        vm.expectRevert(BurnTracker.InvalidState.selector);
        tracker.recover(PARENT);
        vm.prank(owner);
        vm.expectRevert(BurnTracker.InvalidState.selector);
        tracker.setResultHash(keccak256(_proof()));
        vm.prank(alice);
        vm.expectRevert(BurnTracker.InvalidState.selector);
        tracker.updateBurntracker(_proof(), PRICE);
        _complete(id, keccak256(_proof()));
        vm.prank(owner);
        vm.expectRevert(BurnTracker.InvalidState.selector);
        tracker.open(OPEN_BODY);
    }

    function testRefusedOpenReturnsToUnopenedAndCanRetry() public {
        _refuse(_open(), 1);
        _state(1);
        assertEq(token.balanceOf(treasury), PRICE);
        bytes32 id = _open();
        _complete(id, keccak256(_proof()));
        _state(2);
    }

    function testRefusedUpdateRestartsCooldownAndKeepsLastProof() public {
        _ready(_proof());
        vm.prank(alice);
        bytes32 id = tracker.updateBurntracker(_proof(), PRICE);
        vm.warp(vm.getBlockTimestamp() + 77);
        _refuse(id, 1);
        _state(2);
        assertEq(tracker.resultHash(), keccak256(_proof()));
        assertEq(tracker.nextUpdateAt(), vm.getBlockTimestamp() + 86400);
        assertEq(token.balanceOf(alice), 100 ether - PRICE);
        vm.warp(tracker.nextUpdateAt());
        vm.prank(bob);
        tracker.updateBurntracker(_proof(), PRICE);
    }

    function testRefusedRecoverGoesStuck() public {
        _ready(_proof());
        vm.prank(owner);
        bytes32 id = tracker.recover(PARENT);
        _refuse(id, 1);
        _state(4);
        vm.prank(alice);
        vm.expectRevert(BurnTracker.InvalidState.selector);
        tracker.updateBurntracker(_proof(), PRICE);
    }

    function test_FailedHostingJobAllowsNewOpen() public {
        _refuse(_open(), 2);
        _state(4);
        bytes32 next = _open();
        _complete(next, keccak256(_proof()));
        _state(2);
    }

    function test_FailedUpdateAndRecoverGoStuck() public {
        _ready(_proof());
        vm.prank(alice);
        bytes32 id = tracker.updateBurntracker(_proof(), PRICE);
        _refuse(id, 2);
        _state(4);
        vm.prank(owner);
        id = tracker.recover(PARENT);
        _refuse(id, 2);
        _state(4);
        _open();
        _state(3);
    }

    function testRecoverFromIdleIgnoresCooldownAndUsesOwnerPayment() public {
        _complete(_open(), keccak256(_proof()));
        vm.recordLogs();
        vm.prank(owner);
        bytes32 id = tracker.recover(PARENT);
        assertEq(
            _requestBody(vm.getRecordedLogs(), CONTINUE),
            bytes.concat(LaunchParameters.prefix(), bytes(PARENT), LaunchParameters.suffix())
        );
        (, uint8 kind,,,,,) = tracker.status();
        assertEq(kind, 3);
        assertEq(token.balanceOf(owner), 100 ether - 2 * PRICE);
        _complete(id, keccak256("new result"));
        _state(2);
        assertEq(tracker.resultHash(), keccak256("new result"));
    }

    function testRecoverOnlyAfterFixedStaleDeadlineAndRejectsOldCallbacks() public {
        bytes32 abandoned = _open();
        (,,,, uint40 deadline,,) = tracker.status();
        vm.prank(owner);
        tracker.setTiming(3600, 30 days);
        (,,,, uint40 unchanged,,) = tracker.status();
        assertEq(unchanged, deadline);
        vm.warp(deadline - 1);
        vm.prank(owner);
        vm.expectRevert(BurnTracker.InvalidState.selector);
        tracker.recover(PARENT);
        vm.warp(deadline);
        vm.prank(owner);
        bytes32 next = tracker.recover(PARENT);
        vm.prank(address(intake));
        vm.expectRevert(BurnTracker.UnexpectedCallback.selector);
        tracker.onResult(abandoned, keccak256("old"), "old");
        vm.prank(address(intake));
        vm.expectRevert(BurnTracker.UnexpectedCallback.selector);
        tracker.onFailure(abandoned, 2, "failed", 0, 0, "");
        _complete(next, keccak256(_proof()));
    }

    function testOpenAfterStaleOrderRejectsLateCallback() public {
        bytes32 abandoned = _open();
        (,,,, uint40 deadline,,) = tracker.status();
        vm.warp(deadline);
        bytes32 next = _open();
        assertNotEq(next, abandoned);
        vm.prank(writer);
        assertFalse(intake.complete(abandoned, 0, keccak256("old"), "", ""));
        _state(3);
        _complete(next, keccak256(_proof()));
    }

    function testAStaleButNotAbandonedOrderCanStillComplete() public {
        bytes32 id = _open();
        vm.warp(vm.getBlockTimestamp() + 172801);
        _complete(id, keccak256(_proof()));
        _state(2);
    }

    function testSetResultHashFromStalePendingIdleAndStuck() public {
        bytes32 id = _open();
        vm.warp(vm.getBlockTimestamp() + 172800);
        bytes32 hash = keccak256(_proof());
        vm.prank(owner);
        tracker.setResultHash(hash);
        _state(2);
        assertEq(tracker.resultHash(), hash);
        assertEq(tracker.nextUpdateAt(), vm.getBlockTimestamp() + 86400);
        vm.prank(address(intake));
        vm.expectRevert(BurnTracker.UnexpectedCallback.selector);
        tracker.onResult(id, hash, "late");
        vm.warp(vm.getBlockTimestamp() + 20);
        vm.prank(owner);
        tracker.setResultHash(hash);
        assertEq(tracker.nextUpdateAt(), vm.getBlockTimestamp() + 86400);
        vm.prank(owner);
        id = tracker.recover(PARENT);
        _refuse(id, 2);
        vm.prank(owner);
        tracker.setResultHash(hash);
        _state(2);
        vm.warp(tracker.nextUpdateAt());
        vm.prank(alice);
        tracker.updateBurntracker(_proof(), PRICE);
    }

    function testCannotRecoverOrAdoptBeforeOpeningOrAdoptZero() public {
        vm.prank(owner);
        vm.expectRevert(BurnTracker.InvalidState.selector);
        tracker.recover(PARENT);
        vm.prank(owner);
        vm.expectRevert(BurnTracker.InvalidState.selector);
        tracker.setResultHash(keccak256(_proof()));
        _ready(_proof());
        vm.prank(owner);
        vm.expectRevert(BurnTracker.InvalidHash.selector);
        tracker.setResultHash(0);
    }

    function testWrongSenderUnknownAndDuplicateCallbacksRejected() public {
        bytes32 id = _open();
        vm.expectRevert(BurnTracker.UnexpectedCallback.selector);
        tracker.onResult(id, keccak256("r"), "u");
        vm.expectRevert(BurnTracker.UnexpectedCallback.selector);
        tracker.onFailure(id, 1, "r", 0, 0, "");
        vm.prank(address(intake));
        vm.expectRevert(BurnTracker.UnexpectedCallback.selector);
        tracker.onResult(keccak256("unknown"), keccak256("r"), "u");
        vm.prank(address(intake));
        vm.expectRevert(BurnTracker.UnexpectedCallback.selector);
        tracker.onFailure(keccak256("unknown"), 2, "r", 0, 0, "");
        _complete(id, keccak256(_proof()));
        vm.prank(address(intake));
        vm.expectRevert(BurnTracker.UnexpectedCallback.selector);
        tracker.onResult(id, keccak256("r"), "u");
        vm.prank(address(intake));
        vm.expectRevert(BurnTracker.UnexpectedCallback.selector);
        tracker.onFailure(id, 1, "r", 0, 0, "");
    }

    function test_FailureConsumesCallbackOnceAndInvalidStatusDoesNot() public {
        bytes32 id = _open();
        vm.prank(address(intake));
        vm.expectRevert(BurnTracker.InvalidFailureStatus.selector);
        tracker.onFailure(id, 0, "r", 0, 0, "");
        vm.prank(address(intake));
        vm.expectRevert(BurnTracker.InvalidFailureStatus.selector);
        tracker.onFailure(id, 3, "r", 0, 0, "");
        vm.prank(address(intake));
        vm.expectRevert(BurnTracker.InvalidHash.selector);
        tracker.onResult(id, 0, "");
        _refuse(id, 1);
        vm.prank(address(intake));
        vm.expectRevert(BurnTracker.UnexpectedCallback.selector);
        tracker.onFailure(id, 1, "r", 0, 0, "");
        vm.prank(address(intake));
        vm.expectRevert(BurnTracker.UnexpectedCallback.selector);
        tracker.onResult(id, keccak256("r"), "");
    }

    function testPendingOrderKeepsOriginalIntakeAuthentication() public {
        bytes32 id = _open();
        MockIntake next = new MockIntake(writer, treasury);
        next.setPrice(CONTINUE, address(token), PRICE);
        vm.prank(owner);
        tracker.setIntake(address(next), address(token));
        vm.prank(address(next));
        vm.expectRevert(BurnTracker.UnexpectedCallback.selector);
        tracker.onResult(id, keccak256(_proof()), "");
        _complete(id, keccak256(_proof()));
        vm.warp(tracker.nextUpdateAt());
        vm.prank(alice);
        bytes32 nextId = tracker.updateBurntracker(_proof(), PRICE);
        (address payer,,,) = next.requests(nextId);
        assertEq(payer, address(tracker));
        vm.prank(address(intake));
        vm.expectRevert(BurnTracker.UnexpectedCallback.selector);
        tracker.onResult(nextId, keccak256(_proof()), "");
        vm.prank(writer);
        assertTrue(next.complete(nextId, 0, keccak256(_proof()), "", ""));
    }

    function testIntakeOrTokenRevertRollsBackWholeOrder() public {
        intake.setReject(true);
        vm.prank(owner);
        vm.expectRevert("intake rejected");
        tracker.open(OPEN_BODY);
        _state(1);
        assertEq(token.balanceOf(owner), 100 ether);
        assertEq(token.allowance(address(tracker), address(intake)), 0);
        intake.setReject(false);
        token.configure(true, false, false, 0);
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(SafeERC20.SafeERC20FailedOperation.selector, address(token)));
        tracker.open(OPEN_BODY);
        _state(1);
    }

    function testNonReturningAndZeroFirstApprovalToken() public {
        token.configure(false, true, true, 0);
        token.setAllowance(address(tracker), address(intake), 7);
        _open();
        assertEq(token.allowance(address(tracker), address(intake)), 0);
    }

    function testBalanceReadRejectsShortReturnAndBubblesTokenRevert() public {
        bytes memory query = abi.encodeCall(token.balanceOf, (address(tracker)));
        vm.mockCall(address(token), query, hex"01");
        vm.prank(owner);
        vm.expectRevert();
        tracker.open(OPEN_BODY);
        vm.clearMockedCalls();
        bytes memory reason = abi.encodeWithSignature("BalanceReadRejected()");
        vm.mockCallRevert(address(token), query, reason);
        vm.prank(owner);
        vm.expectRevert(reason);
        tracker.open(OPEN_BODY);
        vm.clearMockedCalls();
        _state(1);
        assertEq(token.balanceOf(owner), 100 ether);
        _open(); // Reverts must also roll back the packed reentrancy guard.
    }

    function testPaymentRejectsMalformedTokenReturnsAndBubblesTransferRevert() public {
        bytes memory transfer = abi.encodeCall(token.transferFrom, (owner, address(tracker), PRICE));
        bytes[3] memory invalid = [abi.encode(false), bytes(hex"01"), abi.encode(uint256(2))];
        for (uint256 i; i < invalid.length; ++i) {
            vm.mockCall(address(token), transfer, invalid[i]);
            vm.prank(owner);
            vm.expectRevert(abi.encodeWithSelector(SafeERC20.SafeERC20FailedOperation.selector, address(token)));
            tracker.open(OPEN_BODY);
            vm.clearMockedCalls();
            _state(1);
        }
        bytes memory reason = abi.encodeWithSignature("TransferRejected()");
        vm.mockCallRevert(address(token), transfer, reason);
        vm.prank(owner);
        vm.expectRevert(reason);
        tracker.open(OPEN_BODY);
        vm.clearMockedCalls();
        assertEq(token.balanceOf(owner), 100 ether);
        assertEq(token.balanceOf(address(tracker)), 0);
        _open();
    }

    function testRejectedApprovalRollsBackPulledTokens() public {
        bytes memory approval = abi.encodeWithSelector(token.approve.selector);
        vm.mockCall(address(token), approval, abi.encode(false));
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(SafeERC20.SafeERC20FailedOperation.selector, address(token)));
        tracker.open(OPEN_BODY);
        vm.clearMockedCalls();
        _state(1);
        assertEq(token.balanceOf(owner), 100 ether);
        assertEq(token.balanceOf(address(tracker)), 0);
        assertEq(token.allowance(address(tracker), address(intake)), 0);
        _open();
    }

    function testFeeTokenCannotSpendPreviouslyDonatedTokens() public {
        token.mint(address(tracker), PRICE);
        token.configure(false, false, false, 1);
        vm.prank(owner);
        vm.expectRevert(BurnTracker.IncorrectTokenAmount.selector);
        tracker.open(OPEN_BODY);
        assertEq(token.balanceOf(address(tracker)), PRICE);
        assertEq(token.balanceOf(owner), 100 ether);
    }

    function testTokenReentrancyAndSynchronousCallbackCannotSettle() public {
        _ready(_proof());
        token.setHook(address(tracker), abi.encodeCall(tracker.updateBurntracker, (_proof(), PRICE)));
        intake.setSynchronous(true);
        vm.prank(alice);
        bytes32 id = tracker.updateBurntracker(_proof(), PRICE);
        assertFalse(token.reentered());
        assertFalse(intake.synchronousDelivered());
        _state(3);
        _complete(id, keccak256(_proof()));
    }

    function testEventsExposeOrderCompletionAndFailure() public {
        vm.expectEmit(false, true, false, true, address(tracker));
        emit Ordered(0, 1, owner, PRICE, "");
        bytes32 id = _open();
        vm.expectEmit(true, false, false, true, address(tracker));
        emit Updated(id, keccak256(_proof()), "ipfs://result/result.json");
        _complete(id, keccak256(_proof()));
        vm.prank(owner);
        id = tracker.recover(PARENT);
        vm.expectEmit(true, false, false, true, address(tracker));
        emit Failed(id, 1, "admission_refused", 4);
        _refuse(id, 1);
    }

    function testRealDocumentsMatchOnchainHashesParseAndAuthorizeProofs() public {
        bytes32 id = _open();
        for (uint256 i; i < RealResults.count(); ++i) {
            (bytes memory document, bytes32 hash, string memory jobId) = RealResults.get(i);
            assertEq(keccak256(document), hash);
            assertEq(tracker.parentJobIdOf(document), bytes(jobId));
            _complete(id, hash);
            vm.warp(tracker.nextUpdateAt());
            vm.recordLogs();
            vm.prank(alice);
            id = tracker.updateBurntracker(document, PRICE);
            assertEq(
                _requestBody(vm.getRecordedLogs(), CONTINUE),
                bytes.concat(LaunchParameters.prefix(), bytes(jobId), LaunchParameters.suffix())
            );
        }
    }
}
