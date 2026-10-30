// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

/// @notice Local deploy stand-in. CoinLotto only needs setDelegate during construction.
contract EndpointStandIn {
    function setDelegate(address) external {}
}
