// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BurnTracker} from "./BurnTracker.sol";

/// @notice The first launch's name. No additional state, functions, or behavior.
contract BurnTrackerTest is BurnTracker {
    constructor(
        address owner_,
        address intake_,
        address asset_,
        bytes32 openAction_,
        bytes32 continueAction_,
        bytes memory bodyPrefix_,
        bytes memory bodySuffix_,
        uint32 cooldown_,
        uint32 staleAfter_
    )
        BurnTracker(
            owner_, intake_, asset_, openAction_, continueAction_, bodyPrefix_, bodySuffix_, cooldown_, staleAfter_
        )
    {}
}
