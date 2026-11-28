# D9【必做】跑通你的项目：第一条完整链路

> 任务：跑通你的项目（150 学分，必做）· 2026-11-28
> 项目：**Reactive Guardian — 热钱包异常转出自动保护**
> 说明：不是示例改名。源链事件、react 判断、目标链动作三个合约都是为本项目写的，目标链动作是**真的转移资产**。

---

## 提交项 ①：项目仓库

https://github.com/xiapushan/reactive-guardian

```
reactive-guardian/
├── README.md                      # 含时序图、链上证据、安全设计、已知问题
├── src/GuardianReactive.sol       # Lasna：订阅 + 判断 + 请求回调
├── src/SafeVault.sol              # Sepolia：收到回调后真的把资产转走
├── src/IERC20.sol
├── script/Project.s.sol           # 五步部署 + 触发脚本
├── foundry.toml
└── .env.example
```

## 提交项 ②：三笔交易链接

| 环节 | 链 | 交易 |
|---|---|---|
| ① 源链：热钱包异常转出 10,000 CTT | Sepolia | [0x79b750c8…](https://sepolia.etherscan.io/tx/0x79b750c813c73db4dab75a119dbc7947747aafefd2569923bea6fa350c18e314) |
| ② Reactive：`react()` 判断并请求回调 | Lasna | [0xa81d23f6…](https://lasna.reactscan.net/tx/0xa81d23f6dc4801c68e0c198325e6109432a486c32f526f444b45a71cb99683f5) |
| ③ 目标链：`Secured`，490,000 CTT 转入冷钱包 | Sepolia | [0xed6b9c99…](https://sepolia.etherscan.io/tx/0xed6b9c9946369e0c303a14d95291e4418a95f9e4ca0159997a57ebc4972ea95c) |

**合约地址**

| 角色 | 链 | 地址 |
|---|---|---|
| GuardianReactive | Lasna `5318007` | `0x76652275835179548786b95A6BF436a615049725` |
| SafeVault | Sepolia `11155111` | `0x44A24F536b46A3593d479bD21b5F5B702E0A40A3` |

**结果**

```
热钱包   500,000 ──攻击者转走 10,000──▶ 490,000 ──守护转走 490,000──▶ 0
冷钱包   972,890 ──────────────────────────────────────────────▶ 1,462,890
```

`Secured` 事件里的 `originTxHash` 与第 ① 笔逐位一致。

**延迟**：源链事件块 → Lasna react 块 **0 秒**；Lasna → 目标链回调块 **12 秒**；端到端 **12 秒**（瓶颈是 Sepolia 12 秒出块）。

## 提交项 ③：时序图

时序图放在项目 README 的「时序图」一节（纯文字流程图）：

https://github.com/xiapushan/reactive-guardian#时序图

完整文字版：

```
① 源链 Sepolia
   热钱包 0xf8a9… ──transfer──▶ 0x…dEaD   (10,000 CTT)
        └─ emit Transfer(from=0xf8a9…, to=0xdEaD, 10000e18)
                │
                │ 订阅匹配：chainId 11155111 + 代币合约 + topic0=Transfer + topic1=热钱包
                ▼
② Reactive 侧 Lasna
   GuardianReactive.react(log)   [onlySystem]
     ├─ topic2 == 冷钱包？ → return        （跳过守护动作自身的转账）
     ├─ value < 阈值 5000？ → return       （用 return 不用 revert）
     └─ 命中 → requestCallbackV_1_0(gasLimit 1,000,000, payload=onEvent(address(0), token, value, originTxHash))
                │
                │ Callback Proxy 把首参 address(0) 替换成 0x7665…
                ▼
③ 目标链 Sepolia
   SafeVault.onEvent(...)   [onlyServiceProvider + onlyCallbackSender]
     └─ transferFrom(热钱包 → 冷钱包 0xef93…, min(余额, MAX_SECURE))
            └─ emit Secured(token, cold, 490000e18, 490000e18, originTxHash, timestamp)
```

---

## 这个项目和 D3/D4/D5 练习的区别

| | 练习（D3/D4/D5） | 本项目（D9） |
|---|---|---|
| 源链事件 | 自己 emit 的 Ping / 普通转账 | **「我的热钱包转出」这一特定语义**（topic1 钉死 from） |
| 判断 | 阈值比较 | 阈值 + **跳过守护自身动作**（topic2 == 冷钱包） |
| 目标链动作 | 记计数 / 记告警 | **真的 `transferFrom` 把资产转进冷钱包** |
| 安全边界 | 两道鉴权 | 两道鉴权 + 冷钱包 immutable + 单次上限 + 只能动已授权额度 |
| 失败处理 | emit 记录 | `NothingToSecure` 事件，不 revert（revert 也收费） |

---

## 本次踩到并修掉的一个真 bug

**守护动作会触发自己。**

`SafeVault.transferFrom(热钱包 → 冷钱包)` 也会发出 `Transfer(from=热钱包)`，正好命中我们的订阅条件（topic1 = 热钱包），于是 `react()` 被再唤醒一次，**白白消耗一次额度**。

实测证据：第一版跑完 `alerts = 2`（一次异常转出，两轮守护）。

修复：把冷钱包地址传进 `GuardianReactive`，`react()` 开头加一行

```solidity
if (log_.topic2 == uint256(uint160(COLD_WALLET))) return;
```

修完重跑：`alerts = 1`，热钱包 490,000 一次性全部转走。

> 这条正好对上第 2 周 D10「加保护：只在该触发时触发」——不是抄概念，是真被咬了一口才加的。

---

## 下一步（D10/D11 要补的）

| 待办 | 为什么 |
|---|---|
| `setVault` 改由冷钱包/多签控制 | 现在只要拿到热钱包就能改 vault，等于给攻击者留了后门 |
| 补 Foundry 单元测试 | 目前只有链上集成验证，没有回归保护 |
| 支持多次回调分批转移 | 现在单次受 `MAX_SECURE` 限制 |
| 失败可观测 | 守护失败时只有链上事件，没有推送 |
