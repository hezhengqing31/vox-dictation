import Foundation

/// Model client: talks to the llmwriter scenes already running on the server by default,
/// but any equivalent endpoint (local mlx_lm.server / llama.cpp) works too.
struct LLMClient {
    /// e.g. http://192.168.1.101:5000
    var baseURL: URL
    /// Writer endpoint: first draft, or tidy the new content into the existing text.
    var writerPath: String = "/llmwriter/write"
    /// Rewrite endpoint: change the text as instructed, add nothing.
    var rewritePath: String = "/llmwriter/rewrite"

    struct WriterResult: Decodable {
        let content: String
        let model: String?
        let scene: String?
        let temperature: Double?
        let max_tokens: Int?
    }

    struct ServerError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    private var session: URLSession {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 180
        cfg.timeoutIntervalForResource = 240
        // Direct LAN connection: no system proxy (Clash forwards 192.168.x.x and answers 502)
        cfg.connectionProxyDictionary = [:]
        return URLSession(configuration: cfg)
    }

    /// Health check: being able to read the scene table counts as reachable.
    func health() async -> Bool {
        guard let url = URL(string: baseURL.absoluteString + "/llmwriter/info") else { return false }
        var req = URLRequest(url: url)
        req.timeoutInterval = 6
        do {
            let (_, resp) = try await session.data(for: req)
            return (resp as? HTTPURLResponse)?.statusCode == 200
        } catch {
            return false
        }
    }

    /// Writing: target text + several instructions (+ optional previous output).
    /// The model decides whether an instruction adds something to the target or changes it.
    func write(instructions: [String], target: String, lastOutput: String) async throws -> (text: String, seconds: Double) {
        var body: [String: Any] = [
            "target": target,
            "instructions": instructions,
        ]
        if !lastOutput.trimmingCharacters(in: .whitespaces).isEmpty { body["last_output"] = lastOutput }

        guard let url = URL(string: baseURL.absoluteString + writerPath) else {
            throw ServerError(message: T(.errBadURL))
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let started = Date()
        let (data, resp) = try await session.data(for: req)
        let seconds = Date().timeIntervalSince(started)
        guard let http = resp as? HTTPURLResponse else { throw ServerError(message: T(.errNoResponse)) }
        guard http.statusCode == 200 else {
            let raw = String(data: data, encoding: .utf8) ?? ""
            throw ServerError(message: "HTTP \(http.statusCode) \(raw.prefix(160))")
        }
        let decoded = try JSONDecoder().decode(WriterResult.self, from: data)
        // Trailing whitespace, blank lines and the overall trim are the server's job
        // (writer_core._tidy_lines); the client shows exactly what it gets.
        let text = decoded.content
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw ServerError(message: T(.errEmptyModelOutput))
        }
        return (text, seconds)
    }

    /// Rewrite endpoint: content + instructions (mode: tidy = append, modify = change) -> full text.
    /// Tidy sends several raw takes; modify sends one request.
    func modify(content: String, instructions: [String], mode: String = "modify") async throws -> (text: String, seconds: Double) {
        // Tidy goes to /write, modify to /rewrite; the endpoint decides the behaviour, `mode` is not sent.
        let isTidy = (mode == "tidy")
        let path = isTidy ? writerPath : rewritePath
        guard let url = URL(string: baseURL.absoluteString + path) else {
            throw ServerError(message: T(.errBadURL))
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        var body: [String: Any] = ["content": content]
        if isTidy {
            body["instructions"] = instructions        // raw list: no numbering, no joining
        } else {
            body["instruction"] = instructions.joined(separator: "\n")
        }
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let started = Date()
        let (data, resp) = try await session.data(for: req)
        let seconds = Date().timeIntervalSince(started)
        guard let http = resp as? HTTPURLResponse else { throw ServerError(message: T(.errNoResponse)) }
        guard http.statusCode == 200 else {
            let raw = String(data: data, encoding: .utf8) ?? ""
            throw ServerError(message: "HTTP \(http.statusCode) \(raw.prefix(160))")
        }
        let decoded = try JSONDecoder().decode(WriterResult.self, from: data)
        // Trailing whitespace, blank lines and the overall trim are the server's job
        // (writer_core._tidy_lines); the client shows exactly what it gets.
        let text = decoded.content
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw ServerError(message: T(.errEmptyModelOutput))
        }
        return (text, seconds)
    }
}
