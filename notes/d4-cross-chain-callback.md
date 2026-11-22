# D4【必做】跨链回调三步走

> 任务：跨链回调三步走（120 学分，必做）· 2026-11-22 提交
> 链路：**Ethereum Sepolia（源链）→ Lasna（Reactive）→ Ethereum Sepolia（目标链）**
> 全部为测试网，未混用主网。源链与目标链同链，赛道 1 不强制两条链。

---

## 提交项 ①：三笔交易链接

### 1. 源链事件

**`CampOrigin.ping(500)`** —— 在 Sepolia 发出 `Ping(address indexed who, uint256 value)` 事件

https://sepolia.etherscan.io/tx/0x85a95c13d86737122cd43d74d053f31dd9d7acd7ed2875ae4eea56b3177b618e

| 项 | 值 |
|---|---|
| 区块 | 12126122 |
| 区块时间 | 2026-11-13 21:00:12（UTC+8） |
| 合约 | `0x4176Fd872507E10c7cFC5fe6c7FfaBd718CA13fD` |
| topic0 | `0xfd8d0c1dc3ab254ec49463a1192bb2423b3b851adedec1aa94dcd362dc063c9d` |
| data | `0x…01f4` = 500（达到阈值 100） |

### 2. Reactive 上 react() 执行

**`CampReactive.react(LogRecord)`** —— 在 Lasna 被系统合约调用，判断通过后请求回调

https://lasna.reactscan.net/tx/0x0c1b80e089cf4f4e4ac964d5b2a98486a413f463eabc29e8a43bc008b26ea9f9

| 项 | 值 |
|---|---|
| 区块 | 8247224 |
| 区块时间 | 2026-11-13 21:00:12（与源链**同一秒**） |
| 合约 | `0xC223Fa471F6BB56e7983BEfeFd88464EDc720D8A` |
| 该交易发出的事件 | `Seen(11155111, 0x4176…13fD, 0x85a95c13…b618e, 500)`、`CallbackRequested(11155111, 0xd9Fb…1aD80, 500)` |

### 3. 目标链回调

**`CampCallback.onEvent(...)`** —— 被 Callback Proxy 调用，`count` 从 0 变 1

https://sepolia.etherscan.io/tx/0xda56e83572d8763085d115960280baf743197e293dcee99a59075b95d98673dc

| 项 | 值 |
|---|---|
| 区块 | 12126123 |
| 区块时间 | 2026-11-13 21:00:24（UTC+8） |
| 合约 | `0xd9Fb2389103779eCD5aFC0df64A3D9417C91aD80` |
| 事件 | `Handled(reactive=0xC223…0D8A, originChainId=11155111, originTxHash=0x85a95c13…b618e, value=500, count=1)` |

**数据一致性验证**：回调事件里的 `originTxHash` 解出来是 `0x85a95c13d86737122cd43d74d053f31dd9d7acd7ed2875ae4eea56b3177b618e`，与第 ① 笔**逐位一致**——证明数据原样穿过网络，没有串。

**延迟实测**：源链事件块 → Lasna react 块 = **0 秒**（同一秒落地）；Lasna → 目标链回调 = **12 秒**（Sepolia 出块 12s 是瓶颈）。

---

## 提交项 ②：失败实验

### 真实上链的失败交易

我用自己的钱包**直接调用** `CampCallback.onEvent()`：

https://sepolia.etherscan.io/tx/0x9badd35cafdd37313f7d2f04fed40e44020576fca9508ea9ad9e5979c6ec49b2

| 项 | 值 |
|---|---|
| status | **0 (failed)** |
| gasUsed | 23,448 |
| from | `0xf8a9863c156CCc444ccD666Fe7000dF7F5760A31`（我的钱包） |
| to | `0xd9Fb2389103779eCD5aFC0df64A3D9417C91aD80`（Callback 合约） |
| revert 原因 | `NotAuthorized(0xf8a9…0A31, 0xAa14…23b4)` |

用 `cast run` 回溯真实链上交易，确认 revert 出现在第一道检查：

```
└─ ← [Revert] NotAuthorized(0xf8a9863c156CCc444ccD666Fe7000dF7F5760A31,
                            0xAa14d9Cd0f788Ca23d11805986C1d8bd035D23b4)
```

![失败实验](../assets/d4-failure-experiment.png)

### 一句话解释为什么被拒

> **因为 `onEvent()` 上的第一道锁 `onlyServiceProvider` 要求 `msg.sender` 必须是 Callback Proxy；我用自己的钱包直接调用，`msg.sender` 是我的地址而不是 Proxy `0xAa14…23b4`，所以立刻 revert `NotAuthorized(调用者, 期望的 Proxy)`，函数体一行都没执行。**

### 额外做了两个对照实验（证明两道锁都真的在工作）

用 `cast call --from` 模拟不同调用者，不花钱：

| 实验 | 调用者 | payload 首参（reactive） | 结果 |
|---|---|---|---|
| A（上面那笔真实交易） | 我的钱包 `0xf8a9…` | 正确的 `0xC223…` | ❌ `NotAuthorized`（第一道锁） |
| B | **模拟 Proxy** `0xAa14…` | 错误的 `0xf8a9…` | ❌ `CallbackNotAuthorized`（第二道锁） |
| C | 模拟 Proxy `0xAa14…` | 正确的 `0xC223…` | ✅ 通过（返回 `0x`） |

```
实验 B:
  Error: execution reverted:
    CallbackNotAuthorized(0xf8a9863c156CCc444ccD666Fe7000dF7F5760A31,
                          0xC223Fa471F6BB56e7983BEfeFd88464EDc720D8A)
                         ↑ 我传进去的地址        ↑ 构造函数里的 _CALLBACK_SENDER
```

**C 是关键对照组**：同样的调用者、同样的函数，只把 reactive 地址换成正确的就通过了——说明不是函数坏了，而是鉴权在正常工作。

---

## 要求逐条对照

| 要求 | 实现 | 证据 |
|---|---|---|
| 源链和目标链都用测试网，不混主网 | Sepolia `11155111` ↔ Lasna `5318007` ↔ Sepolia `11155111` | 三笔交易均在测试网浏览器 |
| Reactive 侧统一用 Lasna | 部署在 `5318007` | Reactscan 链接 |
| Callback 继承 `AbstractCallback` | `contract CampCallback is AbstractCallback` | 源码 |
| 第一个参数是 `address` | `onEvent(address reactive_, uint256, uint256, uint256)` | 源码 + 回调事件 |
| 同时加 `onlyServiceProvider` 和 `onlyCallbackSender` | 两个修饰符都在函数签名上 | 源码 + 失败实验 |
| Callback Proxy 地址以官方 Origins & Destinations 为准 | `0xAa14d9Cd0f788Ca23d11805986C1d8bd035D23b4` | cheatsheet 第 2 节，且回调真实落地过 |
| 做一次失败实验 | 真实交易 + 两个模拟对照 | 见上 |

### Callback Proxy 为什么必须是这个地址

Omni 升级后测试网的 Proxy **全部换过**。旧地址（`0xc9f3…`、`0xa6eA…`、`0x9299…`）链上仍然有代码，但**不再投递**任何回调。

用旧地址的表现是「什么都没有发生」——回调合约不报错、不 revert、只是永远收不到调用。这个坑比 revert 难查得多，因为它没有任何信号。所以交任务时一定要贴能跑到目标的那个 Proxy。

我用 `cast code` 确认过它确实有代码（218 字节），并且这笔回调真实落地了。

---

## 完整链路回顾

```
① Sepolia  0x4176…13fD  emit Ping(0xf8a9…, 500)          block 12126122
        │  订阅匹配：chainId 11155111 + 合约 0x4176… + topic0 Ping
        ▼
② Lasna    0xC223…0D8A  react(log)                       block 8247224（同一秒）
        │  → value 500 ≥ 阈值 100，remaining 5→4
        │  → payload = onEvent(address(0), 11155111, txHash, 500)
        │  → SYSTEM.requestCallbackV_1_0({chainId, recipient, gasLimit 1e6, payload})
        ▼
③ Sepolia  Proxy 0xAa14…23b4 → 0xd9Fb…1aD80 onEvent()     block 12126123（+12 秒）
           首参 address(0) 被替换成 0xC223…0D8A
           两道鉴权通过 → count 0→1，emit Handled(...)
```

---

## 复现命令

```bash
cd reactive-builder-camp/starter
set -a; source .env; set +a

# 五步部署（脚本会自动回填地址）
bash script/deploy-all.sh

# 一键核验三笔交易
bash script/verify.sh

# 失败实验：用自己的钱包直接调 Callback
cast send $CALLBACK_ADDR "onEvent(address,uint256,uint256,uint256)" \
  $REACTIVE_ADDR 11155111 0 500 \
  --rpc-url $SEPOLIA_RPC_URL --private-key $PRIVATE_KEY --gas-limit 120000

# 回溯 revert 原因
cast run <失败交易的哈希> --rpc-url $SEPOLIA_RPC_URL
```

---

## 这一任务真正想让你理解的

**状态码 0 的交易也是证据。** 大多数人只留成功交易，但「被正确拒绝」才能证明鉴权不是摆设——如果去掉两道锁，任何人都能让你的回调合约替他们写状态、花你的 ETH。

**两道锁分别防不同的人：**

| 锁 | 防谁 | 校验什么 |
|---|---|---|
| `onlyServiceProvider` | 任何人（包括你）绕过 Proxy 直接调 | `msg.sender == Proxy` |
| `onlyCallbackSender` | 别人通过 Proxy 冒充某个 Reactive 合约 | payload 首参 == 构造函数里的 `_CALLBACK_SENDER` |

少了第一道，谁都能骗你的合约；少了第二道，别的 Reactive 合约能冒充你的。两者都不能省。
