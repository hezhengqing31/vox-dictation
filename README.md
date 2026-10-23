# Vox Dictation

English | [中文](README.zh-CN.md)

A macOS dictation app that does not just transcribe — it edits. Press **Dictate**, speak,
and the transcript lands as an *instruction*; **AI Append** folds it into the text you are
writing, **AI Revise** rewrites what is already there. Text goes where your cursor is, so it
works in any app you can paste into.

![screenshot](docs/screenshot.png)

## Why not just speech-to-text

Raw dictation gives you one long block of whatever you said. Writing is rarely that: you say
"add a line about the rollback rule", or "make paragraph two more formal". Vox keeps the spoken
text as a list of instructions and only touches your document when you ask:

- **Dictate** — click to start, click to stop. Every take becomes one numbered instruction.
- **AI Append** — the new content is tidied into the same format as the existing text and
  appended with continuing numbering. Existing text is left untouched — guaranteed by code, not
  by asking the model nicely: the model only supplies the new items, the app keeps your text and
  does the numbering.
- **AI Revise** — the take is treated as a request and applied to the existing text.
- **Copy** / **Clear All** — put the result on the clipboard or start over. Executed
  instructions move to a history list and are never sent again.

The interface is available in English and Chinese; it follows the system language and can be
switched in Settings.

## Requirements

- macOS 14 or later
- Xcode 16 / Swift 6 toolchain (the package builds with `swift-tools-version:6.0` in Swift 5
  language mode)
- A model endpoint with your own API key — see *Configuration*
- A speech engine: either a local sherpa-onnx setup, or any vendor with an OpenAI-compatible
  transcription endpoint

## Build and run

```bash
./build.sh          # release build, assembles and ad-hoc signs Vox.app
./build.sh run      # same, then opens the app
./build.sh selftest # headless check against the configured provider
```

The app is a SwiftPM executable assembled into a `.app` by hand — there is no `.xcodeproj`.
Ad-hoc signing gives it a stable identity, which the microphone permission (TCC) needs.

## Configuration

Everything lives in **Settings** (bottom right). Keys are stored in the macOS Keychain, never in
`UserDefaults`.

### Model

| Field | Meaning |
|---|---|
| Provider | DeepSeek, OpenAI, Moonshot, Zhipu GLM, SiliconFlow, Ollama, LM Studio, or Custom |
| Base URL | OpenAI-compatible base URL, e.g. `https://api.deepseek.com/v1` |
| Model | Model id; pre-filled per provider and still editable |
| API Key | Bearer key. Local runtimes (Ollama, LM Studio) do not need one. |

The prompts ship inside the app (`WritingPrompts.swift`), so the model is called directly — you
do not need a server of your own.

### Speech

| Engine | What it talks to |
|---|---|
| Local sherpa | A sherpa-onnx streaming server on `:6006` (live preview) and an offline server on `:6007` (final transcript), on the host you enter |
| OpenAI / Groq / SiliconFlow / Custom | `POST {base}/audio/transcriptions`, multipart upload, Bearer key. Batch: the transcript arrives after you stop |
| Deepgram | `POST {base}/v1/listen?model=…` with the raw audio in the body |

Not supported: vendors that queue a job or sign every request with their own scheme (AssemblyAI,
Azure Speech, Alibaba Cloud, Tencent Cloud, Volcano Engine, iFlytek). Each needs a different auth
flow plus a polling loop, so they are out of scope for now. Anything OpenAI-compatible works as
*Custom*.

## How it works

```
Sources/VoxApp/
  App.swift             entry point, headless self-tests, window screenshot helper
  AppModel.swift        state, the actions (dictate / append / revise), settings
  ContentView.swift     layout: output pane, pending instructions, history, settings
  CodeEditor.swift      NSTextView + line-number ruler, placeholder, IME-safe updates
  ASR.swift             capture path, engine switch, final-transcript hand-off
  MicCapture.swift      AVAudioEngine on its own serial queue, resampled to 16 kHz mono
  CloudASR.swift        batch upload (OpenAI-compatible multipart, Deepgram), WAV container
  FileASR.swift         offline final transcript over the sherpa offline WebSocket protocol
  ASREngine.swift       speech engine presets and the settings struct
  ChatClient.swift      OpenAI-compatible /chat/completions
  Writer.swift          the three writing paths, item splitting, numbering, text hygiene
  WritingPrompts.swift  prompt fragments (tuned for Chinese dictation)
  Providers.swift       model provider presets
  Keychain.swift        API key storage
  L10n.swift            all user-visible strings, English + Chinese
  Net.swift             proxy-aware URLSession, base URL normalisation
  Theme.swift           colours and button style
```

Three details worth knowing before changing the audio or model path:

- The microphone is opened when you press **Dictate** and closed right after release, so the
  system recording indicator only lights up while recording. All `AVAudioEngine` calls run on a
  serial queue; doing them on the main thread is what makes a first press stutter.
- The streaming model never decodes its final partial chunk, so the tail word is often lost. With
  the local engine the app keeps the raw PCM of the take and sends it to the offline server for
  the final transcript, falling back to padding silence into the stream if that fails. Cloud
  engines simply upload the take once — which is why they have no live preview.
- **Append never rewrites your text**: the model is asked for the new items only, then
  `Writer.attach` keeps the original string and continues the numbering. A take that is really a
  request ("tidy this up") is routed to the revise path by a 4-token classifier call first;
  without that split the model invents items to append.

The prompts are tuned for Chinese dictation: they tell the model to repair homophones, drop
self-corrections and keep the speaker's own voice. They are not translated yet — an English
prompt set would need its own regression pass.

## Self-tests

```bash
Vox.app/Contents/MacOS/VoxApp --selftest                          # draft / append / revise
Vox.app/Contents/MacOS/VoxApp --cloudasrtest sample16k.wav        # cloud transcription upload
Vox.app/Contents/MacOS/VoxApp --fileasrtest sample16k.wav         # local offline transcript
Vox.app/Contents/MacOS/VoxApp --asrtest sample16k.wav [pad] [live] # local streaming ASR
Vox.app/Contents/MacOS/VoxApp --shot out.png [delay]              # render the window to PNG
```

They read the same settings as the app, so configure it first. wav files must be 16 kHz mono.

## License

MIT — see [LICENSE](LICENSE).
