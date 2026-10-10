# Undertone

**Reads the subtext in English messages, and explains it in your language.**

**[Download for Mac](https://github.com/timothyzhbw-jpg/undertone/releases/latest)** · [中文说明](README.zh-CN.md)

Undertone is a macOS floating panel for people who study, work or trade in English as a second language. It was built first for Chinese speakers, and explains in 13 languages: English, Chinese, Spanish, French, Portuguese, German, Russian, Arabic, Hindi, Indonesian, Japanese, Korean and Vietnamese. When a buyer writes *"We'll review it internally and get back to you"*, a manager says *"That's an interesting idea, let's keep it in mind"*, or a professor sends *"Just checking in"*, Undertone tells you:

- **what they actually mean** (still deciding, a polite no, waiting on you…);
- **why** native speakers say it that way in this setting;
- **how sure** it is;
- **a natural English reply** you can send.

Before you send your own reply, **Check before you send** tells you how your draft will come across (too blunt, too apologetic, too casual, unclear, grammar slips) and offers a more natural version.

<p align="center">
  <img src="docs/screenshots/en/report.png" width="300" alt="A buyer pushing on price, explained">
  <img src="docs/screenshots/en/draft.png" width="300" alt="Checking a reply before sending it">
</p>

Everything runs **on your Mac** by default, with a local Qwen 3.5 4B model through [Ollama](https://ollama.com). No chat leaves the machine unless you choose a cloud model (OpenAI-compatible or Anthropic Claude), and the panel says so the whole time. Undertone only reads the screen. It doesn't hook into any messaging app or send anything, so it can't get your account banned.

## What it reads

The model sorts each English message into one of 11 readings, explains it, and suggests a reply:

| Reading | Example |
|---|---|
| Means what it says | "Sounds good, see you at 3." |
| Just being polite | "We should grab coffee sometime." (no date, not a real invitation) |
| A polite no | "Thanks, but we're all set for now. We'll keep your info on file." |
| Not decided yet | "Let me run this by my manager and circle back." |
| Waiting on you | "Just following up on my email from Monday." |
| Not happy | "Per my last email…", "This is quite disappointing." |
| Genuinely interested | "Can you send three samples? If quality is right, we're looking at 2,000 units." |
| Negotiating | "Another factory quoted us $10.50 for the same spec." |
| Sarcastic | "Oh great, another meeting that could have been an email." |
| Joking | "I'm dead 💀", "this exam is going to kill me" |
| Red flag | "Our bank account has changed due to an audit. Please pay the new account." |

<p align="center"><img src="docs/screenshots/en/scam.png" width="300" alt="A changed-bank-account scam"></p>

A keyword safety net catches payment and account scams even when the model misses them. "Our bank account has changed" is the most common fraud in foreign trade, so the panel tells you to confirm through a phone number or email you already had. A second net watches for crisis language and shows support resources.

## How it works

```
chat window ──ScreenCaptureKit──▶ Apple Vision OCR + pixel layout detector ──▶ bubbles: left = them, right = me
     ──▶ new message from them? ──▶ local LLM (cross-cultural prompt, 15 examples) ──▶ keyword safety nets ──▶ panel
```

- **Capture and layout.** ScreenCaptureKit captures only the chat window. A pixel-level detector finds bubbles, avatars, emoji and stickers, so it can tell their messages from yours. Emoji are painted out before OCR, then cropped and named by the vision model.
- **Analysis.** A system prompt (in [Chinese](presets/subtext.llm.zh.json), or in [English](presets/subtext.llm.en.json) with the worked examples in the chosen explanation language) with an ordered decision checklist and 15 worked examples covering trade, workplace, campus, friends, hard negatives, a scam and a crisis message, with a JSON answer. The model explains the convention and the real meaning first, and picks the label last.
- **Robust parsing.** Small models often quote English phrases inside JSON strings without escaping them. The parser repairs that instead of failing.
- **Per-contact memory.** Notes such as "first order 5,000 pcs by end of March" are saved only when you confirm.
- **Paste mode** for email, Slack, Teams or anything else you can copy, and **screenshots**: paste or drop a phone chat or email screenshot and it's read on your Mac (OCR plus the same bubble detector), shown as editable text, then analyzed. **Voice messages** can optionally be transcribed with Whisper via [deAPI](https://deapi.ai), only when you tap Listen.

## Quick start

**Download:** get `Undertone-<version>.dmg` from [Releases](https://github.com/timothyzhbw-jpg/undertone/releases/latest), drag Undertone into Applications, then install [Ollama](https://ollama.com) and run `ollama pull qwen3.5:4b`. Undertone isn't notarized, so macOS blocks the first launch: open System Settings → Privacy & Security and click **Open Anyway**, or run `xattr -dr com.apple.quarantine /Applications/Undertone.app`.

**Build from source:** macOS 14 or later, Xcode or the Command Line Tools (Swift 5.10+), and [Ollama](https://ollama.com).

```bash
ollama pull qwen3.5:4b
git clone https://github.com/timothyzhbw-jpg/undertone.git && cd undertone
./scripts/build_app.sh          # builds build/Undertone.app
open build/Undertone.app
```

Allow Undertone under System Settings → Privacy & Security → Screen & System Audio Recording, then select the column of message bubbles in Settings. Pick the language for the explanations under Settings → Explain in. To try it without a real chat, run the demo chat window, where a fictional buyer negotiates an order:

```bash
swift run UndertoneDemo
```

A one-time local code-signing certificate (Keychain Access → Certificate Assistant → Create a Certificate, named `Undertone Local`, type Code Signing) keeps the screen-recording permission across rebuilds.

## Evaluation

All sets are hand-written English messages with expected readings and must-raise / must-not-raise signals. They are small, so read the numbers as direction, not as a benchmark.

Prompted qwen3.5:4b, running locally, with the two original explanation languages (the others are below):

| Set | Size | Chinese explanations | English explanations |
|---|---|---|---|
| [`eval/crosscultural.jsonl`](eval/crosscultural.jsonl) (development) | 42 | reading 34/40 (85%) | 38/40 (95%) |
| [`eval/crosscultural.holdout.jsonl`](eval/crosscultural.holdout.jsonl) (first held-out set) | 29 | 22/28 (79%) | — |
| [`eval/crosscultural.holdout2.jsonl`](eval/crosscultural.holdout2.jsonl) (fresh set, not used for tuning) | 40 | **32/39 (82%)** | **30/39 (77%)** |
| [`eval/draft.jsonl`](eval/draft.jsonl) (Check before you send) | 26 | verdict 23/26 (88%) | 24/26 (92%) |

The English prompt is a translation of the Chinese one, made after the fresh set was written; it was run once on each set and not tuned on any of them. The development set was used to tune the Chinese prompt, so its numbers flatter both. On the fresh set the two are within two messages of each other.

### Explanation languages

The other explanation languages are built from the English prompt by [`scripts/make_language_presets.py`](scripts/make_language_presets.py). The rules stay in English, which the 4B model follows best, and the worked examples (15 for reading, 7 for drafts) carry their explanations in the target language ([`presets/languages/`](presets/languages)). Suggested replies and labels are the same in every language. Each language was run once on the fresh held-out set and the draft set through the same code path, and [`scripts/check_language.py`](scripts/check_language.py) checked that the explanations really came out in that language:

| Explanations in | Reading, fresh held-out set | Check before you send | Explanations in that language |
|---|---|---|---|
| Chinese | 33/39 (85%) | 24/26 (92%) | 66/66 |
| English | 32/39 (82%) | 24/26 (92%) | 66/66 |
| Spanish | 29/39 (74%) | 20/26 (77%) | 66/66 |
| French | 32/39 (82%) | 23/26 (88%) | 66/66 |
| Portuguese | 26/39 (67%) | 21/26 (81%) | 66/66 |
| German | 31/39 (79%) | 23/26 (88%) | 66/66 |
| Russian | 30/39 (77%) | 25/26 (96%) | 66/66 |
| Arabic | 33/39 (85%) | 23/26 (88%) | 66/66 |
| Hindi | 27/39 (69%) | 22/26 (85%) | 66/66 |
| Indonesian | 33/39 (85%) | 24/26 (92%) | 66/66 |
| Japanese | 27/39 (69%) | 24/26 (92%) | 66/66 |
| Korean | 29/38 (76%) | 21/26 (81%) | 65/65 |
| Vietnamese | 30/39 (77%) | 23/26 (88%) | 66/66 |

How to read this:

- **Run-to-run noise is about two messages.** The Chinese and English reading rows are a second run of the same prompts as the table above, and moved by one and two messages (32 → 33, 30 → 32). On 39 messages one message is 2.6 points, so most of the spread between languages is noise. Portuguese, Hindi and Japanese came out lowest in this run. The draft rows were run after one draft example stopped repeating a price in its rewrite (the model had been copying "$3.50" into unrelated replies); Spanish scored 23/26 before that change and 20/26 after.
- **The model always answered in the requested language** (one Korean answer failed to parse, so it has 65 instead of 66).
- **The example translations were machine-written for this project and haven't been checked by native speakers.** Treat the less common languages as a first version, and corrections to `presets/languages/*.json` are welcome.
- **No language was fine-tuned.** The prompted model beat our fine-tuned ones on new messages (see below), so new languages are added through prompts.

Run one yourself: `UNDERTONE_EXPLAIN=es swift run Undertone --eval eval/crosscultural.holdout2.jsonl results.jsonl`, then `python3 scripts/check_language.py results.jsonl es`.

The prompt was last tuned against the 324 labelled messages in [`train/pool.jsonl`](train/pool.jsonl), going from 67% to 75% there. Replacing a blunt "don't over-interpret" rule with an ordered decision checklist fixed most of the cases where polite filler and soft refusals were read as literal. On the fresh held-out set, the same change moved the score only from 79% to 82%, so treat the larger gains as partly the model learning the labelling conventions. Details are in [`train/RESULTS.md`](train/RESULTS.md). Run the evaluations yourself:

```bash
swift run Undertone --eval eval/crosscultural.jsonl results.jsonl              # add --language en for English explanations
python3 scripts/score_eval.py eval/crosscultural.jsonl results.jsonl
```

## Fine-tuning a local model

[`train/`](train) holds an overnight experiment: can a small local model learn the task well enough to drop the long few-shot prompt? It uses QLoRA on a 4-bit **Qwen3.5-4B-Base** with [MLX](https://github.com/ml-explore/mlx) on a 24 GB M4 Pro, and compares two ways of labelling a 288-message training pool:

- **Supervised:** gold readings written by hand, with explanations and replies written by the prompted model given the gold answer.
- **Self-training (no human labels):** the prompted model samples each message three times, and only unanimous answers are kept (167 of 288, 87% correct against the gold labels).

| Model | Dev (40) | Held out (28) | **Fresh held out (39)** | Time per message |
|---|---|---|---|---|
| Prompted qwen3.5:4b (prompt used during training) | 80% | 68% | 79% | 5.9 s |
| **Prompted qwen3.5:4b, current prompt** | **85%** | **79%** | **82%** | 6.1 s |
| Base model, short prompt, no fine-tuning | 31% | — | — | 4.1 s |
| LoRA, supervised (255) | 80% | 61% | — | 4.0 s |
| LoRA, self-training only (145) | 70% | 71% | — | 3.7 s |
| LoRA, supervised + self-training (400) | 85% | 68% | 62%\* | 3.9 s |
| LoRA on 8 layers instead of 5 | 78% | 71% | — | 4.1 s |
| Same, plus 36 targeted messages (30 more minutes) | 78% | 75% | 66%\* | 4.1 s |

\* Exported to Ollama as a 4-bit model, which scored 2 points lower than MLX on the dev set.

Fine-tuning lifts the base model from 31% to about the prompted model's level on the development and first held-out sets, and runs about 30% faster because the long prompt is gone. **On a fresh held-out set written afterwards, though, the prompted model wins clearly**: 79% against 62–66% for the fine-tuned models (exported to Ollama), which also missed more scam and crisis signals. The small, hand-written training pool doesn't generalize as well as a strong instruct model with good examples. So the app keeps the prompted model as the default, and offers the fine-tuned one only as an experimental **Fast** mode ([how to build it](train/ollama/README.md)).

Details, scripts and the pitfalls hit along the way are in [`train/RESULTS.md`](train/RESULTS.md). One of those pitfalls, a per-token loop when training Qwen3.5's Gated DeltaNet layers, is reported upstream as [ml-explore/mlx-lm#1956](https://github.com/ml-explore/mlx-lm/issues/1956).

## Privacy and limits

- **Local by default.** Messages, memory and screenshots stay on your Mac. Cloud models and deAPI are opt-in, and API keys live only in the Keychain.
- **It's a hint, not a verdict.** In our tests the local 4B model gets roughly a quarter to a third of readings wrong, so check against the actual words and what you know about the person. It isn't legal, financial or business advice.
- Live mode works with chat apps that put their messages on the left and yours on the right. For email or team chat tools, use paste mode.

## Development

```bash
swift build && swift test                  # build, then 140 unit tests (parsing, layout, prompts, safety nets)
swift run Undertone --inspect chat.png     # run recognition on one screenshot
swift run Undertone --render-previews out  # render every panel state with fictional data
python3 scripts/make_language_presets.py   # rebuild the other explanation languages after editing the English prompt
```

```
Sources/UndertoneCore/   parsing, layout detection, message tracking, analyzer, draft checker, safety nets
Sources/Undertone/       macOS app: capture, OCR, panel, settings
Sources/UndertoneDemo/   demo chat window
presets/                 prompts, examples and JSON schemas
eval/                    evaluation sets;  train/  fine-tuning experiment
```

## Credits

[Ollama](https://ollama.com), [Qwen](https://github.com/QwenLM), [MLX](https://github.com/ml-explore/mlx), [deAPI](https://deapi.ai). Built with Claude; the chat-bubble parser and new-message tracker were first written with OpenAI Codex.

## License

[Apache License 2.0](LICENSE)
