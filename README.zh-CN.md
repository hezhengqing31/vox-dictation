# Vox Dictation

[English](README.md) | 中文

一个 macOS 听写工具，不只是把语音转成文字——它会改稿。点 **ASR 录入** 说话，这段语音先成为一条**指令**；点 **AI整理** 把它并进你正在写的正文，点 **AI修改** 按它的要求改写已有内容。文字落在你的光标处，任何能粘贴的应用都能用。

![screenshot](docs/screenshot.png)

## 和普通语音输入的区别

纯转写只会把你说的话原样码成一大段。但写字很少是这个状态：你会说"补一句回滚规则"，或者说"第二段语气改正式点"。Vox 把口述内容当成一列待发指令，只有你按下按钮时它才动你的稿子：

- **ASR 录入** — 点一下开始，再点一下停止。每说一次就是一条带编号的指令。说话期间不向任何接口发请求。
- **AI整理** — 把新增内容整理成和现有正文一致的格式，接在后面、编号顺延，已有文字一字不动。
- **AI修改** — 把这段口述当作修改要求，应用到现有正文上。
- **复制输出** / **清空全部** — 把结果放进剪贴板，或者推倒重来。执行过的指令沉到历史记录，不会再被发出去。

界面支持中英双语，默认跟随系统，可在设置里手动切换。

## 环境要求

- macOS 14 或更新
- Xcode 16 / Swift 6 工具链（包用 `swift-tools-version:6.0`，以 Swift 5 语言模式编译）
- 目前还需要两个本地服务（见"配置"）：
  - 一个写作服务，提供 `POST /llmwriter/write` 与 `POST /llmwriter/rewrite`
  - 语音服务：sherpa-onnx 流式 WebSocket 服务（`:6006`），以及 sherpa-onnx 非流式 WebSocket 服务（`:6007`）用于出定稿

## 构建与运行

```bash
./build.sh          # release 构建，组装并 ad-hoc 签名 Vox.app
./build.sh run      # 同上，构建完直接打开
./build.sh selftest # 无界面跑一遍大模型接口
```

这是一个 SwiftPM 可执行目标，`.app` 是脚本手工组装的，没有 `.xcodeproj`。ad-hoc 签名给它一个稳定身份，麦克风权限（TCC）要靠这个。

## 配置

点右下角 **设置**：

| 字段 | 含义 |
|---|---|
| 大模型地址 | 写作服务的基址，例如 `http://127.0.0.1:5000`。整理走 `/llmwriter/write`，修改走 `/llmwriter/rewrite`。 |
| 清空前不再询问 | 勾选后点"清空全部"不再弹确认框。 |
| 语言 | 跟随系统，或强制中文 / English。 |

ASR 的主机名从大模型地址里取：流式连接 `:6006`，定稿走 `:6007`。

> **路线图：** 接下来要做"自带厂商"的配置——选大模型厂商、填自己的 API Key、选 ASR 厂商。在此之前，应用依赖上面这两个本地服务，写作提示词在服务端，不在客户端里。

## 代码结构

```
Sources/VoxApp/
  App.swift          入口、无界面自检、窗口截图工具
  AppModel.swift     状态、三个动作（录入 / 整理 / 修改）、设置
  ContentView.swift  版式：输出窗口、待发指令、历史记录、底栏
  CodeEditor.swift   NSTextView + 行号栏、占位文字、输入法安全的外部写入
  ASR.swift          流式 ASR 客户端、采集开关、定稿交接
  FileASR.swift      走 sherpa 非流式 WebSocket 协议的定稿
  MicCapture.swift   AVAudioEngine 跑在独立串行队列，重采样到 16k 单声道
  LLMClient.swift    写作 / 改写接口
  L10n.swift         全部界面文案，中英各一份
  Theme.swift        配色与按钮样式
```

改动音频链路前值得知道的两件事：

- 麦克风在按下 **ASR 录入** 时才打开，松手立刻关闭，所以系统的录音指示点只在真正录音时亮。所有 `AVAudioEngine` 调用都在串行队列上做；放在主线程就是"第一次点录音卡一下"的来源。
- 流式模型不会解码最后那个不满的 chunk，尾字经常丢。所以应用同时保留了整段 PCM，松手后交给非流式服务出定稿；失败才退回"往流里补静音"的老办法。

## 自检

```bash
Vox.app/Contents/MacOS/VoxApp --selftest                          # 大模型接口
Vox.app/Contents/MacOS/VoxApp --fileasrtest sample16k.wav         # 非流式 ASR
Vox.app/Contents/MacOS/VoxApp --asrtest sample16k.wav [pad] [live] # 流式 ASR
Vox.app/Contents/MacOS/VoxApp --shot out.png [delay]              # 把窗口渲染成 PNG
```

wav 必须是 16k 单声道。

## License

MIT — 见 [LICENSE](LICENSE)。
