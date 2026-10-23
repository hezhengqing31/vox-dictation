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

/// Headless self-test: verifies the "model endpoint + llmwriter" path end to end
enum SelfTest {
    static func runAndExit() -> Never {
        let base = UserDefaults.standard.string(forKey: "vox.baseURL") ?? "http://127.0.0.1:5000"
        guard let url = URL(string: base) else { print("bad url"); exit(2) }
        let client = LLMClient(baseURL: url)
        let sem = DispatchSemaphore(value: 0)
        var code: Int32 = 1

        Task.detached {
            let ok = await client.health()
            print("health: \(ok ? "ok" : "fail")  base=\(base)")
            do {
                // Sample payloads stay in Chinese: they exercise the Chinese writing scenes on the server.
                let (text, seconds) = try await client.write(
                    instructions: ["把这段整理通顺"],
                    target: "呃我们这个方案 那个 什么时候能定下来 然后 我这边 好安排",
                    lastOutput: "")
                print(String(format: "llmwriter %.2fs → %@", seconds, text))
                // Rewrite endpoint: content + instructions
                let (m1, s1) = try await client.modify(
                    content: "下周上线新的支付流程。灰度期间每天看错误率。",
                    instructions: ["补一句 错误率超过百分之一就回滚"])
                print(String(format: "modify %.2fs → %@", s1, m1))
                let (m2, s2) = try await client.modify(
                    content: "",
                    instructions: ["列出三件上线前必须确认的事"])
                print(String(format: "modify(empty content) %.2fs → %@", s2, m2))
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
