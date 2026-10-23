import Foundation
import AVFoundation

/// Microphone capture: every AVAudioEngine call runs on its own serial queue.
///
/// Why it is a separate type: the first access to `engine.inputNode`, `installTap`,
/// `engine.prepare()` and `engine.start()` each cost hundreds of milliseconds the first
/// time (opening the device, building the graph, registering with the HAL). On the main
/// thread any of them freezes the "Dictate" press — that is where "the first press after
/// launch stutters" came from. Now the main thread only issues a command and everything
/// else happens on the `vox.audio.mic` queue.
///
/// A fresh AVAudioEngine is built for every take: the device is closed between recordings
/// (the system microphone dot only shows while recording), and a new instance is cleaner
/// than reusing one that was stopped.
final class MicCapture: @unchecked Sendable {

    private static let outFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false
    )!

    private let queue = DispatchQueue(label: "vox.audio.mic", qos: .userInitiated)
    private var engine: AVAudioEngine?
    private var converter: AVAudioConverter?
    private var active = false

    /// Start capturing. Idempotent: returns immediately when already capturing or starting.
    /// - Parameters:
    ///   - gate: lock-protected capture switch (checked on every realtime frame)
    ///   - onPCM: raw bytes of 16k mono Float32, called off the main thread
    ///   - onError: device error text, called off the main thread
    func start(gate: CaptureGate,
               onPCM: @escaping (Data) -> Void,
               onError: @escaping (String) -> Void) {
        queue.async { [self] in
            guard !active else { return }
            guard let engineRef = makeEngine(gate: gate, onPCM: onPCM, onError: onError) else { return }
            do {
                try engineRef.start()
                active = true
            } catch {
                engineRef.inputNode.removeTap(onBus: 0)
                engineRef.stop()
                engine = nil
                converter = nil
                onError(TF(.errMicStart, error.localizedDescription))
            }
        }
    }

    /// Stop capturing and close the device (the system dot goes out with it).
    func stop() {
        queue.async { [self] in
            guard active, let engine else { return }
            engine.stop()
            engine.inputNode.removeTap(onBus: 0)
            self.engine = nil
            self.converter = nil
            self.active = false
        }
    }

    // MARK: Internals (all on `queue`)

    private func makeEngine(gate: CaptureGate,
                            onPCM: @escaping (Data) -> Void,
                            onError: @escaping (String) -> Void) -> AVAudioEngine? {
        let engine = AVAudioEngine()
        let input = engine.inputNode
        let inFormat = input.outputFormat(forBus: 0)
        guard inFormat.channelCount > 0, inFormat.sampleRate > 0 else {
            onError(T(.errNoMicInput))
            return nil
        }
        guard let conv = AVAudioConverter(from: inFormat, to: Self.outFormat) else {
            onError(T(.errConverterInit))
            return nil
        }
        converter = conv
        let out = Self.outFormat

        input.installTap(onBus: 0, bufferSize: 2048, format: inFormat) { [weak self] buffer, _ in
            guard gate.isOn, let self else { return }          // not recording: drop it before converting
            guard let pcm = self.resample(buffer, to: out) else { return }
            let n = Int(pcm.frameLength)
            guard n > 0, let ch = pcm.floatChannelData?[0] else { return }
            onPCM(Data(bytes: ch, count: n * MemoryLayout<Float>.size))
        }

        engine.prepare()
        self.engine = engine
        return engine
    }

    /// Hardware sample rate -> 16k mono Float32
    private func resample(_ buffer: AVAudioPCMBuffer, to out: AVAudioFormat) -> AVAudioPCMBuffer? {
        guard let conv = converter else { return nil }
        let ratio = out.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 64
        guard let outBuf = AVAudioPCMBuffer(pcmFormat: out, frameCapacity: capacity) else { return nil }
        var provided = false
        var error: NSError?
        let status = conv.convert(to: outBuf, error: &error) { _, outStatus in
            if provided { outStatus.pointee = .noDataNow; return nil }
            provided = true
            outStatus.pointee = .haveData
            return buffer
        }
        if status == .error || outBuf.frameLength == 0 { return nil }
        return outBuf
    }
}
