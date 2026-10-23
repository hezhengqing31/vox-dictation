import Foundation
import SwiftUI
import AppKit
import Combine

@MainActor
final class AppModel: ObservableObject {

    enum OutputKind { case none, voice, tidy }

    // Text
    @Published var input = ""
    @Published var output = ""
    @Published var outputKind: OutputKind = .none
    @Published var outputSeconds: Double = 0

    // State
    @Published var busy = false
    /// Voice instructions collected since the last run, not sent yet (one per take).
    @Published var instructions: [String] = []
    /// Instructions that already ran (kept as history, never sent again).
    @Published var applied: [AppliedItem] = []

    struct AppliedItem: Identifiable, Hashable {
        let id = UUID()
        let text: String
        let isTidy: Bool      // true = append, false = revise
    }
    /// Output, instructions and history all empty (drives the "Clear All" disabled state).
    var isAllEmpty: Bool { output.isEmpty && instructions.isEmpty && applied.isEmpty }

    @Published var llmOK: Bool? = nil
    /// Model status line: running > not checked yet (connecting) > ready / offline.
    var llmStatusText: String {
        if busy && !pill.isEmpty { return pill }
        if llmOK == nil { return T(.stConnecting) }
        return llmOK! ? T(.stReady) : T(.stOffline)
    }

    var llmStatusColor: SwiftUI.Color {   // read directly by the view, no re-checking there
        if busy && !pill.isEmpty { return Theme.sAccent }
        if llmOK == nil { return Theme.sDim2 }
        return llmOK! ? Theme.sDim2 : Theme.sFire
    }
    @Published var asrAuthorized: Bool? = nil
    @Published var asrOnline: Bool? = nil
    /// ASR status line: recording wins over connection state.
    var asrStatusText: String {
        if asr.running { return T(.stListening) }
        if asr.finishing { return T(.stFinishing) }
        if asrOnline == nil { return T(.stConnecting) }
        return asrOnline! ? T(.stReady) : T(.stOffline)
    }

    var asrStatusColor: SwiftUI.Color {
        if asr.running { return Theme.sAccent }
        if asr.finishing { return Theme.sAccent }
        if asrOnline == nil { return Theme.sDim2 }      // connecting: grey text
        return asrOnline! ? Theme.sDim2 : Theme.sFire
    }
    @Published var pill = ""
    @Published var showSettings = false
    /// Skip the confirmation dialog before clearing (can be turned back on in Settings).
    @Published var clearNoAsk: Bool {
        didSet { UserDefaults.standard.set(clearNoAsk, forKey: "vox.clearNoAsk") }
    }
    /// UI language; changing it retranslates every view that observes this model.
    @Published var uiLanguage: UILanguage {
        didSet {
            UserDefaults.standard.set(uiLanguage.rawValue, forKey: "vox.language")
            L10n.shared.apply(uiLanguage)
        }
    }
    @Published var toast: String? = nil

    // Settings
    @Published var baseURLString: String {
        didSet {
            UserDefaults.standard.set(baseURLString, forKey: "vox.baseURL")
            asr.configure(baseURL: baseURLString)
        }
    }

    let asr = ASR()
    let inputHandle = EditorHandle()
    let outputHandle = EditorHandle()

    private var bag = Set<AnyCancellable>()
    private var toastTask: Task<Void, Never>? = nil


    init() {
        // Talk to the backend on :5000 directly to dodge the 30s Next proxy timeout
        // (the first request after a cold start can take 25s+).
        let stored = UserDefaults.standard.string(forKey: "vox.baseURL")
        baseURLString = (stored == nil || stored == "http://192.168.1.101:3000")
            ? "http://192.168.1.101:5000"
            : stored!
        clearNoAsk = UserDefaults.standard.bool(forKey: "vox.clearNoAsk")

        let storedLanguage = UserDefaults.standard.string(forKey: "vox.language")
        uiLanguage = UILanguage(rawValue: storedLanguage ?? "") ?? .system
        L10n.shared.apply(uiLanguage)

        asr.onFinal = { [weak self] text in
            self?.handleVoiceFinal(text)      // synchronous: lands in the same frame that clears the live text
        }
        // ASR is its own ObservableObject; nested changes never reach the parent view,
        // so forward them explicitly.
        asr.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &bag)
    }

    var client: LLMClient {
        LLMClient(baseURL: URL(string: baseURLString) ?? URL(string: "http://127.0.0.1:3000")!)
    }

    var hasOutput: Bool { !output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    // MARK: Bootstrap

    func bootstrap() async {
        asr.configure(baseURL: baseURLString)
        asr.warmConnection()               // shake hands early so the first press does not wait for the TCP setup
        // Light the status dots first: the permission dialog can block for a long time and must not drag them down.
        Task { await self.refreshHealth() }
        asrAuthorized = await asr.requestPermission()
        // Do not open the microphone up front: the system recording dot should only
        // show between pressing "Dictate" and releasing. The device is closed in
        // ASR.releaseEngine().
        await refreshHealth()
    }

    func refreshHealth() async {
        asr.configure(baseURL: baseURLString)
        let ok = await client.health()
        // Only write on an actual change: assigning the same value to @Published still
        // invalidates the view, and doing that every 20s drags the focused editor into
        // an update loop.
        if llmOK != ok { llmOK = ok }
        let online = await asr.probe()
        if asrOnline != online { asrOnline = online }
    }

    /// Refresh the status dots every 20s (recovers after a network drop or service restart).
    func startHealthTicker() {
        healthTicker?.cancel()
        healthTicker = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 20_000_000_000)
                guard let self, !self.busy, !self.asr.running else { continue }
                await self.refreshHealth()
            }
        }
    }

    private var healthTicker: Task<Void, Never>? = nil

    // MARK: Voice

    func startRecording() {
        guard !busy else { return }
        if asrAuthorized != true {
            Task {
                let ok = await asr.requestPermission()
                asrAuthorized = ok
                toastNow(ok ? T(.toastMicGranted) : T(.toastMicDenied))
            }
            return
        }
        asr.prepareEngine()        // microphone on demand: the system dot lights here and dies on release
        asr.start()                // recording state lives in the ASR pane only, never in the model status line
    }

    func stopRecording() {
        guard asr.running else { return }
        let started = Date()
        asr.stop()
        _ = started
    }

    private func handleVoiceFinal(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        // Every stop is one instruction: push it into the list. Status stays in the ASR pane.
        instructions.append(trimmed)
    }

    func removeInstruction(at index: Int) {
        guard instructions.indices.contains(index) else { return }
        instructions.remove(at: index)
    }

    // MARK: AI append

    /// Requests only fire on a button press: target = whatever the output pane holds,
    /// instructions = the takes collected by voice.
    /// If recording is still running it is stopped first so the last take lands in the list.
    private func settleASR() async {
        guard asr.running else { return }
        stopRecording()
        var waited = 0
        while (asr.running || asr.finishing) && waited < 60 {
            try? await Task.sleep(nanoseconds: 100_000_000)
            waited += 1
        }
    }

    /// Whether Append/Revise may run: needs at least one collected instruction.
    /// Recording still counts — the click stops the recording first, then runs.
    var canSendToLLM: Bool {
        !busy && (!instructions.isEmpty || asr.running || asr.finishing)
    }

    /// "AI Append": fold the new content into the existing text (add only, never rewrite it).
    func tidy() async {
        await settleASR()
        let pending = instructions
        guard !pending.isEmpty else {
            toastNow(T(.toastNoNewContent))
            return
        }
        await runModify(content: output, instructions: pending, isTidy: true)
    }

    /// "AI Revise": apply the collected instructions to the existing text (rewrite / cut / reorder).
    func revise() async {
        await settleASR()
        let pending = instructions
        guard !pending.isEmpty else {
            toastNow(T(.toastNoNewContent))
            return
        }
        await runModify(content: output, instructions: pending, isTidy: false)
    }

    /// Call the writer endpoint: content + instructions -> result replaces the output pane;
    /// the instructions move from pending to history.
    private func runModify(content: String, instructions pending: [String], isTidy: Bool) async {
        guard !busy else { return }
        busy = true
        pill = isTidy ? T(.stAppending) : T(.stRevising)
        do {
            let (text, seconds) = try await client.modify(
                content: content, instructions: pending, mode: isTidy ? "tidy" : "modify")
            output = text
            outputKind = .tidy
            outputSeconds = seconds
            pill = T(.stReady)
            // The instructions ran: clear the pending list, keep them as history, never resend.
            applied.append(contentsOf: pending.map { AppliedItem(text: $0, isTidy: isTidy) })
            instructions.removeAll()
        } catch {
            pill = T(.stFailed)
            toastNow(TF(.toastModelUnavailable, error.localizedDescription))
        }
        busy = false
    }

    // MARK: Actions

    func copyOutput() {
        guard hasOutput else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(output, forType: .string)
        toastNow(T(.toastCopiedOutput))
    }

    /// Copy a single pending instruction (row button, left of the delete button).
    func copyInstruction(at index: Int) {
        guard instructions.indices.contains(index) else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(instructions[index], forType: .string)
        toastNow(T(.toastCopiedInstruction))
    }

    /// Clear everything: confirm in a modal first; skip it once "don't ask again" is on.
    func clearAll() {
        guard !input.isEmpty || !output.isEmpty || !instructions.isEmpty || !applied.isEmpty else {
            toastNow(T(.toastAlreadyEmpty)); return
        }
        if clearNoAsk { performClear(); return }

        let alert = NSAlert()
        alert.messageText = T(.alertTitle)
        alert.informativeText = T(.alertBody)
        alert.alertStyle = .warning
        alert.addButton(withTitle: T(.alertClear))
        alert.addButton(withTitle: T(.alertCancel))
        alert.showsSuppressionButton = true
        alert.suppressionButton?.title = T(.alertDontAsk)
        let response = alert.runModal()
        if alert.suppressionButton?.state == .on {
            clearNoAsk = true
        }
        if response == .alertFirstButtonReturn { performClear() }
    }

    private func performClear() {
        input = ""
        inputHandle.replaceAll(with: "")
        output = ""
        outputHandle.replaceAll(with: "")
        outputKind = .none
        instructions.removeAll()
        applied.removeAll()
        toastNow(T(.toastCleared))
    }

    // MARK: Toast

    func toastNow(_ msg: String) {
        toast = msg
        toastTask?.cancel()
        toastTask = Task {
            try? await Task.sleep(nanoseconds: 2_200_000_000)
            if !Task.isCancelled { toast = nil }
        }
    }
}
