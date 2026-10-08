# Undertone

**读懂英文消息里的话外音，用中文讲给你听。**

[English](README.md)

Undertone 是一个 macOS 悬浮面板，给在英语环境里上学、工作、做外贸的中文用户用。客户说 *"We'll review it internally and get back to you"*，上司说 *"That's an interesting idea, let's keep it in mind"*，老师发来一句 *"Just checking in"*，Undertone 会告诉你：

- **对方其实是什么意思**（还没决定、委婉拒绝、在催你……）；
- **为什么**英语母语者在这种场合会这么说；
- **把握有多大**；
- **一句地道的英文回复**，附中文意思。

自己要回消息时，用「**发之前看看**」检查草稿：对方读起来是什么感觉（太生硬、太客气、太随意、意思不清、有语病），再给一个更自然的写法。

<p align="center">
  <img src="docs/screenshots/zh/report.png" width="300" alt="客户在压价">
  <img src="docs/screenshots/zh/draft.png" width="300" alt="发之前看看">
</p>

默认**全部在你的 Mac 上运行**：本地 Qwen 3.5 4B 模型（通过 [Ollama](https://ollama.com)），不上传任何聊天内容。你也可以换成云端模型（OpenAI 兼容服务或 Anthropic Claude），面板底部会一直提示消息会发给谁。Undertone 只读屏幕，不接入任何聊天软件、也不会替你发消息，所以不会导致封号。

## 能读出哪些话外音

| 类型 | 例子 |
|---|---|
| 字面意思 | "Sounds good, see you at 3." |
| 客套 | "We should grab coffee sometime."（没有具体时间，不算真的约） |
| 委婉拒绝 | "Thanks, but we're all set for now. We'll keep your info on file." |
| 还没决定 | "Let me run this by my manager and circle back." |
| 在催你 | "Just following up on my email from Monday." |
| 不满 | "Per my last email…"、"This is quite disappointing." |
| 有兴趣 | "Can you send three samples? If quality is right, we're looking at 2,000 units." |
| 在压价 | "Another factory quoted us $10.50 for the same spec." |
| 反话 | "Oh great, another meeting that could have been an email." |
| 开玩笑 | "I'm dead 💀"、"this exam is going to kill me" |
| 可疑 | "Our bank account has changed due to an audit. Please pay the new account." |

<p align="center"><img src="docs/screenshots/zh/scam.png" width="300" alt="改收款账户的骗局"></p>

**骗局提醒**：说收款账户换了、要你先付费、要验证码，这类消息就算模型没认出来，关键词安全网也会拦下。改收款账户是外贸里最常见的骗局，面板会提醒你先用之前存的电话或邮箱联系对方本人核实。另有一道安全网，遇到轻生信号会给出求助渠道。

## 用起来

需要 macOS 14 以上、Xcode 或 Command Line Tools（Swift 5.10+）、[Ollama](https://ollama.com)。

```bash
ollama pull qwen3.5:4b
git clone https://github.com/timothyzhbw-jpg/undertone.git && cd undertone
./scripts/build_app.sh          # 生成 build/Undertone.app
open build/Undertone.app
```

1. 系统设置 → 隐私与安全性 → 屏幕与系统录音，允许 Undertone。
2. 在设置里选中聊天窗口，**只框住消息气泡那一栏**。
3. 在面板上选关系：客户、同事、老师、同学、朋友。同一句英文，对不同的人说意思常常不一样。

没有现成的英文聊天，可以先用演示窗口试，里面是一位虚构的外国买家在谈订单：

```bash
swift run UndertoneDemo
```

邮件、团队协作软件里的消息，用「手动粘贴」：复制几条消息粘进来就能分析，不需要屏幕录制权限。

建议在「钥匙串访问 → 证书助理 → 创建证书」建一个名为 `Undertone Local` 的代码签名证书，这样重新编译后不用再授权一次。

## 效果怎么样

评测集都是手写的英文消息，标注了期望的话外音类型和必须报、绝不能报的信号。样本很小，数字只说明大方向。

| 评测集 | 条数 | 本地 qwen3.5:4b（提示词版本） |
|---|---|---|
| 开发集 [`eval/crosscultural.jsonl`](eval/crosscultural.jsonl) | 42 | 话外音类型 32/40（80%） |
| 留出集 [`eval/crosscultural.holdout.jsonl`](eval/crosscultural.holdout.jsonl)（调提示词时没看过） | 29 | 19/28（68%） |
| 发之前看看 [`eval/draft.jsonl`](eval/draft.jsonl) | 26 | 23/26（88%） |

开发集 80%、留出集 68%，中间的落差就是对着 42 条例子调提示词的代价。本地 4B 模型大约每三到五条会看错一条，请对照原话和你对这个人的了解来判断，它给的只是参考。

## 本地模型训练

[`train/`](train) 里是一晚上的实验：用 MLX 在 24GB 的 M4 Pro 上对 4 bit 的 Qwen3.5-4B-Base 做 QLoRA 微调，比较两种给训练数据打标签的办法：

- **有监督**：288 条训练消息的话外音类型由人工标注，解释和回复让提示词模型照着标准答案写。
- **无监督（自训练）**：不用人工标签。让提示词模型对每条采样 3 次，只留 3 次结论都一样的那些（167 条，对照人工标签有 87% 是对的）。

| 模型 | 开发集 | 留出集 | 每条耗时 |
|---|---|---|---|
| 提示词版本（指令模型 + 15 条示例） | 80% | 68% | 5.9 秒 |
| 没微调的 Base 模型 | 31% | — | 4.1 秒 |
| 有监督 | 80% | 61% | 4.0 秒 |
| 只用自训练 | 70% | 71% | 3.7 秒 |
| **有监督 + 自训练** | **85%** | **68%** | **3.9 秒** |

微调把 Base 模型从 31% 提到和提示词版本相当的水平，没有误报，而且因为不用再带一长段示例，快了约 35%。留出集只有 28 条，几组之间的差距还在误差范围里。过程、脚本和踩过的坑见 [`train/RESULTS.md`](train/RESULTS.md)。

## 隐私

- 默认全部在本机：消息、联系人记忆、截图都不离开你的 Mac。云端模型和 deAPI 语音转写需要你自己打开，API Key 只存在钥匙串里。
- 日志里的聊天内容一律标成隐私，不会以明文出现。
- 实时模式适用于对方消息在左、自己在右的聊天界面；其他场景用手动粘贴。

## 许可证

[Apache License 2.0](LICENSE)
