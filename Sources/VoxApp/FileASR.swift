import Foundation

/// Offline final transcript: send one whole take of 16k mono Float32 PCM to the
/// sherpa-onnx offline websocket server on the server machine (SenseVoice model,
/// ws://host:6007 by default).
///
/// Why it exists: the streaming paraformer never decodes its last chunk when no audio
/// follows it, so the tail word is frequently lost. The offline model sees the whole take
/// and does not have to guess; the same sentence that dropped "去" while streaming comes
/// back complete here, in 0.2-0.4s (the model stays resident on the server).
///
/// Protocol (sherpa offline ws server):
///   1. first frame = int32(sample rate) + int32(total bytes) + first samples, all little endian
///   2. following frames = the remaining samples
///   3. once the total byte count is reached the server replies with one JSON object (with `text`)
///   4. the client sends the text "Done" to close the session
enum FileASR {

    static let port = 6007

    struct Result: Decodable { let text: String }

    /// Returns the final transcript; nil when the service is unreachable, times out or returns
    /// nothing — the caller then falls back to the streaming result.
    static func transcribe(pcm: Data, host: String, timeout: TimeInterval = 3) async -> String? {
        guard pcm.count >= 3_200 else { return nil }          // less than 100ms is pointless
        guard let url = URL(string: "ws://\(host):\(port)") else { return nil }

        let cfg = URLSessionConfiguration.ephemeral
        cfg.connectionProxyDictionary = [:]                  // direct LAN connection, bypass the system proxy
        cfg.timeoutIntervalForRequest = timeout
        let session = URLSession(configuration: cfg)
        defer { session.invalidateAndCancel() }

        let task = session.webSocketTask(with: url)
        task.resume()
        defer { task.cancel(with: .normalClosure, reason: nil) }

        // First frame carries the header
        var header = Data()
        var rate = Int32(16_000).littleEndian
        var total = Int32(pcm.count).littleEndian
        withUnsafeBytes(of: &rate) { header.append(contentsOf: $0) }
        withUnsafeBytes(of: &total) { header.append(contentsOf: $0) }
        let firstChunk = pcm.prefix(64_000 * 4)              // at most one second
        do {
            try await task.send(.data(header + firstChunk))
            var offset = firstChunk.count
            while offset < pcm.count {
                let end = min(offset + 64_000 * 4, pcm.count)
                try await task.send(.data(pcm.subdata(in: offset..<end)))
                offset = end
            }
        } catch {
            return nil
        }

        // Wait for the single JSON reply
        let text: String? = await withTaskGroup(of: String?.self) { group in
            group.addTask {
                do {
                    let msg = try await task.receive()
                    switch msg {
                    case .string(let s): return parse(s)
                    case .data(let d): return parse(String(data: d, encoding: .utf8) ?? "")
                    @unknown default: return nil
                    }
                } catch {
                    return nil
                }
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }

        try? await task.send(.string("Done"))
        let cleaned = (text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? nil : cleaned
    }

    private static func parse(_ raw: String) -> String? {
        guard let d = raw.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
              let text = obj["text"] as? String else { return nil }
        return text
    }
}
