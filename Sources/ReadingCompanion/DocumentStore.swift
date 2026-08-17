import CryptoKit
import Foundation

struct DocumentState: Codable {
    var lastPageIndex = 0
    var bookmarks: [BookmarkRecord] = []
    var highlights: [HighlightRecord] = []
    var chats: [ChatTurn] = []
    var outline: [OutlineEntry]?
    var outlineRefinedByAI: Bool?
    var outlineWasManuallyEdited: Bool?
    var outlineAlgorithmVersion: Int?
    var chapterSummaries: [String: String]? = nil
    var chapterSummaryAlgorithmVersion: Int? = nil
    var answerCache: [String: ChatTurn]? = nil

    /// Drops only an automatically generated outline from an older parser.
    /// All reading data and deliberately edited manual outlines are preserved.
    mutating func invalidateAutomaticOutline(olderThan currentVersion: Int) -> Bool {
        guard outlineWasManuallyEdited != true,
              let outline,
              !outline.isEmpty,
              outlineAlgorithmVersion != currentVersion else { return false }
        self.outline = nil
        outlineRefinedByAI = false
        outlineWasManuallyEdited = false
        outlineAlgorithmVersion = currentVersion
        return true
    }

    /// Summaries are derived data and must never outlive the outline/parser
    /// contract that produced their chapter boundaries.
    mutating func invalidateChapterSummaries(olderThan currentVersion: Int) -> Bool {
        guard chapterSummaryAlgorithmVersion != currentVersion else { return false }
        chapterSummaries = nil
        chapterSummaryAlgorithmVersion = currentVersion
        return true
    }
}

struct CachedProject: Codable, Hashable, Identifiable {
    var sourcePath: String
    var title: String
    var lastOpenedAt: Date

    var id: String { sourcePath }
    var sourceURL: URL { URL(fileURLWithPath: sourcePath) }
    var isAvailable: Bool { FileManager.default.fileExists(atPath: sourcePath) }
}

actor DocumentStore {
    static let shared = DocumentStore()

    private let directory: URL
    private let fileManager: FileManager
    private var deletedProjectIdentifiers: Set<String> = []

    init(fileManager: FileManager = .default, directoryURL: URL? = nil) {
        self.fileManager = fileManager
        let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        directory = directoryURL ?? base.appendingPathComponent("ReadingCompanionOpen/Documents", isDirectory: true)
        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    func identifier(for url: URL) -> String {
        let source = url.standardizedFileURL.path.data(using: .utf8) ?? Data()
        return SHA256.hash(data: source).map { String(format: "%02x", $0) }.joined()
    }

    func load(for url: URL) -> DocumentState {
        guard !deletedProjectIdentifiers.contains(identifier(for: url)) else { return DocumentState() }
        let target = fileURL(for: url)
        guard let data = try? Data(contentsOf: target) else { return DocumentState() }
        return (try? JSONDecoder().decode(DocumentState.self, from: data)) ?? DocumentState()
    }

    func save(_ state: DocumentState, for url: URL) throws {
        guard !deletedProjectIdentifiers.contains(identifier(for: url)) else { return }
        let data = try JSONEncoder().encode(state)
        try data.write(to: fileURL(for: url), options: .atomic)
    }

    func loadMarkdown(for url: URL) -> [PageText]? {
        guard !deletedProjectIdentifiers.contains(identifier(for: url)) else { return nil }
        return loadCacheEnvelope(for: url)?.pages
    }

    func loadIndex(for url: URL, outline: [OutlineEntry]) -> [TextChunk]? {
        guard let envelope = loadCacheEnvelope(for: url),
              envelope.indexVersion == LocalIndex.cacheVersion,
              envelope.outlineSignature == outlineSignature(outline),
              let chunks = envelope.chunks,
              !chunks.isEmpty else { return nil }
        return chunks
    }

    func saveMarkdown(
        pages: [PageText],
        outline: [OutlineEntry],
        title: String,
        for url: URL
    ) throws {
        guard !deletedProjectIdentifiers.contains(identifier(for: url)) else { return }
        let compactPages = PDFMarkdownDocument.compactPages(pages)
        let fingerprint = sourceFingerprint(for: url)
        let envelope = PDFMarkdownCacheEnvelope(
            version: PDFMarkdownDocument.cacheVersion,
            sourceFingerprint: fingerprint,
            pages: compactPages,
            indexVersion: LocalIndex.cacheVersion,
            outlineSignature: outlineSignature(outline),
            chunks: LocalIndex.makeChunks(pages: compactPages, outline: outline)
        )
        try JSONEncoder().encode(envelope).write(to: markdownCacheURL(for: url), options: .atomic)
        let markdown = PDFMarkdownDocument.render(title: title, pages: compactPages, outline: outline)
        try markdown.write(to: markdownURL(for: url), atomically: true, encoding: .utf8)
    }

    func markdownURL(for url: URL) -> URL {
        directory.appendingPathComponent(identifier(for: url)).appendingPathExtension("md")
    }

    func registerProject(url: URL, title: String) {
        deletedProjectIdentifiers.remove(identifier(for: url))
        var projects = loadProjects()
        projects.removeAll { $0.sourcePath == url.standardizedFileURL.path }
        projects.insert(
            CachedProject(
                sourcePath: url.standardizedFileURL.path,
                title: title,
                lastOpenedAt: Date()
            ),
            at: 0
        )
        projects = Array(projects.prefix(80))
        guard let data = try? JSONEncoder().encode(projects) else { return }
        try? data.write(to: projectIndexURL, options: .atomic)
    }

    func cachedProjects() -> [CachedProject] {
        loadProjects().sorted { $0.lastOpenedAt > $1.lastOpenedAt }
    }

    /// Removes every app-owned artifact for one PDF while leaving the source
    /// PDF and any notes exported to Obsidian untouched.
    func deleteProject(for url: URL) throws {
        let sourceURL = url.standardizedFileURL
        let identifier = identifier(for: sourceURL)
        let artifacts = [
            directory.appendingPathComponent(identifier).appendingPathExtension("json"),
            directory.appendingPathComponent(identifier).appendingPathExtension("md"),
            directory.appendingPathComponent(identifier + ".markdown-cache.json")
        ]
        for artifact in artifacts where fileManager.fileExists(atPath: artifact.path) {
            try fileManager.removeItem(at: artifact)
        }

        var projects = loadProjects()
        projects.removeAll { $0.sourcePath == sourceURL.path }
        let data = try JSONEncoder().encode(projects)
        try data.write(to: projectIndexURL, options: .atomic)
        deletedProjectIdentifiers.insert(identifier)
    }

    private func loadProjects() -> [CachedProject] {
        guard let data = try? Data(contentsOf: projectIndexURL),
              let projects = try? JSONDecoder().decode([CachedProject].self, from: data) else {
            return []
        }
        return projects
    }

    private var projectIndexURL: URL {
        directory.appendingPathComponent("projects.json")
    }

    private func fileURL(for source: URL) -> URL {
        directory.appendingPathComponent(identifier(for: source)).appendingPathExtension("json")
    }

    private func markdownCacheURL(for source: URL) -> URL {
        directory.appendingPathComponent(identifier(for: source) + ".markdown-cache.json")
    }

    private func loadCacheEnvelope(for url: URL) -> PDFMarkdownCacheEnvelope? {
        guard let data = try? Data(contentsOf: markdownCacheURL(for: url)),
              let envelope = try? JSONDecoder().decode(PDFMarkdownCacheEnvelope.self, from: data),
              envelope.version == PDFMarkdownDocument.cacheVersion,
              envelope.sourceFingerprint == sourceFingerprint(for: url),
              !envelope.pages.isEmpty else { return nil }
        return envelope
    }

    private func outlineSignature(_ outline: [OutlineEntry]) -> String {
        let material = outline.enumerated().map { offset, entry in
            "\(offset)|\(entry.pageIndex)|\(entry.level)|\(entry.title)"
        }.joined(separator: "\u{1E}")
        return SHA256.hash(data: Data(material.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }

    private func sourceFingerprint(for url: URL) -> String {
        // Read live filesystem attributes instead of URL resource values. URL
        // instances can retain stale metadata after a PDF is replaced in place.
        let attributes = try? fileManager.attributesOfItem(atPath: url.path)
        let size = (attributes?[.size] as? NSNumber)?.int64Value ?? -1
        let modified = (attributes?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        return "\(size)|\(Int64(modified * 1_000))"
    }
}
