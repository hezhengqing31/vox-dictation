# Vox Dictation

English | [中文](README.zh-CN.md)

A macOS dictation app that does not just transcribe — it edits. Press **Dictate**, speak, and
the transcript lands as an *instruction*: **AI Append** folds it into the text you are writing,
**AI Revise** rewrites what is already there. The text stays in the app's own pane, ready to copy
into anything.

![screenshot](docs/screenshot.png)

## Usage

- **Dictate** — click to start, click to stop. Each take becomes one numbered instruction.
- **AI Append** — the new content is tidied and appended after the existing text with continuing
  numbering; the existing text is left as it is.
- **AI Revise** — the take is treated as a request and applied to the existing text.
- **Copy** / **Clear All** — put the result on the clipboard, or start over. Instructions that
  already ran move to a history list and are never sent again.

The interface is available in English and Chinese; it follows the system language and can be
switched under **Settings → App**.

## Configuration

Everything is in **Settings** (bottom right), split into *Model*, *Speech (ASR)* and *App*.

For the model, pick a provider (DeepSeek, OpenAI, Moonshot, Zhipu GLM, SiliconFlow, Ollama,
LM Studio or Custom), keep or edit the base URL and model id, and paste your API key. Local
runtimes need no key. Keys are stored in the macOS Keychain. Each tab has a **Test** button that
checks the connection without sending any audio.

For speech recognition, either point the app at a local sherpa-onnx setup (streaming on `:6006`,
final transcript on `:6007`), or use any vendor with an OpenAI-compatible transcription endpoint —
OpenAI, Groq, SiliconFlow, Deepgram, Aliyun Qwen-ASR and Baidu Speech are built in, and anything
else that speaks the OpenAI transcription API works through *Custom*.

## Build

Requires macOS 14 or later and the Xcode 16 / Swift 6 toolchain.

```bash
./build.sh       # release build, assembles and ad-hoc signs Vox.app
./build.sh run   # same, then opens the app
```

The result is `Vox.app` in the project directory. The bundle is ad-hoc signed, which the
microphone permission needs.

## License

MIT — see [LICENSE](LICENSE).
