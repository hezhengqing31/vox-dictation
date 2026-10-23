import Foundation

/// The writing pipeline, ported from the server scenes. Three behaviours:
///
/// - **draft**: no existing text, instructions describe what to write.
/// - **append**: existing text + new spoken items. The model only produces the new items and
///   this file assembles the result, so the original text is preserved byte for byte and the
///   numbering continues from it. A pure request ("tidy this up") is routed to revise first.
/// - **revise**: the take is an order about the existing text. Change only, add nothing.
struct Writer {
    let client: ChatClient

    enum Mode { case append, revise }

    struct Result {
        let text: String
        let added: Int          // 0 for revise and draft; the count of appended items otherwise
        let seconds: Double
    }

    func run(mode: Mode, content: String, instructions: [String]) async throws -> Result {
        let joined = instructions
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
        let target = content.trimmingCharacters(in: .whitespacesAndNewlines)
        let started = Date()

        if target.isEmpty {
            // Nothing to append to: write the first version from the instructions alone.
            let text = try await draft(instructions: joined)
            return Result(text: text, added: 0, seconds: Date().timeIntervalSince(started))
        }
        if mode == .revise {
            let text = try await revise(content: target, instruction: joined)
            return Result(text: text, added: 0, seconds: Date().timeIntervalSince(started))
        }
        // Append: a take with no new facts in it is a request, not content. Ask the cheap
        // classifier first instead of hoping the long prompt notices.
        if !(await isNewContent(joined)) {
            let text = try await revise(content: target, instruction: joined)
            return Result(text: text, added: 0, seconds: Date().timeIntervalSince(started))
        }
        let (text, added) = try await append(target: target, instructions: joined)
        return Result(text: text, added: added, seconds: Date().timeIntervalSince(started))
    }

    // MARK: Scenes

    /// Write the first version from the instructions.
    private func draft(instructions: String) async throws -> String {
        let raw = try await client.chat(
            [.init(role: "system", content: Prompts.writeSystem),
             .init(role: "user", content: Prompts.userMessage(target: "", instructions: [instructions]))],
            temperature: 0.3, maxTokens: 900)
        return Writer.tidyLines(raw)
    }

    /// Apply the take to the existing text. The take is prefixed so the model sees it as a
    /// request; without the prefix it treats the words as content and pastes them in.
    private func revise(content: String, instruction: String) async throws -> String {
        let raw = try await client.chat(
            [.init(role: "system", content: Prompts.rewriteSystem),
             .init(role: "user",
                   content: Prompts.userMessage(target: content,
                                                instructions: [Prompts.rewritePrefix + instruction]))],
            temperature: 0.3, maxTokens: 900)
        return Writer.tidyLines(Writer.stripMeta(raw))
    }

    /// New items only; the original text and the numbering are ours to keep consistent.
    private func append(target: String, instructions: String) async throws -> (String, Int) {
        let raw = try await client.chat(
            [.init(role: "system", content: Prompts.appendSystem),
             .init(role: "user", content: instructions)],
            temperature: 0.3, maxTokens: 400)

        let items = Writer.splitItems(Writer.tidyLines(Writer.stripMeta(raw)))
        let added = items.filter { !$0.isEmpty }
        // "无新增" is the model's way of saying the take carried no new fact.
        if added.isEmpty || added.contains(where: { $0.hasPrefix("无新增") }) {
            return (Writer.tidyLines(target), 0)
        }
        return (Writer.tidyLines(Writer.attach(target: target, items: added)), added.count)
    }

    /// Is the take new content, or a request about the text? One tiny call, temperature 0.
    /// On any failure assume content: never silently rewrite what the user wrote.
    func isNewContent(_ text: String) async -> Bool {
        do {
            let raw = try await client.chat(
                [.init(role: "system", content: Prompts.classifySystem),
                 .init(role: "user", content: text)],
                temperature: 0, maxTokens: 4)
            let answer = raw.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
            if answer.hasPrefix("B") { return false }
            if answer.hasPrefix("A") { return true }
            return answer.contains("A") && !answer.contains("B")
        } catch {
            return true
        }
    }

    // MARK: Text hygiene (ported from writer_core)

    /// Trim trailing spaces per line and drop leading/trailing blank lines. Blank lines between
    /// paragraphs stay: they are the model's own paragraphing, not noise.
    static func tidyLines(_ text: String) -> String {
        var lines = text.replacingOccurrences(of: "\r\n", with: "\n")
            .components(separatedBy: "\n")
            .map { line in
                var l = line
                while let last = l.last, last == " " || last == "\t" { l.removeLast() }
                return l
            }
        while let first = lines.first, first.isEmpty { lines.removeFirst() }
        while let last = lines.last, last.isEmpty { lines.removeLast() }
        return lines.joined(separator: "\n")
    }

    /// Drop self-commentary lines ("说明：…", "经核查…", a line that is only a parenthesised note)
    /// and the occasional "old text then new text" double output.
    static func stripMeta(_ text: String) -> String {
        let prefixes = ["说明", "注", "备注", "经核查", "核对", "综上", "最终输出", "最终调整", "解释", "分析", "推理"]
        let hints = ["根据指令", "故将", "故最终", "应为", "确认为正确写法"]
        var kept: [String] = []

        for line in text.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { kept.append(line); continue }
            if Writer.isMetaLine(trimmed, prefixes: prefixes) { continue }
            if (trimmed.hasPrefix("（") && trimmed.hasSuffix("）"))
                || (trimmed.hasPrefix("(") && trimmed.hasSuffix(")")) { continue }
            if trimmed.hasPrefix("根据指令") || trimmed.hasPrefix("经核查") || trimmed.hasPrefix("最终输出") { continue }
            if trimmed.contains("说明："), trimmed.count > 60,
               hints.filter({ trimmed.contains($0) }).count >= 2 { continue }
            kept.append(line)
        }
        while let last = kept.last, last.trimmingCharacters(in: .whitespaces).isEmpty { kept.removeLast() }

        // "original, then the rewrite": if both halves are identical, keep one.
        let body = kept.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        let half = body.count / 2
        if half >= 2 && Array(body.prefix(half)) == Array(body.suffix(half)) {
            kept = Array(body.suffix(half))
        }
        return kept.joined(separator: "\n")
    }

    private static func isMetaLine(_ line: String, prefixes: [String]) -> Bool {
        var s = Substring(line)
        // A note may open with a bracket: "（说明：…）" or "【注】…".
        while let first = s.first, "（(【[".contains(first) {
            s = s.dropFirst().drop(while: { $0 == " " || $0 == "\t" })
        }
        for prefix in prefixes where s.hasPrefix(prefix) {
            let after = s.dropFirst(prefix.count).drop(while: { $0 == " " })
            if let ch = after.first, ch == "：" || ch == ":" { return true }
        }
        return false
    }

    // MARK: Items and numbering

    /// Split model output into items, dropping any list marker it added on its own.
    static func splitItems(_ text: String) -> [String] {
        text.components(separatedBy: "\n").compactMap { line in
            var s = line.trimmingCharacters(in: .whitespaces)
            while let first = s.first, "-*•·".contains(first) {
                s = String(s.dropFirst()).trimmingCharacters(in: .whitespaces)
            }
            if let numbered = leadingNumber(s) { s = numbered.rest }
            let cleaned = s.trimmingCharacters(in: .whitespaces)
            return cleaned.isEmpty ? nil : cleaned
        }
    }

    /// Leading "N." / "N、" / "N)" marker of a line, if any.
    private static func leadingNumber(_ line: String) -> (number: Int, sep: Character, rest: String)? {
        let chars = Array(line)
        var i = 0
        while i < chars.count, chars[i] == " " || chars[i] == "\t" { i += 1 }
        var digits = ""
        while i < chars.count, chars[i].isNumber { digits.append(chars[i]); i += 1 }
        guard !digits.isEmpty, i < chars.count else { return nil }
        let sep = chars[i]
        guard ".、)．".contains(sep) else { return nil }
        i += 1
        while i < chars.count, chars[i] == " " { i += 1 }
        guard let number = Int(digits) else { return nil }
        return (number, sep, String(chars[i...]))
    }

    /// The last number and separator used by the existing text, if it is a numbered list.
    private static func numbering(_ target: String) -> (last: Int, sep: String)? {
        var last = 0
        var sep = ". "
        for line in target.components(separatedBy: "\n") {
            guard let numbered = leadingNumber(line) else { continue }
            last = numbered.number
            sep = String(numbered.sep) + " "
        }
        return last > 0 ? (last, sep) : nil
    }

    /// Attach the new items below the existing text: continue the numbering when the text is
    /// numbered, otherwise start a new paragraph. The original string is never rewritten.
    static func attach(target: String, items: [String]) -> String {
        var items = items
        // If every non-empty line of the target ends with a period, match that style.
        let lines = target.components(separatedBy: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        if !lines.isEmpty,
           lines.allSatisfy({ $0.trimmingCharacters(in: .whitespaces).hasSuffix("。") }) {
            items = items.map { item in
                guard let last = item.last else { return item }
                return "。！？".contains(last) ? item : item + "。"
            }
        }

        var body = target
        while body.hasSuffix("\n") { body.removeLast() }

        if let (last, sep) = numbering(target) {
            let block = items.enumerated()
                .map { "\(last + $0.offset + 1)\(sep)\($0.element)" }
                .joined(separator: "\n")
            return body + "\n" + block + "\n"
        }
        if lines.count <= 1 {
            return body + "\n\n" + items.joined(separator: "\n") + "\n"
        }
        return body + "\n" + items.joined(separator: "\n") + "\n"
    }
}
