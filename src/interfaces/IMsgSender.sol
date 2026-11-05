// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @notice Implemented by the trusted router so the hook can learn the real initiator.
interface IMsgSender {
    function msgSender() external view returns (address);
}
