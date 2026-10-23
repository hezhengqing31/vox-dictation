import Foundation

/// UI language selection. `.system` follows the macOS preferred language.
enum UILanguage: String, CaseIterable, Identifiable {
    case system, zh, en

    var id: String { rawValue }

    /// Picker label. Kept bilingual on purpose: it has to stay readable even
    /// when the current UI language is not the one you are switching to.
    var label: String {
        switch self {
        case .system: return "跟随系统 / System"
        case .zh: return "中文"
        case .en: return "English"
        }
    }
}

/// The language actually used for rendering (`.system` already resolved).
enum Lang {
    case zh, en
}

/// Every user-visible string in the app.
enum LKey {
    // Chrome
    case appTitle, settingsTitle, close

    // Pending / history panes
    case historyTitle, tagAppend, tagRevise
    case emptyPending, emptyApplied
    case copyInstructionHelp, deleteInstructionHelp

    // Output pane
    case outputPlaceholder, modelLabel

    // Footer buttons
    case btnDictate, btnStop, btnAppend, btnRevise, btnCopyOutput, btnClearAll, btnSettings

    // Status line
    case stConnecting, stReady, stOffline, stListening, stFinishing, stAppending, stRevising, stFailed

    // Toasts
    case toastMicGranted, toastMicDenied, toastNoNewContent
    case toastNoNewContentAdded
    case toastCopiedOutput, toastCopiedInstruction, toastAlreadyEmpty, toastCleared
    case toastModelUnavailable

    // Clear-all alert
    case alertTitle, alertBody, alertClear, alertCancel, alertDontAsk

    // Settings sheet
    case setLanguage, setProvider, setModel, setApiKey, setKeyHint
    case setModelEndpoint, setEndpointHint
    case setTest, setNotChecked, setConnected, setUnreachable
    case setModelSection, setSpeechSection, setInterfaceSection
    case tabModel, tabSpeech, tabApp, setConfirmClear, setConfirmClearHelp
    case asrNotConfigured, asrKeyMissing, asrUnreachable, asrReady, setAsrLocalHelp, setAsrCloudHelp
    case setAsrEngine, asrSherpa, asrCustom, setAsrBaseURL, setAsrModel, setAsrKey, setAsrLanguage
    case setAsrHost, setAsrTitle, setAsrProtocol, setMicGranted, setMicDenied

    // Runtime errors (ASR / microphone / client)
    case errNoMicPermission, errDisconnected, errMicStart
    case errNoMicInput, errConverterInit
    case errBadURL, errNoResponse, errEmptyModelOutput, errProviderNotSet
    case errASRFailed, errASREmptyAudio, errEmptyTranscript
}

/// One string in both languages.
private struct Pair {
    let zh: String
    let en: String
}

/// The single translation table. Add new keys here, never inline in views.
private let table: [LKey: Pair] = [
    // Chrome
    .appTitle: Pair(zh: "AI录入助手", en: "AI Dictation"),
    .settingsTitle: Pair(zh: "设置", en: "Settings"),
    .close: Pair(zh: "关闭", en: "Close"),

    // Pending / history panes
    .historyTitle: Pair(zh: "历史记录", en: "History"),
    .tagAppend: Pair(zh: "整理", en: "Append"),
    .tagRevise: Pair(zh: "修改", en: "Revise"),
    .emptyPending: Pair(
        zh: "点「ASR 录入」开始，再点一下停止；每说一次在这里多一条，点「AI整理」或「AI修改」发给大模型",
        en: "Press “Dictate” to start, press again to stop. Each take adds one instruction here; “AI Append” or “AI Revise” sends them to the model."),
    .emptyApplied: Pair(
        zh: "执行过的指令会留在这里，不会再发给大模型",
        en: "Instructions you have run stay here; they are never sent again."),
    .copyInstructionHelp: Pair(zh: "复制这条指令", en: "Copy this instruction"),
    .deleteInstructionHelp: Pair(zh: "删除这条指令", en: "Delete this instruction"),

    // Output pane
    .outputPlaceholder: Pair(
        zh: "可以直接打字，也可以点「ASR 录入」攒指令：点「AI整理」把新增内容整理补充进来，点「AI修改」按要求改动现有内容。",
        en: "Type here, or press “Dictate” to stack up instructions: “AI Append” folds the new content into the text, “AI Revise” changes the text the way you ask."),
    .modelLabel: Pair(zh: "大模型", en: "Model"),

    // Footer buttons
    .btnDictate: Pair(zh: "ASR 录入", en: "Dictate"),
    .btnStop: Pair(zh: "停止", en: "Stop"),
    .btnAppend: Pair(zh: "AI整理", en: "AI Append"),
    .btnRevise: Pair(zh: "AI修改", en: "AI Revise"),
    .btnCopyOutput: Pair(zh: "复制输出", en: "Copy"),
    .btnClearAll: Pair(zh: "清空全部", en: "Clear All"),
    .btnSettings: Pair(zh: "设置", en: "Settings"),

    // Status line
    .stConnecting: Pair(zh: "连接中…", en: "Connecting…"),
    .stReady: Pair(zh: "已就绪", en: "Ready"),
    .stOffline: Pair(zh: "连接失败", en: "Offline"),
    .stListening: Pair(zh: "聆听中…", en: "Listening…"),
    .stFinishing: Pair(zh: "收尾中…", en: "Finishing…"),
    .stAppending: Pair(zh: "整理中…", en: "Appending…"),
    .stRevising: Pair(zh: "修改中…", en: "Revising…"),
    .stFailed: Pair(zh: "失败", en: "Failed"),

    // Toasts
    .toastMicGranted: Pair(zh: "已授权，再按一次开始说", en: "Microphone granted — press again to start"),
    .toastMicDenied: Pair(zh: "麦克风未授权", en: "Microphone access denied"),
    .toastNoNewContent: Pair(
        zh: "还没有新说的话，点「ASR 录入」先说一条",
        en: "Nothing new to send — press “Dictate” and say something first."),
    .toastNoNewContentAdded: Pair(zh: "没有新增内容，原文未改动", en: "Nothing new to add — the text is unchanged"),
    .toastCopiedOutput: Pair(zh: "已复制输出", en: "Output copied"),
    .toastCopiedInstruction: Pair(zh: "已复制这条指令", en: "Instruction copied"),
    .toastAlreadyEmpty: Pair(zh: "已经是空的", en: "Already empty"),
    .toastCleared: Pair(zh: "已清空", en: "Cleared"),
    .toastModelUnavailable: Pair(zh: "大模型不可用：%@", en: "Model unavailable: %@"),

    // Clear-all alert
    .alertTitle: Pair(zh: "清空全部内容？", en: "Clear everything?"),
    .alertBody: Pair(
        zh: "输出栏、待发指令和已用指令都会清掉，不能撤销。",
        en: "The output, the pending instructions and the history will all be removed. This cannot be undone."),
    .alertClear: Pair(zh: "清空", en: "Clear"),
    .alertCancel: Pair(zh: "取消", en: "Cancel"),
    .alertDontAsk: Pair(zh: "以后不再提醒", en: "Don't ask again"),

    // Settings sheet
    .setLanguage: Pair(zh: "语言", en: "Language"),
    .setProvider: Pair(zh: "厂商", en: "Provider"),
    .setModel: Pair(zh: "模型", en: "Model"),
    .setApiKey: Pair(zh: "API Key", en: "API Key"),
    .setKeyHint: Pair(
        zh: "Key 存在系统钥匙串里，不写进偏好设置",
        en: "Stored in the macOS Keychain, never in preferences."),
    .setModelEndpoint: Pair(zh: "接口地址", en: "Base URL"),
    .setEndpointHint: Pair(
        zh: "OpenAI 兼容地址，例如 https://api.deepseek.com/v1；本机服务直接用 http://127.0.0.1:11434/v1",
        en: "An OpenAI-compatible base URL, e.g. https://api.deepseek.com/v1 — a local runtime is http://127.0.0.1:11434/v1"),
    .setTest: Pair(zh: "测试连接", en: "Test"),
    .setNotChecked: Pair(zh: "未检测", en: "Not checked"),
    .setConnected: Pair(zh: "连接正常", en: "Connected"),
    .setUnreachable: Pair(zh: "连不上", en: "Unreachable"),
    .setModelSection: Pair(zh: "大模型", en: "Model"),
    .tabModel: Pair(zh: "大模型", en: "Model"),
    .tabSpeech: Pair(zh: "语音识别", en: "Speech"),
    .tabApp: Pair(zh: "应用设置", en: "App"),
    .setConfirmClear: Pair(zh: "清空全部前先确认", en: "Ask before clearing everything"),
    .setConfirmClearHelp: Pair(
        zh: "清空会把输出、待发指令和历史记录一起抹掉，不能撤销。关掉这个开关，点「清空全部」就直接清，不再弹窗。",
        en: "Clearing wipes the output, the pending instructions and the history at once, and cannot be undone. Turn this off and “Clear All” clears immediately without a dialog."),
    .setSpeechSection: Pair(zh: "语音识别（ASR）", en: "Speech recognition (ASR)"),
    .setInterfaceSection: Pair(zh: "界面", en: "Interface"),
    .asrNotConfigured: Pair(
        zh: "还没配好：语音识别要单独设置，否则松手后出不来文字",
        en: "Not set up yet — speech recognition is configured separately; without it nothing appears after you stop."),
    .asrKeyMissing: Pair(zh: "还缺 API Key", en: "API key is still missing"),
    .asrUnreachable: Pair(
        zh: "连不上：检查地址、Key 和模型名",
        en: "Can't connect — check the endpoint, key and model name"),
    .asrReady: Pair(zh: "已就绪：%@ · %@", en: "Ready: %@ · %@"),
    .setAsrLocalHelp: Pair(
        zh: "需要在这台主机上运行 sherpa-onnx 两个服务：流式 :6006（边说边出字）与非流式 :6007（出定稿）",
        en: "Needs both sherpa-onnx servers running on that host: streaming :6006 (live text) and offline :6007 (final transcript)"),
    .setAsrCloudHelp: Pair(
        zh: "和上面的大模型是两套配置：地址、模型、Key 都单独填，松手后整段上传识别",
        en: "Separate from the model above — its own endpoint, model and key. The take is uploaded once you stop."),
    .setAsrEngine: Pair(zh: "识别方式", en: "Speech engine"),
    .asrSherpa: Pair(zh: "本地 sherpa", en: "Local sherpa"),
    .asrCustom: Pair(zh: "自定义", en: "Custom"),
    .setAsrBaseURL: Pair(zh: "识别接口", en: "Speech endpoint"),
    .setAsrModel: Pair(zh: "识别模型", en: "Speech model"),
    .setAsrKey: Pair(zh: "识别用 API Key", en: "Speech API key"),
    .setAsrLanguage: Pair(zh: "识别语言（留空=自动）", en: "Language (blank = auto)"),
    .setAsrHost: Pair(zh: "ASR 服务地址", en: "ASR host"),
    .setAsrTitle: Pair(zh: "ASR：sherpa 流式 + 非流式定稿", en: "ASR: sherpa streaming + offline final pass"),
    .setAsrProtocol: Pair(
        zh: "（16k 单声道 Float32，与网页版同一协议）",
        en: " (16 kHz mono Float32, same protocol as the web version)"),
    .setMicGranted: Pair(zh: "麦克风已授权", en: "Microphone access granted"),
    .setMicDenied: Pair(
        zh: "麦克风未授权：系统设置 → 隐私与安全性",
        en: "Microphone access denied — System Settings → Privacy & Security"),

    // Runtime errors
    .errNoMicPermission: Pair(
        zh: "麦克风未授权：系统设置 → 隐私与安全性 → 麦克风",
        en: "Microphone access denied — System Settings → Privacy & Security → Microphone"),
    .errDisconnected: Pair(zh: "连接断开：%@", en: "Connection lost: %@"),
    .errMicStart: Pair(zh: "启动麦克风失败：%@", en: "Could not start the microphone: %@"),
    .errNoMicInput: Pair(zh: "没有可用的麦克风输入", en: "No microphone input available"),
    .errConverterInit: Pair(zh: "音频转换器初始化失败", en: "Could not create the audio converter"),
    .errBadURL: Pair(zh: "地址不合法", en: "Invalid endpoint URL"),
    .errNoResponse: Pair(zh: "无响应", en: "No response"),
    .errEmptyModelOutput: Pair(zh: "模型没有返回内容", en: "The model returned nothing"),
    .errASRFailed: Pair(zh: "语音识别失败：%@", en: "Transcription failed: %@"),
    .errASREmptyAudio: Pair(zh: "没有可上传的音频", en: "No audio to upload"),
    .errEmptyTranscript: Pair(zh: "没有识别到文字", en: "Nothing was transcribed"),
    .errProviderNotSet: Pair(
        zh: "还没有配置大模型：到设置里选厂商、填 API Key",
        en: "No model configured yet — pick a provider and paste an API key in Settings."),
]

/// Holds the resolved language. Readable from any thread (microphone callbacks
/// build error strings off the main actor), so the value sits behind a lock.
final class L10n {
    static let shared = L10n()

    private let lock = NSLock()
    private var current: Lang = .zh

    var lang: Lang {
        lock.lock(); defer { lock.unlock() }
        return current
    }

    /// Apply the user's choice and resolve `.system` against the preferred languages.
    func apply(_ language: UILanguage) {
        let resolved = L10n.resolve(language)
        lock.lock(); current = resolved; lock.unlock()
    }

    static func resolve(_ language: UILanguage) -> Lang {
        switch language {
        case .zh: return .zh
        case .en: return .en
        case .system:
            // Chinese stays the default: anything else falls back to English.
            let preferred = Locale.preferredLanguages.first ?? "en"
            return preferred.hasPrefix("zh") ? .zh : .en
        }
    }
}

/// Localized text for `key`.
func T(_ key: LKey) -> String {
    let pair = table[key] ?? Pair(zh: key.debugName, en: key.debugName)
    return L10n.shared.lang == .zh ? pair.zh : pair.en
}

/// Localized text with `String(format:)` arguments (`%@`, `%d`, `%.1f`).
func TF(_ key: LKey, _ args: CVarArg...) -> String {
    String(format: T(key), arguments: args)
}

/// "3 条" / "3 items" — the count badges need real plural forms in English.
func TCount(_ n: Int) -> String {
    if L10n.shared.lang == .zh { return "\(n) 条" }
    return n == 1 ? "1 item" : "\(n) items"
}

/// "3 字" / "3 chars" — the character counter under the output.
func TChars(_ n: Int) -> String {
    if L10n.shared.lang == .zh { return "\(n) 字" }
    return n == 1 ? "1 char" : "\(n) chars"
}

private extension LKey {
    /// Fallback text if a key ever misses the table.
    var debugName: String { String(describing: self) }
}
