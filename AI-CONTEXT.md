# 给 AI 的上下文（每次都贴）

> 来源：WCB 课程页「第 0 周 · 给 AI 的上下文（重要）」原文。让 AI 写 Reactive 代码前，先把这段贴给它。

---

我在用 Reactive Network 的 Omni 新版本（2026-10-28 主网迁移后）。请只参考 https://dev.reactive.network/reactive-contracts 、https://dev.reactive.network/callback-contracts 、https://dev.reactive.network/economy 和 https://github.com/Reactive-Network/reactive-smart-contract-demos/tree/omni/src/micro-demos 。不要使用 `vm` 修饰符、ReactVM、`emit Callback` 或系统合约 `0x...fffFfF`（只有 Cron 事件来自它）。react() 必须加 onlySystem，回调用 requestCallbackV_1_0。

---

## 附：判断 AI 是否在写旧写法

| 出现这些 | 说明 | 正确写法 |
|---|---|---|
| `modifier vm` / `rnOnly` | 旧版 ReactVM | `onlySystem` |
| `emit Callback(...)` | 旧版回调请求 | `SYSTEM.requestCallbackV_1_0(...)` |
| 系统合约 `0x…fffFfF` | 旧版 | `0x8888…8888`（`fffFfF` 只在 Cron 订阅里出现） |
| `import "@reactive/src/..."` 来自 `reactive-lib` | 旧库 | 用 `reactive-lib-omni` |

## 三条硬规则（AI 常写错）

1. 回调 payload **第一个参数必须是 `address(0)` 占位**，网络会替换成 Reactive 合约地址；回调合约用 `onlyCallbackSender` 校验。
2. 回调合约方法同时加 `onlyServiceProvider` 和 `onlyCallbackSender`，两道校验不能删。
3. 一个合约不能既是 Reactive 合约又是回调合约。

## 费用规则（影响写法）

- `react()` 里 `revert` 照样收费 → 用 `return` 过滤。
- 回调由**接收方**在目标链用原生币付费 → 回调合约部署时要带 ETH。
- `debt > 0` 时合约静默停止，什么都不触发。
