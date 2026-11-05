// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Client} from "@chainlink/contracts-ccip/contracts/libraries/Client.sol";

/// @notice Single place for CCIP extraArgs encoding.
/// @dev Uses GenericExtraArgsV2 (tag 0x181dcf10). CCIP 2.0 lanes still accept it and honour gasLimit;
///      ExtraArgsV3 (tag 0xa69dd4aa, ExtraArgsCodec) can be swapped in here without touching callers.
library ExtraArgsLib {
    function encode(uint256 gasLimit) internal pure returns (bytes memory) {
        return Client._argsToBytes(Client.GenericExtraArgsV2({gasLimit: gasLimit, allowOutOfOrderExecution: true}));
    }
}
