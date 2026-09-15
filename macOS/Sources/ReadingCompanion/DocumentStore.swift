import CryptoKit
import Foundation

struct DocumentState: Codable {
    var lastPageIndex = 0
    var reflowReadingPosition: ReflowReadingPosition? = nil
    var bookmarks: [BookmarkRecord] = []
    var highlights: [HighlightRecord] = []
    var chats: [ChatTurn] = []
    var outline: [OutlineEntry]?
    var outlineRefinedByAI: Bool?
    var outlineWasManuallyEdited: Bool?
    var outlineAlgorithmVersion: Int?
    var chapterSummaries: [String: String]? = nil
    var chapterSummaryAlgorithmVersion: Int? = nil
    var pageRangeSummaries: [PageRangeSummaryRecord]? = nil
    var answerCache: [String: ChatTurn]? = nil
    var bookCategory: BookCategory? = nil
    var characters: [BookCharacter]? = nil
    var characterHighlightsEnabled: Bool? = nil
    var ljgReadSkillEnabled: Bool? = nil

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
    var category: BookCategory? = nil
    var folderID: UUID? = nil
    var folderIDs: [UUID]? = nil
    var coverPath: String? = nil
    var coverVersion: Int? = nil

    var id: String { sourcePath }
    var sourceURL: URL { URL(fileURLWithPath: sourcePath) }
    var isAvailable: Bool { FileManager.default.fileExists(atPath: sourcePath) }
    var assignedFolderIDs: Set<UUID> {
        var result = Set(folderIDs ?? [])
        if let folderID { result.insert(folderID) }
        return result
    }
}

struct BookshelfFolder: Codable, Hashable, Identifiable {
    var id = UUID()
    var title: String
}

private struct BookshelfIndex: Codable {
    var projects: [CachedProject]
    var folders: [BookshelfFolder]
    var categoryPolicyVersion: Int? = nil
}

enum BookshelfOpenDestination: Equatable {
    case currentWindow
    case newWindow
    case alreadyOpen
}

enum BookshelfOpenPolicy {
    static func destination(currentDocumentURL: URL?, project: CachedProject) -> BookshelfOpenDestination {
        guard let currentDocumentURL else { return .currentWindow }
        if currentDocumentURL.standardizedFileURL.path == project.sourceURL.standardizedFileURL.path {
            return .alreadyOpen
        }
        return .newWindow
    }
}

actor DocumentStore {
    static let shared = DocumentStore()
    private static let categoryPolicyVersion = 1

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
        var library = loadLibrary()
        migrateCategoryPolicyIfNeeded(&library)
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

    @discardableResult
    func registerProject(
        url: URL,
        title: String,
        category: BookCategory? = nil,
        coverPNGData: Data? = nil
    ) -> CachedProject {
        deletedProjectIdentifiers.remove(identifier(for: url))
        var library = loadLibrary()
        migrateCategoryPolicyIfNeeded(&library)
        let sourcePath = url.standardizedFileURL.path
        let existing = library.projects.first { $0.sourcePath == sourcePath }
        let coverURL = coverURL(for: url)
        let existingCoverIsCurrent = existing?.coverVersion == BookCoverRenderer.version
            && fileManager.fileExists(atPath: coverURL.path)
        if let coverPNGData, !existingCoverIsCurrent {
            try? coverPNGData.write(to: coverURL, options: .atomic)
        }
        let project = CachedProject(
            sourcePath: sourcePath,
            title: title,
            lastOpenedAt: Date(),
            category: existing?.category ?? category,
            folderID: existing?.folderID,
            folderIDs: existing?.folderIDs,
            coverPath: fileManager.fileExists(atPath: coverURL.path) ? coverURL.path : existing?.coverPath,
            coverVersion: fileManager.fileExists(atPath: coverURL.path)
                ? (existingCoverIsCurrent ? existing?.coverVersion : BookCoverRenderer.version)
                : existing?.coverVersion
        )
        library.projects.removeAll { $0.sourcePath == sourcePath }
        library.projects.insert(project, at: 0)
        library.projects = Array(library.projects.prefix(500))
        saveLibrary(library)
        return project
    }

    func updateProjectCover(url: URL, coverPNGData: Data) {
        var library = loadLibrary()
        let sourcePath = url.standardizedFileURL.path
        guard let index = library.projects.firstIndex(where: { $0.sourcePath == sourcePath }) else { return }
        let target = coverURL(for: url)
        guard (try? coverPNGData.write(to: target, options: .atomic)) != nil else { return }
        library.projects[index].coverPath = target.path
        library.projects[index].coverVersion = BookCoverRenderer.version
        saveLibrary(library)
    }

    func cachedProjects() -> [CachedProject] {
        var library = loadLibrary()
        migrateCategoryPolicyIfNeeded(&library)
        return library.projects.sorted { $0.lastOpenedAt > $1.lastOpenedAt }
    }

    func bookshelfFolders() -> [BookshelfFolder] {
        loadLibrary().folders.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }

    @discardableResult
    func createBookshelfFolder(title: String) -> BookshelfFolder? {
        let clean = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return nil }
        var library = loadLibrary()
        if let existing = library.folders.first(where: { $0.title.localizedCaseInsensitiveCompare(clean) == .orderedSame }) {
            return existing
        }
        let folder = BookshelfFolder(title: clean)
        library.folders.append(folder)
        saveLibrary(library)
        return folder
    }

    func renameBookshelfFolder(_ folder: BookshelfFolder, title: String) {
        let clean = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return }
        var library = loadLibrary()
        guard let index = library.folders.firstIndex(where: { $0.id == folder.id }) else { return }
        library.folders[index].title = clean
        saveLibrary(library)
    }

    func deleteBookshelfFolder(_ folder: BookshelfFolder) {
        var library = loadLibrary()
        library.folders.removeAll { $0.id == folder.id }
        for index in library.projects.indices {
            var memberships = library.projects[index].assignedFolderIDs
            memberships.remove(folder.id)
            library.projects[index].folderID = nil
            library.projects[index].folderIDs = Array(memberships)
        }
        saveLibrary(library)
    }

    func moveProject(_ project: CachedProject, to folderID: UUID?) {
        var library = loadLibrary()
        guard let index = library.projects.firstIndex(where: { $0.sourcePath == project.sourcePath }) else { return }
        library.projects[index].folderID = folderID
        library.projects[index].folderIDs = folderID.map { [$0] } ?? []
        saveLibrary(library)
    }

    func setProjects(_ projects: [CachedProject], in folderID: UUID, included: Bool) {
        guard !projects.isEmpty else { return }
        var library = loadLibrary()
        let paths = Set(projects.map(\.sourcePath))
        for index in library.projects.indices where paths.contains(library.projects[index].sourcePath) {
            var memberships = library.projects[index].assignedFolderIDs
            if included { memberships.insert(folderID) } else { memberships.remove(folderID) }
            library.projects[index].folderID = nil
            library.projects[index].folderIDs = Array(memberships)
        }
        saveLibrary(library)
    }

    func setProjects(_ projects: [CachedProject], category: BookCategory) {
        guard !projects.isEmpty else { return }
        var library = loadLibrary()
        migrateCategoryPolicyIfNeeded(&library)
        let paths = Set(projects.map(\.sourcePath))
        for index in library.projects.indices where paths.contains(library.projects[index].sourcePath) {
            library.projects[index].category = category
            let sourceURL = library.projects[index].sourceURL
            let stateURL = fileURL(for: sourceURL)
            let stateData = try? Data(contentsOf: stateURL)
            var state = stateData.flatMap { try? JSONDecoder().decode(DocumentState.self, from: $0) }
                ?? DocumentState()
            state.bookCategory = category
            if let updated = try? JSONEncoder().encode(state) {
                try? updated.write(to: stateURL, options: .atomic)
            }
        }
        saveLibrary(library)
    }

    /// Removes every app-owned artifact for one source document while leaving
    /// the original book and any notes exported to Obsidian untouched.
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

        let cover = coverURL(for: sourceURL)
        if fileManager.fileExists(atPath: cover.path) { try fileManager.removeItem(at: cover) }
        var library = loadLibrary()
        library.projects.removeAll { $0.sourcePath == sourceURL.path }
        try JSONEncoder().encode(library).write(to: projectIndexURL, options: .atomic)
        deletedProjectIdentifiers.insert(identifier)
    }

    private func loadLibrary() -> BookshelfIndex {
        guard let data = try? Data(contentsOf: projectIndexURL) else {
            return BookshelfIndex(
                projects: [],
                folders: [],
                categoryPolicyVersion: Self.categoryPolicyVersion
            )
        }
        if let library = try? JSONDecoder().decode(BookshelfIndex.self, from: data) {
            return library
        }
        if let legacyProjects = try? JSONDecoder().decode([CachedProject].self, from: data) {
            return BookshelfIndex(projects: legacyProjects, folders: [])
        }
        return BookshelfIndex(
            projects: [],
            folders: [],
            categoryPolicyVersion: Self.categoryPolicyVersion
        )
    }

    private func migrateCategoryPolicyIfNeeded(_ library: inout BookshelfIndex) {
        guard (library.categoryPolicyVersion ?? 0) < Self.categoryPolicyVersion else { return }
        for index in library.projects.indices {
            library.projects[index].category = nil
            let stateURL = fileURL(for: library.projects[index].sourceURL)
            guard let data = try? Data(contentsOf: stateURL),
                  var state = try? JSONDecoder().decode(DocumentState.self, from: data) else { continue }
            state.bookCategory = nil
            if let updated = try? JSONEncoder().encode(state) {
                try? updated.write(to: stateURL, options: .atomic)
            }
        }
        library.categoryPolicyVersion = Self.categoryPolicyVersion
        saveLibrary(library)
    }

    private func saveLibrary(_ library: BookshelfIndex) {
        guard let data = try? JSONEncoder().encode(library) else { return }
        try? data.write(to: projectIndexURL, options: .atomic)
    }

    private var projectIndexURL: URL {
        directory.appendingPathComponent("projects.json")
    }

    private func coverURL(for source: URL) -> URL {
        directory.appendingPathComponent(identifier(for: source) + ".cover.png")
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
        // instances can retain stale metadata after a source is replaced in place.
        let attributes = try? fileManager.attributesOfItem(atPath: url.path)
        let size = (attributes?[.size] as? NSNumber)?.int64Value ?? -1
        let modified = (attributes?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        return "\(size)|\(Int64(modified * 1_000))"
    }
}
