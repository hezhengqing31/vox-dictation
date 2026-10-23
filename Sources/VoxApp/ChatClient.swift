import Foundation

/// Minimal OpenAI-compatible chat client: one POST to `/chat/completions`, one string back.
/// Works with every provider in `LLMProvider` plus anything else that speaks the same API.
struct ChatClient {
    var config: ModelConfig
    /// Overrides the request timeout (the default is generous: cold local models are slow).
    var timeout: TimeInterval = 180

    struct ChatMessage: Encodable {
        let role: String
        let content: String
    }

    struct ServerError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    private var base: String {
        var s = config.baseURL.trimmingCharacters(in: .whitespaces)
        while s.hasSuffix("/") { s.removeLast() }
        return s
    }

    /// A direct LAN/localhost call must not go through a system proxy (a global proxy answers
    /// 502 for 127.0.0.1), while a remote vendor usually needs one. Only clear it for local hosts.
    private var session: URLSession {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = timeout
        cfg.timeoutIntervalForResource = timeout + 60
        if let host = URL(string: base)?.host, ChatClient.isLocal(host) {
            cfg.connectionProxyDictionary = [:]
        }
        return URLSession(configuration: cfg)
    }

    static func isLocal(_ host: String) -> Bool {
        if host == "localhost" || host == "127.0.0.1" || host == "::1" { return true }
        if host.hasPrefix("10.") || host.hasPrefix("192.168.") || host.hasPrefix("169.254.") { return true }
        if host.hasPrefix("172.") {
            // 172.16.0.0 – 172.31.255.255
            let parts = host.split(separator: ".")
            if parts.count > 1, let second = Int(parts[1]), (16...31).contains(second) { return true }
        }
        return false
    }

    /// Reachability check for the status dot: GET /models is free and every compatible
    /// endpoint implements it.
    func reachable() async -> Bool {
        guard config.isUsable, let url = URL(string: base + "/models") else { return false }
        var req = URLRequest(url: url)
        req.timeoutInterval = 8
        if let key = config.apiKey, !key.isEmpty {
            req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        }
        do {
            let (_, resp) = try await session.data(for: req)
            return (resp as? HTTPURLResponse)?.statusCode == 200
        } catch {
            return false
        }
    }

    /// One completion. Returns the assistant text, trimmed of surrounding whitespace.
    func chat(_ messages: [ChatMessage],
              temperature: Double,
              maxTokens: Int) async throws -> String {
        guard config.isUsable else { throw ServerError(message: T(.errProviderNotSet)) }
        guard let url = URL(string: base + "/chat/completions") else {
            throw ServerError(message: T(.errBadURL))
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let key = config.apiKey, !key.isEmpty {
            req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        }
        let body: [String: Any] = [
            "model": config.model,
            "messages": messages.map { ["role": $0.role, "content": $0.content] },
            "temperature": temperature,
            "max_tokens": maxTokens,
            "stream": false,
        ]
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, resp) = try await session.data(for: req)
        guard let http = resp as? HTTPURLResponse else { throw ServerError(message: T(.errNoResponse)) }
        guard http.statusCode == 200 else {
            throw ServerError(message: "HTTP \(http.statusCode) \(ChatClient.errorSnippet(data))")
        }
        guard let text = ChatClient.extractContent(data) else {
            throw ServerError(message: T(.errEmptyModelOutput))
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { throw ServerError(message: T(.errEmptyModelOutput)) }
        return trimmed
    }

    /// Pulls `choices[0].message.content` (string form). Vendors that answer with a content
    /// array of parts are handled by joining their `text` fields.
    static func extractContent(_ data: Data) -> String? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        guard let choices = obj["choices"] as? [[String: Any]], let first = choices.first else { return nil }
        if let message = first["message"] as? [String: Any] {
            if let s = message["content"] as? String { return s }
            if let parts = message["content"] as? [[String: Any]] {
                let joined = parts.compactMap { $0["text"] as? String }.joined()
                if !joined.isEmpty { return joined }
            }
        }
        if let s = first["text"] as? String { return s }
        return nil
    }

    /// Small slice of the error body, for the toast.
    static func errorSnippet(_ data: Data) -> String {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return String(data: data, encoding: .utf8)?.prefix(160).description ?? ""
        }
        if let err = obj["error"] as? [String: Any], let msg = err["message"] as? String {
            return msg.prefix(160).description
        }
        if let msg = obj["message"] as? String { return msg.prefix(160).description }
        return String(data: data, encoding: .utf8)?.prefix(160).description ?? ""
    }
}
