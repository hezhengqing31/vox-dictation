# Vox Dictation

English | [中文](README.zh-CN.md)

A macOS dictation app that does not just transcribe — it edits. Press **Dictate**, speak,
and the transcript lands as an *instruction*; **AI Append** folds it into the text you are
writing, **AI Revise** rewrites what is already there. Text goes where your cursor is, so it
works in any app you can copy from.

![screenshot](docs/screenshot.png)

## Why not just speech-to-text

Raw dictation gives you one long block of whatever you said. Writing is rarely that: you
say "add a line about the rollback rule", or "make paragraph two more formal". Vox keeps the
spoken text as a list of instructions and only touches your document when you ask:

- **Dictate** — click to start, click to stop. Every take becomes one numbered instruction.
  Nothing is sent anywhere while you speak.
- **AI Append** — the new content is tidied into the same format as the existing text and
  appended with continuing numbering. Existing text is left untouched.
- **AI Revise** — the take is treated as a request and applied to the existing text.
- **Copy** / **Clear All** — put the result on the clipboard or start over. Executed
  instructions move to a history list and are never sent again.

The interface is available in English and Chinese; it follows the system language and can be
switched in Settings.

## Requirements

- macOS 14 or later
- Xcode 16 / Swift 6 toolchain (the package builds with `swift-tools-version:6.0` in Swift 5
  language mode)
- Two local services for now (see *Configuration*):
  - a writing service exposing `POST /llmwriter/write` and `POST /llmwriter/rewrite`
  - a speech service: a sherpa-onnx streaming WebSocket server (`:6006`) plus a
    sherpa-onnx offline WebSocket server (`:6007`) for the final transcript

## Build and run

```bash
./build.sh          # release build, assembles and ad-hoc signs Vox.app
./build.sh run      # same, then opens the app
./build.sh selftest # headless check of the model endpoint
```

The app is a SwiftPM executable assembled into a `.app` by hand — there is no `.xcodeproj`.
Ad-hoc signing gives it a stable identity, which the microphone permission (TCC) needs.

## Configuration

Open **Settings** (bottom right):

| Field | Meaning |
|---|---|
| Model endpoint | Base URL of the writing service, e.g. `http://127.0.0.1:5000`. The app calls `/llmwriter/write` (append) and `/llmwriter/rewrite` (revise) on it. |
| Don't ask before clearing | Skip the confirmation dialog when pressing *Clear All*. |
| Language | Follow the system, or force Chinese / English. |

The ASR endpoint is derived from the model endpoint's host: streaming on `:6006`, offline
final transcript on `:6007`.

> **Roadmap:** bring-your-own-provider support (choose an LLM vendor, paste an API key,
> choose an ASR vendor) is the next thing to land. Until then the app expects the two local
> services above, and the writing prompts live on that service, not in the app.

## How it works

```
Sources/VoxApp/
  App.swift          entry point, headless self-test, window screenshot helper
  AppModel.swift     state, the three actions (dictate / append / revise), settings
  ContentView.swift  layout: output pane, pending instructions, history, footer
  CodeEditor.swift   NSTextView + line-number ruler, placeholder, IME-safe updates
  ASR.swift          streaming ASR client, capture gating, final-transcript hand-off
  FileASR.swift      offline final transcript over the sherpa offline WebSocket protocol
  MicCapture.swift   AVAudioEngine on its own serial queue, resampled to 16 kHz mono
  LLMClient.swift    writer/rewrite endpoints
  L10n.swift         all user-visible strings, English + Chinese
  Theme.swift        colours and button style
```

Two details worth knowing if you change the audio path:

- The microphone is opened when you press **Dictate** and closed right after release, so the
  system recording indicator only lights up while recording. All `AVAudioEngine` calls run on
  a serial queue; doing them on the main thread is what makes a first press stutter.
- The streaming model never decodes its final partial chunk, so the tail word is often lost.
  The app therefore also keeps the raw PCM of the take and sends it to the offline server for
  the final transcript, falling back to padding silence into the stream if that fails.

## Self-tests

```bash
Vox.app/Contents/MacOS/VoxApp --selftest                          # model endpoint
Vox.app/Contents/MacOS/VoxApp --fileasrtest sample16k.wav         # offline ASR
Vox.app/Contents/MacOS/VoxApp --asrtest sample16k.wav [pad] [live] # streaming ASR
Vox.app/Contents/MacOS/VoxApp --shot out.png [delay]              # render the window to PNG
```

The wav files must be 16 kHz mono.

## License

MIT — see [LICENSE](LICENSE).
