import AppKit
import Combine
import CryptoKit
import PDFKit
import SwiftUI
import UniformTypeIdentifiers

@MainActor
final class ReaderModel: ObservableObject {
    @Published var document: PDFDocument?
    @Published var documentURL: URL?
    @Published var documentTitle = "未打开文档"
    @Published var selectedSidebar: SidebarSection = .outline
    @Published var outline: [OutlineEntry] = []
    @Published var bookmarks: [BookmarkRecord] = []
    @Published var highlights: [HighlightRecord] = []
    @Published var selectedHighlightIDs: Set<UUID> = []
    @Published var searchResults: [SearchRecord] = []
    @Published var searchQuery = ""
    @Published var displayMode: ReaderDisplayMode = .single
    @Published var fitMode: ReaderFitMode = .page
    @Published var zoomScale = 1.0
    @Published var zoomLocked = false
    @Published var highlightModeEnabled = false
    @Published var highlightTint: HighlightTint = HighlightTint(
        rawValue: UserDefaults.standard.string(forKey: "highlightTint") ?? ""
    ) ?? .yellow {
        didSet { UserDefaults.standard.set(highlightTint.rawValue, forKey: "highlightTint") }
    }
    @Published var currentPageIndex = 0
    @Published var navigationTarget: Int?
    @Published var leftSidebarVisible = true
    @Published var assistantVisible = true
    @Published var statusMessage = "打开一份 PDF 开始阅读"
    @Published var noteFeedbackMessage: String?
    @Published var errorMessage: String?
    @Published var pendingAnnotation: HighlightRecord?
    @Published var chatTurns: [ChatTurn] = []
    @Published var textChunks: [TextChunk] = []
    @Published var indexingProgress = 0.0
    @Published var indexingStatus = "等待文档"
    @Published var outlineStatus = "等待文档"
    @Published var isLocatingTOC = false
    @Published var isRefiningOutline = false
    @Published var enhancedTOCInstalled = EnhancedTOCService.isInstalled
    @Published var outlineRefinedByAI = false
    @Published var outlineWasManuallyEdited = false
    @Published var isAnswering = false
    @Published var isSearchingWeb = false
    @Published var isExportingChatNote = false
    @Published var chapterSummaries: [String: String] = [:]
    @Published var generatingChapterSummaryKeys: Set<String> = []
    @Published var assistantDraft = ""
    @Published var assistantUsesWebSearch = false
    @Published var assistantUsesWholeBook = false
    @Published var aiProvider = AIProvider(
        rawValue: UserDefaults.standard.string(forKey: "aiProvider") ?? ""
    ) ?? .openAI
    @Published var aiModel = UserDefaults.standard.string(forKey: "aiModel") ?? "" {
        didSet { UserDefaults.standard.set(aiModel, forKey: "aiModel") }
    }
    @Published var aiReadingDepth = AIReadingDepth(
        rawValue: UserDefaults.standard.string(forKey: "aiReadingDepth") ?? ""
    ) ?? .balanced {
        didSet { UserDefaults.standard.set(aiReadingDepth.rawValue, forKey: "aiReadingDepth") }
    }
    @Published var availableAIModels: [String] = []
    @Published var catalogAIModels: [String] = []
    @Published var isLoadingAIModels = false
    @Published var closeSettingsAfterValidation = false
    @Published var apiKeyStatus = "尚未连接 AI 服务"
    @Published var hasActiveAPIKey = false
    @Published var hasStoredAPIKey = false
    @Published var rememberAPIKey = UserDefaults.standard.object(forKey: "rememberAPIKey") == nil
        ? true
        : UserDefaults.standard.bool(forKey: "rememberAPIKey")
    @Published var customRelayEnabled = UserDefaults.standard.bool(forKey: CustomRelayConfiguration.enabledKey)
    @Published var customRelayBaseURL = UserDefaults.standard.string(forKey: CustomRelayConfiguration.baseURLKey) ?? ""
    @Published var customRelayModel = UserDefaults.standard.string(forKey: CustomRelayConfiguration.modelKey) ?? ""
    @Published var obsidianVaultPath = UserDefaults.standard.string(forKey: "obsidianVaultPath") ?? ""
    @Published var obsidianFolder = UserDefaults.standard.string(forKey: "obsidianFolder") ?? "Reading Companion" {
        didSet { UserDefaults.standard.set(obsidianFolder, forKey: "obsidianFolder") }
    }
    @Published var obsidianNoteURL: URL?
    @Published var cachedProjects: [CachedProject] = []

    private let openAI = OpenAIService()
    private let enhancedTOC = EnhancedTOCService()
    private let apiKeyStore = APIKeyStore()
    private let obsidian = ObsidianService()
    private var indexingTask: Task<Void, Never>?
    private var answerTask: Task<Void, Never>?
    private var activeAnswerRequestID: UUID?
    private var pendingQuestionTurnID: UUID?
    private var pendingQuestionText: String?
    private var pendingAnswerUsesWebSearch = false
    private var pendingAnswerUsesWholeBook = false
    private var pendingAnswerContextScope: ReadingContextScope = .standard
    private var derivedCacheNeedsSave = false
    private var pageTexts: [PageText] = []
    private var tocPageIndices: [Int] = []
    private var outlineRecognitionSource = "自动"
    private var preparedQuestionBase: String?
    private var pendingContextScope: ReadingContextScope = .standard
    private var answerCache: [String: ChatTurn] = [:]
    private var sessionAPIKey: String?
    private var aiValidationID = UUID()
    private let outlineAlgorithmVersion = 13
    private let chapterSummaryAlgorithmVersion = 4
    private struct HighlightChange {
        var before: [HighlightRecord]
        var after: [HighlightRecord]
    }
    private struct ChatNoteGroup {
        var turns: [ChatTurn]
        var pageReferences: Set<Int>
        let anchorPageIndex: Int?
        let chapterTitle: String?
    }
    private struct ChatNoteWrite: Sendable {
        let block: String
        let anchorPageIndex: Int?
        let chapterTitle: String?
    }
    private var highlightUndoStack: [HighlightChange] = []
    private var highlightRedoStack: [HighlightChange] = []

    var pageCount: Int { document?.pageCount ?? 0 }
    var suggestedTOCStartPDFPage: Int {
        min(max((tocPageIndices.min() ?? currentPageIndex) + 1, 1), max(pageCount, 1))
    }
    var suggestedTOCEndPDFPage: Int {
        min(max((tocPageIndices.max() ?? currentPageIndex) + 1, 1), max(pageCount, 1))
    }
    var canUndoHighlight: Bool { !highlightUndoStack.isEmpty }
    var canRedoHighlight: Bool { !highlightRedoStack.isEmpty }
    var aiModelChoices: [String] {
        availableAIModels.sorted()
    }

    init() {
        customRelayEnabled = aiProvider == .customRelay
        configureDefaultObsidianDirectory()
        availableAIModels = UserDefaults.standard.stringArray(
            forKey: "availableAIModels.\(aiProvider.storageAccount)"
        ) ?? []
        catalogAIModels = UserDefaults.standard.stringArray(
            forKey: "catalogAIModels.\(aiProvider.storageAccount)"
        ) ?? []
        if !availableAIModels.isEmpty, !availableAIModels.contains(aiModel) {
            aiModel = preferredModel(from: availableAIModels) ?? availableAIModels[0]
        }
        if rememberAPIKey {
            apiKeyStatus = "正在恢复本机保存的 \(aiProvider.rawValue) API Key…"
            restoreSavedAPIKey(showErrors: false)
        } else {
            apiKeyStatus = "API Key 仅在本次运行中使用"
        }
        refreshCachedProjects()
    }

    private func configureDefaultObsidianDirectory() {
        let defaults = UserDefaults.standard
        if obsidianFolder.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            obsidianFolder = "Reading Companion"
        }
        if obsidianVaultPath.isEmpty, let vault = ObsidianVaultRegistry.preferredVault() {
            obsidianVaultPath = vault.path
            defaults.set(vault.path, forKey: "obsidianVaultPath")
        }
        guard !obsidianVaultPath.isEmpty else { return }
        let directory = URL(fileURLWithPath: obsidianVaultPath, isDirectory: true)
            .appendingPathComponent(obsidianFolder, isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    func presentOpenPanel() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.pdf]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.message = "选择要伴读的 PDF"
        if panel.runModal() == .OK, let url = panel.url {
            open(url)
        }
    }

    func open(_ url: URL) {
        guard url.pathExtension.lowercased() == "pdf" else {
            errorMessage = "目前只支持 PDF 文件。"
            return
        }
        guard let loaded = PDFDocument(url: url) else {
            errorMessage = "无法打开这份 PDF。文件可能损坏、受密码保护或无读取权限。原文件没有被修改。"
            return
        }
        cancelActiveAnswer(restoreQuestion: false)
        indexingTask?.cancel()
        document = loaded
        documentURL = url
        pageTexts = []
        tocPageIndices = []
        textChunks = []
        derivedCacheNeedsSave = false
        selectedHighlightIDs = []
        chapterSummaries = [:]
        generatingChapterSummaryKeys = []
        highlightUndoStack = []
        highlightRedoStack = []
        outlineRefinedByAI = false
        outlineWasManuallyEdited = false
        preparedQuestionBase = nil
        isRefiningOutline = false
        documentTitle = loaded.documentAttributes?[PDFDocumentAttribute.titleAttribute] as? String
            ?? url.deletingPathExtension().lastPathComponent
        outline = OutlineBuilder.entries(for: loaded)
        if outline.isEmpty {
            outlineStatus = "正在定位目录…"
        } else {
            outlineStatus = "PDF 自带目录"
        }
        statusMessage = "文档已打开，正在建立全文索引"

        Task {
            await DocumentStore.shared.registerProject(url: url, title: documentTitle)
            var state = await DocumentStore.shared.load(for: url)
            let outlineInvalidated = state.invalidateAutomaticOutline(olderThan: outlineAlgorithmVersion)
            let summariesInvalidated = state.invalidateChapterSummaries(olderThan: chapterSummaryAlgorithmVersion)
            if outlineInvalidated || summariesInvalidated {
                try? await DocumentStore.shared.save(state, for: url)
            }
            let projects = await DocumentStore.shared.cachedProjects()
            await MainActor.run {
                guard documentURL?.standardizedFileURL == url.standardizedFileURL else { return }
                cachedProjects = projects
                currentPageIndex = min(state.lastPageIndex, max(loaded.pageCount - 1, 0))
                navigationTarget = currentPageIndex
                bookmarks = state.bookmarks
                highlights = state.highlights
                chatTurns = state.chats
                chapterSummaries = state.chapterSummaries ?? [:]
                answerCache = state.answerCache ?? [:]
                if state.outlineWasManuallyEdited == true,
                   let savedOutline = state.outline,
                   !savedOutline.isEmpty {
                    outline = savedOutline
                    outlineWasManuallyEdited = true
                    outlineStatus = "手动目录已恢复"
                } else if state.outlineAlgorithmVersion == outlineAlgorithmVersion,
                          let savedOutline = state.outline,
                          !savedOutline.isEmpty {
                    outline = savedOutline
                    outlineRefinedByAI = state.outlineRefinedByAI == true
                    outlineStatus = "目录已恢复"
                }
                startIndexing()
            }
        }
    }

    func refreshCachedProjects() {
        Task {
            let projects = await DocumentStore.shared.cachedProjects()
            await MainActor.run { cachedProjects = projects }
        }
    }

    func deleteCachedProject(_ project: CachedProject) {
        let url = project.sourceURL.standardizedFileURL
        if documentURL?.standardizedFileURL.path == url.path {
            resetOpenDocument()
        }
        Task {
            do {
                try await DocumentStore.shared.deleteProject(for: url)
                let projects = await DocumentStore.shared.cachedProjects()
                await MainActor.run {
                    cachedProjects = projects
                    statusMessage = "已删除“\(project.title)”的缓存；可重新导入 PDF"
                }
            } catch {
                await MainActor.run {
                    errorMessage = "无法删除项目缓存：\(error.localizedDescription)"
                }
            }
        }
    }

    private func resetOpenDocument() {
        cancelActiveAnswer(restoreQuestion: false)
        indexingTask?.cancel()
        indexingTask = nil
        document = nil
        documentURL = nil
        documentTitle = "未打开文档"
        currentPageIndex = 0
        navigationTarget = nil
        outline = []
        bookmarks = []
        highlights = []
        selectedHighlightIDs = []
        chatTurns = []
        searchResults = []
        searchQuery = ""
        textChunks = []
        pageTexts = []
        tocPageIndices = []
        chapterSummaries = [:]
        generatingChapterSummaryKeys = []
        answerCache = [:]
        assistantDraft = ""
        preparedQuestionBase = nil
        pendingAnnotation = nil
        obsidianNoteURL = nil
        derivedCacheNeedsSave = false
        indexingProgress = 0
        indexingStatus = "等待文档"
        outlineStatus = "等待文档"
        statusMessage = "项目缓存已删除，可重新导入 PDF"
    }

    func acceptDroppedURLs(_ providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first(where: { $0.hasItemConformingToTypeIdentifier(UTType.pdf.identifier) }) else {
            return false
        }
        provider.loadItem(forTypeIdentifier: UTType.pdf.identifier, options: nil) { [weak self] item, _ in
            let url = item as? URL ?? (item as? Data).flatMap { URL(dataRepresentation: $0, relativeTo: nil) }
            guard let url else { return }
            Task { @MainActor in self?.open(url) }
        }
        return true
    }

    func go(to pageIndex: Int) {
        guard pageCount > 0 else { return }
        let bounded = min(max(pageIndex, 0), pageCount - 1)
        currentPageIndex = bounded
        navigationTarget = bounded
        persist()
    }

    func changePage(by delta: Int) { go(to: currentPageIndex + delta) }

    func didNavigate(to pageIndex: Int) {
        guard pageIndex != currentPageIndex else { return }
        currentPageIndex = pageIndex
        persist()
    }

    func toggleBookmark() {
        guard document != nil else { return }
        if let existing = bookmarks.first(where: { $0.pageIndex == currentPageIndex }) {
            bookmarks.removeAll { $0.id == existing.id }
            statusMessage = "已取消第 \(currentPageIndex + 1) 页书签"
            persist()
            return
        }
        selectedSidebar = .bookmarks
        bookmarks.append(BookmarkRecord(title: "第 \(currentPageIndex + 1) 页", pageIndex: currentPageIndex))
        statusMessage = "已添加第 \(currentPageIndex + 1) 页书签"
        persist()
    }

    func addBookmark() {
        guard !bookmarks.contains(where: { $0.pageIndex == currentPageIndex }) else {
            selectedSidebar = .bookmarks
            statusMessage = "本页已有书签"
            return
        }
        toggleBookmark()
    }

    func updateBookmark(_ bookmark: BookmarkRecord, title: String) {
        updateBookmark(id: bookmark.id, title: title)
    }

    func updateBookmark(id: UUID, title: String) {
        guard let index = bookmarks.firstIndex(where: { $0.id == id }) else { return }
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        bookmarks[index].title = trimmed.isEmpty ? "第 \(bookmarks[index].pageIndex + 1) 页" : trimmed
        persist()
    }

    func setBookmarkTitleDraft(id: UUID, title: String) {
        guard let index = bookmarks.firstIndex(where: { $0.id == id }) else { return }
        bookmarks[index].title = title
        persist()
    }

    func removeBookmark(_ bookmark: BookmarkRecord) {
        bookmarks.removeAll { $0.id == bookmark.id }
        persist()
    }

    @discardableResult
    func recordHighlight(
        text: String,
        fragments: [HighlightFragment],
        tint: HighlightTint? = nil
    ) -> HighlightRecord? {
        guard let first = fragments.first else { return nil }
        let selectedTint = tint ?? highlightTint
        let record = HighlightRecord(
            text: HighlightTextNormalizer.inline(text),
            pageIndex: first.pageIndex,
            bounds: first.bounds,
            tint: selectedTint,
            fragments: fragments
        )
        let before = highlights
        highlights.append(record)
        rememberHighlightChange(from: before)
        statusMessage = fragments.count > 1
            ? "已添加一条跨行划线"
            : "已添加划线"
        persist()
        scheduleOCRCorrection(for: record.id, original: text, fragments: fragments)
        return record
    }

    @discardableResult
    func recordAnnotation(text: String, fragments: [HighlightFragment], note: String? = nil) -> HighlightRecord? {
        guard let first = fragments.first else { return nil }
        let record = HighlightRecord(
            text: HighlightTextNormalizer.inline(text),
            pageIndex: first.pageIndex,
            bounds: first.bounds,
            tint: .yellow,
            note: note?.trimmingCharacters(in: .whitespacesAndNewlines),
            fragments: fragments,
            kind: .annotation
        )
        let before = highlights
        highlights.append(record)
        rememberHighlightChange(from: before)
        statusMessage = "批注已添加"
        persist()
        scheduleOCRCorrection(for: record.id, original: text, fragments: fragments)
        return record
    }

    private func scheduleOCRCorrection(for id: UUID, original: String, fragments: [HighlightFragment]) {
        guard let document else { return }
        Task { @MainActor [weak self] in
            guard let recognized = await OCRService.recognizeSelection(fragments: fragments, from: document),
                  let corrected = OCRSelectionTextCorrector.preferred(original: original, recognized: recognized),
                  let self,
                  let index = self.highlights.firstIndex(where: { $0.id == id }),
                  self.highlights[index].text != corrected else { return }
            self.highlights[index].text = corrected
            self.persist()
        }
    }

    func convertHighlightToAnnotation(id: UUID, note: String?) {
        guard let index = highlights.firstIndex(where: { $0.id == id }) else { return }
        let before = highlights
        highlights[index].kind = .annotation
        highlights[index].note = note?.trimmingCharacters(in: .whitespacesAndNewlines)
        rememberHighlightChange(from: before)
        pendingAnnotation = nil
        statusMessage = "划线已改为批注"
        persist()
    }

    func recolorHighlight(id: UUID, tint: HighlightTint) {
        guard let index = highlights.firstIndex(where: { $0.id == id }) else { return }
        let before = highlights
        highlights[index].tint = tint
        highlights[index].kind = .highlight
        highlightTint = tint
        rememberHighlightChange(from: before)
        statusMessage = "划线颜色已更新"
        persist()
    }

    func updateAnnotation(_ record: HighlightRecord, note: String?) {
        guard let index = highlights.firstIndex(where: { $0.id == record.id }) else { return }
        highlights[index].note = note?.trimmingCharacters(in: .whitespacesAndNewlines)
        pendingAnnotation = nil
        persist()
    }

    func updateAnnotation(id: UUID, note: String?) {
        guard let record = highlights.first(where: { $0.id == id }) else { return }
        updateAnnotation(record, note: note)
        statusMessage = "批注已保存"
    }

    func updateHighlight(_ record: HighlightRecord, note: String?, tint: HighlightTint) {
        guard let index = highlights.firstIndex(where: { $0.id == record.id }) else { return }
        let before = highlights
        highlights[index].note = note?.trimmingCharacters(in: .whitespacesAndNewlines)
        highlights[index].tint = tint
        rememberHighlightChange(from: before)
        pendingAnnotation = nil
        statusMessage = record.markKind == .annotation ? "批注已保存" : "划线修改已保存"
        persist()
    }

    func editHighlight(_ record: HighlightRecord) {
        pendingAnnotation = highlights.first(where: { $0.id == record.id }) ?? record
    }

    func deleteHighlight(_ record: HighlightRecord) {
        let before = highlights
        highlights.removeAll { $0.id == record.id }
        selectedHighlightIDs.remove(record.id)
        rememberHighlightChange(from: before)
        pendingAnnotation = nil
        persist()
    }

    func deleteHighlights(ids: Set<UUID>) {
        guard !ids.isEmpty else { return }
        let before = highlights
        highlights.removeAll { ids.contains($0.id) }
        selectedHighlightIDs.subtract(ids)
        rememberHighlightChange(from: before)
        statusMessage = "已删除 \(ids.count) 条划线"
        persist()
    }

    func deleteSelectedChats() {
        let ids = Set(chatTurns.filter {
            $0.selectedForNotes
        }.map(\.id))
        guard !ids.isEmpty else {
            errorMessage = "请先选择要删除的对话。"
            return
        }
        chatTurns.removeAll { ids.contains($0.id) }
        statusMessage = "已删除 \(ids.count) 条对话"
        persist()
    }

    func undoHighlightChange() {
        guard let change = highlightUndoStack.popLast() else { return }
        highlightRedoStack.append(change)
        highlights = change.before
        pendingAnnotation = nil
        statusMessage = "已撤销划线修改"
        persist()
    }

    func redoHighlightChange() {
        guard let change = highlightRedoStack.popLast() else { return }
        highlightUndoStack.append(change)
        highlights = change.after
        pendingAnnotation = nil
        statusMessage = "已重做划线修改"
        persist()
    }

    private func rememberHighlightChange(from before: [HighlightRecord]) {
        guard before != highlights else { return }
        highlightUndoStack.append(HighlightChange(before: before, after: highlights))
        if highlightUndoStack.count > 30 { highlightUndoStack.removeFirst() }
        highlightRedoStack.removeAll()
    }

    func performSearch() {
        guard let document, !searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            searchResults = []
            return
        }
        let selections = document.findString(searchQuery, withOptions: .caseInsensitive)
        searchResults = selections.compactMap { selection in
            guard let page = selection.pages.first else { return nil }
            let index = document.index(for: page)
            return SearchRecord(text: selection.string ?? searchQuery, pageIndex: index)
        }
        statusMessage = "找到 \(searchResults.count) 处结果"
    }

    func persist() {
        guard let documentURL else { return }
        let shouldSaveDerivedCache = derivedCacheNeedsSave && !pageTexts.isEmpty
        if shouldSaveDerivedCache { derivedCacheNeedsSave = false }
        let state = DocumentState(
            lastPageIndex: currentPageIndex,
            bookmarks: bookmarks,
            highlights: highlights,
            chats: chatTurns,
            outline: outline,
            outlineRefinedByAI: outlineRefinedByAI,
            outlineWasManuallyEdited: outlineWasManuallyEdited,
            // Version every automatic outline, including the local parser.
            // Older builds only versioned AI results, so broken local outlines
            // could survive an algorithm upgrade indefinitely.
            outlineAlgorithmVersion: outlineWasManuallyEdited ? nil : outlineAlgorithmVersion,
            chapterSummaries: chapterSummaries,
            chapterSummaryAlgorithmVersion: chapterSummaryAlgorithmVersion,
            answerCache: answerCache
        )
        Task {
            do {
                try await DocumentStore.shared.save(state, for: documentURL)
                if shouldSaveDerivedCache {
                    try await DocumentStore.shared.saveMarkdown(pages: pageTexts, outline: outline, title: documentTitle, for: documentURL)
                }
            }
            catch {
                await MainActor.run {
                    if shouldSaveDerivedCache { derivedCacheNeedsSave = true }
                    errorMessage = "阅读记录保存失败：\(error.localizedDescription)"
                }
            }
        }
    }

    func startIndexing() {
        indexingTask?.cancel()
        guard let document else { return }
        indexingProgress = 0
        indexingStatus = "正在提取文本与 OCR…"
        indexingTask = Task { @MainActor [weak self] in
            guard let self else { return }
            if let documentURL,
               let cachedPages = await DocumentStore.shared.loadMarkdown(for: documentURL) {
                let cachedChunks = await DocumentStore.shared.loadIndex(for: documentURL, outline: self.outline)
                self.installIndexedPages(
                    cachedPages,
                    cachedChunks: cachedChunks,
                    source: cachedChunks == nil ? "OCR 缓存" : "OCR / 索引缓存"
                )
                if cachedChunks == nil {
                    try? await DocumentStore.shared.saveMarkdown(
                        pages: cachedPages,
                        outline: self.outline,
                        title: self.documentTitle,
                        for: documentURL
                    )
                }
                return
            }
            let pages = await OCRService.extract(from: document) { completed, total in
                self.indexingProgress = total == 0 ? 0 : Double(completed) / Double(total)
                self.indexingStatus = "正在处理第 \(completed) / \(total) 页"
            }
            guard !Task.isCancelled else { return }
            let compactPages = PDFMarkdownDocument.compactPages(pages)
            self.installIndexedPages(compactPages, cachedChunks: nil, source: "PDF → Markdown")
            if let documentURL {
                try? await DocumentStore.shared.saveMarkdown(
                    pages: compactPages,
                    outline: self.outline,
                    title: self.documentTitle,
                    for: documentURL
                )
            }
        }
    }

    private func installIndexedPages(
        _ pages: [PageText],
        cachedChunks: [TextChunk]?,
        source: String
    ) {
            self.pageTexts = pages
            self.tocPageIndices = TOCPageDetector.locate(in: pages)
            self.textChunks = cachedChunks ?? LocalIndex.makeChunks(pages: pages, outline: self.outline)
            self.indexingProgress = 1
            self.indexingStatus = "全书索引已就绪 · \(source) · \(self.textChunks.count) 个片段"
            if self.outlineWasManuallyEdited {
                self.outlineStatus = "手动目录"
            } else if self.tocPageIndices.isEmpty {
                self.outlineStatus = self.outline.isEmpty
                    ? "未找到目录页"
                    : (self.outlineRefinedByAI ? "目录已恢复" : "PDF 自带目录")
            } else if !self.outlineRefinedByAI {
                self.outlineStatus = "目录页 \(self.tocPageDescription)"
            }
            // 目录 AI 只由用户点击触发，避免每次打开文档或验证 Key 都产生费用。
    }

    func refineOutlineWithAI(showErrors: Bool = true) {
        guard !pageTexts.isEmpty else {
            if showErrors { errorMessage = "全文文本还在提取或 OCR，请等待右侧状态显示“全书索引已就绪”后再试。" }
            return
        }
        if tocPageIndices.isEmpty {
            tocPageIndices = TOCPageDetector.locate(in: pageTexts)
        }
        guard !tocPageIndices.isEmpty else {
            outlineStatus = "未找到目录页"
            if showErrors { errorMessage = "没有定位到可信目录页。请确认 PDF 中有印刷目录页，并检查目录页文字能否被选中或被 OCR 识别。" }
            return
        }
        guard let apiKey = sessionAPIKey, !apiKey.isEmpty else {
            outlineStatus = "目录页 \(tocPageDescription) · 待连接 AI"
            if showErrors { errorMessage = "请先在“设置 > AI”中验证 API Key。可以长期保存在本机应用数据中，或选择仅用于本次运行。" }
            return
        }
        guard !isRefiningOutline else { return }
        isRefiningOutline = true
        outlineStatus = "正在识别目录…"
        let pages = pageTexts
        let directoryPages = tocPageIndices
        Task {
            do {
                let result = try await openAI.generateOutlineFromTOC(
                    pages: pages,
                    tocPageIndices: directoryPages,
                    model: aiModel,
                    apiKey: apiKey,
                    provider: aiProvider
                )
                await MainActor.run {
                    outline = result
                    chapterSummaries.removeAll()
                    generatingChapterSummaryKeys.removeAll()
                    outlineRefinedByAI = true
                    outlineWasManuallyEdited = false
                    isRefiningOutline = false
                    outlineStatus = "\(outlineRecognitionSource) · \(result.count) 项"
                    rebuildTextIndex(using: result)
                    statusMessage = "AI 目录识别完成"
                    persist()
                }
            } catch {
                await MainActor.run {
                    isRefiningOutline = false
                    let hasLocalOutline = !outline.isEmpty
                    outlineStatus = hasLocalOutline ? "本地目录 · \(outline.count) 项" : "目录识别失败"
                    if hasLocalOutline {
                        statusMessage = "AI 精修不可用，已保留本地目录"
                    }
                    handleOpenAIError(error, showAlert: showErrors && !hasLocalOutline)
                }
            }
        }
    }

    func relocateTOC() {
        guard let document, !pageTexts.isEmpty else {
            errorMessage = "全文文本还在提取或 OCR，请等待处理完成后再定位目录页。"
            return
        }
        guard !isLocatingTOC, !isRefiningOutline else { return }
        let nativeOutline = OutlineBuilder.entries(for: document)
        if !nativeOutline.isEmpty {
            outline = nativeOutline
            chapterSummaries.removeAll()
            generatingChapterSummaryKeys.removeAll()
            outlineRefinedByAI = false
            outlineWasManuallyEdited = false
            tocPageIndices = []
            rebuildTextIndex(using: nativeOutline)
            outlineStatus = "PDF 自带目录 · \(nativeOutline.count) 项"
            statusMessage = "已使用 PDF 自带目录"
            persist()
            return
        }
        discardCurrentAutomaticOutline()
        isLocatingTOC = true
        outlineStatus = "正在自动识别…"
        Task { @MainActor [weak self] in
            guard let self else { return }
            var located = TOCPageDetector.locate(in: self.pageTexts)
            var byPage = Dictionary(uniqueKeysWithValues: self.pageTexts.map { ($0.pageIndex, $0) })
            if located.isEmpty {
                // PDF 文本层可能把双栏或竖排目录横向打乱。此时先以 Vision
                // 重读常见的前置目录区，再根据重建后的空间顺序重新定位。
                let scanCount = min(document.pageCount, max(12, min(60, max(document.pageCount / 5, 1))))
                self.outlineStatus = "正在扫描前 \(scanCount) 页…"
                let scanned = await OCRService.reextract(pageIndices: Array(0..<scanCount), from: document) { completed, total in
                    self.outlineStatus = "正在扫描 \(completed) / \(total)"
                }
                for page in scanned { byPage[page.pageIndex] = page }
                self.pageTexts = byPage.values.sorted { $0.pageIndex < $1.pageIndex }
                located = TOCPageDetector.locate(in: self.pageTexts)
            }
            guard !located.isEmpty else {
                self.isLocatingTOC = false
                self.tocPageIndices = []
                self.outlineStatus = "未找到目录页"
                self.errorMessage = "没有找到目录页。可以选择“手动添加”，逐行粘贴目录文字。"
                return
            }
            let baselineEntries = TOCReliableParser.parse(
                TOCPageTextBuilder.build(pages: self.pageTexts, pageIndices: located)
            )
            let refreshed: [PageText]
            if let enhanced = await self.enhancedTOCPageTexts(pageIndices: located, document: document) {
                refreshed = enhanced
            } else {
                self.outlineStatus = "自动 · 正在重读目录页…"
                refreshed = await OCRService.reextract(pageIndices: located, from: document) { completed, total in
                    self.outlineStatus = "自动 · 读取 \(completed) / \(total)"
                }
            }
            for page in refreshed { byPage[page.pageIndex] = page }
            self.pageTexts = byPage.values.sorted { $0.pageIndex < $1.pageIndex }
            let refreshedEntries = TOCReliableParser.parse(
                TOCPageTextBuilder.build(pages: self.pageTexts, pageIndices: located)
            )
            let calibrationEntries = TOCHierarchyInferer.apply(
                to: TOCSourceMerger.merge(primary: refreshedEntries, secondary: baselineEntries)
            )
            let calibrationPages = self.tocPageCalibrationPages(
                for: calibrationEntries,
                tocPages: located,
                pageCount: document.pageCount
            )
            if !calibrationPages.isEmpty {
                self.outlineStatus = "正在校准目录页码…"
                let calibrated = await OCRService.reextract(pageIndices: calibrationPages, from: document) { completed, total in
                    self.outlineStatus = "正在校准页码 \(completed) / \(total)"
                }
                for page in calibrated { byPage[page.pageIndex] = page }
                self.pageTexts = byPage.values.sorted { $0.pageIndex < $1.pageIndex }
            }
            self.isLocatingTOC = false
            self.applyLocatedTOCPages(
                located,
                source: "自动识别",
                supplementalEntries: baselineEntries
            )
        }
    }

    func previewPastedOutline(
        _ text: String,
        tocStartPDFPage: Int,
        tocEndPDFPage: Int
    ) -> [OutlineEntry] {
        // Manual input promises one entry per line. Do not union it with the
        // flexible OCR parser: that parser can reinterpret column fragments
        // and append the last few entries a second time.
        let linewiseEntries = ManualTOCTextParser.parse(text)
        let sourceEntries = linewiseEntries.isEmpty
            ? TOCReliableParser.parse(text, preferLinewise: true)
            : TOCHierarchyInferer.apply(to: linewiseEntries)
        guard !sourceEntries.isEmpty else {
            errorMessage = "没有识别到有效目录。请确保每行只有一个条目，包含标题和页码；行首每多一个空格表示下一级。"
            return []
        }
        let pages: [PageText]
        if pageTexts.isEmpty {
            pages = (0..<pageCount).map { PageText(pageIndex: $0, text: "", cameFromOCR: false) }
        } else {
            pages = pageTexts
        }
        let startPage = min(max(tocStartPDFPage, 1), max(pageCount, 1))
        let endPage = min(max(tocEndPDFPage, startPage), max(pageCount, 1))
        let directoryPages = Array((startPage - 1)...(endPage - 1))
        let resolved = TOCPageResolver.resolve(
            sourceEntries,
            tocPageIndices: directoryPages,
            pages: pages,
            preserveUnmatched: true
        )
        statusMessage = "已逐行识别、按序号整理并校准 \(resolved.count) 条目录"
        return resolved
    }

    func applyManualOutline(_ entries: [OutlineEntry]) {
        guard let document else { return }
        let cleaned = entries.compactMap { entry -> OutlineEntry? in
            let title = entry.title.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty else { return nil }
            return OutlineEntry(
                id: entry.id,
                title: title,
                pageIndex: min(max(entry.pageIndex, 0), max(document.pageCount - 1, 0)),
                level: min(max(entry.level, 0), 5),
                generated: true
            )
        }
        outline = cleaned
        chapterSummaries.removeAll()
        generatingChapterSummaryKeys.removeAll()
        outlineRefinedByAI = false
        outlineWasManuallyEdited = true
        rebuildTextIndex(using: cleaned)
        outlineStatus = "手动目录 \(cleaned.count) 项"
        statusMessage = "手动目录已保存"
        persist()
    }

    private func applyLocatedTOCPages(
        _ pages: [Int],
        source: String,
        supplementalEntries: [TOCSourceEntry] = []
    ) {
        tocPageIndices = Array(Set(pages)).sorted()
        outlineRecognitionSource = source
        let refreshedEntries = TOCReliableParser.parse(
            TOCPageTextBuilder.build(pages: pageTexts, pageIndices: tocPageIndices)
        )
        let localEntries = TOCHierarchyInferer.apply(
            to: TOCSourceMerger.merge(primary: refreshedEntries, secondary: supplementalEntries)
        )
        let localOutline = TOCPageResolver.resolve(
            localEntries,
            tocPageIndices: tocPageIndices,
            pages: pageTexts,
            preserveUnmatched: true
        )
        outline = localOutline
        chapterSummaries.removeAll()
        generatingChapterSummaryKeys.removeAll()
        outlineRefinedByAI = false
        outlineWasManuallyEdited = false
        rebuildTextIndex(using: outline)
        outlineStatus = localOutline.isEmpty
            ? "\(source) · 已读取目录页"
            : "\(source) · \(localOutline.count) 项"
        statusMessage = localOutline.isEmpty ? "目录页已读取" : "目录已生成"
        persist()
        if localOutline.isEmpty {
            errorMessage = "目录页已读取，但本地没有解析出条目。请调整目录页数后重试，或选择“手动添加”。"
        }
    }

    /// Builds small OCR windows around likely top-level openings. It is only
    /// used where the initial index trusted an embedded text layer; pages that
    /// already came from Vision OCR are skipped. This lets title matching learn
    /// irregular offsets caused by omitted blank/title pages without rescanning
    /// the whole book.
    private func tocPageCalibrationPages(
        for entries: [TOCSourceEntry],
        tocPages: [Int],
        pageCount: Int
    ) -> [Int] {
        guard pageCount > 0, !entries.isEmpty else { return [] }
        let firstContent = (tocPages.max() ?? -1) + 1
        var segments = Array(repeating: 0, count: entries.count)
        var segment = 0
        var previous: (page: Int, style: PrintedPageStyle)?
        for index in entries.indices {
            let entry = entries[index]
            let style = entry.pageStyle ?? .arabic
            if let page = entry.printedPage, page > 0 {
                if let previous {
                    let restarted = previous.style == style
                        && previous.page - page >= 5
                        && page <= max(3, previous.page / 3)
                    if previous.style != style || restarted { segment += 1 }
                }
                previous = (page, style)
            }
            segments[index] = segment
        }
        let finalSegment = segments.max() ?? 0
        let indexedPages = Dictionary(uniqueKeysWithValues: pageTexts.map { ($0.pageIndex, $0) })
        var candidates = Set<Int>()
        for index in entries.indices {
            let entry = entries[index]
            guard entry.level <= 1, let printed = entry.printedPage, printed > 0 else { continue }
            let estimate = segments[index] < finalSegment
                ? printed - 1
                : firstContent + printed - 1
            for page in (estimate - 3)...(estimate + 3)
            where (0..<pageCount).contains(page)
                && !tocPages.contains(page)
                && indexedPages[page]?.cameFromOCR != true {
                candidates.insert(page)
            }
        }
        return candidates.sorted()
    }

    private func enhancedTOCPageTexts(pageIndices: [Int], document: PDFDocument) async -> [PageText]? {
        enhancedTOCInstalled = EnhancedTOCService.isInstalled
        guard enhancedTOCInstalled, !pageIndices.isEmpty else { return nil }
        outlineStatus = "增强版面识别 · 正在分析 \(pageIndices.count) 页…"
        do {
            let inputURL = try EnhancedTOCService.makeInputPDF(from: document, pageIndices: pageIndices)
            let temporaryDirectory = inputURL.deletingLastPathComponent()
            defer { try? FileManager.default.removeItem(at: temporaryDirectory) }
            let results = try await enhancedTOC.recognize(pdfURL: inputURL, sourcePageIndices: pageIndices)
            guard !results.isEmpty else { return nil }
            let pageLabels = Dictionary(uniqueKeysWithValues: pageTexts.map { ($0.pageIndex, $0.pageLabel) })
            outlineStatus = "增强版面识别 · 已读取 \(results.count) / \(pageIndices.count)"
            return results.map {
                PageText(
                    pageIndex: $0.pageIndex,
                    text: TOCInputNormalizer.normalize($0.text),
                    cameFromOCR: true,
                    pageLabel: pageLabels[$0.pageIndex] ?? nil
                )
            }
        } catch {
            statusMessage = "增强识别暂不可用，已自动回退"
            return nil
        }
    }

    private func discardCurrentAutomaticOutline() {
        guard !outlineWasManuallyEdited else { return }
        outline = []
        chapterSummaries.removeAll()
        generatingChapterSummaryKeys.removeAll()
        outlineRefinedByAI = false
        rebuildTextIndex(using: [])
    }

    private func rebuildTextIndex(using outline: [OutlineEntry]) {
        textChunks = LocalIndex.makeChunks(pages: pageTexts, outline: outline)
        derivedCacheNeedsSave = true
    }

    func submitQuestion(_ question: String) {
        let trimmed = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        guard !isAnswering else { return }
        guard indexingProgress >= 1, !textChunks.isEmpty else {
            errorMessage = "全文仍在提取或 OCR。请等待“全书索引已就绪”后再提问。"
            return
        }
        guard let apiKey = sessionAPIKey, !apiKey.isEmpty else {
            errorMessage = "还没有为本次运行配置 API Key。请打开“设置 > AI”粘贴密钥，应用会自动识别平台并验证。"
            return
        }
        let explicitPage = Self.explicitPageReference(in: trimmed)
        let focusPage = Self.inferredFocusPage(
            for: trimmed,
            explicitPage: explicitPage,
            currentPageIndex: currentPageIndex,
            priorTurns: chatTurns
        )
        let userTurn = ChatTurn(
            role: .user,
            content: trimmed,
            pageReferences: [focusPage],
            noteAnchorPageIndex: focusPage
        )
        preparedQuestionBase = nil
        chatTurns.append(userTurn)
        pendingQuestionTurnID = userTurn.id
        pendingQuestionText = trimmed
        isAnswering = true
        statusMessage = assistantUsesWebSearch
            ? "AI 正在联网查找资源"
            : (assistantUsesWholeBook ? "AI 正在联系全书结构" : "AI 正在阅读当前上下文")
        let usesWebSearch = assistantUsesWebSearch
        isSearchingWeb = usesWebSearch
        assistantUsesWebSearch = false
        let usesWholeBook = assistantUsesWholeBook
        assistantUsesWholeBook = false
        let scope = pendingContextScope
        pendingContextScope = .standard
        pendingAnswerUsesWebSearch = usesWebSearch
        pendingAnswerUsesWholeBook = usesWholeBook
        pendingAnswerContextScope = scope
        let retrievedContext = LocalIndex.retrieveForReading(
            trimmed,
            focusPageIndex: focusPage,
            from: textChunks,
            limit: aiReadingDepth.contextLimit,
            wholeBook: usesWholeBook,
            scope: scope
        )
        let context = LocalIndex.prepareForPrompt(
            retrievedContext,
            tokenBudget: aiReadingDepth.contextTokenBudget(scope: scope, wholeBook: usesWholeBook)
        )
        let cacheIdentity = Self.promptCacheIdentity(for: documentURL)
        let history = Self.contextualHistory(
            from: chatTurns,
            currentQuestion: trimmed
        )
        let cacheKey = Self.answerCacheKey(
            question: trimmed,
            context: context,
            model: aiModel,
            provider: aiProvider,
            depth: aiReadingDepth,
            usesWebSearch: usesWebSearch,
            usesWholeBook: usesWholeBook,
            history: history
        )
        if !usesWebSearch, var cached = answerCache[cacheKey] {
            cached.id = UUID()
            cached.createdAt = Date()
            cached.noteAnchorPageIndex = focusPage
            cached.apiUsage = nil
            cached.servedFromLocalCache = true
            chatTurns.append(cached)
            isAnswering = false
            isSearchingWeb = false
            pendingQuestionTurnID = nil
            pendingQuestionText = nil
            pendingAnswerUsesWebSearch = false
            pendingAnswerUsesWholeBook = false
            pendingAnswerContextScope = .standard
            statusMessage = "已使用本地回答缓存（未调用 API）"
            persist()
            return
        }
        let requestID = UUID()
        activeAnswerRequestID = requestID
        answerTask = Task {
            do {
                var answer = try await openAI.ask(
                    question: trimmed,
                    context: context,
                    priorTurns: history,
                    model: aiModel,
                    apiKey: apiKey,
                    provider: aiProvider,
                    readingDepth: aiReadingDepth,
                    usesWebSearch: usesWebSearch,
                    usesWholeBook: usesWholeBook,
                    bookOutline: usesWholeBook ? outline : [],
                    cacheIdentity: cacheIdentity
                )
                try Task.checkCancellation()
                answer.noteAnchorPageIndex = focusPage
                answer.servedFromLocalCache = false
                await MainActor.run {
                    guard self.activeAnswerRequestID == requestID else { return }
                    if !usesWebSearch {
                        self.answerCache[cacheKey] = answer
                        if self.answerCache.count > 160 {
                            self.answerCache.removeValue(forKey: self.answerCache.keys.sorted().first!)
                        }
                    }
                    chatTurns.append(answer)
                    self.finishAnswerRequest(requestID)
                    statusMessage = usesWebSearch
                        ? "资源链接已整理"
                        : answer.apiUsage.map { "AI 回答完成 · \($0.compactDescription)" } ?? "AI 回答完成"
                    persist()
                }
            } catch {
                await MainActor.run {
                    guard self.activeAnswerRequestID == requestID else { return }
                    if Self.isCancellationError(error) {
                        self.cancelActiveAnswer(restoreQuestion: true)
                    } else {
                        self.finishAnswerRequest(requestID)
                        self.handleOpenAIError(error, showAlert: true)
                    }
                }
            }
        }
    }

    func cancelAnswer() {
        cancelActiveAnswer(restoreQuestion: true)
    }

    private func cancelActiveAnswer(restoreQuestion: Bool) {
        guard isAnswering || answerTask != nil else { return }
        activeAnswerRequestID = nil
        answerTask?.cancel()
        answerTask = nil

        if let turnID = pendingQuestionTurnID {
            chatTurns.removeAll { $0.id == turnID }
        }
        if restoreQuestion,
           let question = pendingQuestionText,
           assistantDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            assistantDraft = question
        }
        if restoreQuestion {
            assistantUsesWebSearch = pendingAnswerUsesWebSearch
            assistantUsesWholeBook = pendingAnswerUsesWholeBook
            pendingContextScope = pendingAnswerContextScope
        }
        pendingQuestionTurnID = nil
        pendingQuestionText = nil
        pendingAnswerUsesWebSearch = false
        pendingAnswerUsesWholeBook = false
        pendingAnswerContextScope = .standard
        isAnswering = false
        isSearchingWeb = false
        statusMessage = restoreQuestion ? "已取消发送，问题已恢复" : "已取消 AI 请求"
        persist()
    }

    private func finishAnswerRequest(_ requestID: UUID) {
        guard activeAnswerRequestID == requestID else { return }
        activeAnswerRequestID = nil
        answerTask = nil
        pendingQuestionTurnID = nil
        pendingQuestionText = nil
        pendingAnswerUsesWebSearch = false
        pendingAnswerUsesWholeBook = false
        pendingAnswerContextScope = .standard
        isAnswering = false
        isSearchingWeb = false
    }

    nonisolated static func isCancellationError(_ error: Error) -> Bool {
        if error is CancellationError { return true }
        return (error as? URLError)?.code == .cancelled
    }

    func askAboutHighlight(_ highlight: HighlightRecord, action: String) {
        pendingAnnotation = nil
        prepareQuestion(from: highlight.inlineText, pageIndex: highlight.pageIndex)
        applyQuickQuestion(action == "解释" ? "解释" : "上下文")
    }

    func prepareQuestion(from text: String, pageIndex: Int) {
        let original = HighlightTextNormalizer.inline(text)
        let base = "P\(pageIndex + 1)\n\(original)"
        preparedQuestionBase = base
        pendingContextScope = .standard
        assistantDraft = base
        assistantVisible = true
    }

    func applyQuickQuestion(_ action: String) {
        let expandedQuestion: String
        switch action {
        case "解释":
            expandedQuestion = QuickQuestionPrompt.explanation
            pendingContextScope = .explanation
        case "资源":
            expandedQuestion = QuickQuestionPrompt.resources
            assistantUsesWebSearch = true
        default:
            expandedQuestion = QuickQuestionPrompt.context
            pendingContextScope = .context
        }
        if let base = preparedQuestionBase, !base.isEmpty {
            assistantDraft = base + "\n\n" + expandedQuestion
        } else {
            assistantDraft = expandedQuestion
        }
        assistantVisible = true
    }

    func saveAISettings(apiKey: String, model: String, remember: Bool) {
        rememberAPIKey = remember
        UserDefaults.standard.set(remember, forKey: "rememberAPIKey")
        let trimmedKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedKey.isEmpty else {
            let selectedModel = model.trimmingCharacters(in: .whitespacesAndNewlines)
            if !selectedModel.isEmpty { aiModel = selectedModel }
            UserDefaults.standard.set(aiModel, forKey: "aiModel")
            if hasActiveAPIKey {
                statusMessage = "已切换模型：\(aiModel)"
                closeSettingsAfterValidation = true
            } else if remember {
                restoreSavedAPIKey(showErrors: true)
            } else {
                apiKeyStatus = hasActiveAPIKey
                    ? "\(aiProvider.rawValue) 已连接 · Key 仅本次运行有效"
                    : "请粘贴 API Key，应用会自动识别平台"
            }
            statusMessage = "AI 模型设置已保存"
            return
        }
        guard AIProvider.looksLikeCompleteAPIKey(trimmedKey) else {
            apiKeyStatus = "密钥格式无效"
            errorMessage = OpenAIService.ServiceError.invalidAPIKeyFormat.localizedDescription
            return
        }
        let validationID = UUID()
        aiValidationID = validationID
        apiKeyStatus = "正在识别 API 平台并验证 Key…"
        Task {
            do {
                let detection = try await openAI.detectProvider(apiKey: trimmedKey)
                let provider = detection.provider
                let models = detection.models
                var storageFailure: String?
                if remember {
                    do { try await apiKeyStore.save(trimmedKey, for: provider) }
                    catch { storageFailure = error.localizedDescription }
                } else {
                    do { try await apiKeyStore.delete(for: provider) }
                    catch { storageFailure = error.localizedDescription }
                }
                await MainActor.run {
                    guard aiValidationID == validationID else { return }
                    sessionAPIKey = trimmedKey
                    hasActiveAPIKey = true
                    hasStoredAPIKey = remember && storageFailure == nil
                    aiProvider = provider
                    UserDefaults.standard.set(provider.rawValue, forKey: "aiProvider")
                    availableAIModels = models
                    catalogAIModels = UserDefaults.standard.stringArray(
                        forKey: "catalogAIModels.\(provider.storageAccount)"
                    ) ?? []
                    UserDefaults.standard.set(models, forKey: "availableAIModels.\(provider.storageAccount)")
                    let requestedModel = model.trimmingCharacters(in: .whitespacesAndNewlines)
                    if models.contains(requestedModel) {
                        aiModel = requestedModel
                    } else if let preferred = preferredModel(from: models, provider: provider) {
                        aiModel = preferred
                    }
                    UserDefaults.standard.set(aiModel, forKey: "aiModel")
                    if let storageFailure {
                        apiKeyStatus = "\(provider.rawValue) 已连接，但未能长期保存"
                        errorMessage = "API Key 验证成功，本次运行可以使用；长期保存失败：\(storageFailure)"
                    } else {
                        apiKeyStatus = remember
                            ? "\(provider.rawValue) 已连接 · API Key 已保存到本机应用数据"
                            : "\(provider.rawValue) 已连接 · API Key 仅本次运行有效"
                    }
                    statusMessage = "AI 已连接到 \(provider.rawValue)"
                    refreshModelCatalog(for: provider)
                    closeSettingsAfterValidation = true
                }
            } catch {
                await MainActor.run {
                    guard aiValidationID == validationID else { return }
                    apiKeyStatus = "API Key 识别或验证失败"
                    handleOpenAIError(error, showAlert: true)
                }
            }
        }
    }

    func saveCustomRelaySettings(
        apiKey: String,
        baseURL: String,
        protocol requestedProtocol: CustomAPIProtocol = .automatic,
        authentication requestedAuthentication: CustomAPIAuthentication = .automatic,
        modelHint: String = "",
        remember: Bool
    ) {
        let apiProtocol = CustomRelayConfiguration.resolvedProtocol(for: baseURL, requested: requestedProtocol)
        let authentication = CustomRelayConfiguration.resolvedAuthentication(
            for: baseURL,
            protocol: apiProtocol,
            requested: requestedAuthentication
        )
        let enteredKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedKey = authentication == .none && enteredKey.isEmpty ? "local-no-key" : enteredKey
        guard let normalizedURL = CustomRelayConfiguration.normalizedBaseURL(from: baseURL) else {
            apiKeyStatus = "Base URL 无效"
            errorMessage = "请输入 HTTPS 接口地址；本机 Ollama/vLLM 可使用 http://localhost。"
            return
        }
        guard authentication == .none || AIProvider.looksLikeCompleteAPIKey(trimmedKey) else {
            apiKeyStatus = "密钥格式无效"
            errorMessage = OpenAIService.ServiceError.invalidAPIKeyFormat.localizedDescription
            return
        }
        let directEndpoint = CustomRelayConfiguration.directEndpoint(from: baseURL)
        rememberAPIKey = remember
        UserDefaults.standard.set(remember, forKey: "rememberAPIKey")
        let validationID = UUID()
        aiValidationID = validationID
        apiKeyStatus = "正在验证中转站连接…"
        Task {
            do {
                let models = try await openAI.validateCustomRelay(
                    apiKey: trimmedKey,
                    baseURL: normalizedURL,
                    directEndpoint: directEndpoint,
                    protocol: apiProtocol,
                    authentication: authentication,
                    modelHint: modelHint
                )
                var storageFailure: String?
                if remember {
                    do { try await apiKeyStore.save(trimmedKey, for: .customRelay) }
                    catch { storageFailure = error.localizedDescription }
                } else {
                    do { try await apiKeyStore.delete(for: .customRelay) }
                    catch { storageFailure = error.localizedDescription }
                }
                await MainActor.run {
                    guard self.aiValidationID == validationID else { return }
                    self.customRelayEnabled = true
                    self.customRelayBaseURL = normalizedURL.absoluteString
                    let selectedModel = self.preferredModel(from: models, provider: .customRelay) ?? models[0]
                    self.customRelayModel = selectedModel
                    UserDefaults.standard.set(true, forKey: CustomRelayConfiguration.enabledKey)
                    UserDefaults.standard.set(normalizedURL.absoluteString, forKey: CustomRelayConfiguration.baseURLKey)
                    UserDefaults.standard.set(selectedModel, forKey: CustomRelayConfiguration.modelKey)
                    UserDefaults.standard.set(apiProtocol.rawValue, forKey: CustomRelayConfiguration.protocolKey)
                    UserDefaults.standard.set(authentication.rawValue, forKey: CustomRelayConfiguration.authenticationKey)
                    if let directEndpoint {
                        UserDefaults.standard.set(directEndpoint.absoluteString, forKey: CustomRelayConfiguration.directEndpointKey)
                    } else {
                        UserDefaults.standard.removeObject(forKey: CustomRelayConfiguration.directEndpointKey)
                    }
                    self.aiProvider = .customRelay
                    UserDefaults.standard.set(AIProvider.customRelay.rawValue, forKey: "aiProvider")
                    self.aiModel = selectedModel
                    self.availableAIModels = models
                    UserDefaults.standard.set(models, forKey: "availableAIModels.\(AIProvider.customRelay.storageAccount)")
                    self.sessionAPIKey = trimmedKey
                    self.hasActiveAPIKey = true
                    self.hasStoredAPIKey = remember && storageFailure == nil
                    if let storageFailure {
                        self.apiKeyStatus = "连接成功，但未能长期保存"
                        self.errorMessage = "中转站验证成功，本次运行可以使用；长期保存失败：\(storageFailure)"
                    } else {
                        self.apiKeyStatus = "连接成功"
                    }
                    self.statusMessage = "独立中转站已连接"
                    self.closeSettingsAfterValidation = true
                }
            } catch {
                await MainActor.run {
                    guard self.aiValidationID == validationID else { return }
                    self.apiKeyStatus = "连接失败"
                    self.handleOpenAIError(error, showAlert: true)
                }
            }
        }
    }

    func clearAPIKey() {
        aiValidationID = UUID()
        sessionAPIKey = nil
        hasActiveAPIKey = false
        hasStoredAPIKey = false
        apiKeyStatus = "正在删除 \(aiProvider.rawValue) API Key…"
        let provider = aiProvider
        Task {
            do {
                try await apiKeyStore.delete(for: provider)
                await MainActor.run {
                    apiKeyStatus = "没有保存 API Key"
                    statusMessage = "已清除本次运行和本机保存的 \(provider.rawValue) API Key"
                }
            } catch {
                await MainActor.run {
                    apiKeyStatus = "本次连接已清除；本机凭据删除失败"
                    errorMessage = error.localizedDescription
                }
            }
        }
    }

    private func restoreSavedAPIKey(showErrors: Bool) {
        let provider = aiProvider
        let model = aiModel
        let validationID = UUID()
        aiValidationID = validationID
        apiKeyStatus = "正在恢复本机保存的 \(provider.rawValue) API Key…"
        Task {
            do {
                guard let key = try await apiKeyStore.load(for: provider) else {
                    await MainActor.run {
                        guard aiValidationID == validationID else { return }
                        hasStoredAPIKey = false
                        apiKeyStatus = "本机没有保存 \(provider.rawValue) API Key，请输入并保存"
                    }
                    return
                }
                let models: [String]
                if provider == .customRelay {
                    guard let baseURL = CustomRelayConfiguration.savedBaseURL else {
                        throw OpenAIService.ServiceError.invalidResponse
                    }
                    models = try await openAI.validateCustomRelay(
                        apiKey: key,
                        baseURL: baseURL,
                        directEndpoint: CustomRelayConfiguration.savedDirectEndpoint,
                        protocol: CustomRelayConfiguration.savedProtocol,
                        authentication: CustomRelayConfiguration.savedAuthentication,
                        modelHint: customRelayModel
                    )
                } else {
                    models = try await openAI.validate(apiKey: key, model: model, provider: provider)
                }
                await MainActor.run {
                    guard aiValidationID == validationID, aiProvider == provider else { return }
                    sessionAPIKey = key
                    hasActiveAPIKey = true
                    hasStoredAPIKey = true
                    availableAIModels = models
                    UserDefaults.standard.set(models, forKey: "availableAIModels.\(provider.storageAccount)")
                    if !models.contains(aiModel), let preferred = preferredModel(from: models, provider: provider) { aiModel = preferred }
                    apiKeyStatus = "\(provider.rawValue) API Key 已从本机应用数据恢复"
                    statusMessage = "AI 已自动连接到 \(provider.rawValue)"
                    refreshModelCatalog(for: provider)
                }
            } catch {
                await MainActor.run {
                    guard aiValidationID == validationID else { return }
                    sessionAPIKey = nil
                    hasActiveAPIKey = false
                    hasStoredAPIKey = false
                    apiKeyStatus = "未能恢复 \(provider.rawValue) API Key，请重新输入并保存"
                    if showErrors { errorMessage = error.localizedDescription }
                }
            }
        }
    }

    func selectAIModel(_ model: String) {
        let trimmed = model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        aiModel = trimmed
        if aiProvider == .customRelay {
            customRelayModel = trimmed
            UserDefaults.standard.set(trimmed, forKey: CustomRelayConfiguration.modelKey)
        }
        statusMessage = "已切换模型：\(trimmed)"
    }

    func cachedAIModels(for provider: AIProvider) -> [String] {
        UserDefaults.standard.stringArray(
            forKey: "availableAIModels.\(provider.storageAccount)"
        ) ?? []
    }

    func cachedAIModelCatalog(for provider: AIProvider) -> [String] {
        UserDefaults.standard.stringArray(
            forKey: "catalogAIModels.\(provider.storageAccount)"
        ) ?? []
    }

    private func preferredModel(from models: [String], provider: AIProvider? = nil) -> String? {
        let selectedProvider = provider ?? aiProvider
        let priorities: [String]
        switch selectedProvider {
        case .openAI: priorities = ["gpt-5.6", "gpt-5", "gpt-4.1"]
        case .aiHubMix: priorities = ["claude-opus", "claude-sonnet", "gpt-5.6", "gpt-5", "gemini"]
        case .anthropic: priorities = ["claude-opus", "claude-sonnet", "claude-haiku"]
        case .googleGemini: priorities = ["gemini-3", "gemini-2.5-pro", "gemini-2.5-flash"]
        case .deepSeek: priorities = ["deepseek-reasoner", "deepseek-chat"]
        case .openRouter: priorities = ["anthropic/claude-opus", "anthropic/claude-sonnet", "openai/gpt-5", "google/gemini"]
        case .customRelay: priorities = [customRelayModel, "claude", "gpt", "gemini", "deepseek"]
        }
        for prefix in priorities {
            if let match = models.first(where: { $0.localizedCaseInsensitiveContains(prefix) }) {
                return match
            }
        }
        return models.first
    }

    func refreshAvailableAIModels() {
        guard let apiKey = sessionAPIKey, !apiKey.isEmpty else {
            errorMessage = "请先验证 API Key。"
            return
        }
        guard !isLoadingAIModels else { return }
        isLoadingAIModels = true
        let provider = aiProvider
        Task {
            do {
                let models = try await openAI.availableModels(apiKey: apiKey, provider: provider)
                await MainActor.run {
                    guard self.aiProvider == provider else { return }
                    self.availableAIModels = models
                    self.isLoadingAIModels = false
                    UserDefaults.standard.set(models, forKey: "availableAIModels.\(provider.storageAccount)")
                    if !models.contains(self.aiModel), let preferred = self.preferredModel(from: models, provider: provider) {
                        self.aiModel = preferred
                    }
                    self.statusMessage = "模型列表已更新"
                    self.refreshModelCatalog(for: provider)
                }
            } catch {
                await MainActor.run {
                    self.isLoadingAIModels = false
                    self.handleOpenAIError(error, showAlert: true)
                }
            }
        }
    }

    private func refreshModelCatalog(for provider: AIProvider) {
        guard provider.modelCatalogURL != nil else {
            catalogAIModels = availableAIModels
            return
        }
        Task {
            do {
                let models = try await openAI.modelCatalog(for: provider)
                await MainActor.run {
                    guard self.aiProvider == provider else { return }
                    self.catalogAIModels = models
                    UserDefaults.standard.set(models, forKey: "catalogAIModels.\(provider.storageAccount)")
                }
            } catch {
                // The authorized model list remains usable even if the public
                // catalog is temporarily unavailable.
            }
        }
    }

    private func handleOpenAIError(_ error: Error, showAlert: Bool) {
        if case OpenAIService.ServiceError.invalidAPIKey = error {
            sessionAPIKey = nil
            hasActiveAPIKey = false
            apiKeyStatus = "本次运行的 API Key 无效，已清除"
        }
        if showAlert { errorMessage = error.localizedDescription }
    }

    private var tocPageDescription: String {
        let physicalPages = tocPageIndices.map { $0 + 1 }
        guard let first = physicalPages.first, let last = physicalPages.last else { return "无" }
        if physicalPages.count == 1 { return "\(first)" }
        let isContinuous = zip(physicalPages, physicalPages.dropFirst()).allSatisfy { pair in
            pair.1 == pair.0 + 1
        }
        return isContinuous ? "\(first)–\(last)" : physicalPages.map(String.init).joined(separator: "、")
    }

    func chooseObsidianVault() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.message = "选择已在 Obsidian 中打开过的 Vault 根目录（不要选择 Vault 内的笔记子文件夹）"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let registered = ObsidianVaultRegistry.registeredVaults()
        guard let vault = ObsidianVaultRegistry.exactVault(url, registered: registered) else {
            errorMessage = "所选文件夹不是 Obsidian 已注册的 Vault 根目录。请先在 Obsidian 中用“打开文件夹作为仓库”注册它，或选择下面已注册的 Vault：\n\n\(ObsidianVaultRegistry.displayList(registered))"
            return
        }
        obsidianVaultPath = vault.path
        UserDefaults.standard.set(vault.path, forKey: "obsidianVaultPath")
        obsidianNoteURL = nil
        statusMessage = "已连接 Obsidian Vault"
    }

    func createObsidianSkeleton() {
        guard let documentURL, !obsidianVaultPath.isEmpty else {
            errorMessage = "请先在“设置 > Obsidian”选择 Vault。"
            return
        }
        let vault = URL(fileURLWithPath: obsidianVaultPath, isDirectory: true)
        let registered = ObsidianVaultRegistry.registeredVaults()
        guard ObsidianVaultRegistry.exactVault(vault, registered: registered) != nil else {
            errorMessage = "当前设置的文件夹不是 Obsidian 已注册的 Vault，因此不会创建一个无法从 Obsidian 打开的笔记。请在“设置 > Obsidian”重新选择。\n\n已注册 Vault：\n\(ObsidianVaultRegistry.displayList(registered))"
            return
        }
        let title = documentTitle
        let outline = outline
        Task {
            do {
                let note = try await obsidian.createOrUpdateBookNote(
                    vault: vault,
                    folder: obsidianFolder,
                    title: title,
                    sourcePath: documentURL.path,
                    outline: outline
                )
                await MainActor.run {
                    obsidianNoteURL = note
                    statusMessage = "目录已加入笔记"
                    showNoteFeedback("目录已加入笔记")
                }
            } catch { await MainActor.run { errorMessage = "Obsidian 写入失败：\(error.localizedDescription)" } }
        }
    }

    func createObsidianNotebook() {
        guard let documentURL, !obsidianVaultPath.isEmpty else {
            errorMessage = "请先在“设置 > Obsidian”选择 Vault。"
            return
        }
        let vault = URL(fileURLWithPath: obsidianVaultPath, isDirectory: true)
        let registered = ObsidianVaultRegistry.registeredVaults()
        guard ObsidianVaultRegistry.exactVault(vault, registered: registered) != nil else {
            errorMessage = "当前 Vault 未在 Obsidian 中注册，请重新选择。"
            return
        }
        let title = documentTitle
        let existing = obsidianNoteURL
        Task {
            do {
                let note = try await obsidian.createOrUpdateBookNote(
                    vault: vault,
                    folder: obsidianFolder,
                    title: title,
                    sourcePath: documentURL.path,
                    outline: [],
                    preferredURL: existing
                )
                await MainActor.run {
                    obsidianNoteURL = note
                    statusMessage = "笔记本已创建"
                    showNoteFeedback("笔记本已创建")
                }
            } catch {
                await MainActor.run { errorMessage = "Obsidian 写入失败：\(error.localizedDescription)" }
            }
        }
    }

    func chapterSummary(for entry: OutlineEntry) -> String? {
        chapterSummaries[chapterSummaryKey(for: entry)]
    }

    func isGeneratingChapterSummary(for entry: OutlineEntry) -> Bool {
        generatingChapterSummaryKeys.contains(chapterSummaryKey(for: entry))
    }

    func generateChapterSummary(for entry: OutlineEntry, refresh: Bool = false) {
        let key = chapterSummaryKey(for: entry)
        if !refresh, chapterSummaries[key]?.isEmpty == false { return }
        guard let apiKey = sessionAPIKey, !apiKey.isEmpty else {
            errorMessage = "请先在设置中验证 API Key。"
            return
        }
        guard indexingProgress >= 1, !textChunks.isEmpty else {
            errorMessage = "全文索引尚未完成。"
            return
        }
        guard !generatingChapterSummaryKeys.contains(key) else { return }
        let context = chapterContext(for: entry)
        guard !context.isEmpty else {
            errorMessage = "没有找到这一章节的可用文本。"
            return
        }
        generatingChapterSummaryKeys.insert(key)
        let siblings = outline.filter { $0.level == entry.level }
        let position = siblings.firstIndex(where: { $0.id == entry.id })
        let previous = position.flatMap { $0 > 0 ? siblings[$0 - 1] : nil }
        let next = position.flatMap { $0 + 1 < siblings.count ? siblings[$0 + 1] : nil }
        let previousContext = previous.map { Array(chapterContext(for: $0).suffix(2)) } ?? []
        let nextContext = next.map { Array(chapterContext(for: $0).prefix(2)) } ?? []
        Task {
            do {
                let content = try await openAI.generateInlineChapterSummary(
                    chapterTitle: entry.title,
                    context: context,
                    previousChapter: previous.map { ($0.title, previousContext) },
                    nextChapter: next.map { ($0.title, nextContext) },
                    model: aiModel,
                    apiKey: apiKey,
                    provider: aiProvider
                )
                await MainActor.run {
                    self.chapterSummaries[key] = content
                    self.generatingChapterSummaryKeys.remove(key)
                    self.statusMessage = "“\(entry.title)”概要已生成"
                    self.persist()
                }
            } catch {
                await MainActor.run {
                    self.generatingChapterSummaryKeys.remove(key)
                    self.handleOpenAIError(error, showAlert: true)
                }
            }
        }
    }

    private func chapterSummaryKey(for entry: OutlineEntry) -> String {
        "\(entry.level)|\(entry.pageIndex)|\(entry.title)"
    }

    func sendHighlightToObsidian(_ highlight: HighlightRecord) {
        guard !highlight.isInNotes else {
            statusMessage = "这条划线已在笔记中"
            return
        }
        let chapterTitle = chapterTitle(for: highlight.pageIndex, sourceText: highlight.inlineText)
        ensureObsidianNote(successMessage: "划线已加入笔记") { note in
            let block = ObsidianNoteBuilder.highlightBlock(highlight)
            try await self.obsidian.append(
                block: block,
                afterPage: highlight.pageIndex,
                chapterTitle: chapterTitle,
                to: note
            )
            await MainActor.run {
                if let index = self.highlights.firstIndex(where: { $0.id == highlight.id }) {
                    self.highlights[index].noteExportedAt = Date()
                    self.persist()
                }
            }
        }
    }

    func sendHighlightsToObsidian(_ selected: [HighlightRecord]) {
        let pending = selected.filter { !$0.isInNotes }
        guard !pending.isEmpty else {
            errorMessage = selected.isEmpty ? "请先选择划线或批注。" : "所选内容已经加入笔记。"
            return
        }
        let ids = Set(pending.map(\.id))
        let outline = outline
        let pages = pageTexts
        ensureObsidianNote(successMessage: "已加入 \(pending.count) 条划线与批注") { note in
            try await self.obsidian.append(highlights: pending, outline: outline, pages: pages, to: note)
            await MainActor.run {
                for index in self.highlights.indices where ids.contains(self.highlights[index].id) {
                    self.highlights[index].noteExportedAt = Date()
                }
                self.selectedHighlightIDs.subtract(ids)
                self.persist()
            }
        }
    }

    func openObsidianNote() {
        guard let note = obsidianNoteURL else {
            errorMessage = "请先生成当前文档的 Obsidian 笔记。"
            return
        }
        let registered = ObsidianVaultRegistry.registeredVaults()
        guard let vault = ObsidianVaultRegistry.containingVault(for: note, registered: registered) else {
            errorMessage = "这份笔记不在 Obsidian 已注册的 Vault 中，无法使用 Obsidian 链接打开。请在“设置 > Obsidian”选择已注册的 Vault 后重新生成。\n\n已注册 Vault：\n\(ObsidianVaultRegistry.displayList(registered))"
            return
        }
        if let url = ObsidianDeepLink.openURL(vault: vault, note: note), NSWorkspace.shared.open(url) {
            statusMessage = "正在 Obsidian 中打开笔记"
            return
        }
        NSWorkspace.shared.open(note)
    }

    func rotateCurrentPage() {
        guard let page = document?.page(at: currentPageIndex) else { return }
        page.rotation = (page.rotation + 90) % 360
        statusMessage = "当前页已顺时针旋转 90°（原 PDF 未修改）"
        navigationTarget = nil
        navigationTarget = currentPageIndex
    }

    func sendSelectedChatsToObsidian(
        mode: ChatNoteExportMode,
        collapsed: Bool
    ) {
        let selected = selectedChatTurnsIncludingConversationPairs()
        guard !selected.isEmpty else {
            errorMessage = chatTurns.contains(where: {
                $0.selectedForNotes
            })
                ? "所选对话已经加入笔记。"
                : "请先选择对话。"
            return
        }
        guard !obsidianVaultPath.isEmpty, documentURL != nil else {
            errorMessage = "请先连接 Obsidian Vault。"
            return
        }
        let groups = chatNoteGroups(for: selected)
        let selectedIDs = Set(selected.map(\.id))
        isExportingChatNote = true
        if mode == .original {
            let writes = groups.map { group in
                ChatNoteWrite(
                    block: ObsidianNoteBuilder.aiBlock(
                        turns: group.turns,
                        pages: group.pageReferences.sorted(),
                        collapsed: collapsed
                    ),
                    anchorPageIndex: group.anchorPageIndex,
                    chapterTitle: group.chapterTitle
                )
            }
            appendChatBlocks(
                writes,
                selectedIDs: selectedIDs
            )
            return
        }
        guard let apiKey = sessionAPIKey, !apiKey.isEmpty else {
            isExportingChatNote = false
            errorMessage = "整理浓缩需要 AI。请先在“设置 > AI”中验证 API Key，或选择“保留原文”。"
            return
        }
        Task {
            do {
                var writes: [ChatNoteWrite] = []
                for group in groups {
                    let summary = try await openAI.condenseConversation(
                        group.turns,
                        model: aiModel,
                        apiKey: apiKey,
                        provider: aiProvider
                    )
                    writes.append(ChatNoteWrite(
                        block: ObsidianNoteBuilder.aiBlock(
                            summary: summary,
                            pages: group.pageReferences.sorted(),
                            collapsed: collapsed,
                            sourceTurnIDs: group.turns.map(\.id)
                        ),
                        anchorPageIndex: group.anchorPageIndex,
                        chapterTitle: group.chapterTitle
                    ))
                }
                self.appendChatBlocks(writes, selectedIDs: selectedIDs)
            } catch {
                self.isExportingChatNote = false
                self.handleOpenAIError(error, showAlert: true)
            }
        }
    }

    /// The picker presents individual turns for precision, but a selected
    /// question or answer should still be written as a readable conversation.
    /// Include its adjacent counterpart automatically and keep exported turns
    /// excluded from subsequent writes.
    private func selectedChatTurnsIncludingConversationPairs() -> [ChatTurn] {
        Self.chatTurnsForNote(from: chatTurns)
    }

    /// A note should always contain a readable question-answer unit. The
    /// counterpart is included even if an older app version already marked it
    /// as exported; otherwise selecting the remaining answer can create an
    /// incomplete block with no question (or vice versa).
    nonisolated static func chatTurnsForNote(from modeTurns: [ChatTurn]) -> [ChatTurn] {
        let explicitlySelected = Set(modeTurns.indices.filter {
            modeTurns[$0].selectedForNotes
        })
        var included = explicitlySelected
        for index in explicitlySelected {
            if modeTurns[index].role == .assistant {
                if let question = (0..<index).reversed().first(where: { modeTurns[$0].role == .user }) {
                    included.insert(question)
                }
            } else if index + 1 < modeTurns.count {
                for candidate in (index + 1)..<modeTurns.count {
                    if modeTurns[candidate].role == .user { break }
                    if modeTurns[candidate].role == .assistant { included.insert(candidate) }
                }
            }
        }
        return included.sorted().map { modeTurns[$0] }
    }

    private func chatNoteGroups(for selected: [ChatTurn]) -> [ChatNoteGroup] {
        let selectedIDs = Set(selected.map(\.id))
        var inheritedAnchor: Int?
        var inheritedChapter: String?
        var groups: [ChatNoteGroup] = []
        for turn in chatTurns {
            if turn.role == .user {
                inheritedAnchor = turn.noteAnchorPageIndex
                    ?? Self.explicitPageReference(in: turn.content)
                    ?? (turn.pageReferences.count == 1 ? turn.pageReferences.first : nil)
                inheritedChapter = inheritedAnchor.flatMap {
                    chapterTitle(for: $0, sourceText: Self.selectedSourceText(in: turn.content))
                }
            }
            guard selectedIDs.contains(turn.id) else { continue }
            let anchor = turn.noteAnchorPageIndex
                ?? inheritedAnchor
                ?? (turn.pageReferences.count == 1 ? turn.pageReferences.first : nil)
            let chapter = inheritedChapter ?? anchor.flatMap { chapterTitle(for: $0) }
            if let index = groups.firstIndex(where: {
                if let chapter { return $0.chapterTitle == chapter }
                return $0.chapterTitle == nil && $0.anchorPageIndex == anchor
            }) {
                groups[index].turns.append(turn)
                groups[index].pageReferences.formUnion(turn.pageReferences)
                if let anchor { groups[index].pageReferences.insert(anchor) }
            } else {
                var pages = Set(turn.pageReferences)
                if let anchor { pages.insert(anchor) }
                groups.append(ChatNoteGroup(
                    turns: [turn],
                    pageReferences: pages,
                    anchorPageIndex: anchor,
                    chapterTitle: chapter
                ))
            }
        }
        return groups
    }

    private func appendChatBlocks(_ writes: [ChatNoteWrite], selectedIDs: Set<UUID>) {
        ensureObsidianNote(successMessage: "AI 对话已加入笔记") { note in
            for write in writes {
                try await self.obsidian.append(
                    block: write.block,
                    afterPage: write.anchorPageIndex,
                    chapterTitle: write.chapterTitle,
                    to: note
                )
            }
            await MainActor.run {
                for index in self.chatTurns.indices where selectedIDs.contains(self.chatTurns[index].id) {
                    self.chatTurns[index].selectedForNotes = false
                    self.chatTurns[index].noteExportedAt = Date()
                }
                self.isExportingChatNote = false
                self.persist()
            }
        }
    }

    private func ensureObsidianNote(
        successMessage: String = "内容已加入笔记",
        operation: @escaping @Sendable (URL) async throws -> Void
    ) {
        guard let documentURL, !obsidianVaultPath.isEmpty else {
            errorMessage = "请先连接 Obsidian Vault。"
            return
        }
        let existing = obsidianNoteURL
        let vault = URL(fileURLWithPath: obsidianVaultPath, isDirectory: true)
        let title = documentTitle
        let outline = outline
        let folder = obsidianFolder
        Task {
            do {
                let note = try await obsidian.createOrUpdateBookNote(
                    vault: vault,
                    folder: folder,
                    title: title,
                    sourcePath: documentURL.path,
                    outline: outline,
                    preferredURL: existing
                )
                try await operation(note)
                await MainActor.run {
                    obsidianNoteURL = note
                    statusMessage = successMessage
                    showNoteFeedback(successMessage)
                }
            } catch {
                await MainActor.run {
                    isExportingChatNote = false
                    errorMessage = "Obsidian 写入失败：\(error.localizedDescription)"
                }
            }
        }
    }

    private func chapterTitle(for pageIndex: Int, sourceText: String? = nil) -> String? {
        OutlineNoteLocator.chapterTitle(
            for: pageIndex,
            sourceText: sourceText,
            pageText: pageTexts.first(where: { $0.pageIndex == pageIndex })?.text,
            outline: outline
        )
    }

    nonisolated static func selectedSourceText(in question: String) -> String? {
        let lines = question.components(separatedBy: .newlines)
        guard lines.first?.range(of: #"^\s*P\s*[0-9]+\s*$"#, options: [.regularExpression, .caseInsensitive]) != nil else {
            return nil
        }
        let remainder = lines.dropFirst().joined(separator: "\n")
        let paragraphs = remainder
            .replacingOccurrences(of: #"\n\s*\n"#, with: "\u{E000}", options: .regularExpression)
            .components(separatedBy: "\u{E000}")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard paragraphs.count >= 2 else { return nil }
        return paragraphs.first
    }

    nonisolated static func explicitPageReference(in question: String) -> Int? {
        let patterns = [
            #"(?im)^\s*P\s*([0-9]+)\b"#,
            #"第\s*([0-9]+)\s*页"#
        ]
        for pattern in patterns {
            guard let expression = try? NSRegularExpression(pattern: pattern),
                  let match = expression.firstMatch(
                    in: question,
                    range: NSRange(question.startIndex..<question.endIndex, in: question)
                  ),
                  let range = Range(match.range(at: 1), in: question),
                  let page = Int(question[range]), page > 0 else { continue }
            return page - 1
        }
        return nil
    }

    nonisolated static func inferredFocusPage(
        for question: String,
        explicitPage: Int?,
        currentPageIndex: Int,
        priorTurns: [ChatTurn]
    ) -> Int {
        if let explicitPage { return explicitPage }
        guard isReferentialFollowUp(question) else { return currentPageIndex }
        return priorTurns.last(where: { $0.role == .user }).flatMap {
            $0.noteAnchorPageIndex ?? explicitPageReference(in: $0.content)
        } ?? currentPageIndex
    }

    nonisolated private static func isReferentialFollowUp(_ question: String) -> Bool {
        let trimmed = question.trimmingCharacters(in: .whitespacesAndNewlines)
        let signals = ["上面", "刚才", "这个", "这里", "其中", "该", "它", "为什么", "继续", "展开", "那", "所以"]
        return trimmed.count <= 120 && signals.contains { trimmed.hasPrefix($0) || trimmed.contains($0) }
    }

    /// Carries prior turns only while the reader stays on the same selected
    /// passage. Selecting different source text starts a clean thread; a
    /// question without a new passage is treated as a follow-up.
    nonisolated static func contextualHistory(
        from turns: [ChatTurn],
        currentQuestion: String
    ) -> [ChatTurn] {
        guard !turns.isEmpty else { return [] }
        let currentSignature = passageSignature(in: currentQuestion)
        let currentIndex = turns.indices.last ?? 0
        let earlierAnchors = turns.indices.dropLast().filter {
            turns[$0].role == .user && (
                turns[$0].noteAnchorPageIndex != nil || explicitPageReference(in: turns[$0].content) != nil
            )
        }
        if let currentSignature {
            _ = currentSignature
            // Any newly supplied source passage starts a clean API context,
            // even when the reader selects the same passage again.
            return [turns[currentIndex]]
        }
        // A question without selected source text is a new topic by default.
        // Only a short, clearly referential follow-up inherits the prior passage.
        guard isReferentialFollowUp(currentQuestion),
              let latestAnchor = earlierAnchors.last else { return [turns[currentIndex]] }
        return Array(turns[latestAnchor...currentIndex])
    }

    nonisolated static func answerCacheKey(
        question: String,
        context: [TextChunk],
        model: String,
        provider: AIProvider,
        depth: AIReadingDepth,
        usesWebSearch: Bool,
        usesWholeBook: Bool,
        history: [ChatTurn]
    ) -> String {
        let material = [
            "v3", provider.storageAccount, model, depth.rawValue,
            usesWebSearch.description, usesWholeBook.description,
            HighlightTextNormalizer.inline(question),
            context.map { "P\($0.pageIndex + 1)|\($0.text)" }.joined(separator: "\n"),
            history.dropLast().map { "\($0.role.rawValue)|\($0.content)" }.joined(separator: "\n")
        ].joined(separator: "\u{1F}")
        return SHA256.hash(data: Data(material.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// A stable, opaque book identity improves provider-side prompt-cache
    /// routing without exposing the local file path to the API.
    nonisolated static func promptCacheIdentity(for documentURL: URL?) -> String {
        let material = documentURL?.standardizedFileURL.path ?? "reading-companion-untitled"
        return SHA256.hash(data: Data(material.utf8))
            .prefix(16)
            .map { String(format: "%02x", $0) }
            .joined()
    }

    nonisolated private static func passageSignature(in question: String) -> String? {
        let normalized = question.replacingOccurrences(of: "\r\n", with: "\n")
        let lines = normalized.components(separatedBy: .newlines)
        guard let pageLine = lines.firstIndex(where: {
            $0.range(of: #"^\s*P\s*[0-9]+\s*$"#, options: [.regularExpression, .caseInsensitive]) != nil
        }) else { return nil }
        let passageLines = lines.dropFirst(pageLine + 1).prefix { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        let passage = HighlightTextNormalizer.inline(passageLines.joined(separator: " "))
        guard !passage.isEmpty else { return nil }
        return String(passage.lowercased().prefix(240))
    }

    private func chapterContext(for entry: OutlineEntry) -> [TextChunk] {
        let laterBoundary = outline
            .filter { $0.pageIndex > entry.pageIndex && $0.level <= entry.level }
            .map(\.pageIndex)
            .min() ?? pageCount
        return textChunks.filter {
            $0.pageIndex >= entry.pageIndex && $0.pageIndex < laterBoundary
        }
    }

    private func showNoteFeedback(_ message: String) {
        noteFeedbackMessage = message
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(3))
            guard self?.noteFeedbackMessage == message else { return }
            self?.noteFeedbackMessage = nil
        }
    }
}
