// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test, Vm} from "../../vendor/forge-std/src/Test.sol";
import {BurnTracker} from "../../src/BurnTracker.sol";
import {BurnTrackerTest} from "../../src/BurnTrackerTest.sol";
import {MockToken, MockIntake} from "./Mocks.sol";
import {LaunchParameters} from "../../script/LaunchParameters.sol";
import {RealResults} from "./RealResults.sol";

abstract contract TrackerFixture is Test {
    BurnTracker internal tracker;
    MockIntake internal intake;
    MockToken internal token;
    address internal owner = makeAddr("launch payer");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal writer = makeAddr("writer");
    address internal treasury = makeAddr("treasury");
    bytes32 internal constant OPEN = bytes32("job.open@job-1");
    bytes32 internal constant CONTINUE = bytes32("job.continue@job-1");
    uint256 internal constant PRICE = 0.5 ether;
    string internal constant PARENT = "4c5dbeb7-9acb-4a64-b204-9f55e6d78ada";
    bytes internal constant OPEN_BODY = '{"objective":"Host the IMD burn tracker.","skill":"import-site","host":true}';
    bytes32 internal constant REQUESTED =
        keccak256("Requested(bytes32,address,bytes32,bytes,address,bytes4,address,uint256)");

    function setUp() public virtual {
        vm.warp(1_800_000_000);
        token = new MockToken();
        intake = new MockIntake(writer, treasury);
        intake.setPrice(OPEN, address(token), PRICE);
        intake.setPrice(CONTINUE, address(token), PRICE);
        tracker = new BurnTracker(
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
        for (uint256 i; i < 3; ++i) {
            address user = [owner, alice, bob][i];
            token.mint(user, 100 ether);
            vm.prank(user);
            token.approve(address(tracker), 100 ether);
        }
    }

    function _open() internal returns (bytes32) {
        vm.prank(owner);
        return tracker.open(OPEN_BODY);
    }

    function _complete(bytes32 id, bytes32 hash) internal {
        vm.prank(writer);
        assertTrue(intake.complete(id, 0, hash, "ipfs://result/result.json", ""));
    }

    function _refuse(bytes32 id, uint8 status) internal {
        vm.prank(writer);
        assertTrue(intake.complete(id, status, "", "", bytes32("admission_refused")));
    }

    function _ready(bytes memory document) internal {
        _complete(_open(), keccak256(document));
        vm.warp(tracker.nextUpdateAt());
    }

    function _proof() internal pure returns (bytes memory) {
        return bytes(string.concat('{"jobId":"', PARENT, '"}'));
    }

    function _state(uint8 expected) internal view {
        (uint8 state,,,,,,) = tracker.status();
        assertEq(state, expected);
    }

    function _requestBody(Vm.Log[] memory logs, bytes32 expectedAction) internal view returns (bytes memory body) {
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter == address(intake) && logs[i].topics[0] == REQUESTED) {
                assertEq(logs[i].topics[2], bytes32(uint256(uint160(address(tracker)))));
                assertEq(logs[i].topics[3], expectedAction);
                (body,,,,) = abi.decode(logs[i].data, (bytes, address, bytes4, address, uint256));
                return body;
            }
        }
        revert("Requested missing");
    }
}
