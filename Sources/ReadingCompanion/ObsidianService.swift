import AppKit
import Foundation

enum ObsidianVaultRegistry {
    private struct Registry: Decodable {
        struct Vault: Decodable {
            var path: String
            var ts: Double?
            var open: Bool?
        }
        var vaults: [String: Vault]
    }

    static var defaultRegistryURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("obsidian/obsidian.json")
    }

    static func registeredVaults(registryURL: URL = defaultRegistryURL) -> [URL] {
        guard let data = try? Data(contentsOf: registryURL) else { return [] }
        return decode(data: data)
    }

    static func decode(data: Data) -> [URL] {
        guard let registry = try? JSONDecoder().decode(Registry.self, from: data) else { return [] }
        return registry.vaults.values
            .sorted {
                if ($0.open ?? false) != ($1.open ?? false) { return $0.open == true }
                if ($0.ts ?? 0) != ($1.ts ?? 0) { return ($0.ts ?? 0) > ($1.ts ?? 0) }
                return $0.path.localizedStandardCompare($1.path) == .orderedAscending
            }
            .map { URL(fileURLWithPath: $0.path, isDirectory: true).standardizedFileURL }
    }

    static func preferredVault(registryURL: URL = defaultRegistryURL) -> URL? {
        registeredVaults(registryURL: registryURL).first
    }

    static func exactVault(_ candidate: URL, registered: [URL]) -> URL? {
        let path = candidate.standardizedFileURL.path
        return registered.first { $0.standardizedFileURL.path == path }
    }

    static func containingVault(for item: URL, registered: [URL]) -> URL? {
        let itemPath = item.standardizedFileURL.path
        return registered
            .filter { root in
                let rootPath = root.standardizedFileURL.path
                return itemPath == rootPath || itemPath.hasPrefix(rootPath + "/")
            }
            .max { $0.path.count < $1.path.count }
    }

    static func displayList(_ registered: [URL]) -> String {
        registered.isEmpty ? "没有检测到已注册 Vault" : registered.map(\.path).joined(separator: "\n")
    }
}

enum ObsidianDeepLink {
    static func openURL(vault: URL, note: URL) -> URL? {
        let vaultURL = vault.standardizedFileURL
        let noteURL = note.standardizedFileURL
        let root = vaultURL.path.hasSuffix("/") ? vaultURL.path : vaultURL.path + "/"
        guard noteURL.path.hasPrefix(root) else { return nil }
        let relativeFile = String(noteURL.path.dropFirst(root.count))
        guard !relativeFile.isEmpty,
              let vaultName = encode(vaultURL.lastPathComponent),
              let file = encode(relativeFile) else { return nil }
        return URL(string: "obsidian://open?vault=\(vaultName)&file=\(file)")
    }

    private static func encode(_ value: String) -> String? {
        var allowed = CharacterSet.urlQueryAllowed
        // URLQueryItem leaves '+' untouched, while Obsidian's query parser can
        // interpret it as a space. Encode all query separators explicitly.
        allowed.remove(charactersIn: "+&=?#")
        return value.addingPercentEncoding(withAllowedCharacters: allowed)
    }
}

enum OutlineNoteLocator {
    static func chapterTitle(
        for pageIndex: Int,
        sourceText: String?,
        pageText: String?,
        outline: [OutlineEntry]
    ) -> String? {
        let eligible = outline.enumerated().filter { $0.element.pageIndex <= pageIndex }
        guard !eligible.isEmpty else { return nil }
        let onPage = eligible.filter { $0.element.pageIndex == pageIndex }
        guard !onPage.isEmpty else { return eligible.last?.element.title }

        if let sourceText, let pageText,
           let sourceLocation = location(of: sourceText, in: pageText) {
            let precedingHeading = onPage.compactMap { indexed -> (entry: OutlineEntry, location: Int)? in
                guard let headingLocation = headingLocation(for: indexed.element.title, in: pageText),
                      headingLocation <= sourceLocation else { return nil }
                return (indexed.element, headingLocation)
            }.max { $0.location < $1.location }
            if let precedingHeading { return precedingHeading.entry.title }
        }

        // Text before the first subsection on a page belongs to its nearest
        // parent (for example the unlabelled opening of an introduction), not
        // to the last subsection that happens to share the same PDF page.
        guard let first = onPage.first else { return eligible.last?.element.title }
        if first.element.level > 0,
           let parent = eligible.prefix(while: { $0.offset < first.offset }).last(where: {
               $0.element.level < first.element.level
           }) {
            return parent.element.title
        }
        return onPage.min { lhs, rhs in
            lhs.element.level == rhs.element.level
                ? lhs.offset < rhs.offset
                : lhs.element.level < rhs.element.level
        }?.element.title
    }

    private static func headingLocation(for title: String, in pageText: String) -> Int? {
        if let exact = location(of: title, in: pageText) { return exact }
        let withoutSequence = title.replacingOccurrences(
            of: #"^(?:(?:第\s*[0-9一二三四五六七八九十百千零〇两]+\s*(?:部分|篇|部|卷|章|节))|(?:chapter|part|section)\s+\S+|(?:\d+(?:\.\d+)*))[\s、.．:：\-]*"#,
            with: "",
            options: [.regularExpression, .caseInsensitive]
        )
        return withoutSequence == title ? nil : location(of: withoutSequence, in: pageText)
    }

    private static func location(of needle: String, in haystack: String) -> Int? {
        let source = TOCInputNormalizer.comparisonKey(needle)
        let page = TOCInputNormalizer.comparisonKey(haystack)
        guard source.count >= 4, !page.isEmpty else { return nil }
        let maximum = min(source.count, 48)
        for length in stride(from: maximum, through: min(maximum, 8), by: -4) {
            let fragment = String(source.prefix(length))
            if let range = page.range(of: fragment) {
                return page.distance(from: page.startIndex, to: range.lowerBound)
            }
        }
        return nil
    }
}

enum ObsidianNoteBuilder {
    static func skeleton(title: String, sourcePath: String?, outline: [OutlineEntry]) -> String {
        var lines = ["# \(title)", ""]
        for entry in outline {
            guard entry.title.trimmingCharacters(in: .whitespacesAndNewlines)
                .localizedCaseInsensitiveCompare(title.trimmingCharacters(in: .whitespacesAndNewlines)) != .orderedSame else { continue }
            let heading = String(repeating: "#", count: min(entry.level + 2, 6))
            lines += ["\(heading) \(entry.title)", ""]
        }
        lines += ["## 我的笔记", "", ""]
        return lines.joined(separator: "\n")
    }

    static func highlightBlock(_ highlight: HighlightRecord) -> String {
        if highlight.markKind == .annotation {
            var lines = [
                "> [!success] 批注 · 第 \(highlight.pageIndex + 1) 页",
                "> *原文：* \(highlight.inlineText)"
            ]
            if let note = highlight.note, !note.isEmpty {
                lines += [">", "> \(note.replacingOccurrences(of: "\n", with: "\n> "))"]
            }
            return lines.joined(separator: "\n")
        }
        var lines = [
            "> [!\(highlight.tint.obsidianCallout)] 划线 · 第 \(highlight.pageIndex + 1) 页",
            "> \(highlight.inlineText)"
        ]
        if let note = highlight.note, !note.isEmpty {
            lines += ["", "> [!note] 批注", "> \(note.replacingOccurrences(of: "\n", with: "\n> "))"]
        }
        return lines.joined(separator: "\n")
    }

    static func aiBlock(turns: [ChatTurn], pages: [Int], collapsed: Bool) -> String {
        let body = turns.map { turn in
            let label = turn.role == .user ? "问题" : "伴读"
            return "**\(label)：** \(turn.content)"
        }.joined(separator: "\n\n")
        return aiBlock(
            body: body,
            pages: pages,
            collapsed: collapsed,
            sourceTurnIDs: turns.map(\.id)
        )
    }

    static func aiBlock(summary: String, pages: [Int], collapsed: Bool, sourceTurnIDs: [UUID]) -> String {
        aiBlock(
            body: summary,
            pages: pages,
            collapsed: collapsed,
            title: "AI 讨论 · 整理",
            sourceTurnIDs: sourceTurnIDs
        )
    }

    private static func aiBlock(
        body: String,
        pages: [Int],
        collapsed: Bool,
        title: String = "AI 讨论",
        sourceTurnIDs: [UUID]
    ) -> String {
        let pageLabel = pages.sorted().map { String($0 + 1) }.joined(separator: "、")
        return """
        > [!example]\(collapsed ? "-" : "+") \(title)\(pageLabel.isEmpty ? "" : " · 第 \(pageLabel) 页")
        > \(body.replacingOccurrences(of: "\n", with: "\n> "))
        """
    }

    static func insert(
        block: String,
        into markdown: String,
        afterPage pageIndex: Int?,
        chapterTitle: String? = nil
    ) -> String {
        guard let pageIndex else { return appendToMyNotes(block: block, markdown: markdown) }
        if let chapterTitle,
           let insertion = exactChapterInsertionPoint(
               in: markdown,
               title: chapterTitle,
               pageIndex: pageIndex
           ) {
            var result = markdown
            result.insert(contentsOf: "\n\n\(block)\n", at: insertion)
            return result
        }
        return appendToMyNotes(block: block, markdown: markdown)
    }

    /// Adds headings introduced by a newly recognized or manually corrected
    /// outline without rewriting existing chapter content or handwritten notes.
    static func ensureOutlineHeadings(in markdown: String, outline: [OutlineEntry]) -> String {
        let existingLines = Set(markdown.components(separatedBy: .newlines))
        let missing = outline.compactMap { entry -> String? in
            let heading = "\(String(repeating: "#", count: min(entry.level + 2, 6))) \(entry.title)"
            return existingLines.contains(heading) ? nil : heading
        }
        guard !missing.isEmpty else { return markdown }
        let block = missing.map { "\($0)\n" }.joined(separator: "\n")
        guard let notesHeading = markdown.range(of: "\n## 我的笔记") else {
            return markdown + "\n\n" + block
        }
        var result = markdown
        result.insert(contentsOf: "\n\n\(block)", at: notesHeading.lowerBound)
        return result
    }

    private static func exactChapterInsertionPoint(
        in markdown: String,
        title: String,
        pageIndex: Int
    ) -> String.Index? {
        let escapedTitle = NSRegularExpression.escapedPattern(for: title.trimmingCharacters(in: .whitespacesAndNewlines))
        guard let headingExpression = try? NSRegularExpression(
            pattern: "(?m)^(#{2,6})[ \\t]+\(escapedTitle)[ \\t]*$"
        ) else { return nil }
        let fullRange = NSRange(markdown.startIndex..<markdown.endIndex, in: markdown)
        let headings = headingExpression.matches(in: markdown, range: fullRange)
        for heading in headings {
            guard let headingRange = Range(heading.range(at: 0), in: markdown) else { continue }
            let searchStart = headingRange.upperBound
            let tailRange = NSRange(searchStart..<markdown.endIndex, in: markdown)
            guard let anyHeading = try? NSRegularExpression(pattern: #"(?m)^(#{2,6})[ \t]+"#) else { return nil }
            let nextHeading = anyHeading.firstMatch(in: markdown, range: tailRange)
            let peerIndex = nextHeading.flatMap { Range($0.range(at: 0), in: markdown)?.lowerBound }
            let myNotesIndex = markdown.range(of: "\n## 我的笔记", range: searchStart..<markdown.endIndex)?.lowerBound
            return [peerIndex, myNotesIndex].compactMap { $0 }.min() ?? markdown.endIndex
        }
        return nil
    }

    private static func appendToMyNotes(block: String, markdown: String) -> String {
        guard let heading = markdown.range(of: "\n## 我的笔记") else {
            return markdown + "\n\n## 我的笔记\n\n" + block + "\n"
        }
        let insertion = markdown[heading.upperBound...].firstIndex(of: "\n") ?? markdown.endIndex
        var result = markdown
        result.insert(contentsOf: "\n\n\(block)\n", at: insertion)
        return result
    }

    static func migrateLegacyMarkdown(_ markdown: String) -> String {
        var result = markdown
        let replacements = [
            "[!quote-yellow]": "[!warning]",
            "[!quote-red]": "[!danger]",
            "[!quote-blue]": "[!info]",
            "[!annotation]": "[!success]",
            "[!comment]": "[!note]",
            "[!ai]": "[!example]",
            "[!chapter-overview]": "[!tip]",
            "[!chapter-framework]": "[!example]"
        ]
        for (old, new) in replacements {
            result = result.replacingOccurrences(of: old, with: new)
        }
        result = result.replacingOccurrences(
            of: #"(?m)^> \[!question\]([+-]?) (AI 讨论[^\n]*)$"#,
            with: "> [!example]$1 $2",
            options: .regularExpression
        )
        result = result.replacingOccurrences(
            of: #"(?m)^\s*<!--\s*reading-companion:[^\n]*-->\s*\n?"#,
            with: "",
            options: .regularExpression
        )
        result = result.replacingOccurrences(
            of: #"\A---\s*\n(?s:.*?)\n---\s*\n*"#,
            with: "",
            options: .regularExpression
        )
        result = result.replacingOccurrences(
            of: #"(?m)^> \[!info\] 原文\s*\n> `[^\n]*`\s*\n*"#,
            with: "",
            options: .regularExpression
        )
        result = result.replacingOccurrences(
            of: #"(?m)^## 阅读地图\s*\n+(?:_?\*?可在这里补充全书问题、结构和阅读进度[。.]?\*?_?\s*\n*)?"#,
            with: "",
            options: .regularExpression
        )
        result = removeDuplicateBookTitle(in: result)
        result = result.replacingOccurrences(of: #"\n{3,}"#, with: "\n\n", options: .regularExpression)
        return result
    }

    private static func removeDuplicateBookTitle(in markdown: String) -> String {
        let lines = markdown.components(separatedBy: .newlines)
        guard let firstHeading = lines.firstIndex(where: { $0.hasPrefix("# ") }) else { return markdown }
        let title = lines[firstHeading].dropFirst(2).trimmingCharacters(in: .whitespacesAndNewlines)
        var seen = false
        return lines.compactMap { line in
            guard line.range(of: #"^#{1,6}\s+"#, options: .regularExpression) != nil else { return line }
            let headingTitle = line.replacingOccurrences(of: #"^#{1,6}\s+"#, with: "", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard headingTitle.localizedCaseInsensitiveCompare(title) == .orderedSame else { return line }
            if seen { return nil }
            seen = true
            return line
        }.joined(separator: "\n")
    }
}

actor ObsidianService {
    func createOrUpdateBookNote(
        vault: URL,
        folder: String,
        title: String,
        sourcePath: String?,
        outline: [OutlineEntry],
        preferredURL: URL? = nil
    ) throws -> URL {
        let manager = FileManager.default
        let notesDirectory = vault.appendingPathComponent(folder, isDirectory: true)
        try manager.createDirectory(at: notesDirectory, withIntermediateDirectories: true)
        let safeTitle = title.replacingOccurrences(of: #"[/\\:]"#, with: "-", options: .regularExpression)
        let defaultURL = notesDirectory.appendingPathComponent(safeTitle).appendingPathExtension("md")
        let vaultRoot = vault.standardizedFileURL.path + "/"
        let preferred = preferredURL?.standardizedFileURL
        let noteURL = preferred?.path.hasPrefix(vaultRoot) == true ? preferred! : defaultURL
        if !manager.fileExists(atPath: noteURL.path) {
            let markdown = ObsidianNoteBuilder.skeleton(title: title, sourcePath: sourcePath, outline: outline)
            try markdown.write(to: noteURL, atomically: true, encoding: .utf8)
        } else {
            let current = try String(contentsOf: noteURL, encoding: .utf8)
            let migrated = ObsidianNoteBuilder.migrateLegacyMarkdown(current)
            let synchronized = ObsidianNoteBuilder.ensureOutlineHeadings(in: migrated, outline: outline)
            if synchronized != current {
                try synchronized.write(to: noteURL, atomically: true, encoding: .utf8)
            }
        }
        return noteURL
    }

    func append(
        block: String,
        afterPage pageIndex: Int?,
        chapterTitle: String? = nil,
        to noteURL: URL
    ) throws {
        let stored = try String(contentsOf: noteURL, encoding: .utf8)
        let current = ObsidianNoteBuilder.migrateLegacyMarkdown(stored)
        if let marker = Self.deduplicationMarker(in: block), current.contains(marker) { return }
        if let payload = Self.payloadWithoutMarker(in: block), current.contains(payload) { return }
        if current.contains(block.trimmingCharacters(in: .whitespacesAndNewlines)) {
            if current != stored { try current.write(to: noteURL, atomically: true, encoding: .utf8) }
            return
        }
        let merged = ObsidianNoteBuilder.insert(
            block: block,
            into: current,
            afterPage: pageIndex,
            chapterTitle: chapterTitle
        )
        try merged.write(to: noteURL, atomically: true, encoding: .utf8)
        let saved = try String(contentsOf: noteURL, encoding: .utf8)
        let expected = block.trimmingCharacters(in: .whitespacesAndNewlines)
        guard expected.isEmpty || saved.contains(expected) else {
            throw NSError(
                domain: "ReadingCompanion.Obsidian",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: "笔记写入后校验失败，未标记为已加入；请重试。"]
            )
        }
    }

    func append(highlights: [HighlightRecord], outline: [OutlineEntry], pages: [PageText], to noteURL: URL) throws {
        let stored = try String(contentsOf: noteURL, encoding: .utf8)
        var markdown = ObsidianNoteBuilder.migrateLegacyMarkdown(stored)
        for highlight in highlights.sorted(by: {
            if $0.pageIndex == $1.pageIndex { return $0.createdAt < $1.createdAt }
            return $0.pageIndex < $1.pageIndex
        }) {
            let block = ObsidianNoteBuilder.highlightBlock(highlight)
            if let marker = Self.deduplicationMarker(in: block), markdown.contains(marker) { continue }
            if let payload = Self.payloadWithoutMarker(in: block), markdown.contains(payload) { continue }
            if markdown.contains(block.trimmingCharacters(in: .whitespacesAndNewlines)) { continue }
            markdown = ObsidianNoteBuilder.insert(
                block: block,
                into: markdown,
                afterPage: highlight.pageIndex,
                chapterTitle: OutlineNoteLocator.chapterTitle(
                    for: highlight.pageIndex,
                    sourceText: highlight.inlineText,
                    pageText: pages.first(where: { $0.pageIndex == highlight.pageIndex })?.text,
                    outline: outline
                )
            )
        }
        try markdown.write(to: noteURL, atomically: true, encoding: .utf8)
    }

    static func deduplicationMarker(in block: String) -> String? {
        block.split(separator: "\n", omittingEmptySubsequences: true)
            .map(String.init)
            .first { $0.hasPrefix("<!-- reading-companion:") && $0.hasSuffix("-->") }
    }

    static func payloadWithoutMarker(in block: String) -> String? {
        let lines = block.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard let markerIndex = lines.firstIndex(where: {
            $0.hasPrefix("<!-- reading-companion:") && $0.hasSuffix("-->")
        }) else { return nil }
        let payload = lines.enumerated()
            .filter { $0.offset != markerIndex }
            .map(\.element)
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return payload.isEmpty ? nil : payload
    }

}
