// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @notice Wire format shared by NidhiDispatcher (source) and DestinationReceiver (destination).
library AckLib {
    /// Destination-side outcome reported back to the source chain.
    uint8 internal constant PAID = 1; // recipient paid on arrival or on retry
    uint8 internal constant HELD = 2; // payout failed or paused; funds held by the receiver, recoverable
    uint8 internal constant RECOVERED = 3; // held funds released by the DAO to a recovery address

    /// Source -> destination payload (tokens travel alongside as a CCIP programmable token transfer).
    function encodeGrant(bytes32 grantId, address recipient, uint256 amount) internal pure returns (bytes memory) {
        return abi.encode(grantId, recipient, amount);
    }

    function decodeGrant(bytes memory data) internal pure returns (bytes32, address, uint256) {
        return abi.decode(data, (bytes32, address, uint256));
    }

    /// Destination -> source acknowledgement. `sourceMessageId` is the CCIP messageId of the grant transfer.
    function encodeAck(bytes32 grantId, bytes32 sourceMessageId, uint256 amount, uint8 outcome)
        internal
        pure
        returns (bytes memory)
    {
        return abi.encode(grantId, sourceMessageId, amount, outcome);
    }

    function decodeAck(bytes memory data) internal pure returns (bytes32, bytes32, uint256, uint8) {
        return abi.decode(data, (bytes32, bytes32, uint256, uint8));
    }
}
