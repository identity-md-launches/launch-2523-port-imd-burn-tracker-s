// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test, Vm} from "../../vendor/forge-std/src/Test.sol";
import {BurnTrackerTest} from "../../src/BurnTrackerTest.sol";
import {IIntake} from "../../src/interfaces/IIntake.sol";
import {IERC20} from "../../vendor/openzeppelin/contracts/token/ERC20/IERC20.sol";
import {LaunchParameters} from "../../script/LaunchParameters.sol";
import {RealResults} from "../helpers/RealResults.sol";
import {UpdateCaller} from "../helpers/UpdateCaller.sol";

interface ILiveIntake is IIntake {
    function requests(bytes32 id) external view returns (address payer, address target, bytes4 selector, bool completed);
    function failureSelectorOf(bytes32 id) external view returns (bytes4);
    function writer() external view returns (address);
    function payTo() external view returns (address);
    function callbackGas() external view returns (uint64);
    function complete(bytes32 id, uint8 status, bytes32 hash, string calldata uri, bytes calldata args) external;
}

/// @notice Run with --fork-url and --fork-block-number 26258169. No environment variables or network in default tests.
/// @dev Uses live bytecode/storage. Only test wallets' balances and the writer impersonation are synthetic.
contract MainnetForkTest is Test {
    ILiveIntake private constant INTAKE = ILiveIntake(LaunchParameters.INTAKE);
    IERC20 private constant IMD = IERC20(LaunchParameters.ASSET);
    bytes32 private constant OPEN = bytes32("job.open@job-1");
    bytes32 private constant CONTINUE = bytes32("job.continue@job-1");
    BurnTrackerTest private tracker;
    address private owner = makeAddr("fork owner");
    address private caller = makeAddr("fork updater");
    bytes private constant OPEN_BODY = '{"objective":"Host the IMD burn tracker.","skill":"import-site","host":true}';

    function setUp() public {
        try vm.activeFork() returns (uint256) {}
        catch {
            vm.skip(true);
            return;
        }
        assertEq(block.chainid, 1);
        assertEq(block.number, 26258169);
        assertGt(address(INTAKE).code.length, 0);
        assertGt(address(IMD).code.length, 0);
        tracker = new BurnTrackerTest(
            owner,
            address(INTAKE),
            address(IMD),
            OPEN,
            CONTINUE,
            LaunchParameters.prefix(),
            LaunchParameters.suffix(),
            86400,
            172800
        );
        deal(address(IMD), owner, 10 ether);
        deal(address(IMD), caller, 10 ether);
        vm.prank(owner);
        IMD.approve(address(tracker), 10 ether);
        vm.prank(caller);
        IMD.approve(address(tracker), 10 ether);
    }

    function testMainnetRealIntakeRecordsTrackerAsPayerAndDeliversCallbacks() public {
        assertEq(INTAKE.callbackGas(), 200_000);
        uint256 amount = INTAKE.priceOf(OPEN, address(IMD));
        address treasury = INTAKE.payTo();
        uint256 beforeBalance = IMD.balanceOf(treasury);
        vm.prank(owner);
        bytes32 id = tracker.open(OPEN_BODY);
        _recorded(id);
        assertEq(IMD.balanceOf(owner), 10 ether - amount);
        assertEq(IMD.balanceOf(treasury), beforeBalance + amount);
        (bytes memory document, bytes32 hash,) = RealResults.get(6);
        _complete(id, hash);
        assertEq(tracker.resultHash(), hash);
        vm.warp(tracker.nextUpdateAt());
        uint256 livePrice = tracker.price();
        vm.prank(caller);
        bytes32 next = tracker.updateBurntracker(document, livePrice);
        _recorded(next);
        assertEq(IMD.balanceOf(address(tracker)), 0);
        assertEq(IMD.allowance(address(tracker), address(INTAKE)), 0);
        vm.prank(INTAKE.writer());
        INTAKE.complete{gas: 500_000}(
            next, 1, 0, "", abi.encode(next, uint8(1), bytes32("admission_refused"), uint16(0), uint16(0), bytes(""))
        );
        (uint8 state,,,,,,) = tracker.status();
        assertEq(state, 2);
    }

    function testMainnet4545ByteProofBelow300000ExecutionGas() public {
        (bytes memory document, bytes32 hash, string memory jobId) = RealResults.get(6);
        assertEq(document.length, 4545);
        assertEq(keccak256(document), hash);
        vm.prank(owner);
        bytes32 id = tracker.open(OPEN_BODY);
        _complete(id, hash);
        vm.warp(tracker.nextUpdateAt());
        uint256 maxPrice = tracker.price();
        UpdateCaller meter = new UpdateCaller();
        deal(address(IMD), address(meter), 10 ether);
        meter.approve(address(IMD), address(tracker), maxPrice);
        address treasury = INTAKE.payTo();
        vm.cool(address(tracker));
        vm.cool(address(IMD));
        vm.cool(address(INTAKE));
        vm.cool(treasury);
        vm.recordLogs();
        (bytes32 next, uint256 executionGas) = meter.measure(tracker, document, maxPrice);
        _recorded(next);
        emit log_named_uint("4545-byte proof execution gas (cold accounts/storage)", executionGas);
        assertLt(executionGas, 300_000);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bool found;
        for (uint256 i; i < logs.length; ++i) {
            if (
                logs[i].emitter == address(INTAKE)
                    && logs[i].topics[0]
                        == keccak256("Requested(bytes32,address,bytes32,bytes,address,bytes4,address,uint256)")
            ) {
                assertEq(logs[i].topics[2], bytes32(uint256(uint160(address(tracker)))));
                assertEq(logs[i].topics[3], CONTINUE);
                (bytes memory body,,,,) = abi.decode(logs[i].data, (bytes, address, bytes4, address, uint256));
                assertEq(body, bytes.concat(LaunchParameters.prefix(), bytes(jobId), LaunchParameters.suffix()));
                found = true;
            }
        }
        assertTrue(found);
    }

    function _recorded(bytes32 id) private view {
        (address payer, address target, bytes4 selector, bool completed) = INTAKE.requests(id);
        assertEq(payer, address(tracker));
        assertEq(target, address(tracker));
        assertEq(selector, tracker.onResult.selector);
        assertFalse(completed);
        assertEq(INTAKE.failureSelectorOf(id), tracker.onFailure.selector);
    }

    function _complete(bytes32 id, bytes32 hash) private {
        vm.prank(INTAKE.writer());
        INTAKE.complete{gas: 500_000}(
            id, 0, hash, "ipfs://fixture/result.json", abi.encode(id, hash, "ipfs://fixture/result.json")
        );
        (uint8 state,,,,,,) = tracker.status();
        assertEq(state, 2);
    }
}
