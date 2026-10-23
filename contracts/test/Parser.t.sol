// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {TrackerFixture, RealResults} from "./helpers/TrackerFixture.sol";
import {ResultJson} from "../src/libraries/ResultJson.sol";
import {ResultReaderHarness} from "./helpers/ResultReaderHarness.sol";

contract ParserTest is TrackerFixture {
    ResultReaderHarness private reader;

    function setUp() public override {
        super.setUp();
        reader = new ResultReaderHarness();
    }

    function _bad(bytes memory document) internal {
        vm.expectRevert(ResultJson.InvalidResultJson.selector);
        tracker.parentJobIdOf(document);
    }

    function testMissingDuplicateNestedDuplicateAndWrongTypeRejected() public {
        _bad("");
        _bad("{}");
        _bad('{"parentJobId":"4c5dbeb7-9acb-4a64-b204-9f55e6d78ada"}');
        _bad(bytes(string.concat('{"jobId":"', PARENT, '","jobId":"', PARENT, '"}')));
        _bad(bytes(string.concat('{"jobId":"', PARENT, '","nested":{"jobId":"', PARENT, '"}}')));
        _bad('{"jobId":null}');
        _bad('{"jobId":123}');
        _bad('{"jobId":true}');
        _bad('{"jobId":{}}');
        _bad('{"jobId":[]}');
        _bad('{"jobId":""}');
    }

    function testMalformedUuidRejected() public {
        string[8] memory ids = [
            "4C5dbeb7-9acb-4a64-b204-9f55e6d78ada",
            "4c5dbeb79-acb-4a64-b204-9f55e6d78ada",
            "4c5dbeb7-9acb-4a64-b204-9f55e6d78adz",
            "4c5dbeb7_9acb-4a64-b204-9f55e6d78ada",
            "4c5dbeb7-9acb-4a64-b204-9f55e6d78ad",
            "4c5dbeb7-9acb-4a64-b204-9f55e6d78adaa",
            " 4c5dbeb7-9acb-4a64-b204-9f55e6d78ada",
            "4c5dbeb7-9acb-4a64-b204-9f55e6d78ada "
        ];
        for (uint256 i; i < ids.length; ++i) {
            _bad(bytes(string.concat('{"jobId":"', ids[i], '"}')));
        }
    }

    function testEscapedQuotesAndBackslashesCannotForgeKeys() public {
        _bad(bytes(string.concat('{"note":"\\\"jobId\\\":\\\"', PARENT, '\\\""}')));
        bytes memory document = bytes(
            string.concat(
                '{"before":"slash\\\\ and quote\\\"jobId\\\":\\\"ignored",',
                '"jobId":"',
                PARENT,
                '","after":"\\\"jobId\\\":\\\"also ignored"}'
            )
        );
        assertEq(tracker.parentJobIdOf(document), bytes(PARENT));
        _bad(bytes(string.concat('{"job\\u0049d":"', PARENT, '"}')));
        _bad(bytes(string.concat('{"jobId":"', PARENT, '","\\u006aobId":"', PARENT, '"}')));
        _bad('{"jobId":"\\u0034c5dbeb7-9acb-4a64-b204-9f55e6d78ada"}');
    }

    function testValidNestedJsonWhitespaceEscapesNumbersAndUnicode() public view {
        bytes memory document = bytes(
            string.concat(
                unicode' \n{ "array": [null,true,false,0,-2,1.4,5e2,6E-2,7e+3,{"text":"Café € \\b\\f\\n\\r\\t\\/\\u20ac"}], "jobId" \t:\r "',
                PARENT,
                '" } \n'
            )
        );
        assertEq(tracker.parentJobIdOf(document), bytes(PARENT));
    }

    function testMalformedGrammarRejected() public {
        bytes[18] memory bad = [
            bytes('{"x":"unterminated}'),
            bytes('{"x":"\\q"}'),
            bytes('{"x":"\\u123z"}'),
            bytes('{"x":"raw\nline"}'),
            bytes('{"x":01}'),
            bytes('{"x":-}'),
            bytes('{"x":1.}'),
            bytes('{"x":1e}'),
            bytes('{"x":1e+}'),
            bytes('{"x":tru}'),
            bytes('{"x":falseX}'),
            bytes('{"x":nulla}'),
            bytes('{"x":[]} trailing'),
            bytes('{"x":[1,]}'),
            bytes('{"x":{},}'),
            bytes('{"x" "no colon"}'),
            bytes('[{"jobId":"4c5dbeb7-9acb-4a64-b204-9f55e6d78ada"}]'),
            bytes('{"x":{')
        ];
        for (uint256 i; i < bad.length; ++i) {
            _bad(bad[i]);
        }
        _bad(bytes.concat(_proof(), "x"));
    }

    function testStringValueNamedJobIdIsNotAKey() public {
        _bad('{"x":"jobId"}');
        assertEq(tracker.parentJobIdOf(bytes(string.concat('{"x":"jobId","jobId":"', PARENT, '"}'))), bytes(PARENT));
    }

    function testBoundsAndDepthCannotExhaustUnboundedGas() public {
        _bad(new bytes(16_385));
        bytes memory document = _proof();
        for (uint256 i; i < 66; ++i) {
            document = bytes.concat('{"x":', document, "}");
        }
        _bad(document);
    }

    function testEveryTruncationOfRealDocumentIsRejected() public {
        (bytes memory document,,) = RealResults.get(4); // 750-byte API fixture
        uint256 len = document.length;
        for (uint256 i; i < len; ++i) {
            assembly ("memory-safe") { mstore(document, i) }
            _bad(document);
        }
        assembly ("memory-safe") { mstore(document, len) }
        assertEq(tracker.parentJobIdOf(document).length, 36);
    }

    function testFuzzValidUuidAndEscapedValue(bytes16 raw, uint8 padding) public view {
        bytes memory id = _uuid(raw);
        bytes memory pad = new bytes(uint256(padding));
        for (uint256 i; i < pad.length; ++i) {
            pad[i] = "a";
        }
        // Vary quote/backslash positions across every 32-byte scanning boundary.
        bytes memory document = bytes.concat(
            '{"before":"', pad, '\\\"jobId\\\":\\\"fake\\\\", "jobId":"', id, '","after":[true,false,null]}'
        );
        assertEq(tracker.parentJobIdOf(document), id);
        assertEq(reader.authenticated(document), id);
    }

    function testFuzzMalformedUuidCharacter(bytes16 raw, uint8 at) public {
        bytes memory id = _uuid(raw);
        id[uint256(at) % 36] = "G";
        _bad(bytes.concat('{"jobId":"', id, '"}'));
    }

    function testUuidClassifierEveryByteAtEveryPosition() public pure {
        bytes memory id = bytes("01234567-89ab-cdef-0123-456789abcdef");
        for (uint256 at; at < 36; ++at) {
            bytes1 previous = id[at];
            bool separator = at == 8 || at == 13 || at == 18 || at == 23;
            for (uint256 c; c < 256; ++c) {
                id[at] = bytes1(uint8(c));
                bool expected = separator ? c == 45 : (c >= 48 && c <= 57) || (c >= 97 && c <= 102);
                assertEq(ResultJson.isUuid(id), expected);
            }
            id[at] = previous;
        }
        assertFalse(ResultJson.isUuid(new bytes(35)));
        assertFalse(ResultJson.isUuid(new bytes(37)));
    }

    function testUuidClassifierIgnoresMemoryPadding() public pure {
        bytes memory id = bytes.concat(bytes(PARENT), hex"ffffffffffffffffffffffffffffffffffffffffffffffffffffffff");
        assembly ("memory-safe") { mstore(id, 36) }
        assertTrue(ResultJson.isUuid(id));
    }

    function testFuzzWordScannerAcrossChunkBoundariesAndBorrowCandidates(bytes16 raw, uint16 padding) public view {
        bytes memory id = _uuid(raw);
        bytes memory pad = new bytes(uint256(padding) % 1024);
        for (uint256 i; i < pad.length; ++i) {
            // H immediately before I can set an extra bit in the coarse filter.
            pad[i] = i % 2 == 0 ? bytes1("H") : bytes1("I");
        }
        bytes memory document =
            bytes.concat('{"before":"', pad, '\\\"jobId\\\":\\\"fake", "jobId":"', id, '","after":"IHIH"}');
        assertEq(reader.authenticated(document), id);
        assertEq(tracker.parentJobIdOf(document), id);
    }

    function testFuzzArbitraryInputNeverPanics(bytes memory document) public view {
        (bool ok, bytes memory returned) =
            address(tracker).staticcall(abi.encodeCall(tracker.parentJobIdOf, (document)));
        if (ok) assertTrue(ResultJson.isUuid(abi.decode(returned, (bytes))));
        else assertEq(returned, abi.encodeWithSelector(ResultJson.InvalidResultJson.selector));
    }

    function testAuthenticatedReaderMatchesStrictReaderOnEveryRealDocument() public view {
        for (uint256 i; i < RealResults.count(); ++i) {
            (bytes memory document,, string memory jobId) = RealResults.get(i);
            assertEq(reader.authenticated(document), bytes(jobId));
            assertEq(reader.authenticated(document), tracker.parentJobIdOf(document));
        }
    }

    function testAuthenticatedReaderIgnoresTrailingCalldataOutsideDocument() public view {
        bytes memory payload = bytes.concat(abi.encodeCall(reader.authenticated, (_proof())), _proof());
        (bool ok, bytes memory returned) = address(reader).staticcall(payload);
        assertTrue(ok);
        assertEq(abi.decode(returned, (bytes)), bytes(PARENT));
    }

    function testAuthenticatedReaderRejectsMissingDuplicateAndMalformedKeys() public {
        vm.expectRevert(ResultJson.InvalidResultJson.selector);
        reader.authenticated("{}");
        vm.expectRevert(ResultJson.InvalidResultJson.selector);
        reader.authenticated(bytes(string.concat('{"jobId":"', PARENT, '","x":{"jobId":"', PARENT, '"}}')));
        vm.expectRevert(ResultJson.InvalidResultJson.selector);
        reader.authenticated('{"jobId":null}');
        vm.expectRevert(ResultJson.InvalidResultJson.selector);
        reader.authenticated('{"jobId":"bad"}');
        vm.expectRevert(ResultJson.InvalidResultJson.selector);
        reader.authenticated(bytes(string.concat('{"x":"\\\"jobId\\\":\\\"', PARENT, '\\\""}')));
    }

    function testFuzzAuthenticatedReaderCountsDuplicateKeys(bytes16 raw, uint8 padding) public {
        bytes memory id = _uuid(raw);
        bytes memory pad = new bytes(uint256(padding));
        for (uint256 i; i < pad.length; ++i) {
            pad[i] = "j";
        }
        bytes memory document = bytes.concat('{"jobId":"', id, '","pad":"', pad, '","nested":{"jobId":"', id, '"}}');
        vm.expectRevert(ResultJson.InvalidResultJson.selector);
        reader.authenticated(document);
    }

    function _uuid(bytes16 raw) private pure returns (bytes memory id) {
        bytes16 alphabet = "0123456789abcdef";
        id = new bytes(36);
        uint256 j;
        for (uint256 i; i < 36; ++i) {
            if (i == 8 || i == 13 || i == 18 || i == 23) {
                id[i] = "-";
            } else {
                uint8 b = uint8(raw[j / 2]);
                id[i] = alphabet[j % 2 == 0 ? b >> 4 : b & 15];
                ++j;
            }
        }
    }
}
