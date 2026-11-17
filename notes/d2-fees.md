# D2 读懂费用｜用 cast 查询 Lasna 系统合约参数

> 任务：读懂费用（60 学分）· 2026-11-18
> RPC：`https://lasna-rpc.rnk.dev/` ｜ 系统合约：`0x8888888888888888888888888888888888888888`
> 以下所有输出均为 2026-11-18 在 Lasna 上的实际调用结果

---

## 一、三条 cast 命令与输出

```bash
SYSTEM=0x8888888888888888888888888888888888888888
RPC=https://lasna-rpc.rnk.dev/

cast call $SYSTEM "_gasPriceCoeffPer1000()(uint256)" --rpc-url $RPC
# → 1000

cast call $SYSTEM "_extraGas()(uint256)" --rpc-url $RPC
# → 100000 [1e5]

cast call $SYSTEM "_maxChargeGas()(uint256)" --rpc-url $RPC
# → 50000 [5e4]
```

| 参数 | 值 | 含义 |
|---|---|---|
| `_gasPriceCoeffPer1000` | **1000** | 定价系数，实际使用时要 **除以 1000**，也就是 C = 1.0（不加价） |
| `_extraGas` | **100000** | 固定附加 gas（K），每次触发都按 100k gas 收，不管你实际用了多少 |
| `_maxChargeGas` | **50000** | **不进入计费公式**。它是留给「结算付款」的 gas 预算上限 |

> 三者的关系容易看错：`_extraGas`（100k）比 `_maxChargeGas`（50k）大，但两者**不在同一层**——前者是加进账单的 gas，后者是扣款动作本身能用的 gas。看文档那句「`_maxChargeGas` doesn't enter the fee itself; it caps the gas available for settling payment」才对得上。

---

## 二、补充：目标链回调 Proxy 的参数是另一套

文档明确写了「Each callback proxy is configured at deployment and has no defaults」，所以必须按链单独查。查 Sepolia 的 Callback Proxy：

```bash
cast call 0xAa14d9Cd0f788Ca23d11805986C1d8bd035D23b4 "_gasPriceCoeffPer1000()(uint256)" \
  --rpc-url https://ethereum-sepolia-rpc.publicnode.com
# → 1100     ← 系数 1.1，比 Reactive 侧贵 10%

cast call 0xAa14d9Cd0f788Ca23d11805986C1d8bd035D23b4 "_extraGas()(uint256)" \
  --rpc-url https://ethereum-sepolia-rpc.publicnode.com
# → 150000   ← 附加 gas 是 150k，不是 100k

cast call 0xAa14d9Cd0f788Ca23d11805986C1d8bd035D23b4 "_maxChargeGas()(uint256)" \
  --rpc-url https://ethereum-sepolia-rpc.publicnode.com
# → 50000
```

**结论：不能拿 Reactive 侧的三个数去估算回调费用。** 两条链路、两套参数。

---

## 三、问题 1：一次 react() 的费用怎么算？

### 公式（来自官方 Economy 文档）

```
fee = p_base × C × (g_used + K)
```

| 符号 | 含义 | Lasna 实测值 |
|---|---|---|
| `p_base` | `max(tx.gasprice, block.basefee)` | **100 gwei**（block.basefee = 100000000000 wei） |
| `C` | `_gasPriceCoeffPer1000 / 1000` | **1.0**（1000/1000） |
| `g_used` | 执行实际消耗的 gas | 反推得 **81,262** |
| `K` | `_extraGas` | **100,000** |

### 用我自己的交易验算

我 11/13 那笔 `react()` 交易（[0x0c1b80e0…](https://lasna.reactscan.net/tx/0x0c1b80e089cf4f4e4ac964d5b2a98486a413f463eabc29e8a43bc008b26ea9f9)）触发后，合约余额从 `0.5` 掉到 `0.4818738`：

```
实际扣费 = 0.5 − 0.4818738 = 0.0181262 lREACT
反推计费 gas = 0.0181262 / 100 gwei = 181,262 gas
g_used = 181,262 − 100,000（K） = 81,262 gas
```

代回公式：

```
fee = 100 gwei × 1.0 × (81,262 + 100,000)
    = 100 × 10⁻⁹ × 181,262 lREACT
    = 0.0181262 lREACT     ✓ 与链上扣费逐位一致
```

### 一个反直觉的发现

那笔交易的**总** `gasUsed` 是 **141,051**，但被计费的只有 **81,262**：

```
141,051（整笔交易） − 81,262（被计费）= 59,789 gas
```

这 59,789 gas 是系统合约自己的开销——订阅匹配、日志记录、扣款结算——**不向合约收费**。所以你只需要关心 `react()` 函数体本身花多少 gas，不用怕系统层面开销。

### 换算成日常感受

| 项 | 数值 |
|---|---|
| 一次 `react()` | **0.0181262 lREACT** |
| 现在的余额 0.4713723 lREACT | 约还能触发 **26 次** |
| 按 faucet 0.01 ETH → 1.05 lREACT 折算 | 每次约 **0.00017 ETH** 等价 |

---

## 四、问题 2：balance、reserves、debt 分别是什么？

### 三个数的定义

| 数 | 由谁持有 | 含义 |
|---|---|---|
| **balance** | **合约自己** | 合约地址上的原生币，合约能花的钱 |
| **reserves** | 系统合约 / 回调 Proxy | **预付信用额度**，只能用来付手续费 |
| **debt** | 系统合约 / 回调 Proxy | **已经产生但还没付的费用** |

关键区别：balance 在合约自己手里，合约想怎么用都行；reserves 是被系统合约代持的、**只能拿去抵手续费**的额度。

### 扣费顺序：先 reserves，后 debt

```
合约被收费
   ↓
先扣 reserves
   ↓
reserves 扣光了 → 才开始产生 debt
```

反过来，充值的时候：`depositTo()` **先清 debt，剩余才加到 reserves**。所以 debt 和 reserves **永远不会同时非零**。

合约自己地址收到的转账（直接转账）**只会涨 balance**，既不算 reserves 也不抵 debt。这就是为什么我部署时用的 `new CampReactive{value: 0.5 ether}(...)` 只让 balance 变成 0.5，reserves 一直是 0。

### 我现在这三个数的真实状态

```bash
SYSTEM=0x8888888888888888888888888888888888888888
RC=0xC223Fa471F6BB56e7983BEfeFd88464EDc720D8A

cast call $SYSTEM "reserves(address)(uint256)" $RC --rpc-url https://lasna-rpc.rnk.dev/
# → 0

cast call $SYSTEM "debt(address)(uint256)" $RC --rpc-url https://lasna-rpc.rnk.dev/
# → 0

cast balance $RC --rpc-url https://lasna-rpc.rnk.dev/ -e
# → 0.481873800000000000
```

> 注：系统合约没有 `balance(address)` 方法（调用会 revert），balance 要用 `cast balance <合约地址>` 直接查链上余额。

### 为什么「只要有一点 debt，合约就停止执行」？

因为系统合约处理每个通知时走 `trigger()` 的六个步骤，**debt 检查是第一步，在任何 gas 花出去之前**：

```
① 检查 debt > 0  →  是则直接返回，什么都不做
② 匹配订阅
③ 执行 react()
④ ...
⑤ 按实际 gas 扣费
⑥ 剩余分给 tx.origin（验证者）
```

两个设计后果：

1. **判定条件是 `> 0`，不是「欠很多」**。差 1 wei 和欠 1 ETH 的结果完全一样——直接停。
2. **停的方式是「静默」**。因为检查发生在花 gas 之前，系统根本不会调用你的 `react()`，所以不会抛错、不会发交易、链上什么都看不到。合约就这么安静地死掉了。

这就是为什么「监控 debt」是运营这类合约的必备动作，光看余额不够——余额可能还够，但 debt 一旦出现就已经停了。

---

## 五、问题 3：react() 回滚了，还收费吗？

### 收费，而且是全额

官方原文（Economy 文档 Warning）：

> A reverting `react()` is caught, logged as a `ReactiveContractReverted` event, and charged in full. A failing callback is logged as a `CallbackFailure` event and charged in full. Neither is refunded.

翻译成操作层面：

| 情况 | 收费？ | 链上留下什么 |
|---|---|---|
| `react()` 正常执行 | ✅ 按公式 | 正常日志 |
| `react()` revert | ✅ **全额** | `ReactiveContractReverted` 事件 |
| 回调执行失败 | ✅ **全额** | `CallbackFailure` 事件 |
| 回调目标是**没有代码的地址** | ❌ 不收费 | 付款前就被拒绝，这是唯一例外 |

因为扣费发生在**执行之后**、按实际消耗的 gas 算（第 ⑤ 步），系统合约把 revert catch 住了，然后照常走第 ⑤ 步收费。

### 对我合约设计的四个影响

**① 过滤条件一律用 `return`，绝不用 `revert`**

模板 `CampReactive.react()` 里就是这么写的：

```solidity
// 注意：不要用 revert 过滤事件，revert 照样收费；用 return。
if (value < threshold || recipient == address(0)) return;
```

`return` 走得越早越省钱——所以我把 topic0 校验、`remaining == 0` 校验都放在最前面。

**② 不能指望「出错不收费」当兜底**

如果合约逻辑有 bug，每条事件都 revert，余额会被一条条烧光。烧光之后 `debt > 0` → 静默停摆，**双重重击**：既花了钱，又死了。

**③ 必须有次数上限和暂停开关**

模板的 `remaining`（上限 5 次，用完自动 `unsubscribe`）+ `topUp()` 就是干这个的，防止测试币被无限扣。

**④ 回调 gas 别卡着 100k 设**

文档写明：Proxy 在调用接收方之前，会先扣掉 `_extraGas`（自身记账）和 `_maxChargeGas`（结算付款），**只把剩下的转发出去**，不够就报 `InsufficientGas`。回调 gas 下限是 100k，但如果你设成 100k 整，扣完就没剩的了。

模板里 `CALLBACK_GAS_LIMIT = 1_000_000`，留足了余量。

### 顺带：两条链的 gas 上限

| 限制 | 值 |
|---|---|
| Reactive 交易 gas 上限 | **900,000** |
| 回调 gas 下限 | **100,000**（低于此值**直接忽略**，不报错） |

---

## 六、两条链路实测费用对比

同样一笔「源链事件 → react() → 回调」，两边的钱花在哪完全不同：

| | Reactive 侧 `react()` | 目标链回调 |
|---|---|---|
| 交易 gasUsed | 141,051 | 402,751 |
| 计费 gas（反推） | 81,262 | 336,593 |
| 固定附加 K | 100,000 | 150,000 |
| 系数 C | 1.0 | 1.1 |
| p_base | 100 gwei | 20 wei |
| **实付** | **0.0181262 lREACT** | **0.0000000000107 ETH** |

回调那笔只花了约 **1e-11 ETH**——因为 Sepolia 测试网的 `baseFee` 只有 15 wei 量级，几乎免费。

**教训：测试网上「回调几乎免费」是假象。** 主网 baseFee 是几十 gwei 量级，同样 486k 计费 gas，费用会放大 9~10 个数量级。评估成本时不能拿测试网的感觉去推主网。

---

## 七、一句话总结

> `react()` 的成本 = `p_base × 系数 × (react 函数体实际 gas + 100k)`，与整笔交易的 gas 无关；
> 钱从 reserves 扣，扣光了变 debt；
> **debt > 0 的那一刻合约就静默死亡**，而且 revert 也照样扣钱——
> 所以省钱的唯一正解是「尽早 `return`」，运维的唯一正解是「盯住 debt」。
