// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BurnTracker} from "../../src/BurnTracker.sol";
import {IERC20} from "../../vendor/openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @dev Measures the function call in a nested frame so Foundry isolation cannot add transaction
/// intrinsic/calldata gas to gasleft(). Includes the CALL and ABI encoding overhead, before refunds.
contract UpdateCaller {
    function approve(address token, address tracker, uint256 amount) external {
        require(IERC20(token).approve(tracker, amount));
    }

    function measure(BurnTracker tracker, bytes calldata document, uint256 maxPrice)
        external
        returns (bytes32 id, uint256 gasUsed)
    {
        uint256 start = gasleft();
        id = tracker.updateBurntracker(document, maxPrice);
        gasUsed = start - gasleft();
    }
}
