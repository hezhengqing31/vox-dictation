import Foundation

/// Where a transcript comes from. The app records a whole take and transcribes it on release,
/// so batch (HTTP) engines are enough; live streaming is only used by the local sherpa setup.
///
/// Three API shapes exist in the wild:
///  1. OpenAI-compatible upload — `POST {base}/audio/transcriptions`, multipart, Bearer key,
///     answers `{"text": …}`. OpenAI, Groq, SiliconFlow, Together, Fireworks… all of these.
///  2. Raw audio body — Deepgram `POST {base}/v1/listen?model=…`, binary body, nested JSON.
///  3. Job + poll / request signing — AssemblyAI, Aliyun, Tencent, Volcano, iFlytek. Each one
///     queues a job or signs with its own scheme, so they are not supported here.
enum ASREngine: String, CaseIterable, Identifiable {
    case sherpa, openai, groq, siliconflow, deepgram, custom

    var id: String { rawValue }

    enum Kind { case sherpa, openAICompatible, deepgram }

    var kind: Kind {
        switch self {
        case .sherpa: return .sherpa
        case .deepgram: return .deepgram
        default: return .openAICompatible
        }
    }

    var label: String {
        switch self {
        case .sherpa: return T(.asrSherpa)
        case .openai: return "OpenAI"
        case .groq: return "Groq"
        case .siliconflow: return "SiliconFlow"
        case .deepgram: return "Deepgram"
        case .custom: return T(.asrCustom)
        }
    }

    /// sherpa talks WebSocket to a host you run; everything else talks HTTPS to a vendor.
    var usesLocalServers: Bool { kind == .sherpa }

    var requiresKey: Bool { kind != .sherpa }

    var defaultBaseURL: String {
        switch self {
        case .sherpa: return ""
        case .openai: return "https://api.openai.com/v1"
        case .groq: return "https://api.groq.com/openai/v1"
        case .siliconflow: return "https://api.siliconflow.cn/v1"
        case .deepgram: return "https://api.deepgram.com"
        case .custom: return ""
        }
    }

    /// Model names move around; the field stays editable.
    var defaultModel: String {
        switch self {
        case .sherpa, .custom: return ""
        case .openai: return "gpt-transcribe"
        case .groq: return "whisper-large-v3-turbo"
        case .siliconflow: return "FunAudioLLM/SenseVoiceSmall"
        case .deepgram: return "nova-3"
        }
    }
}

/// Everything the transcription path needs.
struct ASRSettings {
    var engine: ASREngine = .sherpa
    /// Host of the sherpa servers (streaming :6006, offline final pass :6007).
    var host: String = "127.0.0.1"
    /// Base URL / model / key for the cloud engines.
    var baseURL: String = ""
    var model: String = ""
    var apiKey: String = ""
    /// BCP-47-ish hint ("zh", "en"); empty means let the vendor decide.
    var language: String = "zh"

    var isConfigured: Bool {
        engine.usesLocalServers || (!baseURL.isEmpty && !model.isEmpty)
    }
}
