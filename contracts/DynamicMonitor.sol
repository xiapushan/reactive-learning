// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import { IReactive } from "@reactive/src/interfaces/IReactive.sol";
import { ISystemContract } from "@reactive/src/interfaces/ISystemContract.sol";
import { AbstractReactive } from "@reactive/src/base/AbstractReactive.sol";

/// @title DynamicMonitor — D5 动态订阅实验（部署在 Lasna）
/// @notice 运行时**增删订阅**的完整演示：
///
///   初始订阅：代币 A 的 Transfer + 控制合约的 WatchToken / Stop
///   收到 WatchToken(tokenB) → **新增**订阅 tokenB 的 Transfer
///   收到 Stop()            → **取消**全部订阅，之后任何事件都不再唤醒本合约
///
/// @dev 关键工程点（也是本任务要的「防失控」）：
///      1. 订阅存在节点里、合约读不回来 → 自己在 `tokens` 里记账，退订时按账本逐个退
///      2. 业务事件有 `remaining` 硬上限，归零自动 `_stopAll()`
///      3. 控制事件（WatchToken / Stop）**不消耗** `remaining`，否则可能没机会停
///      4. 只订阅白名单里的代币，绝不用 `address(0)` 通配（否则会被全链转账烧穿余额）
contract DynamicMonitor is AbstractReactive {
    event Seen(address indexed token, uint256 value, uint256 count, uint256 remaining);
    event SubAdded(address indexed token, uint256 totalSubs);
    event SubRemovedAll(uint256 tokensRemoved, uint256 atBlock);
    event KillSwitchMissing();

    uint256 public constant SEPOLIA_CHAIN_ID = 11155111;

    /// @dev keccak256("Transfer(address,address,uint256)")
    uint256 public constant TRANSFER_TOPIC_0 =
        0xddf252ad1be2c89b69c2b068fc378daa952ba7f163c4a11628f55a4df523b3ef;
    /// @dev keccak256("WatchToken(address)")
    uint256 public constant WATCH_TOPIC_0 = uint256(keccak256("WatchToken(address)"));
    /// @dev keccak256("Stop()")
    uint256 public constant STOP_TOPIC_0 = uint256(keccak256("Stop()"));

    /// @notice 控制信道合约（Sepolia）
    address public immutable CONTROL;

    /// @notice 已订阅的代币清单 —— 订阅读不回来，只能自己记账
    address[] public tokens;
    mapping(address => bool) public isWatched;

    /// @notice 业务触发次数（Transfer 命中）
    uint256 public count;
    /// @notice 还剩多少次业务触发额度
    uint256 public remaining;
    /// @notice 是否已经停摆（收到 Stop 或额度耗尽）
    bool public stopped;

    uint256 public lastReactBlock;
    uint256 public lastValue;

    /// @param control_    控制信道合约地址
    /// @param firstToken_ 初始就监听的那个代币
    /// @param limit_      最多处理多少次 Transfer（硬上限）
    constructor(address control_, address firstToken_, uint256 limit_) payable {
        CONTROL = control_;
        remaining = limit_;

        _subToken(firstToken_);
        _subControl(WATCH_TOPIC_0);
        _subControl(STOP_TOPIC_0);
    }

    // ---------- 订阅管理 ----------

    function _subToken(address token_) internal {
        require(token_ != address(0), "zero token");
        require(!isWatched[token_], "already watched");
        isWatched[token_] = true;
        tokens.push(token_);

        // 只订「这个代币的 Transfer」，from/to 都不关心
        SYSTEM.subscribe(
            SEPOLIA_CHAIN_ID,
            token_,
            TRANSFER_TOPIC_0,
            REACTIVE_IGNORE,
            REACTIVE_IGNORE,
            REACTIVE_IGNORE
        );
        emit SubAdded(token_, tokens.length);
    }

    function _unsubToken(address token_) internal {
        // 退订参数必须和订阅时逐字一致，否则静默失败
        SYSTEM.unsubscribe(
            SEPOLIA_CHAIN_ID,
            token_,
            TRANSFER_TOPIC_0,
            REACTIVE_IGNORE,
            REACTIVE_IGNORE,
            REACTIVE_IGNORE
        );
    }

    function _subControl(uint256 topic0_) internal {
        SYSTEM.subscribe(
            SEPOLIA_CHAIN_ID,
            CONTROL,
            topic0_,
            REACTIVE_IGNORE,
            REACTIVE_IGNORE,
            REACTIVE_IGNORE
        );
    }

    function _unsubControl(uint256 topic0_) internal {
        SYSTEM.unsubscribe(
            SEPOLIA_CHAIN_ID,
            CONTROL,
            topic0_,
            REACTIVE_IGNORE,
            REACTIVE_IGNORE,
            REACTIVE_IGNORE
        );
    }

    /// @dev 取消全部订阅。这是「防失控」的最后一道闸。
    function _stopAll() internal {
        if (stopped) return;
        stopped = true;

        uint256 n = tokens.length;
        for (uint256 i = 0; i < n; i++) {
            _unsubToken(tokens[i]);
        }
        _unsubControl(WATCH_TOPIC_0);
        _unsubControl(STOP_TOPIC_0);

        emit SubRemovedAll(n, block.number);
    }

    /// @notice 任何地址都能触发的紧急停止（真实项目里应加权限）
    function emergencyStop() external {
        _stopAll();
    }

    // ---------- 事件入口 ----------

    /// @inheritdoc IReactive
    function react(LogRecord calldata log_) external onlySystem {
        if (stopped) return;

        uint256 t0 = log_.topic0;

        // ① 控制事件：新增订阅（不消耗业务额度）
        if (t0 == WATCH_TOPIC_0) {
            if (log_.contractAddress != CONTROL) return;
            address token_ = address(uint160(log_.topic1)); // indexed token
            if (!isWatched[token_]) {
                _subToken(token_);
            }
            return;
        }

        // ② 控制事件：停止一切（不消耗业务额度）
        if (t0 == STOP_TOPIC_0) {
            if (log_.contractAddress != CONTROL) return;
            _stopAll();
            return;
        }

        // ③ 业务事件：某个被监听的代币发生了转账
        if (t0 == TRANSFER_TOPIC_0) {
            if (!isWatched[log_.contractAddress]) return; // 防御：不在白名单一律忽略

            uint256 value = log_.data.length >= 32 ? abi.decode(log_.data, (uint256)) : 0;
            count += 1;
            lastValue = value;
            lastReactBlock = block.number;

            emit Seen(log_.contractAddress, value, count, remaining);

            unchecked {
                remaining -= 1;
            }
            if (remaining == 0) {
                _stopAll(); // 额度用尽 → 自动退订
            }
        }
    }
}
