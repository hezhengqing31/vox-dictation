import SwiftUI
import AppKit

@main
struct VoxApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var model = AppModel()

    init() {
        if CommandLine.arguments.contains("--selftest") {
            SelfTest.runAndExit()
        }
        if let i = CommandLine.arguments.firstIndex(of: "--asrtest"),
           i + 1 < CommandLine.arguments.count {
            let base = UserDefaults.standard.string(forKey: "vox.baseURL") ?? "http://127.0.0.1:5000"
            let host = URL(string: base)?.host ?? "127.0.0.1"
            // Optional third argument: seconds of tail silence to pad (default 1.2; 0 = none, for comparison)
            let pad = (i + 2 < CommandLine.arguments.count)
                ? (Double(CommandLine.arguments[i + 2]) ?? 1.2) : 1.2
            // Fourth argument "live": replay the real app's timing
            // (43ms slices / 250ms tail window after release / only 700ms wait after padding)
            let live = (i + 3 < CommandLine.arguments.count) && CommandLine.arguments[i + 3] == "live"
            ASRSelfTest.runAndExit(wav: CommandLine.arguments[i + 1], host: host, port: 6006,
                                   pad: pad, live: live)
        }
        if let i = CommandLine.arguments.firstIndex(of: "--fileasrtest"),
           i + 1 < CommandLine.arguments.count {
            let base = UserDefaults.standard.string(forKey: "vox.baseURL") ?? "http://127.0.0.1:5000"
            let host = URL(string: base)?.host ?? "127.0.0.1"
            ASRSelfTest.runFileAndExit(wav: CommandLine.arguments[i + 1], host: host)
        }
        if let i = CommandLine.arguments.firstIndex(of: "--cloudasrtest"),
           i + 1 < CommandLine.arguments.count {
            let d = UserDefaults.standard
            let engine = ASREngine(rawValue: d.string(forKey: "vox.asrEngine") ?? "") ?? .sherpa
            let settings = ASRSettings(
                engine: engine,
                host: d.string(forKey: "vox.asrHost") ?? "127.0.0.1",
                baseURL: d.string(forKey: "vox.asrBaseURL") ?? engine.defaultBaseURL,
                model: d.string(forKey: "vox.asrModel") ?? engine.defaultModel,
                apiKey: Keychain.get(account: "asr." + engine.rawValue) ?? "",
                language: d.string(forKey: "vox.asrLanguage") ?? "zh")
            ASRSelfTest.runCloudAndExit(wav: CommandLine.arguments[i + 1], settings: settings)
        }
        if let i = CommandLine.arguments.firstIndex(of: "--shot"),
           i + 1 < CommandLine.arguments.count {
            let delay = (i + 2 < CommandLine.arguments.count)
                ? (Double(CommandLine.arguments[i + 2]) ?? 2.0) : 2.0
            WindowShot.schedule(path: CommandLine.arguments[i + 1], after: delay)
        }
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(model)
                .preferredColorScheme(.dark)
        }
        .defaultSize(width: 1120, height: 720)
        .commands {
            CommandGroup(replacing: .newItem) {}
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

/// Render our own window to a PNG (no screen-recording permission needed, handy for automated checks)
enum WindowShot {
    static func schedule(path: String, after delay: Double = 2.0) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            defer { NSApp.terminate(nil) }
            guard let window = NSApp.windows.first(where: { $0.isVisible }) ?? NSApp.windows.first,
                  let view = window.contentView else { return }
            guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
            view.cacheDisplay(in: view.bounds, to: rep)
            if let data = rep.representation(using: .png, properties: [:]) {
                try? data.write(to: URL(fileURLWithPath: path))
                print("shot: \(path) \(rep.pixelsWide)x\(rep.pixelsHigh)")
            }
        }
    }
}

/// Headless self-test: exercises the configured provider end to end — reachability,
/// first draft, append (existing text untouched) and revise. Needs a key in the Keychain
/// or a local runtime; run it after `--selftest` reports a healthy endpoint.
enum SelfTest {
    static func runAndExit() -> Never {
        let defaults = UserDefaults.standard
        let provider = LLMProvider(rawValue: defaults.string(forKey: "vox.provider") ?? "") ?? .deepseek
        let config = ModelConfig(
            baseURL: defaults.string(forKey: "vox.baseURL") ?? provider.defaultBaseURL,
            model: defaults.string(forKey: "vox.model") ?? provider.defaultModel,
            apiKey: Keychain.get(account: "llm." + provider.rawValue))
        let client = ChatClient(config: config)
        let writer = Writer(client: client)
        let sem = DispatchSemaphore(value: 0)
        var code: Int32 = 1

        Task.detached {
            print("provider: \(provider.label)  base=\(config.baseURL)  model=\(config.model)  key=\(config.apiKey == nil ? "none" : "set")")
            let ok = await client.reachable()
            print("health: \(ok ? "ok" : "fail")")
            guard ok else { sem.signal(); exit(1) }

            do {
                // 1. first draft from a spoken take
                let draft = try await writer.run(
                    mode: .append, content: "",
                    instructions: ["写一段上线通知 说清楚这周灰度 发现问题就回滚"])
                print(String(format: "draft %.2fs (%d items added) → %@", draft.seconds, draft.added, draft.text))

                // 2. append: a numbered list must keep its numbering and its original lines
                let append = try await writer.run(
                    mode: .append,
                    content: "1. 周四完成回归测试\n2. 周五灰度百分之十",
                    instructions: ["补一条 错误率超过百分之一就回滚"])
                print(String(format: "append %.2fs (%d items added) → %@", append.seconds, append.added, append.text))

                // 3. revise: change the text, add nothing
                let revise = try await writer.run(
                    mode: .revise,
                    content: "下周上线新的支付流程。灰度期间每天看错误率。",
                    instructions: ["语气改正式一点"])
                print(String(format: "revise %.2fs → %@", revise.seconds, revise.text))

                // 4. a take that is a pure request: the classifier must route it to revise,
                //    so nothing is invented and `added` stays 0
                let routed = try await writer.run(
                    mode: .append,
                    content: "1. 周四完成回归测试\n2. 周五灰度百分之十",
                    instructions: ["整理一下 通顺点"])
                print(String(format: "append(request) %.2fs (%d items added) → %@", routed.seconds, routed.added, routed.text))
                code = 0
            } catch {
                print("error: \(error.localizedDescription)")
            }
            sem.signal()
        }

        sem.wait()
        exit(code)
    }
}
