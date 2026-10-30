// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

/// @notice Local deploy stand-in. RndConsumer only reads link() during construction.
contract VrfWrapperStandIn {
    function link() external pure returns (address) {
        return address(0);
    }
}
