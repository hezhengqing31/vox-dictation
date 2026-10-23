import Foundation

/// Built-in providers. Every one of them speaks the OpenAI chat-completions API, so the
/// only differences are the base URL, a suggested model name and whether a key is needed.
enum LLMProvider: String, CaseIterable, Identifiable {
    case deepseek, openai, moonshot, zhipu, siliconflow, ollama, lmstudio, custom

    var id: String { rawValue }

    /// Shown in the provider menu; product names stay untranslated.
    var label: String {
        switch self {
        case .deepseek: return "DeepSeek"
        case .openai: return "OpenAI"
        case .moonshot: return "Moonshot / Kimi"
        case .zhipu: return "Zhipu GLM"
        case .siliconflow: return "SiliconFlow"
        case .ollama: return "Ollama (local)"
        case .lmstudio: return "LM Studio (local)"
        case .custom: return "Custom"
        }
    }

    var defaultBaseURL: String {
        switch self {
        case .deepseek: return "https://api.deepseek.com/v1"
        case .openai: return "https://api.openai.com/v1"
        case .moonshot: return "https://api.moonshot.cn/v1"
        case .zhipu: return "https://open.bigmodel.cn/api/paas/v4"
        case .siliconflow: return "https://api.siliconflow.cn/v1"
        case .ollama: return "http://127.0.0.1:11434/v1"
        case .lmstudio: return "http://127.0.0.1:1234/v1"
        case .custom: return ""
        }
    }

    /// A sensible starting model; the field stays editable because vendors rename things.
    var defaultModel: String {
        switch self {
        case .deepseek: return "deepseek-chat"
        case .openai: return "gpt-4o-mini"
        case .moonshot: return "moonshot-v1-8k"
        case .zhipu: return "glm-4-flash"
        case .siliconflow: return "Qwen/Qwen2.5-7B-Instruct"
        case .ollama: return "qwen2.5:7b"
        case .lmstudio: return "local-model"
        case .custom: return ""
        }
    }

    /// Local runtimes accept any key, so the field is hidden for them.
    var requiresKey: Bool {
        switch self {
        case .ollama, .lmstudio, .custom: return false
        default: return true
        }
    }
}

/// Everything needed to call one model: where, which model, and the key.
struct ModelConfig {
    var baseURL: String
    var model: String
    var apiKey: String?

    var isUsable: Bool {
        !baseURL.trimmingCharacters(in: .whitespaces).isEmpty
            && !model.trimmingCharacters(in: .whitespaces).isEmpty
    }
}
