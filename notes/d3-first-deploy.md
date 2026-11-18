# D3 第一次部署｜监控 Sepolia 上的代币转账

> 任务：第一次部署（80 学分）· 2026-11-18
> 基于 omni 分支 [Xfers 示例](https://github.com/Reactive-Network/reactive-smart-contract-demos/blob/omni/src/micro-demos/Xfers.sol)，改了四处（见第五节）

---

## 三个提交项

### ① 合约地址（Reactscan）

**TransferMonitor（Lasna，被监控的 Reactive 合约）**

https://lasna.reactscan.net/address/0xd9Fb2389103779eCD5aFC0df64A3D9417C91aD80

**TestToken（Sepolia，被监控的 ERC-20）**

https://sepolia.etherscan.io/address/0x4c8c127D8BBc7E64F52a2c693582ae3816172802

### ② react() 被调用的交易链接

**命中（5000 CTT ≥ 阈值 1000）**

https://lasna.reactscan.net/tx/0xf04a95b27e46eda0ae82178545ef7a39dd70ffdb3f247b0ff37d975886f4adc1

**被阈值过滤（100 CTT < 1000，仍然触发 react()，只是不计数）**

https://lasna.reactscan.net/tx/0xaa41e971eeaad8da65b1c27ae2cc1c5b754d4085072b311a7896f6bbb2558aa4

### ③ 一句话说明订阅过滤条件

> 订阅 **Sepolia** 上我自建测试代币 `0x4c8c…2802` 的 **`Transfer(address,address,uint256)`** 事件：`topic0` 固定为 Transfer 签名，`topic1` / `topic2` / `topic3` **全部用 `REACTIVE_IGNORE`**（不区分转出方与转入方）；链上匹配之后，再在 `react()` 里做二级过滤——**单笔转账 ≥ 1000 CTT 才计数**，低于阈值的用 `return` 静默丢弃（不用 `revert`）。

---

## 一、做了什么

三步，全部在测试网真实执行：

```
① Sepolia  部署 TestToken（CTT），给自己铸 1,000,000 枚
      ↓
② Lasna    部署 TransferMonitor，构造函数里订阅 CTT 的 Transfer，部署时充值 0.3 lREACT
      ↓
③ Sepolia  转 100 CTT（低于阈值）→ react() 被调用 → 过滤，不计数
            转 5000 CTT（高于阈值）→ react() 被调用 → 命中，计数 +1
```

### 命令

```bash
cd reactive-builder-camp/starter
set -a; source .env; set +a

export MONITOR_FUND=300000000000000000          # 0.3 lREACT
export MONITOR_THRESHOLD=1000000000000000000000 # 1000 CTT（18 位小数）
export MONITOR_LIMIT=3

# ① 发币
forge script script/DeployD3.s.sol:DeployTestToken \
  --rpc-url $SEPOLIA_RPC_URL --broadcast
# → TOKEN_ADDR=0x4c8c127D8BBc7E64F52a2c693582ae3816172802

# ② 部署监控合约（部署即充值）
forge script script/DeployD3.s.sol:DeployTransferMonitor \
  --rpc-url $LASNA_RPC_URL --broadcast
# → MONITOR_ADDR=0xd9Fb2389103779eCD5aFC0df64A3D9417C91aD80

# ③ 制造事件
export XFER_SMALL=100000000000000000000   # 100 CTT
forge script script/DeployD3.s.sol:FireFiltered --rpc-url $SEPOLIA_RPC_URL --broadcast

export XFER_LARGE=5000000000000000000000  # 5000 CTT
forge script script/DeployD3.s.sol:FireMatched --rpc-url $SEPOLIA_RPC_URL --broadcast
```

---

## 二、四条要求逐条对照

### ✅ 要求 1：构造函数里完成订阅，用 REACTIVE_IGNORE 处理不关心的 topic

`src/TransferMonitor.sol` 构造函数：

```solidity
constructor(address token_, uint256 threshold_, uint256 limit_) payable {
    TOKEN = token_;
    THRESHOLD = threshold_;
    remaining = limit_;

    SYSTEM.subscribe(
        SEPOLIA_CHAIN_ID,            // 11155111：源链
        token_,                      // 精确匹配代币地址（不用 address(0) 通配）
        ERC20_TRANSFER_TOPIC_0,      // 0xddf252ad…b3ef
        REACTIVE_IGNORE,             // topic1（from）不关心
        REACTIVE_IGNORE,             // topic2（to）不关心
        REACTIVE_IGNORE              // topic3 不存在，也不用关心
    );
}
```

**为什么后三个位置都用 `REACTIVE_IGNORE`**：我只关心「这个代币发生了转账」，不关心谁转给谁。把 `from` / `to` 钉死会让订阅条件更严，但会漏掉一半事件（比如别人转给我）。而 `IGNORE` 是通配符，**订阅只支持等值匹配**，没有「大于」这种比较——所有数值判断都只能在 `react()` 里做。

### ✅ 要求 2：react() 带 onlySystem

```solidity
function react(LogRecord calldata log_) external onlySystem {
```

没有这道修饰符，**任何人都能伪造一个 LogRecord 把你的合约叫起来**，每次都花你的 lREACT。`onlySystem` 校验 `msg.sender` 必须是系统合约 `0x8888…8888`。

### ✅ 要求 3：设置处理次数上限，达到后自动取消订阅

```solidity
unchecked { remaining -= 1; }
if (remaining == 0) {
    SYSTEM.unsubscribe(SEPOLIA_CHAIN_ID, TOKEN, ERC20_TRANSFER_TOPIC_0,
                       REACTIVE_IGNORE, REACTIVE_IGNORE, REACTIVE_IGNORE);
}
```

`unsubscribe` 的参数必须和 `subscribe` **完全一致**，否则会静默失败（不报错，但订阅还在）。

### ✅ 要求 4：部署时给合约充值，避免欠款导致不执行

部署时直接带 value：

```solidity
TransferMonitor m = new TransferMonitor{value: fund}(token, threshold, limit);
```

实测到账：合约余额 `0.300000000000000000 lREACT`，`debt = 0`。

> 为什么必须充值：`debt > 0` 时系统合约**在花任何 gas 之前**就检查并直接返回，`react()` 根本不会被调用——不报错、不发交易、链上什么都看不到。合约就这么静默死掉了。

---

## 三、实测状态

部署后、触发前：

| 项 | 值 |
|---|---|
| `remaining` | 3 |
| `notified` / `filtered` / `matched` | 0 / 0 / 0 |
| 合约余额 | 0.3 lREACT |
| `debt` | 0 |

两笔转账之后：

| 项 | 值 | 说明 |
|---|---|---|
| `notified` | **2** | 收到 2 条通知 |
| `filtered` | **1** | 100 CTT 那条被阈值过滤 |
| `matched` | **1** | 5000 CTT 那条命中 |
| `remaining` | **2** | 只有命中的才消耗次数 |
| `lastValue` | `5000000000000000000000` | 5000 CTT |
| 合约余额 | `0.2613015` lREACT | 两条通知共花 **0.0386985** |

**两条通知的花费 ≈ 0.0193 lREACT/条**，比 D2 算出的 0.0181262 略高——因为这条合约多做了几个 SSTORE（`notified` / `filtered` / `matched` / 事件），而 D2 那个模板只存了两个变量。**这正好印证了「费用 = 实际 gas + 100k」这条公式：多写一个存储就是多花钱。**

---

## 四、交易链路

| 环节 | 链 | 交易 | 区块 | 时间 |
|---|---|---|---|---|
| 部署 TestToken | Sepolia | [0xfeb13ba9…](https://sepolia.etherscan.io/tx/0xfeb13ba9f30695f03048b5970399e9e7a2daaf9934bbc2c253cd1363075fdbe7) | 12157799 | — |
| 铸币 1,000,000 CTT | Sepolia | [0x26093e83…](https://sepolia.etherscan.io/tx/0x26093e83c315b285f1b4154e32284f1b602c25a592983a295d54c4125ab7cd8f) | 12157799 | — |
| 部署 TransferMonitor | Lasna | [0x2d97e8d8…](https://lasna.reactscan.net/tx/0x2d97e8d8c31ec26012eee4a33cd14558d87200a3bee5afee29a41d29fa94f2e0) | — | — |
| 转 100 CTT（过滤） | Sepolia | [0xed11226c…](https://sepolia.etherscan.io/tx/0xed11226ce1d3241b8f57fd786a36adad689bf41ff1e831dfe020d13c36f31513) | 12157802 | — |
| **react() #1（过滤）** | **Lasna** | [0xaa41e971…](https://lasna.reactscan.net/tx/0xaa41e971eeaad8da65b1c27ae2cc1c5b754d4085072b311a7896f6bbb2558aa4) | 8609474 | — |
| 转 5000 CTT（命中） | Sepolia | [0x69d7b619…](https://sepolia.etherscan.io/tx/0x69d7b619ac7b047cb293531a44ff1cdbaed017fd71f4dad6410de36c0bbc4858) | 12157808 | 1794960120 |
| **react() #2（命中）** | **Lasna** | [0xf04a95b2…](https://lasna.reactscan.net/tx/0xf04a95b27e46eda0ae82178545ef7a39dd70ffdb3f247b0ff37d975886f4adc1) | 8609551 | 1794960121 |

**检测延迟：源链事件块 → Lasna react 块 = 1 秒。**（Sepolia 出块 12s，但事件一旦落块，Reactive 侧 1 秒内就执行了。端到端慢并不在 Reactive 这一段——这个结论和 11/13 那次完整三步走的实测一致。）

`lastTxHash` 读出 `0x69d7b619…`，与源链那笔 5000 CTT 的转账哈希**逐位一致**——数据没有串。

---

## 五、和官方 Xfers 示例的四处差异

| | 官方 Xfers | 我的 TransferMonitor | 为什么改 |
|---|---|---|---|
| 订阅的合约地址 | `address(0)`（**通配所有合约**） | 精确到 `TOKEN` | 通配会收到 Sepolia 上**全部** ERC-20 的 Transfer，每条都收费。几分钟就能把余额烧光 |
| 阈值判断 | 无 | `value < THRESHOLD` 时 `return` | 任务允许加，也更接近真实需求：不是每笔转账都值得动作 |
| 计数逻辑 | 累计 `_turnovers[token]` | `notified` / `filtered` / `matched` 三个独立计数 | 能分别看出「收到几条」和「命中几条」，便于验证过滤真的生效 |
| 过滤方式 | `if (log_.opCode == 3)` | 显式校验 `topic0` + `contractAddress` | `opCode == 3` 是隐式约定，显式校验更防伪 |

保留了 Xfers 的三个正确做法：构造函数订阅、`onlySystem`、次数归零自动退订。

---

## 六、一个容易困惑的点：为什么这个地址和 11/13 的回调合约一样？

```
Lasna   TransferMonitor   0xd9Fb2389103779eCD5aFC0df64A3D9417C91aD80
Sepolia CampCallback      0xd9Fb2389103779eCD5aFC0df64A3D9417C91aD80
```

**不是抄错了，也不是巧合。** 合约地址由 `keccak256(rlp(发起者, nonce))` 决定，**只看发起者和 nonce，跟链无关**：

- 11/13 在 Sepolia 上部署 `CampCallback` 时，我的地址 nonce = 2
- 今天在 Lasna 上部署 `TransferMonitor` 时，nonce 正好也是 2

相同的 `(发起者, nonce)` 必然算出相同地址。**但它们是两条链上互不相干的两个合约**，字节码、状态、余额各管各的。

这个特性顺带解释了另一个常见现象：同一个人在不同链上部署的第一个合约，地址总是相同的。

---

## 七、复现步骤

```bash
cd reactive-builder-camp/starter
set -a; source .env; set +a

export MONITOR_FUND=300000000000000000
export MONITOR_THRESHOLD=1000000000000000000000
export MONITOR_LIMIT=3

forge script script/DeployD3.s.sol:DeployTestToken      --rpc-url $SEPOLIA_RPC_URL --broadcast
# 把输出里的 TOKEN_ADDR 写进 .env

forge script script/DeployD3.s.sol:DeployTransferMonitor --rpc-url $LASNA_RPC_URL --broadcast
# 把输出里的 MONITOR_ADDR 写进 .env

export XFER_SMALL=100000000000000000000
forge script script/DeployD3.s.sol:FireFiltered --rpc-url $SEPOLIA_RPC_URL --broadcast

export XFER_LARGE=5000000000000000000000
forge script script/DeployD3.s.sol:FireMatched  --rpc-url $SEPOLIA_RPC_URL --broadcast

# 查状态
MON=$MONITOR_ADDR
for f in "notified()(uint256)" "filtered()(uint256)" "matched()(uint256)" "remaining()(uint256)"; do
  printf "%-26s → " "${f%%(*}"; cast call $MON "$f" -r $LASNA_RPC_URL
done
```

---

## 八、踩到的坑

| 坑 | 现象 | 解决 |
|---|---|---|
| 自由函数里用 `vm` | `Undeclared identifier: vm` | 把公共逻辑放进 `abstract contract FireBase is Script`，让脚本继承 |
| 基类写在派生类后面 | `Definition of base has to precede definition of derived contract` | Solidity 要求基类先定义，调整顺序 |
| 只监控一个代币而不是通配 | 若用 `address(0)`，Sepolia 上所有 ERC-20 转账都会触发 | 订阅时钉死 `token_` |
| `unsubscribe` 参数不一致 | 静默失败，订阅还在，持续扣费 | 参数必须与 `subscribe` 完全一致（同一组常量） |

---

## 九、一句话总结

> 构造函数里精确订阅一个合约的 `Transfer`（其余 topic 全 `REACTIVE_IGNORE`）→
> `react()` 用 `onlySystem` 防伪、用 `return` 而不是 `revert` 做阈值过滤 →
> 次数归零自动退订、部署即充值避免静默停摆。
> **实测：源链事件到 Lasna 执行 1 秒，两条通知花 0.0387 lREACT。**
