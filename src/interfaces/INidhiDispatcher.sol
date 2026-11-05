// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Mandate} from "../libraries/Mandate.sol";

interface INidhiDispatcher {
    /// @notice Called by NidhiHook after it has moved `amount` of `m.tokenOut` into the dispatcher.
    function dispatch(Mandate calldata m, uint256 amount) external returns (bytes32 messageId);
}
