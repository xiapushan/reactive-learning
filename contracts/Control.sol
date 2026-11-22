// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

/// @title Control — D5 动态订阅实验的「控制信道」（部署在 Sepolia）
/// @notice 用两个事件控制 Reactive 合约的订阅：
///         - WatchToken(token)：让 Reactive 合约**新增**一个代币的订阅
///         - Stop()：让 Reactive 合约**取消**全部订阅
/// @dev 真实项目里这个角色通常由治理合约或管理面板的合约承担。
contract Control {
    event WatchToken(address indexed token);
    event Stop();

    /// @notice 让监控合约开始监听某个代币
    function watch(address token) external {
        emit WatchToken(token);
    }

    /// @notice 让监控合约停止一切监听
    function stop() external {
        emit Stop();
    }
}
