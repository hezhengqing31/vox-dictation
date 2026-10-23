import Foundation
import AVFoundation

/// Headless ASR self-test: pushes a 16k mono wav to the sherpa WS on the server in 100ms
/// slices and prints what comes back. Verifies the protocol without a microphone.
enum ASRSelfTest {

    private final class Collector: @unchecked Sendable {
        private let lock = NSLock()
        private var finals: [String] = []
        private var partials: [String] = []
        private var raw: [String] = []
        private var timeline: [(Double, String)] = []
        private let t0 = Date()

        func add(_ msg: String) {
            lock.lock(); defer { lock.unlock() }
            raw.append(msg)
            timeline.append((Date().timeIntervalSince(t0), msg))
            guard let d = msg.data(using: .utf8),
                  let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return }
            let text = (j["text"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return }
            if (j["is_final"] as? Bool) ?? false { finals.append(text) } else { partials.append(text) }
        }

        var snapshot: (finals: [String], partials: [String], raw: [String]) {
            lock.lock(); defer { lock.unlock() }
            return (finals, partials, raw)
        }

        var timelineSnapshot: [(Double, String)] {
            lock.lock(); defer { lock.unlock() }
            return timeline
        }
    }

    /// Verify the offline transcript path (the protocol FileASR uses in the app)
    static func runFileAndExit(wav: String, host: String) -> Never {
        let sem = DispatchSemaphore(value: 0)
        Task.detached {
            do {
                let file = try AVAudioFile(forReading: URL(fileURLWithPath: wav))
                let fmt = file.processingFormat
                guard fmt.sampleRate == 16_000, fmt.channelCount == 1 else {
                    print("error: a 16k mono wav is required"); sem.signal(); exit(1)
                }
                guard let buf = AVAudioPCMBuffer(pcmFormat: fmt,
                                                 frameCapacity: AVAudioFrameCount(file.length)) else {
                    print("error: buffer"); sem.signal(); exit(1)
                }
                try file.read(into: buf)
                guard let ch = buf.floatChannelData?[0] else { print("error: no data"); sem.signal(); exit(1) }
                let n = Int(buf.frameLength)
                let pcm = Data(bytes: ch, count: n * MemoryLayout<Float>.size)
                let t0 = Date()
                let text = await FileASR.transcribe(pcm: pcm, host: host) ?? "<nil — falling back to streaming>"
                print(String(format: "fileasr %.2fs → %@", Date().timeIntervalSince(t0), text))
            } catch {
                print("error: \(error.localizedDescription)")
            }
            sem.signal()
            exit(0)
        }
        sem.wait()
        exit(0)
    }

    static func runAndExit(wav: String, host: String, port: Int, pad: Double = 1.2,
                           live: Bool = false) -> Never {
        let sem = DispatchSemaphore(value: 0)
        var code: Int32 = 1

        Task.detached {
            let collector = Collector()
            do {
                let file = try AVAudioFile(forReading: URL(fileURLWithPath: wav))
                let fmt = file.processingFormat
                print("wav: \(fmt.sampleRate)Hz \(fmt.channelCount)ch \(file.length) frames")
                guard fmt.sampleRate == 16_000, fmt.channelCount == 1 else {
                    print("error: a 16k mono wav is required")
                    sem.signal(); return
                }
                guard let buf = AVAudioPCMBuffer(pcmFormat: fmt,
                                                 frameCapacity: AVAudioFrameCount(file.length)) else {
                    print("error: buffer"); sem.signal(); return
                }
                try file.read(into: buf)
                guard let ch = buf.floatChannelData?[0] else { print("error: no float data"); sem.signal(); return }

                let cfg = URLSessionConfiguration.ephemeral
                cfg.connectionProxyDictionary = [:]
                let session = URLSession(configuration: cfg)
                guard let url = URL(string: "ws://\(host):\(port)") else { sem.signal(); return }
                let task = session.webSocketTask(with: url)
                task.resume()
                print("ws: \(url.absoluteString)")
                try await Task.sleep(nanoseconds: 400_000_000)

                let reader = Task.detached {
                    while !Task.isCancelled {
                        do {
                            let msg = try await task.receive()
                            switch msg {
                            case .string(let s): collector.add(s)
                            case .data(let d): collector.add(String(data: d, encoding: .utf8) ?? "")
                            @unknown default: break
                            }
                        } catch { break }
                    }
                }

                let total = Int(buf.frameLength)
                // live mode uses the microphone path's 682-frame slices (2048@48k resampled to 16k ≈ 43ms)
                let chunk = live ? 682 : 1_600
                var sent = 0
                let started = Date()
                while sent < total {
                    let len = min(chunk, total - sent)
                    let data = Data(bytes: ch.advanced(by: sent), count: len * MemoryLayout<Float>.size)
                    try await task.send(.data(data))
                    sent += len
                    try await Task.sleep(nanoseconds: live ? 43_000_000 : 100_000_000)
                }
                let audioSeconds = Date().timeIntervalSince(started)
                if live { try await Task.sleep(nanoseconds: 250_000_000) }   // tail window

                // After release, pad silence to fill the last partial chunk (pad=0 pads nothing, for comparison)
                let padTotal = Int(16_000 * pad)
                let zeros = [Float](repeating: 0, count: chunk)
                var padded = 0
                while padded < padTotal {
                    let len = min(chunk, padTotal - padded)
                    let data = zeros.withUnsafeBufferPointer { Data(bytes: $0.baseAddress!, count: len * MemoryLayout<Float>.size) }
                    try? await task.send(.data(data))
                    padded += len
                    try await Task.sleep(nanoseconds: 20_000_000)   // push the silence fast, not in real time
                }
                print("padded silence: \(Double(padTotal) / 16_000)s (fast)")

                try await Task.sleep(nanoseconds: live ? 700_000_000 : 900_000_000)
                reader.cancel()
                task.cancel(with: .normalClosure, reason: nil)
                session.invalidateAndCancel()

                for (t, m) in collector.timelineSnapshot {
                    let short = m.count > 90 ? String(m.prefix(90)) + "…" : m
                    print(String(format: "  +%.2fs  %@", t, short))
                }
                let snap = collector.snapshot
                print(String(format: "sent %.1fs of audio, received %d messages", audioSeconds, snap.raw.count))
                print("finals: \(snap.finals)")
                print("partials: \(snap.partials.count), last: \(snap.partials.last ?? "-")")
                let text = (snap.finals.joined() + (snap.partials.last ?? ""))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                print("joined: \(text)")
                code = text.isEmpty ? 1 : 0
            } catch {
                print("error: \(error.localizedDescription)")
            }
            sem.signal()
        }

        sem.wait()
        exit(code)
    }
}
