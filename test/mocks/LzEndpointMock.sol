// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {
    MessagingParams,
    MessagingFee,
    MessagingReceipt,
    Origin
} from "@layerzerolabs/lz-evm-protocol-v2/contracts/interfaces/ILayerZeroEndpointV2.sol";

interface ILzReceiver {
    function lzReceive(
        Origin calldata origin,
        bytes32 guid,
        bytes calldata message,
        address executor,
        bytes calldata extraData
    ) external payable;
}

/// @notice LayerZero EndpointV2 stub that can quote, send, and deliver an OFT message.
contract LzEndpointMock {
    bytes32 public constant GUID = keccak256("coinlotto-test-guid");

    uint256 public nativeFee;

    function setNativeFee(uint256 nativeFee_) external {
        nativeFee = nativeFee_;
    }

    function setDelegate(address) external {}

    function lzToken() external pure returns (address) {
        return address(0);
    }

    function quote(MessagingParams calldata, address) external view returns (MessagingFee memory) {
        return MessagingFee({nativeFee: nativeFee, lzTokenFee: 0});
    }

    function send(MessagingParams calldata, address) external payable returns (MessagingReceipt memory) {
        return MessagingReceipt({guid: GUID, nonce: 1, fee: MessagingFee({nativeFee: msg.value, lzTokenFee: 0})});
    }

    function sendCompose(address, bytes32, uint16, bytes calldata) external {}

    function deliver(address oapp, Origin calldata origin, bytes32 guid, bytes calldata message) external {
        ILzReceiver(oapp).lzReceive(origin, guid, message, address(this), "");
    }
}
