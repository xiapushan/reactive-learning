// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import { IReactive } from "@reactive/src/interfaces/IReactive.sol";
import { ISystemContract } from "@reactive/src/interfaces/ISystemContract.sol";
import { AbstractReactive } from "@reactive/src/base/AbstractReactive.sol";

/// @title GuardReactive — D4 场景 2「钱包守护」的 Reactive 侧（部署在 Lasna）
/// @notice 监控「我的热钱包在 Sepolia 上转出 ERC-20」，单笔超过阈值就在目标链触发告警动作。
///
///         与 D3 的 TransferMonitor 相比，这里多做了两件「场景 2」该有的事：
///         1. 订阅时把 topic1 钉死成热钱包地址 —— 只收「我转出」，别人转给我一律不进 react()
///         2. 命中后不只计数，而是请求跨链回调，让目标链真的做一件事
contract GuardReactive is AbstractReactive {
    event Seen(address indexed token, uint256 value, bool alerted, uint256 remaining);
    event AlertRequested(uint256 indexed destChainId, address indexed recipient, uint256 value);

    uint256 public constant SEPOLIA_CHAIN_ID = 11155111;
    /// @dev keccak256("Transfer(address,address,uint256)")
    uint256 public constant ERC20_TRANSFER_TOPIC_0 =
        0xddf252ad1be2c89b69c2b068fc378daa952ba7f163c4a11628f55a4df523b3ef;

    address public immutable TOKEN;
    /// @notice 被守护的热钱包
    address public immutable HOT_WALLET;
    /// @notice 单笔转出达到这个数额才告警
    uint256 public immutable THRESHOLD;
    uint256 public immutable DEST_CHAIN_ID;
    /// @dev 实测教训：请求 400,000 时，Callback Proxy 扣掉 _extraGas(150k) 与 _maxChargeGas(50k)
    ///      以及自身开销后，只转发约 155,000 gas，onEvent 里的 4 个 SSTORE 直接 OutOfGas。
    ///      回调 gas 必须留足余量——这里用 1,000,000（与模板一致）。
    uint64 public constant CALLBACK_GAS_LIMIT = 1_000_000;

    /// @notice 目标链上的告警合约，部署后再 setRecipient 绑定
    address public recipient;

    uint256 public remaining;
    uint256 public matched;
    uint256 public filtered;
    uint256 public lastTxHash;
    uint256 public lastReactBlock;

    /// @param token_      被监控的 ERC-20（Sepolia）
    /// @param hotWallet_  被守护的热钱包地址
    /// @param threshold_  单笔转出阈值（wei 单位）
    /// @param destChainId_ 告警落在哪条链
    /// @param limit_      最多处理多少次
    constructor(
        address token_,
        address hotWallet_,
        uint256 threshold_,
        uint256 destChainId_,
        uint256 limit_
    ) payable {
        TOKEN = token_;
        HOT_WALLET = hotWallet_;
        THRESHOLD = threshold_;
        DEST_CHAIN_ID = destChainId_;
        remaining = limit_;

        // 订阅：Sepolia 上「这个代币」的 Transfer，
        // topic1 = from = 热钱包地址（address 左补零成 uint256）→ 只听我自己的转出
        // 其余 topic 全部 REACTIVE_IGNORE
        SYSTEM.subscribe(
            SEPOLIA_CHAIN_ID,
            token_,
            ERC20_TRANSFER_TOPIC_0,
            uint256(uint160(hotWallet_)),
            REACTIVE_IGNORE,
            REACTIVE_IGNORE
        );
    }

    function setRecipient(address recipient_) external {
        require(msg.sender == HOT_WALLET, "not owner");
        recipient = recipient_;
    }

    /// @inheritdoc IReactive
    function react(LogRecord calldata log_) external onlySystem {
        if (log_.topic0 != ERC20_TRANSFER_TOPIC_0) return;
        if (log_.contractAddress != TOKEN) return;
        if (remaining == 0) return;

        // Transfer 的 value 是唯一的非 indexed 字段
        uint256 value = log_.data.length >= 32 ? abi.decode(log_.data, (uint256)) : 0;

        lastTxHash = log_.txHash;
        lastReactBlock = block.number;

        // 低于阈值用 return 过滤（revert 照样收费）
        if (value < THRESHOLD || recipient == address(0)) {
            filtered += 1;
            emit Seen(TOKEN, value, false, remaining);
            return;
        }

        matched += 1;
        emit Seen(TOKEN, value, true, remaining);
        emit AlertRequested(DEST_CHAIN_ID, recipient, value);

        // 第一个参数 address(0) 是占位符，Proxy 会替换成真实的 reactive 地址
        bytes memory payload = abi.encodeWithSignature(
            "onEvent(address,address,uint256,uint256)",
            address(0),
            TOKEN,
            value,
            log_.txHash
        );

        SYSTEM.requestCallbackV_1_0(
            ISystemContract.CallbackConfiguration_V_1_0({
                chainId: DEST_CHAIN_ID,
                recipient: recipient,
                gasLimit: CALLBACK_GAS_LIMIT,
                payload: payload
            })
        );

        unchecked {
            remaining -= 1;
        }
        if (remaining == 0) {
            SYSTEM.unsubscribe(
                SEPOLIA_CHAIN_ID,
                TOKEN,
                ERC20_TRANSFER_TOPIC_0,
                uint256(uint160(HOT_WALLET)),
                REACTIVE_IGNORE,
                REACTIVE_IGNORE
            );
        }
    }
}
