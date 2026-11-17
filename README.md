# Reactive Builder Camp 学习仓库

ETHPanda × Reactive Network 两周共学（2026-11-16 → 11-29）+ Reactive Omni Buildathon 参赛记录。

## 我是谁 / 目标

- WCB 用户名：`（填写）`
- 赛道意向：`（赛道 1 / 2 / 3，待定）`
- 一句话目标：`（例：用 Reactive 做一个钱包异常转出自动保护）`

## 进度

| 日期 | 内容 | 笔记 |
|---|---|---|
| 2026-11-13 | 环境搭好 + 首个端到端链路跑通（Sepolia ↔ Lasna ↔ Sepolia） | [notes/2026-11-13.md](notes/2026-11-13.md) |
| 2026-11-17 | 第 0 周任务提交（钱包 / lREACT / 仓库 / forge 版本） | [notes/2026-11-17.md](notes/2026-11-17.md) |

## 环境

- Foundry `v1.9.0`，Solc `0.8.29`
- 测试钱包：`0xf8a9863c156CCc444ccD666Fe7000dF7F5760A31`（**只用于本期测试网**）
- 模板仓库：https://github.com/ethpanda-org/reactive-builder-camp
- Omni 写法参考（**不要用旧 ReactVM 写法**）：https://dev.reactive.network/reactive-contracts

## 链上记录

| 步 | 链 | 地址 |
|---|---|---|
| ① 源链事件源 | Sepolia `11155111` | `0x4176Fd872507E10c7cFC5fe6c7FfaBd718CA13fD` |
| ② Reactive | Lasna `5318007` | `0xC223Fa471F6BB56e7983BEfeFd88464EDc720D8A` |
| ③ 回调 | Sepolia `11155111` | `0xd9Fb2389103779eCD5aFC0df64A3D9417C91aD80` |

三笔交易与延迟实测见 [notes/2026-11-13.md](notes/2026-11-13.md)。

## 安全

本仓库**不含任何私钥、助记词、API key**。`.env` 已在 `.gitignore` 中。全营只用测试网与测试钱包。
