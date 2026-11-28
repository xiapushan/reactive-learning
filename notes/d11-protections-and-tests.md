# D11 给项目加保护：防误触发、防重复、设上限

> 任务：给项目加保护（120 学分）· 2026-11-28
> 项目：[reactive-guardian](https://github.com/xiapushan/reactive-guardian)

---

## 提交项 ①：测试代码链接 + forge test 通过截图

**测试代码**：https://github.com/xiapushan/reactive-guardian/blob/main/test/Guardian.t.sol

**截图**：https://github.com/xiapushan/reactive-guardian/blob/main/docs/forge-test.png

![forge test](../../reactive-guardian/docs/forge-test.png)

```
Ran 11 tests for test/Guardian.t.sol:GuardianTest
[PASS] test_happyPath_securesRemainingToCold()   (gas: 652671)   ✅ 正常执行
[PASS] test_belowThreshold_noCallbackRequest()   (gas: 160789)   🚫 低于阈值
[PASS] test_selfSweepToCold_isIgnored()          (gas:  62250)   🚫 守护自身转账
[PASS] test_unexpectedToken_rejected()           (gas: 569574)   🚫 错的代币
[PASS] test_duplicateEvent_onlyExecutesOnce()    (gas: 661067)   🚫 重复事件
[PASS] test_directCall_notAuthorized()           (gas:  37683)   🚫 绕过 Proxy
[PASS] test_wrongCallbackSender_rejected()       (gas:  40451)   🚫 冒充 Reactive 合约
[PASS] test_totalCap_binds()                     (gas: 1047475)  🚫 累计上限
[PASS] test_allowanceTooLow_noTransfer()         (gas: 524256)   🚫 授权不足
[PASS] test_subscriptionUsesHotWalletAsTopic1()  (gas:  33719)   ⚙️ 订阅结构
[PASS] test_limitReached_unsubscribes()          (gas: 1001241)  ⚙️ 自动退订
Suite result: ok. 11 passed; 0 failed; 0 skipped
```

**1 个正常执行 + 7 个应被拦下的情况 + 2 个结构验证。** 测试完全本地：用 `vm.etch` 把 MockSystem 放到 `0x8888…8888`、用 MockProxy 模拟 Proxy 注入 reactive 地址，不需要测试币。

## 提交项 ②：README 里「出问题怎么办」

https://github.com/xiapushan/reactive-guardian#出问题怎么办

---

## 三条保护怎么实现的

### 保护 1：只在应该触发的时候触发

| 层 | 位置 | 规则 |
|---|---|---|
| 订阅层 | `GuardianReactive` 构造函数 | `topic1 = 热钱包地址`，只听「我转出」 |
| 判断层 | `react()` | `value < 5000e18` → `return` |
| 判断层 | `react()` | `topic2 == COLD_WALLET` → `return`（守护自身转账不算异常） |
| 执行层 | `SafeVault.onEvent()` | `token_ != TOKEN` → 拒绝 |

**第三条是实测踩出来的**：D9 时没加，结果守护自己的 `transferFrom(热钱包→冷钱包)` 也发出 `Transfer(from=热钱包)`，命中订阅，导致一次异常转出触发两轮守护（`alerts=2`）。加了之后 `alerts=1`。

### 保护 2：同一件事不做两次

按**源链交易哈希**去重：

```solidity
mapping(uint256 => bool) public handled;
if (handled[originTxHash_]) { emit NothingToSecure(..., "duplicate event"); return; }
handled[originTxHash_] = true;
```

为什么用 `originTxHash` 当幂等键：源链一笔交易可能产生多条日志，但**同一笔异常只该处理一次**；哈希天然唯一，不需要额外计数器。

### 保护 3：金额设上限

```solidity
uint256 amount = hotBalance;
if (amount > MAX_SECURE) amount = MAX_SECURE;   // 单次：1,000,000
if (amount > capLeft)    amount = capLeft;      // 累计：1,500,000
```

实测：热钱包 800,000 → 单次上限没触发（余额小于上限）→ 全部转走；`remainingCap` 从 1,500,000 降到 710,000。

---

## 「出问题怎么办」的三个答案

### 1. lREACT 用完 → 自动停，且不报错

`debt > 0` 时系统合约在花 gas 之前就拦下，`react()` 根本不会执行。表现是「合约突然安静」，和「没有事件」一模一样。

恢复三选一：直接转 lREACT / 调 `revive()`（先 `_coverDebt()`）/ 用系统合约 `depositTo()`。

提前发现只能盯两个数：`debt` 和合约余额。

### 2. 目标链失败 → 钱不动，手续费照收

所有失败路径都改成 `emit NothingToSecure(...) + return`，不 revert——因为**回调失败也全额收费**，revert 只会多花钱且掩盖原因。

唯一 revert 的是 `transferFrom` 返回 false（代币合约本身异常），此时交易 status=0，资产不动。

### 3. 合约被攻破 → 损失有上限

冷钱包 immutable 无 setter、两道鉴权、单次+累计双上限、只能动已授权额度。

**仍存在的风险**（已写进 README 已知问题，最高优先级）：`setVault()` 只校验 `msg.sender == HOT_WALLET`，热钱包私钥若泄露，攻击者可先改 vault。应改为冷钱包多签控制。

---

## 这一轮改了什么

| 文件 | 变化 |
|---|---|
| `src/SafeVault.sol` | 新增 `TOKEN`（代币白名单）、`handled`（去重）、`TOTAL_CAP`（累计上限）、`remainingCap()`；构造参数从 5 个变 7 个 |
| `test/Guardian.t.sol` | 新增，11 个测试 |
| `README.md` | 新增「三道保护」「出问题怎么办」「测试」三节，更新链上证据 |
| `docs/forge-test.png` | forge test 输出截图 |

合约改了就要重新部署，否则仓库代码和链上证据对不上——已重新部署并重跑：

| 环节 | 新交易 |
|---|---|
| ① 源链异常转出 | [0x28b9b97a…](https://sepolia.etherscan.io/tx/0x28b9b97a940038602e6db9feed3829204bf4823f834e4d8cbed0355701a57d39) |
| ② Reactive react() | [0xe22257f3…](https://lasna.reactscan.net/tx/0xe22257f36c2b9fe983317219d5728cf79cb4190e9f32dfabd3dceb8350c014c6) |
| ③ 目标链 Secured | [0x95eb94fe…](https://sepolia.etherscan.io/tx/0x95eb94fef081f2e82da420a7c4b7ac9f49350e74fb053dda0ff481416b9f100b) |

新合约：GuardianReactive `0x978517382211740445c3DBB8d69e37CBEaAc89B5`（Lasna）、SafeVault `0x8a790791462409e41Cd50f39EB094b5c93b4b569`（Sepolia）。

---

## 测试写法上踩的两个坑

**① `vm.prank` 被参数里的外部调用吃掉**

```solidity
vm.prank(systemAddr);
guardian.react(_log(...));   // ← _log() 里读了 guardian.ERC20_TRANSFER_TOPIC_0()，
                             //   那是一次外部调用，把 prank 用掉了，react 的 msg.sender 变成测试合约
```

修法：先构造 `LogRecord`，再 `vm.prank`，最后调用。

**② `proxy.deliver()` 内部用 low-level `call`，revert 不会冒泡**

所以「断言 revert」的测试不能通过 proxy 间接调，要 `vm.prank(address(proxy))` 直接调 `vault.onEvent(...)`，让 revert 直接抛到测试层。

这两条在写 Reactive 测试时一定会遇到——因为整条链路有「系统合约 → react → proxy → 回调」四层，中间任何一层用了 low-level call 或消耗了 prank，断言就会失效。
