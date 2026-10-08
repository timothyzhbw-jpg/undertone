# Undertone

macOS 悬浮窗：截取聊天窗口，用 OCR 加像素版面分析认出消息，再用本地大模型读对方最新一条英文消息的话外音，用中文解释，给一句地道的英文回复；「发之前看看」检查用户要发的英文草稿。给在英语环境里上学、工作、做外贸的中文用户。Swift Package，macOS 14+。

## 结构

- `Sources/UndertoneCore/`：纯逻辑（消息解析、版面检测、新消息检测、分析器、草稿检查、安全网），单元测试都针对它
- `Sources/Undertone/`：Mac 应用（ScreenCaptureKit 截图、Vision OCR、SwiftUI 面板、设置）
- `Sources/UndertoneDemo/`：演示聊天窗口（虚构的外国买家谈订单）
- `presets/`：`subtext.llm.zh.json`（读话外音：中文说明 + 15 条示例）、`draft.llm.zh.json`（发之前看看）、`subtext.ft.zh.json`（微调模型用的短提示）和对应的 JSON Schema
- `eval/`：`crosscultural.jsonl`（开发集）、`crosscultural.holdout.jsonl`（留出集，调提示词时不要看）、`draft.jsonl`；`scripts/score_eval.py` 打分
- `train/`：本地 LoRA 微调实验（MLX），结果和踩过的坑在 `train/RESULTS.md`
- `scripts/`：`build_app.sh` 打包 .app（版本号在这里），`make_dmg.sh` 打安装包

## 编译和测试

- **只能在 macOS 上编译。** 云端会话是 Ubuntu，`swift build` 跑不了：改完推上去，看 GitHub Actions 的 CI（macOS）结果，失败了按日志修。
- `swift build`、`swift test`
- 离线检查识别，不截屏、不弹窗口：`swift run Undertone --inspect 截图.png [--analyze]`，`swift run Undertone --replay 1.png 2.png …`
- 评测（需要本机 Ollama 和 qwen3.5:4b）：`swift run Undertone --eval eval/crosscultural.jsonl 输出.jsonl`，再 `python3 scripts/score_eval.py eval/crosscultural.jsonl 输出.jsonl`
- 界面预览：`swift run Undertone --render-previews 目录 --language zh|en`，CI 每次推送都会渲染并上传

## 规矩

- 对外的文字（README、发布说明、界面文字、仓库简介）不点名具体的聊天软件，说「聊天软件」。产品定位是读英文的话外音，不做恋人、家人之间的情绪分析。
- 隐私：默认全部在本机处理；绝不自动改用云端模型或自动调用任何收费接口；日志里的聊天内容一律 `privacy: .private`；API Key 只进钥匙串。
- 改 `presets/subtext.llm.zh.json` 的说明或示例会改变判断：改之前和之后都跑开发集，前后对比；留出集只在最后确认时跑一次。新写的示例和训练数据不能和评测集撞句子。
- 中英双语界面：文字一律写成 `L("中文", "English")`；话外音类型、情绪、信号、回应方式、关系在内部只存中文规范值，显示用 `Vocabulary.display`，模型输出经 `Vocabulary.canonical` 换回规范值。
- 两道安全网一直开着：`MoneyNet`（付款、账户、验证码类骗局，尤其是「收款账户换了」）和 `SafetyNet`（轻生信号，给求助渠道）。日常夸张（「I'm dead」「kill me now」）不能触发，改动要配正反两类测试。
- 训练（`train/`）和 Ollama 不能同时占 GPU：24GB 的 Mac 上一起跑会卡死重启。MLX 一律通过 `train/mlx_run.py` 调用。
- 注释用中文，风格和周围代码一致；提交信息用英文。
- 新功能配单元测试；识别相关的改动用 `--inspect` / `--replay` 在截图上验证。
- 发版（改 VERSION、打 DMG、签名）需要 macOS 和本机的签名证书，留给维护者在本机做。
