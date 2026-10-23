import Foundation
import AVFoundation

/// Streaming ASR client: 16 kHz mono Float32 audio goes over a WebSocket to the
/// sherpa service on the server, which answers {text, is_final}. Same protocol as
/// the web version.
///
/// It only reports what one take said: partials travel through `liveText`, the whole
/// recording is handed to `onFinal` on release. The instruction list lives in AppModel
/// (one entry per release).
/// The audio callback runs on a realtime thread and must not read @MainActor state,
/// hence a lock-protected switch.
final class CaptureGate: @unchecked Sendable {
    private let lock = NSLock()
    private var on = false
    var isOn: Bool {
        lock.lock(); defer { lock.unlock() }
        return on
    }
    func set(_ v: Bool) {
        lock.lock(); on = v; lock.unlock()
    }
}

@MainActor
final class ASR: ObservableObject {

    @Published private(set) var running = false
    /// Still waiting for the server's last segment after release (the green text stays visible meanwhile).
    @Published private(set) var finishing = false
    @Published private(set) var authorized = false
    @Published private(set) var connected = false
    /// Live transcript while recording (the green line in the left pane).
    @Published private(set) var liveText = ""
    /// Connection / device errors; the normal flow never shows them.
    @Published private(set) var errorText: String?

    /// Whole transcript of the take, delivered on stop.
    var onFinal: ((String) -> Void)?

    private let mic = MicCapture()
    private var ws: URLSessionWebSocketTask?
    private var session: URLSession?
    private var finals: [String] = []
    private var partial = ""

    private var host = "192.168.1.101"
    private var port = 6006
    /// Buffer audio until the socket finishes its handshake, otherwise the first words are lost.
    private var pending: [Data] = []
    private let gate = CaptureGate()
    /// Capture generation: the tail window after release may only close the capture it belongs to,
    /// so pressing start right after releasing is not killed by the previous deferred close.
    private var captureGen = 0
    /// Whole take as 16 kHz Float32 PCM, handed to the offline model for the final transcript.
    private var captureBuffer = Data()
    /// Cap at 60s so an abnormal state cannot grow without bound.
    private let captureLimit = 16_000 * 4 * 60

    // MARK: Configuration

    /// ASR runs on the same server as the model, so the host comes from the model endpoint.
    func configure(baseURL: String) {
        if let u = URL(string: baseURL), let h = u.host { host = h }
    }

    var endpoint: String { "ws://\(host):\(port)" }

    // MARK: Permission

    func requestPermission() async -> Bool {
        let mic = await AVCaptureDevice.requestAccess(for: .audio)
        authorized = mic
        if !mic { errorText = T(.errNoMicPermission) }
        return mic
    }

    // MARK: Reachability (drives the status dot)

    func probe() async -> Bool {
        guard let url = URL(string: endpoint) else { return false }
        let cfg = URLSessionConfiguration.ephemeral
        cfg.connectionProxyDictionary = [:]
        let s = URLSession(configuration: cfg)
        let t = s.webSocketTask(with: url)
        t.resume()
        defer { t.cancel(with: .goingAway, reason: nil); s.invalidateAndCancel() }
        // The sherpa server only answers once it gets audio, so `receive` cannot prove
        // liveness; a handshake that leaves the task in `.running` is enough.
        try? await Task.sleep(nanoseconds: 600_000_000)
        return t.state == .running
    }

    // MARK: Connection (pre-warmed: the handshake happens before the first press)

    func warmConnection() {
        guard ws == nil || ws?.state == .completed || ws?.state == .canceling else { return }
        guard let url = URL(string: endpoint) else { return }
        let cfg = URLSessionConfiguration.ephemeral
        cfg.connectionProxyDictionary = [:]      // direct LAN connection, bypass the system proxy
        let s = URLSession(configuration: cfg)
        session = s
        let task = s.webSocketTask(with: url)
        ws = task
        task.resume()
        listen(task)
    }

    // MARK: Microphone (opened on demand: the system recording dot only shows while recording)

    /// The main thread only issues one command here: device setup (inputNode / installTap /
    /// prepare / start) all runs on MicCapture's serial queue, so pressing "Dictate" never
    /// stalls — including the very first press after launch.
    func prepareEngine() {
        mic.start(
            gate: gate,
            onPCM: { [weak self] data in
                Task { @MainActor in self?.send(data) }
            },
            onError: { [weak self] message in
                Task { @MainActor in self?.fail(message) }
            }
        )
    }

    /// Close the audio device right after release: the recording dot belongs to recording only.
    /// The next take calls `prepareEngine()` again, which builds a fresh engine.
    func releaseEngine() {
        gate.set(false)
        mic.stop()
    }

    // MARK: Recording

    func start() {
        guard !running else { return }
        running = true              // light the button first; everything below is cheap
        finals.removeAll()
        pending.removeAll()
        partial = ""
        liveText = ""
        errorText = nil

        warmConnection()            // usually already warm, this is a no-op
        prepareEngine()             // normally ready; make sure anyway
        captureGen += 1
        captureBuffer.removeAll()
        gate.set(true)              // from here on audio goes to the server
    }

    func stop() {
        guard running else { return }
        running = false
        finishing = true            // finishing: keep the green text on screen instead of blinking it away
        captureGen += 1
        let gen = captureGen

        let sock = ws
        Task { [weak self] in
            // Layer one: at the moment of release the tail of the last word is still in the
            // capture callback (one or two buffers in flight on the realtime thread, ~50-150ms).
            // Closing the capture right away cuts that weakest half syllable off, which sounds
            // like "the last word never appears". Keep a 250ms window first.
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard let self else { return }
            if self.captureGen == gen { self.gate.set(false) }
            // Close the device immediately: the final transcript only needs the PCM captured so far,
            // the recording dot should not wait for the result.
            self.releaseEngine()

            let pcm = self.captureBuffer
            self.captureBuffer.removeAll()

            // Layer two: offline final transcript (SenseVoice on the server). It sees the whole
            // take, so the tail is not guessed; typically 0.2-0.4s. Returns nil when unavailable
            // or timed out, and we fall back to the streaming plus tail-silence path.
            var final: String? = nil
            if !pcm.isEmpty {
                final = await FileASR.transcribe(pcm: pcm, host: self.host)
            }

            if final == nil {
                // Fallback: the streaming paraformer decodes fixed chunks. Once audio stops, the
                // last partial chunk never decodes — pad 1.2s of silence to fill it.
                await self.flushTailSilence(seconds: 1.2)
                try? await Task.sleep(nanoseconds: 700_000_000)
            }

            sock?.cancel(with: .normalClosure, reason: nil)
            self.stopSocket()
            let text = final ?? self.finalizeText()   // liveText is not cleared here
            self.warmConnection()                      // handshake ahead of the next press
            self.onFinal?(text)                        // synchronous: the instruction enters the list first
            self.liveText = ""                         // then clear the green text, one view update, no gap
            self.finishing = false
        }
    }

    func cancel() {
        guard running else { return }
        running = false
        releaseEngine()
        stopSocket()
        partial = ""
        liveText = ""
        finals.removeAll()
        finishing = false
    }

    // MARK: Internals

    private func fail(_ msg: String) {
        errorText = msg
        running = false
    }

    private func listen(_ task: URLSessionWebSocketTask) {
        task.receive { [weak self] result in
            Task { @MainActor in
                guard let self else { return }
                switch result {
                case .failure(let err):
                    self.connected = false
                    if self.running { self.errorText = TF(.errDisconnected, err.localizedDescription) }
                case .success(let msg):
                    self.connected = true
                    switch msg {
                    case .string(let s): self.absorb(s)
                    case .data(let d): self.absorb(String(data: d, encoding: .utf8) ?? "")
                    @unknown default: break
                    }
                    if let ws = self.ws { self.listen(ws) }
                }
            }
        }
    }

    /// Pad silence after release to fill the last chunk (pushed fast, not in real time)
    private func flushTailSilence(seconds: Double) async {
        guard let ws, ws.state == .running else { return }
        let chunk = 1_600                                  // 100ms @16k
        let zeros = [Float](repeating: 0, count: chunk)
        let perChunk = zeros.withUnsafeBufferPointer {
            Data(bytes: $0.baseAddress!, count: chunk * MemoryLayout<Float>.size)
        }
        var sent = 0
        let total = Int(seconds * 16_000)
        while sent < total {
            ws.send(.data(perChunk)) { _ in }
            sent += chunk
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    private func send(_ data: Data) {
        guard let ws, ws.state == .running else {
            pending.append(data)
            if pending.count > 300 { pending.removeFirst(pending.count - 300) }   // at most ~3s
            return
        }
        connected = true
        if running, captureBuffer.count < captureLimit { captureBuffer.append(data) }
        if !pending.isEmpty {
            for d in pending { ws.send(.data(d)) { _ in } }
            pending.removeAll()
        }
        ws.send(.data(data)) { _ in }
    }

    private func absorb(_ raw: String) {
        guard let d = raw.data(using: .utf8),
              let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return }
        let text = (j["text"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        if (j["is_final"] as? Bool) ?? false {
            finals.append(text)
            partial = ""
            liveText = finals.joined()
        } else {
            partial = text
            liveText = finals.joined() + text
        }
    }

    private func finalizeText() -> String {
        connected = false
        var joined = (finals.joined() + partial).trimmingCharacters(in: .whitespacesAndNewlines)
        partial = ""
        // Too much padding makes the server decode the same audio twice ("XXYY"): if both
        // halves are identical, keep one.
        if joined.count % 2 == 0 {
            let half = joined.count / 2
            let a = String(joined.prefix(half)), b = String(joined.suffix(half))
            if a == b { joined = a }
        }
        return joined
    }

    private func stopSocket() {
        ws?.cancel(with: .normalClosure, reason: nil)
        ws = nil
        session?.invalidateAndCancel()
        session = nil
        connected = false
    }

    /// Local verification helper: does the left pane refresh while the transcript changes?
    func _debugLive(_ text: String) {
        liveText = text
    }

    /// Local verification helper: does the green text survive the tail window? Mimics stop()'s timing.
    func _debugSimulateFinish(_ text: String, then seconds: Double = 1.2) {
        finishing = true
        liveText = text
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            guard let self else { return }
            self.onFinal?(text)
            self.liveText = ""
            self.finishing = false
        }
    }
}
