import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var m: AppModel

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(Theme.sBorder)
            // Top half: the output pane (full width; it is both the edit target and the result)
            outputPane
            Divider().overlay(Theme.sBorder)
            // Bottom half: left = pending ASR instructions, right = instructions already run
            HStack(spacing: 0) {
                pendingPane
                Rectangle().fill(Theme.sBorder).frame(width: 1)
                appliedPane
            }
            .frame(height: 220)
            Divider().overlay(Theme.sBorder)
            footer
        }
        .background(Theme.sBg)
        .overlay(alignment: .bottom) {
            if let toast = m.toast {
                Text(toast)
                    .font(.system(size: 12.5))
                    .foregroundStyle(Theme.sFg)
                    .padding(.horizontal, 16).padding(.vertical, 8)
                    .background(Theme.sCard2)
                    .clipShape(RoundedRectangle(cornerRadius: 9))
                    .overlay(RoundedRectangle(cornerRadius: 9).stroke(Theme.sBorder))
                    .padding(.bottom, 66)
                    .transition(.opacity)
            }
        }
        .sheet(isPresented: $m.showSettings) { settingsSheet }
        .task {
            // The fake-demo fixture runs in its own Task before bootstrap:
            // bootstrap awaits the system permission dialog, which can hang for a long time.
            if CommandLine.arguments.contains("--fakedemo") {
                Task { @MainActor in
                    let zh = L10n.shared.lang == .zh
                    m.pill = T(.stReady)
                    m.outputSeconds = 4.5
                    m.input = zh ? "第一行输入文字\n第二行输入文字\n第三行输入文字"
                                 : "First line of input\nSecond line of input\nThird line of input"
                    m.output = zh ? "第一行输出文字\n第二行输出文字\n第三行输出文字"
                                  : "First line of output\nSecond line of output\nThird line of output"
                    m.inputHandle.replaceAll(with: m.input)
                    m.outputHandle.replaceAll(with: m.output)
                    m.instructions.append(zh ? "第一条假指令：把上线步骤按顺序排好"
                                             : "Sample instruction: put the rollout steps in order")
                    m.applied.append(AppModel.AppliedItem(
                        text: zh ? "假记录：把风险单独列一块" : "Sample entry: give risks their own section",
                        isTidy: true))
                    m.applied.append(AppModel.AppliedItem(
                        text: zh ? "假记录：第二段语气改正式" : "Sample entry: make paragraph two more formal",
                        isTidy: false))
                    try? await Task.sleep(nanoseconds: 300_000_000)
                    m.asr._debugSimulateFinish(zh ? "模拟收尾：这一段应该一直是可见的绿字"
                                                  : "Simulated tail: this line stays visible throughout")
                }
            }
            await m.bootstrap()
            m.startHealthTicker()
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 10) {
            Text(T(.appTitle)).font(.system(size: 14, weight: .semibold))
            Spacer()
        }
        .padding(.horizontal, 14).padding(.vertical, 9)
        .background(Theme.sPanel)
    }

    private func statusDot(label: String, ok: Bool?) -> some View {
        HStack(spacing: 5) {
            Circle()
                .fill(ok == nil ? Theme.sDim2 : (ok! ? Theme.sAccent : Theme.sFire))
                .frame(width: 7, height: 7)
            Text(label).font(.system(size: 11)).foregroundStyle(Theme.sDim)
        }
    }

    // MARK: Left: pending instructions from ASR

    private var pendingPane: some View {
        VStack(spacing: 0) {
            paneHeader {
                statusDot(label: "ASR", ok: m.asrOnline)
                Text(m.asrStatusText)
                    .font(.system(size: 10.5))
                    .foregroundStyle(m.asrStatusColor)
                Text(TCount(m.instructions.count)).font(.system(size: 10.5)).foregroundStyle(Theme.sDim2)
                Spacer()
            }
            instructionList(m.instructions, deletable: true)
        }
    }

    // MARK: Right: instructions already run

    private var appliedPane: some View {
        VStack(spacing: 0) {
            paneHeader {
                Text(T(.historyTitle)).font(.system(size: 11)).foregroundStyle(Theme.sDim)
                Text(TCount(m.applied.count)).font(.system(size: 10.5)).foregroundStyle(Theme.sDim2)
                Spacer()
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 5) {
                    ForEach(Array(m.applied.enumerated()), id: \.element.id) { idx, item in
                        HStack(alignment: .top, spacing: 8) {
                            Text("\(idx + 1)")
                                .font(.system(size: 10.5, design: .monospaced))
                                .foregroundStyle(Theme.sDim2)
                                .frame(width: 18, alignment: .trailing)
                            Text(item.isTidy ? T(.tagAppend) : T(.tagRevise))
                                .font(.system(size: 9.5))
                                .foregroundStyle(item.isTidy ? Theme.sAccent : Theme.sFire)
                                .padding(.horizontal, 5).padding(.vertical, 1)
                                .overlay(RoundedRectangle(cornerRadius: 3)
                                    .stroke(item.isTidy ? Theme.sAccent.opacity(0.5) : Theme.sFire.opacity(0.5)))
                            Text(item.text)
                                .font(.system(size: 12.5))
                                .foregroundStyle(Theme.sFg.opacity(0.6))
                                .textSelection(.enabled)
                        }
                    }
                    if m.applied.isEmpty {
                        Text(T(.emptyApplied))
                            .font(.system(size: 11.5)).foregroundStyle(Theme.sDim2)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12).padding(.vertical, 6)
            }
            .background(Theme.sPanel)
        }
    }

    /// Instruction list; `deletable` rows carry the copy/delete buttons.
    private func instructionList(_ items: [String], deletable: Bool) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 5) {
                    ForEach(Array(items.enumerated()), id: \.offset) { idx, text in
                        HStack(alignment: .top, spacing: 8) {
                            Text("\(idx + 1)")
                                .font(.system(size: 10.5, design: .monospaced))
                                .foregroundStyle(Theme.sDim2)
                                .frame(width: 18, alignment: .trailing)
                            Text(text)
                                .font(.system(size: 12.5))
                                .foregroundStyle(deletable ? Theme.sFg.opacity(0.88) : Theme.sFg.opacity(0.6))
                                .textSelection(.enabled)
                            Spacer(minLength: 6)
                            if deletable {
                                Button {
                                    m.copyInstruction(at: idx)
                                } label: {
                                    Image(systemName: "doc.on.doc")
                                        .font(.system(size: 9, weight: .semibold))
                                        .foregroundStyle(Theme.sDim2)
                                        .frame(width: 16, height: 16)
                                        .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .help(T(.copyInstructionHelp))
                                Button {
                                    m.removeInstruction(at: idx)
                                } label: {
                                    Image(systemName: "xmark")
                                        .font(.system(size: 9, weight: .semibold))
                                        .foregroundStyle(Theme.sDim2)
                                        .frame(width: 16, height: 16)
                                        .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .help(T(.deleteInstructionHelp))
                            }
                        }
                        .id("\(deletable ? "p" : "a")\(idx)")
                    }
                    // Live line: its leading number is the one the next instruction will get.
                    if deletable, (m.asr.running || m.asr.finishing), !m.asr.liveText.isEmpty {
                        HStack(alignment: .top, spacing: 8) {
                            Text("\(m.instructions.count + 1)")
                                .font(.system(size: 10.5, design: .monospaced))
                                .foregroundStyle(Theme.sAccent)
                                .frame(width: 18, alignment: .trailing)
                            Text(m.asr.liveText)
                                .font(.system(size: 12.5))
                                .foregroundStyle(Theme.sAccent)
                                .id("live")
                        }
                    }
                    if items.isEmpty && !(deletable && !m.asr.liveText.isEmpty) {
                        Text(deletable ? T(.emptyPending) : T(.emptyApplied))
                            .font(.system(size: 11.5)).foregroundStyle(Theme.sDim2)
                    }
                    if let err = m.asr.errorText, deletable {
                        Text(err).font(.system(size: 11.5)).foregroundStyle(Theme.sFire)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12).padding(.vertical, 6)
            }
            .onChange(of: m.instructions.count) { _, _ in
                withAnimation(.linear(duration: 0.1)) { proxy.scrollTo("p\(max(0, m.instructions.count - 1))", anchor: .bottom) }
            }
            .onChange(of: m.applied.count) { _, _ in
                withAnimation(.linear(duration: 0.1)) { proxy.scrollTo("a\(max(0, m.applied.count - 1))", anchor: .bottom) }
            }
            .onChange(of: m.asr.liveText) { _, _ in
                withAnimation(.linear(duration: 0.08)) { proxy.scrollTo("live", anchor: .bottom) }
            }
        }
        .background(Theme.sPanel)
    }


    // MARK: Output

    private var outputPane: some View {
        VStack(spacing: 0) {
            CodeEditor(
                text: $m.output,
                editable: true,
                placeholder: T(.outputPlaceholder),
                handle: m.outputHandle
            )
            .background(Color(nsColor: Theme.panel))
            .clipped()
            // Status strip under the text area: model dot, status text, character count and duration.
            HStack(spacing: 10) {
                statusDot(label: T(.modelLabel), ok: m.llmOK)
                // Text from the very first frame: connecting -> ready / offline.
                Text(m.llmStatusText)
                    .font(.system(size: 10.5))
                    .foregroundStyle(m.llmStatusColor)
                Text(m.hasOutput
                     ? "\(TChars(m.output.count)) · \(String(format: "%.1fs", m.outputSeconds))"
                     : TChars(m.output.count))
                    .font(.system(size: 10.5)).foregroundStyle(Theme.sDim2)
                Spacer()
            }
            .padding(.horizontal, 12)
            .frame(height: 24)
            .background(Theme.sPanel)
            .overlay(alignment: .top) { Rectangle().fill(Theme.sBorder).frame(height: 1) }
        }
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: 8) {
            // Click to start, click again to stop (no press-and-hold).
            Button {
                if m.asr.running { m.stopRecording() } else { m.startRecording() }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: m.asr.running ? "stop.fill" : "mic.fill")
                        .font(.system(size: 11, weight: .semibold))
                    Text(m.asr.running ? T(.btnStop) : T(.btnDictate))
                }
                .frame(width: 96)
            }
            .buttonStyle(VoxButtonStyle(kind: .primary))
            .disabled(m.busy)
            Button {
                Task { await m.tidy() }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "wand.and.stars").font(.system(size: 11))
                    Text(T(.btnAppend))
                }
                .frame(width: 96)
            }
            .buttonStyle(VoxButtonStyle(kind: .normal))
            .disabled(!m.canSendToLLM)
            Button {
                Task { await m.revise() }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "pencil.line").font(.system(size: 11))
                    Text(T(.btnRevise))
                }
                .frame(width: 96)
            }
            .buttonStyle(VoxButtonStyle(kind: .normal))
            .disabled(!m.canSendToLLM)

            divider

            Button { m.copyOutput() } label: {
                HStack(spacing: 6) {
                    Image(systemName: "doc.on.doc").font(.system(size: 11))
                    Text(T(.btnCopyOutput))
                }
                .frame(width: 96)
            }
            .buttonStyle(VoxButtonStyle(kind: .normal))
            .disabled(!m.hasOutput)
            Button { m.clearAll() } label: {
                HStack(spacing: 6) {
                    Image(systemName: "trash").font(.system(size: 11))
                    Text(T(.btnClearAll))
                }
                .frame(width: 96)
            }
            .buttonStyle(VoxButtonStyle(kind: .normal))
            .disabled(m.isAllEmpty)

            Spacer()

            Button { m.showSettings = true } label: { Text(T(.btnSettings)) }
                .buttonStyle(VoxButtonStyle(kind: .normal))
        }
        .padding(.horizontal, 14).padding(.vertical, 9)
        .background(Color(nsColor: Theme.card).opacity(0.55))
    }

    private var divider: some View {
        Rectangle().fill(Theme.sBorder).frame(width: 1, height: 20).padding(.horizontal, 2)
    }

    private func paneHeader<C: View>(@ViewBuilder _ content: () -> C) -> some View {
        HStack(spacing: 8) { content() }
            .padding(.horizontal, 12).padding(.vertical, 5)
            .frame(height: 28)
            .background(Theme.sPanel)
            .overlay(alignment: .bottom) { Rectangle().fill(Theme.sBorder).frame(height: 1) }
    }

    // MARK: Settings

    private var settingsSheet: some View {
        VStack(spacing: 0) {
            // Scrollable so the sheet height stays fixed whether the ASR engine needs two
            // fields (sherpa) or five (cloud).
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Text(T(.settingsTitle)).font(.system(size: 14, weight: .semibold))

                    labelRow(T(.setProvider)) {
                        Picker("", selection: $m.provider) {
                            ForEach(LLMProvider.allCases) { provider in
                                Text(provider.label).tag(provider)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                        .frame(width: 230)
                    }

                    fieldBlock(T(.setModelEndpoint), text: $m.baseURLString,
                               prompt: "https://api.deepseek.com/v1",
                               help: T(.setEndpointHint))

                    fieldBlock(T(.setModel), text: $m.modelName, prompt: m.provider.defaultModel)

                    if m.provider.requiresKey {
                        secureBlock(T(.setApiKey), text: $m.apiKey, prompt: "sk-…", help: T(.setKeyHint)) {
                            m.saveAPIKey()
                        }
                    }

                    HStack(spacing: 8) {
                        Button {
                            m.saveAPIKey()
                            Task { await m.refreshHealth() }
                        } label: { Text(T(.setTest)) }
                            .buttonStyle(VoxButtonStyle(kind: .normal))
                        Text(m.llmOK == nil ? T(.setNotChecked) : (m.llmOK! ? T(.setConnected) : T(.setUnreachable)))
                            .font(.system(size: 11.5))
                            .foregroundStyle(m.llmOK == nil ? Theme.sDim2 : (m.llmOK! ? Theme.sAccent : Theme.sFire))
                    }

                    Divider().overlay(Theme.sBorder)

                    labelRow(T(.setAsrEngine)) {
                        Picker("", selection: $m.asrEngine) {
                            ForEach(ASREngine.allCases) { engine in
                                Text(engine.label).tag(engine)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                        .frame(width: 230)
                    }

                    if m.asrEngine.usesLocalServers {
                        fieldBlock(T(.setAsrHost), text: $m.asrHost, prompt: "127.0.0.1",
                                   help: T(.setAsrTitle) + "\n" + m.asr.endpoint + T(.setAsrProtocol))
                    } else {
                        fieldBlock(T(.setAsrBaseURL), text: $m.asrBaseURL,
                                   prompt: m.asrEngine.defaultBaseURL)
                        fieldBlock(T(.setAsrModel), text: $m.asrModel, prompt: m.asrEngine.defaultModel)
                        if m.asrEngine.requiresKey {
                            secureBlock(T(.setAsrKey), text: $m.asrKey, prompt: "sk-…", help: nil) {
                                m.saveASRKey()
                            }
                        }
                        fieldBlock(T(.setAsrLanguage), text: $m.asrLanguage, prompt: "zh")
                    }

                    Text(m.asrAuthorized == true ? T(.setMicGranted) : T(.setMicDenied))
                        .font(.system(size: 10))
                        .foregroundStyle(m.asrAuthorized == true ? Theme.sDim2 : Theme.sFire)

                    Divider().overlay(Theme.sBorder)

                    labelRow(T(.setLanguage)) {
                        Picker("", selection: $m.uiLanguage) {
                            ForEach(UILanguage.allCases) { language in
                                Text(language.label).tag(language)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                        .frame(width: 190)
                    }

                    Toggle(isOn: $m.clearNoAsk) {
                        Text(T(.setClearNoAsk)).font(.system(size: 11.5)).foregroundStyle(Theme.sDim)
                    }
                    .toggleStyle(.checkbox)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(18)
            }
            Divider().overlay(Theme.sBorder)
            HStack {
                Spacer()
                Button {
                    m.saveAPIKey()
                    m.saveASRKey()
                    m.showSettings = false
                } label: { Text(T(.close)) }
                    .buttonStyle(VoxButtonStyle(kind: .primary))
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 10)
        }
        .frame(width: 500, height: 620)
        .background(Theme.sBg)
    }

    private func labelRow<C: View>(_ title: String, @ViewBuilder _ control: () -> C) -> some View {
        HStack(spacing: 8) {
            Text(title).font(.system(size: 11.5)).foregroundStyle(Theme.sDim)
                .frame(width: 96, alignment: .leading)
            control()
            Spacer()
        }
    }

    private func plainField(_ text: Binding<String>, prompt: String) -> some View {
        TextField(prompt, text: text)
            .textFieldStyle(.plain)
            .font(.system(size: 12, design: .monospaced))
            .padding(6)
            .background(Theme.sCard2)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Theme.sBorder))
    }

    private func fieldBlock(_ title: String, text: Binding<String>, prompt: String, help: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.system(size: 11.5)).foregroundStyle(Theme.sDim)
            plainField(text, prompt: prompt)
            if let help {
                Text(help)
                    .font(.system(size: 10)).foregroundStyle(Theme.sDim2)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func secureBlock(_ title: String, text: Binding<String>, prompt: String,
                             help: String?, onSubmit: @escaping () -> Void) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.system(size: 11.5)).foregroundStyle(Theme.sDim)
            SecureField(prompt, text: text)
                .textFieldStyle(.plain)
                .font(.system(size: 12, design: .monospaced))
                .padding(6)
                .background(Theme.sCard2)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Theme.sBorder))
                .onSubmit(onSubmit)
            if let help {
                Text(help).font(.system(size: 10)).foregroundStyle(Theme.sDim2)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// Press-and-hold button (mouse down starts, mouse up ends).
struct HoldButton: View {
    let title: String
    var primary: Bool = false
    var enabled: Bool = true
    let onStart: () -> Void
    let onEnd: () -> Void
    var isRecording: Bool = false

    @State private var holding = false

    var body: some View {
        Text(title)
            .font(.system(size: 12.5))
            .foregroundStyle(isRecording ? Color.white : (primary && enabled ? Theme.sBg : Theme.sFg))
            .padding(.horizontal, 12).padding(.vertical, 6)
            .frame(minWidth: 96)
            .background(isRecording ? Theme.sFire : (primary && enabled ? Theme.sAccent : Theme.sCard2))
            .clipShape(RoundedRectangle(cornerRadius: 7))
            .overlay(RoundedRectangle(cornerRadius: 7)
                .stroke(isRecording ? Theme.sFire : (primary && enabled ? Theme.sAccent : Theme.sBorder), lineWidth: 1))
            .contentShape(Rectangle())
            .opacity(enabled ? 1 : 0.5)
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in
                        guard enabled, !holding else { return }
                        holding = true
                        onStart()
                    }
                    .onEnded { _ in
                        guard holding else { return }
                        holding = false
                        onEnd()
                    }
            )
    }
}
