# D5 场景小实验：动态订阅（选 B）

> 任务：定时任务或动态订阅（80 学分）· 2026-11-22
> 选择：**B. 动态订阅** —— 合约在运行中根据收到的事件增加或取消订阅
> 场景出处：场景手册 场景 1 / 2（监控 / 守护）

---

## 提交项 ①：合约地址 + 至少两次触发的交易链接

### 合约地址

| 角色 | 链 | 地址 |
|---|---|---|
| **DynamicMonitor**（被控制的监控合约） | Lasna `5318007` | https://lasna.reactscan.net/address/0x234E67F940C690a2Fd11faD50dA52cCFd8119763 |
| Control（控制信道，发 WatchToken / Stop） | Sepolia `11155111` | https://sepolia.etherscan.io/address/0xF372D327A7a7529f6C273B7AEF99078eb36e273f |
| TokenA（CTT，初始就订阅） | Sepolia | `0x4c8c127D8BBc7E64F52a2c693582ae3816172802` |
| TokenB（运行中动态加进来的） | Sepolia | `0x0d641538CFa91F9F20179EC78c76C998B04f0A7C` |

### 四次触发（每次都是一个「源链事件 → Lasna react()」的完整对）

| # | 动作 | 源链交易（Sepolia） | react() 交易（Lasna） | react 之后的状态 |
|---|---|---|---|---|
| ① | 转代币 A 2000 | [0x6b5bf527…](https://sepolia.etherscan.io/tx/0x6b5bf5273e6cdea5495d4cebb38904cdb09b7410fbbbf8916ad1460a785a82e3) | [0x5aefb321…](https://lasna.reactscan.net/tx/0x5aefb3213153535ec588f28b8fb17e5e0371f13428be16b0fc2734104f97b776) | `count=1` `remaining=2` |
| ② | `WatchToken(TokenB)` | [0x9702b1cf…](https://sepolia.etherscan.io/tx/0x9702b1cf3df6220488b2eb989d502df90e82f4faf974b71d94cb8b8dc87e0288) | [0x7a908e65…](https://lasna.reactscan.net/tx/0x7a908e65df03ea8c7c05d5277f5b8304f89eca25ddccc4fe89a570c570244fc4) | **新增**订阅，`tokens[1]=TokenB` |
| ③ | 转代币 B 3000 | [0x9f981d1f…](https://sepolia.etherscan.io/tx/0x9f981d1fce5969338855ba48dd03a25a5f28e70f480c829fa0ca5fa29f27a1209) | [0x6494dab5…](https://lasna.reactscan.net/tx/0x6494dab519abe0c42b89376b1e19e9ca26d097bf829f5c552587e8e675603aeb) | `count=2` `remaining=1` ← **新订阅确实生效** |
| ④ | `Stop()` | [0xbcbca207…](https://sepolia.etherscan.io/tx/0xbcbca2074590f68f1cad41b1a34c0d53f298ac6632959035ddee1f5f81a487bd) | [0x0b5618b2…](https://lasna.reactscan.net/tx/0x0b5618b2fd9aacb666de0e8ebb3874fe54499e5fa925c71464d93360a365bc51) | `stopped=true`，**4 个订阅全部取消** |

### 反证：停止之后再转，什么都不会发生

停止后我又转了一笔代币 A（4000）：

- 源链交易：[0x27407216…](https://sepolia.etherscan.io/tx/0x27407216fb58653b6af3de8c931f8389250a327bf819a03253c01d23292508a7)
- 结果：`count` 仍然是 **2**、`lastReactBlock` 仍然是 **8980326**（就是 Stop 那次），Lasna 上**没有新的 react 交易**

这比「我说退订了」有力得多——**源链事件真实发生了，但网络不再唤醒合约**。

### 四步的链上状态变化

| 步 | 事件 | count | remaining | tokens 数量 | stopped |
|---|---|---|---|---|---|
| 部署 | `SubAdded(TokenA, 1)` | 0 | 3 | 1 | false |
| ① 转 A | `Seen(TokenA, 2000e18, 1, 2)` | 1 | 2 | 1 | false |
| ② watch B | `SubAdded(TokenB, 2)` | 1 | 2 | **2** | false |
| ③ 转 B | `Seen(TokenB, 3000e18, 2, 1)` | **2** | 1 | 2 | false |
| ④ stop | `SubRemovedAll(2, 8980326)` | 2 | 1 | 2 | **true** |
| ⑤ 再转 A | *(无 react)* | 2 | 1 | 2 | true |

**延迟实测**：源链事件块 → Lasna react 块，四次分别是 **0s / 0s / 1s / 1s**。

---

## 提交项 ②：如何防止它无限执行或耗尽余额

分六层，前四层是设计，后两层是运维。

### 1. 业务额度硬上限（最重要的闸）

```solidity
uint256 public remaining;   // 构造时设 3
...
if (remaining == 0) { _stopAll(); }   // 归零立刻退订
```

不是「靠余额耗尽来停」，而是**业务层面的硬上限**。余额耗尽是被动的、不可预期的停摆；额度上限是主动的、可解释的停止。

### 2. 控制事件不消耗额度

```solidity
if (t0 == WATCH_TOPIC_0) { ... return; }   // 不扣 remaining
if (t0 == STOP_TOPIC_0)  { ... return; }   // 不扣 remaining
```

这是个容易写反的地方：如果 `WatchToken` / `Stop` 也扣额度，那么额度刚好用光时，你连「停」的机会都没有了。**停止动作必须永远可用。**

### 3. 三条停止路径

| 路径 | 触发者 | 何时用 |
|---|---|---|
| `Stop()` 事件 | 我自己（控制合约） | 正常关闭 |
| `remaining == 0` 自动 | 合约自己 | 额度耗尽 |
| `emergencyStop()` | 任何地址 | 紧急刹车（真实项目应加权限） |

### 4. 幂等保护：`stopped` 早退

```solidity
function react(...) external onlySystem {
    if (stopped) return;      // 已停就什么都不做
```

即使有事件在退订生效前已经排队，也不会重复执行；`_stopAll()` 内部也有一层 `if (stopped) return`，防止重复退订（重复 `unsubscribe` 会静默失败但浪费 gas）。

### 5. 只订阅白名单，绝不通配

```solidity
require(!isWatched[token_], "already watched");
```

如果用 `address(0)` 通配，Sepolia 上**所有** ERC-20 转账都会唤醒合约，每条都收费，几分钟就能烧穿余额。这个坑在 D3 已经踩过一次。

### 6. 运维层：盯 debt 和余额

- `debt > 0` 时合约**在花 gas 之前就被拦下**，不报错、不发交易、链上什么都看不到
- 所以要么定期 `depositTo()` 补 reserves，要么外部监控余额并在快耗尽时告警

---

## 这一轮真的把余额耗尽了（实测事故）

预付 0.06 lREACT，四次 react 之后：

```
当前余额  0.010404 lREACT
欠款 debt 0.016463 lREACT   ← 已经欠费
```

四次的实际账目合计约 **0.066** lREACT，比我预付的多。

| 触发 | 交易 gas | 说明 |
|---|---|---|
| 转 A | 148,623 | 两个 SSTORE + 事件 |
| WatchToken | 129,264 | 新增订阅本身也要钱（`subscribe` 是外部调用） |
| 转 B | 97,323 | 最便宜的一次 |
| **Stop** | 137,859 | **退订 4 条订阅 = 4 次外部调用，比一次业务触发还贵** |

**这是我这轮最重要的发现**：

> **「停止」这个动作本身也要花钱，而且往往比正常运行更贵。**
> 如果按「每次 react 约 0.017」来预算，只留刚好够 N 次的钱，那么第 N 次触发后余额归零，**停都停不了**。

正确做法：预算里要给「退订」单独留一笔，或者在余额降到阈值时提前 `depositTo()`。

现在这个合约的 `stopped=true` 且 `debt>0`——即使没退订也不会再执行，属于**双重死亡**。要复活得先 `coverDebt()` 或直接转 lREACT 进去。

---

## 代码与复现

- Reactive 侧：[`src/DynamicMonitor.sol`](../reactive-builder-camp/starter/src/DynamicMonitor.sol)
- 控制信道：[`src/Control.sol`](../reactive-builder-camp/starter/src/Control.sol)
- 脚本：[`script/Dynamic.s.sol`](../reactive-builder-camp/starter/script/Dynamic.s.sol)

```bash
cd reactive-builder-camp/starter
set -a; source .env; set +a

export DYN_LIMIT=3 DYN_FUND=60000000000000000

forge script script/Dynamic.s.sol:DeployControl        --rpc-url $SEPOLIA_RPC_URL --broadcast
forge script script/Dynamic.s.sol:DeployTokenB         --rpc-url $SEPOLIA_RPC_URL --broadcast
# 把两个地址写进 .env 并【重新 source】
forge script script/Dynamic.s.sol:DeployDynamicMonitor --rpc-url $LASNA_RPC_URL  --broadcast

# 触发序列
forge script script/Dynamic.s.sol:FireTransferA        --rpc-url $SEPOLIA_RPC_URL --broadcast  # ①
forge script script/Dynamic.s.sol:FireWatchB           --rpc-url $SEPOLIA_RPC_URL --broadcast  # ②
forge script script/Dynamic.s.sol:FireTransferB        --rpc-url $SEPOLIA_RPC_URL --broadcast  # ③
forge script script/Dynamic.s.sol:FireStop             --rpc-url $SEPOLIA_RPC_URL --broadcast  # ④
forge script script/Dynamic.s.sol:FireTransferAfterStop --rpc-url $SEPOLIA_RPC_URL --broadcast # 反证
```

---

## 动态订阅真正难的地方（不是写 `subscribe`）

**订阅状态存在节点里，合约读不回来。** 你没法在链上查询「我现在订阅了哪些东西」，所以必须：

1. 自己用数组 / mapping 记账（`tokens` + `isWatched`）
2. **退订参数必须和订阅时逐字一致**，差一个值就静默失败——不报错，但订阅还在，继续扣钱
3. 退订要遍历账本逐个退，每退一个都是一次外部调用（要算进 gas 预算）

这三条是「动态订阅」和「一次性订阅」的本质区别。D3 只是订阅一次、用完自动退，D5 是真正在跑起来之后改订阅关系，复杂度不在一个量级。

---

## 一句话总结

> 运行中能加订阅（`WatchToken` → `tokens[1]` 出现且真的能触发）、也能停（`Stop` → 4 条订阅全退、后续转账不再唤醒）。
> **防失控靠三层：额度硬上限、控制事件不扣额度、`stopped` 幂等早退。**
> **但「停止」本身要花钱——这轮实测就因为没给退订留预算，合约欠费了。**
