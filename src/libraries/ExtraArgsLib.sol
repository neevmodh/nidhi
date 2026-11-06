// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Client} from "@chainlink/contracts-ccip/contracts/libraries/Client.sol";
import {ExtraArgsCodec} from "@chainlink/contracts-ccip/contracts/libraries/ExtraArgsCodec.sol";

/// @notice Single place for CCIP extraArgs encoding.
/// @dev Default: GenericExtraArgsV2 (tag 0x181dcf10), which waits for full source-chain finality.
///      With a requested finality (CCIP 2.0 Faster-Than-Finality, see FinalityCodec), GenericExtraArgsV3
///      (tag 0xa69dd4aa) carries it: e.g. a block depth of 32 lets CCIP deliver after 32 source blocks instead of
///      full finality. The lane's token pool and the receiver must both allow that depth.
library ExtraArgsLib {
    function encode(uint256 gasLimit) internal pure returns (bytes memory) {
        return Client._argsToBytes(Client.GenericExtraArgsV2({gasLimit: gasLimit, allowOutOfOrderExecution: true}));
    }

    /// @param finality bytes4(0) = wait for finality (V2); otherwise a FinalityCodec value sent in V3.
    function encode(uint32 gasLimit, bytes4 finality) internal pure returns (bytes memory) {
        if (finality == bytes4(0)) return encode(gasLimit);
        return ExtraArgsCodec._getBasicEncodedExtraArgsV3(gasLimit, finality);
    }
}
