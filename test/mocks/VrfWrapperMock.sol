// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {IVRFV2PlusWrapperLike} from "../../contracts/interfaces/IVRFV2PlusWrapperLike.sol";

interface IRndConsumerCallback {
    function rawFulfillRandomWords(uint256 requestId, uint256[] calldata randomWords) external;
}

/// @notice VRF v2.5 wrapper stub. Quotes a fixed native fee and fulfills on demand.
contract VrfWrapperMock is IVRFV2PlusWrapperLike {
    uint256 public requestPrice;
    uint256 private _nextRequestId = 1;
    mapping(uint256 requestId => address consumer) private _consumers;

    constructor(uint256 requestPrice_) {
        requestPrice = requestPrice_;
    }

    function link() external pure override returns (address) {
        return address(0);
    }

    function calculateRequestPriceNative(uint32, uint32) external view override returns (uint256) {
        return requestPrice;
    }

    function estimateRequestPriceNative(uint32, uint32, uint256) external view override returns (uint256) {
        return requestPrice;
    }

    function requestRandomWordsInNative(
        uint32,
        uint16,
        uint32,
        bytes calldata
    ) external payable override returns (uint256 requestId) {
        requestId = _nextRequestId++;
        _consumers[requestId] = msg.sender;
    }

    function fulfill(uint256 requestId, uint256[] calldata randomWords) external {
        address consumer = _consumers[requestId];
        delete _consumers[requestId];
        IRndConsumerCallback(consumer).rawFulfillRandomWords(requestId, randomWords);
    }
}
