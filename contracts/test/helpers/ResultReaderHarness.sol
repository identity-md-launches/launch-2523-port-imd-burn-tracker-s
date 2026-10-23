// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ResultJson} from "../../src/libraries/ResultJson.sol";

contract ResultReaderHarness {
    function authenticated(bytes calldata json) external pure returns (bytes memory) {
        return ResultJson.authenticatedParentId(json);
    }
}
