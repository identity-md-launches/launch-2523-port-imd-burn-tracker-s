// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {TrackerFixture, RealResults} from "./helpers/TrackerFixture.sol";
import {UpdateCaller} from "./helpers/UpdateCaller.sol";

contract UpdateGasTest is TrackerFixture {
    function test4545ByteRealProofUnder300000ExecutionGasOffline() public {
        (bytes memory document,,) = RealResults.get(6);
        assertEq(document.length, 4545);
        _ready(document);
        UpdateCaller meter = new UpdateCaller();
        token.mint(address(meter), 10 ether);
        meter.approve(address(token), address(tracker), 10 ether);
        vm.cool(address(tracker));
        vm.cool(address(intake));
        vm.cool(address(token));
        vm.cool(treasury);
        (bytes32 id, uint256 used) = meter.measure(tracker, document, PRICE);
        assertEq(tracker.lastRequestId(), id);
        assertLt(used, 300_000);
        emit log_named_uint("4545-byte proof execution gas with protocol mock", used);
    }
}
