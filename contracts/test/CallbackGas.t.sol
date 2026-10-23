// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {TrackerFixture} from "./helpers/TrackerFixture.sol";
import {Vm} from "../vendor/forge-std/src/Vm.sol";

contract CallbackGasTest is TrackerFixture {
    bytes32[16] private constructorSlots;

    function setUp() public override {
        super.setUp();
        for (uint256 i; i < constructorSlots.length; ++i) {
            constructorSlots[i] = vm.load(address(tracker), bytes32(i));
        }
    }

    function _callback(bytes memory payload, uint256 expectedWrites) internal {
        vm.cool(address(tracker));
        for (uint256 i; i < constructorSlots.length; ++i) {
            vm.coolSlot(address(tracker), bytes32(i));
        }
        vm.startStateDiffRecording();
        vm.prank(address(intake));
        uint256 start = gasleft();
        (bool ok,) = address(tracker).call{gas: 200_000}(payload);
        uint256 used = start - gasleft();
        Vm.AccountAccess[] memory accesses = vm.stopAndReturnStateDiff();
        assertTrue(ok, "200,000 gas callback failed");
        assertLt(used, 200_000);
        emit log_named_uint("cold callback gas including call overhead", used);
        uint256 writes;
        for (uint256 i; i < accesses.length; ++i) {
            for (uint256 j; j < accesses[i].storageAccesses.length; ++j) {
                Vm.StorageAccess memory a = accesses[i].storageAccesses[j];
                if (a.account != address(tracker) || !a.isWrite) continue;
                ++writes;
                assertNotEq(a.previousValue, bytes32(0), "callback created a storage slot");
                assertNotEq(a.newValue, bytes32(0), "callback cleared a slot for a future callback");
                assertLt(uint256(a.slot), constructorSlots.length);
                assertNotEq(constructorSlots[uint256(a.slot)], bytes32(0), "slot not initialized in constructor");
            }
        }
        // The compiler can coalesce packed writes. It must never write an extra storage slot.
        assertGt(writes, 0);
        assertLe(writes, expectedWrites);
    }

    function testFirstAndSubsequentResultsWriteOnlyPreexistingSlotsWithinStipend() public {
        bytes32 id = _open();
        _callback(abi.encodeCall(tracker.onResult, (id, keccak256(_proof()), "ipfs://bafy/result.json")), 4);
        vm.warp(tracker.nextUpdateAt());
        vm.prank(alice);
        id = tracker.updateBurntracker(_proof(), PRICE);
        _callback(abi.encodeCall(tracker.onResult, (id, keccak256(_proof()), string(new bytes(4096)))), 4);
        _state(2);
    }

    function testAllFailureKindsAndStatusesWriteOnlyPreexistingSlotsWithinStipend() public {
        for (uint8 failureStatus = 1; failureStatus <= 2; ++failureStatus) {
            for (uint8 kind = 1; kind <= 3; ++kind) {
                // Recreate a constructor-initialized target for each of the six transitions.
                setUp();
                bytes32 id = _open();
                if (kind != 1) {
                    _complete(id, keccak256(_proof()));
                    vm.warp(tracker.nextUpdateAt());
                    if (kind == 2) {
                        vm.prank(alice);
                        id = tracker.updateBurntracker(_proof(), PRICE);
                    } else {
                        vm.prank(owner);
                        id = tracker.recover(PARENT);
                    }
                }
                _callback(abi.encodeCall(tracker.onFailure, (id, failureStatus, bytes32("reason"), 0, 0, bytes(""))), 3);
                _state(failureStatus == 2 || kind == 3 ? 4 : (kind == 1 ? 1 : 2));
            }
        }
    }
}
