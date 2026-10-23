import Foundation

/// Cloud transcription for the batch-style engines: one HTTP request per take.
///
/// Two shapes are supported (see `ASREngine`):
///  - OpenAI-compatible upload: `POST {base}/audio/transcriptions`, multipart form, Bearer key,
///    answer `{"text": …}`. Works for OpenAI, Groq, SiliconFlow and anything else that copied it.
///  - Deepgram: `POST {base}/v1/listen?model=…`, raw audio in the body, answer nested under
///    `results.channels[0].alternatives[0].transcript`.
///
/// Engines that queue a job or sign each request (AssemblyAI, Aliyun, Tencent, Volcano, iFlytek)
/// are deliberately absent: each needs its own auth scheme and polling loop.
enum CloudASR {

    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// Transcribe one take. `pcm` is 16 kHz mono Float32 little-endian, as captured.
    static func transcribe(pcm: Data, settings: ASRSettings) async throws -> String {
        let wav = wav(fromFloat32: pcm)
        guard wav.count > 44 else { throw Failure(message: T(.errASREmptyAudio)) }
        switch settings.engine.kind {
        case .openAICompatible:
            return try await upload(wav: wav, settings: settings)
        case .deepgram:
            return try await deepgram(wav: wav, settings: settings)
        case .dashscope:
            return try await dashscope(wav: wav, settings: settings)
        case .baidu:
            return try await baidu(wav: wav, settings: settings)
        case .sherpa:
            throw Failure(message: TF(.errASRFailed, "local engine"))
        }
    }

    /// Cheap check for the status dot: does the vendor answer an authenticated GET?
    static func reachable(settings: ASRSettings) async -> Bool {
        guard !settings.baseURL.isEmpty else { return false }
        let base = Net.normalizedBase(settings.baseURL)
        let path: String
        switch settings.engine.kind {
        case .openAICompatible: path = "/models"
        case .deepgram: path = "/v1/auth/token"
        case .dashscope, .baidu:
            // No free metadata endpoint: any HTTP answer (even 401/404) proves the host is up,
            // and the real test is the first transcription.
            return await hostAnswers(base)
        case .sherpa: return false
        }
        guard let url = URL(string: base + path) else { return false }
        var req = URLRequest(url: url)
        req.timeoutInterval = 8
        if !settings.apiKey.isEmpty {
            req.setValue(settings.engine.kind == .deepgram ? "Token \(settings.apiKey)" : "Bearer \(settings.apiKey)",
                         forHTTPHeaderField: "Authorization")
        }
        do {
            let (_, resp) = try await URLSession.shared.data(for: req)
            return (resp as? HTTPURLResponse)?.statusCode == 200
        } catch {
            return false
        }
    }

    // MARK: OpenAI-compatible multipart upload

    private static func upload(wav: Data, settings: ASRSettings) async throws -> String {
        let base = Net.normalizedBase(settings.baseURL)
        guard let url = URL(string: base + "/audio/transcriptions") else {
            throw Failure(message: T(.errBadURL))
        }
        var fields = ["model": settings.model, "response_format": "json"]
        if !settings.language.isEmpty { fields["language"] = settings.language }

        let boundary = "vox-" + UUID().uuidString
        let body = multipart(boundary: boundary, fields: fields,
                             fileField: "file", filename: "take.wav",
                             mime: "audio/wav", fileData: wav)

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        if !settings.apiKey.isEmpty {
            req.setValue("Bearer \(settings.apiKey)", forHTTPHeaderField: "Authorization")
        }
        req.httpBody = body

        let (data, resp) = try await send(req, host: url.host ?? "")
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let text = obj["text"] as? String else {
            throw Failure(message: TF(.errASRFailed, snippet(data)))
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { throw Failure(message: T(.errEmptyTranscript)) }
        return trimmed
    }

    // MARK: Deepgram

    private static func deepgram(wav: Data, settings: ASRSettings) async throws -> String {
        let base = Net.normalizedBase(settings.baseURL)
        var comps = URLComponents(string: base + "/v1/listen")
        var items = [URLQueryItem(name: "model", value: settings.model),
                     URLQueryItem(name: "smart_format", value: "true"),
                     URLQueryItem(name: "punctuate", value: "true")]
        if !settings.language.isEmpty { items.append(URLQueryItem(name: "language", value: settings.language)) }
        comps?.queryItems = items
        guard let url = comps?.url else { throw Failure(message: T(.errBadURL)) }

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("audio/wav", forHTTPHeaderField: "Content-Type")
        if !settings.apiKey.isEmpty {
            req.setValue("Token \(settings.apiKey)", forHTTPHeaderField: "Authorization")
        }
        req.httpBody = wav

        let (data, resp) = try await send(req, host: url.host ?? "")
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let results = obj["results"] as? [String: Any],
              let channels = results["channels"] as? [[String: Any]],
              let first = channels.first,
              let alts = first["alternatives"] as? [[String: Any]],
              let transcript = alts.first?["transcript"] as? String else {
            throw Failure(message: TF(.errASRFailed, snippet(data)))
        }
        let trimmed = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { throw Failure(message: T(.errEmptyTranscript)) }
        return trimmed
    }

    // MARK: Aliyun Bailian (Qwen-ASR, OpenAI-compatible chat with an audio part)

    /// DashScope exposes Qwen-ASR through the *chat* endpoint, not /audio/transcriptions: the
    /// audio travels as a base64 `input_audio` part and the transcript comes back as message
    /// content.
    private static func dashscope(wav: Data, settings: ASRSettings) async throws -> String {
        let base = Net.normalizedBase(settings.baseURL)
        guard let url = URL(string: base + "/chat/completions") else {
            throw Failure(message: T(.errBadURL))
        }
        let audioURL = "data:audio/wav;base64," + wav.base64EncodedString()
        var body: [String: Any] = [
            "model": settings.model,
            "messages": [[
                "role": "user",
                "content": [["type": "input_audio", "input_audio": ["data": audioURL]]],
            ]],
            "stream": false,
        ]
        if !settings.language.isEmpty { body["asr_options"] = ["language": settings.language] }

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if !settings.apiKey.isEmpty {
            req.setValue("Bearer \(settings.apiKey)", forHTTPHeaderField: "Authorization")
        }
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, _) = try await send(req, host: url.host ?? "")
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = obj["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any],
              let text = message["content"] as? String else {
            throw Failure(message: TF(.errASRFailed, snippet(data)))
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { throw Failure(message: T(.errEmptyTranscript)) }
        return trimmed
    }

    // MARK: Baidu (short speech recognition, Bearer API key)

    /// Baidu takes JSON with base64 audio, authenticates with a plain Bearer key (the older
    /// access_token flow is also accepted, but the header is simpler), and answers
    /// `{"err_no": 0, "result": ["..."]}`. The `model` field carries Baidu's dev_pid.
    private static func baidu(wav: Data, settings: ASRSettings) async throws -> String {
        let base = Net.normalizedBase(settings.baseURL)
        guard let url = URL(string: base + "/server_api") else {
            throw Failure(message: T(.errBadURL))
        }
        let body: [String: Any] = [
            "format": "wav",
            "rate": 16_000,
            "channel": 1,
            "cuid": "vox-dictation",
            "dev_pid": Int(settings.model) ?? 1537,
            "speech": wav.base64EncodedString(),
            "len": wav.count,
        ]
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if !settings.apiKey.isEmpty {
            req.setValue("Bearer \(settings.apiKey)", forHTTPHeaderField: "Authorization")
        }
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, _) = try await send(req, host: url.host ?? "")
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw Failure(message: TF(.errASRFailed, snippet(data)))
        }
        let errNo = (obj["err_no"] as? Int) ?? -1
        guard errNo == 0, let pieces = obj["result"] as? [String] else {
            let message = (obj["err_msg"] as? String) ?? snippet(data)
            throw Failure(message: TF(.errASRFailed, message))
        }
        let text = pieces.joined().trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty { throw Failure(message: T(.errEmptyTranscript)) }
        return text
    }

    // MARK: Plumbing

    private static func send(_ req: URLRequest, host: String) async throws -> (Data, HTTPURLResponse) {
        let session = Net.session(timeout: 60, host: host)
        do {
            let (data, resp) = try await session.data(for: req)
            guard let http = resp as? HTTPURLResponse else { throw Failure(message: T(.errNoResponse)) }
            guard http.statusCode == 200 else {
                throw Failure(message: TF(.errASRFailed, "HTTP \(http.statusCode) \(snippet(data))"))
            }
            return (data, http)
        } catch let error as Failure {
            throw error
        } catch {
            throw Failure(message: TF(.errASRFailed, error.localizedDescription))
        }
    }

    /// Any HTTP status proves the host is reachable; a transport error means it is not.
    private static func hostAnswers(_ base: String) async -> Bool {
        guard let url = URL(string: base) else { return false }
        var req = URLRequest(url: url)
        req.timeoutInterval = 8
        let session = Net.session(timeout: 8, host: url.host ?? "")
        do {
            _ = try await session.data(for: req)
            return true
        } catch {
            return false
        }
    }

    private static func snippet(_ data: Data) -> String {
        let raw = String(data: data, encoding: .utf8) ?? ""
        return raw.prefix(160).description
    }

    private static func multipart(boundary: String,
                                  fields: [String: String],
                                  fileField: String,
                                  filename: String,
                                  mime: String,
                                  fileData: Data) -> Data {
        var body = Data()
        for (key, value) in fields {
            body.append("--\(boundary)\r\n")
            body.append("Content-Disposition: form-data; name=\"\(key)\"\r\n\r\n")
            body.append("\(value)\r\n")
        }
        body.append("--\(boundary)\r\n")
        body.append("Content-Disposition: form-data; name=\"\(fileField)\"; filename=\"\(filename)\"\r\n")
        body.append("Content-Type: \(mime)\r\n\r\n")
        body.append(fileData)
        body.append("\r\n--\(boundary)--\r\n")
        return body
    }

    /// Wrap 16 kHz mono Float32 samples in a 16-bit PCM WAV container — every vendor accepts
    /// wav, and 16-bit halves the upload compared with float.
    static func wav(fromFloat32 pcm: Data) -> Data {
        let count = pcm.count / MemoryLayout<Float>.size
        var samples = Data(capacity: count * MemoryLayout<Int16>.size)
        pcm.withUnsafeBytes { raw in
            let floats = raw.bindMemory(to: Float.self)
            for i in 0..<count {
                let clamped = max(-1, min(1, floats[i]))
                var sample = Int16(clamped * 32767).littleEndian
                withUnsafeBytes(of: &sample) { samples.append(contentsOf: $0) }
            }
        }
        let sampleRate: UInt32 = 16_000
        let channels: UInt16 = 1
        let bits: UInt16 = 16
        let byteRate = sampleRate * UInt32(channels) * UInt32(bits / 8)
        let blockAlign = channels * (bits / 8)

        var header = Data()
        header.append("RIFF")
        var chunkSize = UInt32(36 + samples.count).littleEndian
        withUnsafeBytes(of: &chunkSize) { header.append(contentsOf: $0) }
        header.append("WAVEfmt ")
        var subchunk1 = UInt32(16).littleEndian
        withUnsafeBytes(of: &subchunk1) { header.append(contentsOf: $0) }
        var audioFormat = UInt16(1).littleEndian
        withUnsafeBytes(of: &audioFormat) { header.append(contentsOf: $0) }
        var ch = channels.littleEndian
        withUnsafeBytes(of: &ch) { header.append(contentsOf: $0) }
        var rate = sampleRate.littleEndian
        withUnsafeBytes(of: &rate) { header.append(contentsOf: $0) }
        var br = byteRate.littleEndian
        withUnsafeBytes(of: &br) { header.append(contentsOf: $0) }
        var ba = blockAlign.littleEndian
        withUnsafeBytes(of: &ba) { header.append(contentsOf: $0) }
        var bps = bits.littleEndian
        withUnsafeBytes(of: &bps) { header.append(contentsOf: $0) }
        header.append("data")
        var dataSize = UInt32(samples.count).littleEndian
        withUnsafeBytes(of: &dataSize) { header.append(contentsOf: $0) }
        header.append(samples)
        return header
    }
}

private extension Data {
    mutating func append(_ string: String) {
        if let d = string.data(using: .utf8) { append(d) }
    }
}
