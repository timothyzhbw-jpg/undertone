# Undertone for Windows and Linux

The same Undertone as the Mac app, in a cross-platform desktop app (Electron): it reads the subtext in English messages and explains it in one of 13 languages, with a natural English reply, Check before you send, and the payment-scam and crisis cards. It uses the same prompts ([`../presets`](../presets)), the same vocabulary and the same keyword safety nets as the Mac app, and the same local model through [Ollama](https://ollama.com).

> **Status: early.**
> - **Linux:** tested on Ubuntu 24.04 (arm64 natively, x64 under emulation) in Docker with a virtual display. Installing the `.deb` with apt, the AppImage, paste analysis, and live reading of a chat window all work.
> - **Windows:** the installers are built, but they haven't been tried on a real Windows PC yet.
> - **macOS:** the same code runs there too, but use the [Mac app](../README.md) instead.

## Install (Windows)

1. Install [Ollama for Windows](https://ollama.com/download), then in a terminal: `ollama pull qwen3.5:4b`
2. Run `Undertone-Setup-<version>-x64.exe` (or `-arm64` on ARM laptops). The installer isn't code-signed yet, so Windows SmartScreen will warn: click **More info → Run anyway**.

## Install (Linux)

1. Install [Ollama](https://ollama.com/download/linux): `curl -fsSL https://ollama.com/install.sh | sh`, then `ollama pull qwen3.5:4b`
2. Ubuntu, Debian and friends: `sudo apt install ./undertone_<version>_amd64.deb` (or `_arm64.deb`), then open Undertone from the app menu or run `undertone-desktop`.
3. Other distributions (x64): `chmod +x Undertone-<version>-x86_64.AppImage` and run it. There's no arm64 AppImage: its launcher needs `libz.so`, which most systems don't have, so use the `.deb` on arm64.

Live mode works on X11 sessions. On Wayland, your desktop will ask which window to share; that path hasn't been tested yet.

## Use

- **Paste:** copy a few messages (`Name: message`) or an email into the box and click Analyze. You can also paste or drop a screenshot of a phone chat or an email; it's read on your computer with OCR, shown as editable text, then analyzed.
- **Live:** pick the chat window to watch. Undertone reads it every couple of seconds and analyzes each new message from the other person: their messages sit on the left, yours on the right. In Settings you can skip the top and bottom of the window (title bar, message box).
- **Relationship:** client, coworker, professor, classmate or friend. The same sentence means different things to different people.
- **Explain in:** Settings → Explain in. Suggested replies are always in English.

Everything runs on your computer. Undertone never connects to a messaging app or sends anything.

## How it differs from the Mac app

| | Mac app (Swift) | This app |
|---|---|---|
| Reading the screen | Apple Vision OCR + pixel-level bubble detection | [Tesseract](https://github.com/naptha/tesseract.js) OCR (English), bubbles by text position |
| Stickers, emoji, voice | Read by the vision model; voice via deAPI | Voice bubbles become `[voice 6s]`; stickers and emoji are skipped |
| Contact memory, cloud models, Fast mode | Yes | Not yet |
| Analysis, prompts, 13 languages, safety nets | Same | Same |

## Same results as the Mac app

- The prompt sent to the model is identical, character for character: [`test/core.test.js`](test/core.test.js) compares it with what the Mac app produces (`Undertone --dump-prompt`) in four languages.
- The vocabulary and the keyword nets are extracted from the Swift source by [`tools/extract_core.py`](tools/extract_core.py), so there is one source of truth.
- On the fresh held-out set, this app read 31/39 messages correctly (the Mac app: 30–32/39 across runs) and got 24/26 draft verdicts right (Mac: 24/26), with English explanations. Run it with `node tools/eval.js ../eval/crosscultural.holdout2.jsonl results.jsonl en`, then `python3 ../scripts/score_eval.py`.

## Develop

```bash
npm install
npm test                          # analysis logic, prompt parity with the Mac app, bubble layout
npm start                         # run the app
UNDERTONE_REPLAY=dir npm start    # live mode replays the PNG screenshots in dir instead of capturing a window
npx electron test/ocr-check.js shot.png   # run OCR and bubble layout on one screenshot
npm run dist:win                  # Windows installers (x64, arm64) in dist/
npm run dist:linux                # Linux: .deb (x64, arm64) and AppImage (x64)
python3 tools/extract_core.py     # after changing Language.swift or SafetyNet.swift
```

```
core/       analysis logic (prompts, parsing, vocabulary, safety nets, pasted transcripts), no UI
app/        Electron: main process, OCR and bubble layout, preload, renderer (panel UI)
test/       Node tests; fixtures/ holds prompts dumped from the Mac app
tools/      extract_core.py, eval.js, cdp.js (drive a running app over the DevTools protocol)
test/linux/ Docker image for trying the Linux build on a virtual display (see its README)
```
