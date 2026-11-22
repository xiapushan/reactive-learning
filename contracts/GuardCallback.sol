// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import { IPayable } from "@reactive/src/interfaces/IPayable.sol";
import { AbstractCallback } from "@reactive/src/base/AbstractCallback.sol";

/// @title GuardCallback — D4 场景 2 的目标链「告警」合约（部署在 Sepolia）
/// @notice 只接受「本链 Callback Proxy」发来、且 payload 里的 reactive 地址等于 _CALLBACK_SENDER 的调用。
/// @dev    两道校验缺一不可：
///         - onlyServiceProvider：msg.sender 必须是 Callback Proxy，防止任何人绕过代理直接调
///         - onlyCallbackSender：payload 首参必须是我们那个 Reactive 合约，防止别的合约冒充
///         回调由本合约支付 gas，所以部署时必须带 ETH，否则收不到回调。
contract GuardCallback is AbstractCallback {
    /// @notice 每次告警触发时发出；这笔交易哈希就是本任务的提交证据
    event Guarded(
        address indexed token,
        uint256 amount,
        uint256 originTxHash,
        uint256 seq,
        uint256 atTimestamp
    );

    uint256 public alerts;
    uint256 public lastAmount;
    uint256 public lastOriginTxHash;
    /// @notice 用时间戳而不是块高记录时间（Base Sepolia 200ms 出块时块高不可做时间基准）
    uint256 public lastAlertAt;

    /// @param proxy_    本链的 Callback Proxy 地址
    /// @param reactive_ 允许给本合约发回调的 Reactive 合约地址（immutable，填错只能重新部署）
    constructor(IPayable proxy_, address reactive_) payable AbstractCallback(proxy_, reactive_) {}

    /// @notice 被 Callback Proxy 调用的函数。
    /// @dev 第一个参数由网络注入真实 reactive 地址，不是 payload 里填的 address(0)。
    function onEvent(
        address reactive_,
        address token_,
        uint256 amount_,
        uint256 originTxHash_
    ) external onlyServiceProvider onlyCallbackSender(reactive_) {
        alerts += 1;
        lastAmount = amount_;
        lastOriginTxHash = originTxHash_;
        lastAlertAt = block.timestamp;

        emit Guarded(token_, amount_, originTxHash_, alerts, block.timestamp);
    }
}
