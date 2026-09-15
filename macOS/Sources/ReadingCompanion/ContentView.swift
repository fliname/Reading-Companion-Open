import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @EnvironmentObject private var model: ReaderModel
    @StateObject private var appUpdater = AppUpdateService.shared
    @State private var pageField = "1"
    @State private var showNotesHub = false
    @State private var showBookshelf = false
    @State private var showManualOutline = false
    @State private var isDocumentDropTargeted = false

    var body: some View {
        VStack(spacing: 0) {
            ReaderToolbar(showNotesHub: $showNotesHub, showBookshelf: $showBookshelf)
            Divider()
            ReaderColumns(
                leftVisible: model.leftSidebarVisible,
                rightVisible: model.assistantVisible || model.characterManagementVisible || showManualOutline,
                locked: model.zoomLocked
            ) {
                SidebarView(showManualOutline: $showManualOutline)
            } reader: {
                readerContent
            } right: {
                ZStack {
                    if model.characterManagementVisible, model.bookCategory == .fiction {
                        CharacterManagementPanel()
                    } else if showManualOutline {
                        ManualOutlinePanel(onClose: { showManualOutline = false })
                    } else {
                        AssistantPanel()
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            StatusBar(pageField: $pageField)
        }
        .background {
            GlobalPageKeyHandler { direction in
                guard model.document != nil, model.documentStateLoaded else { return }
                model.changePage(by: direction)
            }
            .frame(width: 0, height: 0)
        }
        .alert("Reading Companion Open", isPresented: Binding(
            get: { model.errorMessage != nil },
            set: { if !$0 { model.errorMessage = nil } }
        )) {
            Button("好", role: .cancel) { model.errorMessage = nil }
        } message: {
            Text(model.errorMessage ?? "")
        }
        .alert("发现新版本", isPresented: Binding(
            get: { appUpdater.availableUpdate != nil },
            set: { if !$0 { appUpdater.dismiss() } }
        )) {
            if let update = appUpdater.availableUpdate {
                Button("立即升级") {
                    model.statusMessage = "正在下载 macOS \(update.version) 安装包…"
                    Task {
                        do {
                            try await appUpdater.downloadAndOpen(update)
                            model.statusMessage = "安装包已打开，请按窗口提示完成升级"
                        } catch {
                            model.errorMessage = error.localizedDescription
                        }
                    }
                }
                Button("忽略此版本") { appUpdater.skip(update) }
                Button("稍后提醒", role: .cancel) { appUpdater.dismiss() }
            }
        } message: {
            if let update = appUpdater.availableUpdate {
                Text("Reading Companion Open \(update.version) 已可用。可立即下载安装，也可以稍后再升级；阅读项目和设置不会被删除。")
            }
        }
        .sheet(isPresented: $showNotesHub) {
            NotesHub()
                .environmentObject(model)
        }
        .sheet(isPresented: $showBookshelf) {
            BookshelfSheet()
                .environmentObject(model)
        }
        .sheet(isPresented: Binding(
            get: { model.pendingImportURL != nil },
            set: { if !$0 { model.cancelPendingImport() } }
        )) {
            ImportCategorySheet()
                .environmentObject(model)
        }
        .onChange(of: model.currentPageIndex) { _, page in pageField = "\(page + 1)" }
        .task { await appUpdater.checkForUpdates() }
        .overlay {
            if isDocumentDropTargeted {
                RoundedRectangle(cornerRadius: 18)
                    .fill(Color(nsColor: .windowBackgroundColor).opacity(0.92))
                    .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 3, dash: [9, 7]))
                    .padding(16)
                    .overlay {
                        Label("松开即可打开 PDF / EPUB / AZW3 / MOBI", systemImage: "doc.badge.plus")
                            .font(.title2.weight(.semibold))
                            .foregroundStyle(Color.accentColor)
                    }
                    .allowsHitTesting(false)
            }
        }
        .onDrop(
            of: [
                UTType.fileURL.identifier,
                UTType.pdf.identifier,
                ReaderModel.epubContentType.identifier,
                ReaderModel.azw3ContentType.identifier,
                ReaderModel.mobiContentType.identifier
            ],
            isTargeted: $isDocumentDropTargeted,
            perform: model.acceptDroppedURLs
        )
    }

    @ViewBuilder
    private var readerContent: some View {
        if model.document != nil && !model.documentStateLoaded {
            ProgressView("正在恢复阅读位置…").frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if model.reflowBook != nil {
            ReflowReaderView(
                model: model,
                showsTwoPages: usesTwoReflowPages
            )
                .background(Color(nsColor: .underPageBackgroundColor))
        } else if model.document != nil {
            PDFReaderView(model: model)
                .background(Color(nsColor: .underPageBackgroundColor))
        } else {
            ContentUnavailableView {
                Label("打开一本书开始伴读", systemImage: "doc.richtext")
            } description: {
                Text("拖放 PDF、EPUB、AZW3 或 MOBI 到这里，或点击下方按钮。\n电子书正文会随字号与阅读区宽度自动重排；PDF 扫描页将在本机进行 OCR。")
            } actions: {
                Button("选择文档…") { model.presentOpenPanel() }
                    .buttonStyle(.borderedProminent)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(nsColor: .underPageBackgroundColor))
        }
    }

    private var usesTwoReflowPages: Bool {
        switch model.reflowPageMode {
        case .automatic:
            !model.leftSidebarVisible && !model.assistantVisible && !showManualOutline
        case .single:
            false
        case .double:
            true
        }
    }
}

private struct GlobalPageKeyHandler: NSViewRepresentable {
    let onTurn: (Int) -> Void

    func makeNSView(context: Context) -> PageKeyCaptureView {
        PageKeyCaptureView(onTurn: onTurn)
    }

    func updateNSView(_ view: PageKeyCaptureView, context: Context) {
        view.onTurn = onTurn
    }

    static func dismantleNSView(_ view: PageKeyCaptureView, coordinator: Void) {
        view.detach()
    }
}

private final class PageKeyCaptureView: NSView {
    var onTurn: (Int) -> Void
    private var monitor: Any?

    init(onTurn: @escaping (Int) -> Void) {
        self.onTurn = onTurn
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        detach()
        guard window != nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, event.window === self.window,
                  event.modifierFlags.intersection([.command, .control, .option]).isEmpty,
                  !Self.isEditingText(in: event.window) else { return event }
            let direction: Int
            switch event.keyCode {
            case 123, 126: direction = -1
            case 124, 125: direction = 1
            default: return event
            }
            self.onTurn(direction)
            return nil
        }
    }

    func detach() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }

    private static func isEditingText(in window: NSWindow?) -> Bool {
        guard let editor = window?.firstResponder as? NSTextView else { return false }
        return editor.isEditable
    }
}

private struct ReaderToolbar: View {
    @EnvironmentObject private var model: ReaderModel
    @Binding var showNotesHub: Bool
    @Binding var showBookshelf: Bool

    var body: some View {
        HStack(spacing: 10) {
            Button { model.leftSidebarVisible.toggle() } label: {
                Image(systemName: "sidebar.left")
            }
            .disabled(model.zoomLocked)
            .help("显示或隐藏导航栏")

            Button { model.presentOpenPanel() } label: {
                Label("打开", systemImage: "folder")
            }

            Button {
                model.refreshCachedProjects()
                showBookshelf = true
            } label: {
                Label("书架", systemImage: "books.vertical")
            }
            .help("空窗口直接打开；已有项目时在新窗口打开")

            Divider().frame(height: 20)

            Menu {
                if model.reflowBook != nil {
                    Button("默认字号") { setReflowScale(1.0) }
                    Button("较小字号") { setReflowScale(0.85) }
                    Button("较大字号") { setReflowScale(1.2) }
                } else {
                    Button("整页显示") { setFit(.page) }
                    Button("适合宽度") { setFit(.width) }
                    Button("自定义缩放") { setFit(.custom) }
                }
            } label: {
                Label(fitLabel, systemImage: "rectangle.arrowtriangle.2.inward")
            }
            .menuStyle(.borderlessButton)
            .help("调整页面在阅读区中的大小")
            .disabled(model.zoomLocked)

            if model.reflowBook != nil {
                Menu {
                    ForEach(ReflowPageMode.allCases) { mode in
                        Button {
                            model.reflowPageMode = mode
                        } label: {
                            if mode == model.reflowPageMode {
                                Label(mode.rawValue, systemImage: "checkmark")
                            } else {
                                Text(mode.rawValue)
                            }
                        }
                    }
                } label: {
                    Label(model.reflowPageMode.rawValue, systemImage: model.reflowPageMode == .double ? "rectangle.split.2x1" : "rectangle")
                }
                .menuStyle(.borderlessButton)
                .help(model.reflowPageMode.detail)
                .disabled(model.zoomLocked)
            } else if model.document != nil {
                Button { model.pdfTwoPages.toggle() } label: {
                    Label(model.pdfTwoPages ? "双页" : "单页", systemImage: model.pdfTwoPages ? "rectangle.split.2x1" : "rectangle")
                }
                .help("切换 PDF 单页 / 双页阅读")
                .disabled(model.zoomLocked)
            }

            Button { adjustZoom(by: -0.1) } label: { Image(systemName: "minus.magnifyingglass") }
                .disabled(model.zoomLocked)
            Text("\(Int(model.zoomScale * 100))%")
                .frame(width: 46)
                .monospacedDigit()
            Button { adjustZoom(by: 0.1) } label: { Image(systemName: "plus.magnifyingglass") }
                .disabled(model.zoomLocked)
            Button { model.rotateCurrentPage() } label: { Image(systemName: "rotate.right") }
                .help("顺时针旋转当前页")
                .disabled(model.document == nil || model.reflowBook != nil || model.zoomLocked)
            Toggle(isOn: $model.zoomLocked) {
                Image(systemName: model.zoomLocked ? "lock.fill" : "lock.open")
            }
            .toggleStyle(.button)
            .help("锁定阅读区和左右栏宽度；PDF 翻页沿用当前可见范围")

            Divider().frame(height: 20)
            Button { model.undoHighlightChange() } label: { Image(systemName: "arrow.uturn.backward") }
                .help("撤销划线修改（⌘Z）")
                .disabled(!model.canUndoHighlight)
            Button { model.redoHighlightChange() } label: { Image(systemName: "arrow.uturn.forward") }
                .help("重做划线修改（⇧⌘Z）")
                .disabled(!model.canRedoHighlight)

            Divider().frame(height: 20)

            Button { model.toggleBookmark() } label: {
                Image(systemName: currentPageBookmarked ? "bookmark.fill" : "bookmark")
                    .foregroundStyle(currentPageBookmarked ? Color.red : Color.primary)
            }
                .help(currentPageBookmarked ? "取消当前页书签（⌘D）" : "添加当前页书签（⌘D）")
                .disabled(model.document == nil)

            HStack(spacing: 7) {
                Button { model.highlightModeEnabled.toggle() } label: {
                    Image(systemName: "highlighter")
                        .foregroundStyle(model.highlightModeEnabled ? Color.accentColor : Color.secondary)
                        .padding(5)
                        .background(
                            model.highlightModeEnabled ? Color.accentColor.opacity(0.14) : Color.clear,
                            in: RoundedRectangle(cornerRadius: 6)
                        )
                }
                .buttonStyle(.plain)
                .help(model.highlightModeEnabled ? "退出划线模式" : "进入划线模式；再次点击退出")
                HighlightColorSelector(selection: $model.highlightTint, diameter: 16)
            }
            .padding(.horizontal, 3)

            Button { showNotesHub = true } label: {
                NoteInsertIcon()
            }
            .help("Obsidian 笔记中心")
            .disabled(model.document == nil)

            Spacer(minLength: 8)

            Button { model.assistantVisible.toggle() } label: {
                Image(systemName: "sidebar.right")
            }
            .help("显示或隐藏 AI 伴读")
            .disabled(model.zoomLocked)
        }
        .buttonStyle(.borderless)
        .imageScale(.medium)
        .padding(.horizontal, 12)
        .frame(height: 46)
    }

    private func adjustZoom(by delta: Double) {
        model.fitMode = .custom
        let lowerBound = model.reflowBook == nil ? 0.2 : 0.65
        let upperBound = model.reflowBook == nil ? 6.0 : 2.25
        model.zoomScale = min(max(model.zoomScale + delta, lowerBound), upperBound)
    }

    private func setReflowScale(_ scale: Double) {
        model.zoomLocked = false
        model.fitMode = .custom
        model.zoomScale = scale
    }

    private func setFit(_ fit: ReaderFitMode) {
        model.zoomLocked = false
        model.fitMode = fit
    }

    private var fitLabel: String {
        if model.reflowBook != nil { return "字号" }
        return switch model.fitMode {
        case .page: "整页"
        case .width: "适宽"
        case .custom: "缩放"
        }
    }

    private var currentPageBookmarked: Bool {
        model.bookmarks.contains { $0.pageIndex == model.currentPageIndex }
    }
}

private struct HighlightColorSelector: View {
    @Binding var selection: HighlightTint
    var diameter: CGFloat = 18

    var body: some View {
        HStack(spacing: 6) {
            ForEach(HighlightTint.allCases) { tint in
                Button {
                    selection = tint
                } label: {
                    Circle()
                        .fill(Color(nsColor: tint.color.withAlphaComponent(1)))
                        .frame(width: diameter, height: diameter)
                        .overlay {
                            Circle().stroke(
                                selection == tint ? Color.primary : Color.clear,
                                lineWidth: 2
                            )
                        }
                        .padding(2)
                }
                .buttonStyle(.plain)
                .help(tint.rawValue)
                .accessibilityLabel("\(tint.rawValue)划线")
                .accessibilityValue(selection == tint ? "已选择" : "未选择")
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("划线颜色")
    }
}

struct NoteInsertIcon: View {
    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            Image(systemName: "note.text")
            Image(systemName: "plus.circle.fill")
                .font(.system(size: 8, weight: .bold))
                .symbolRenderingMode(.palette)
                .foregroundStyle(Color.white, Color.accentColor)
                .offset(x: 3, y: 3)
        }
        .frame(width: 18, height: 18)
        .accessibilityHidden(true)
    }
}

private enum HighlightListFilter: String, CaseIterable, Identifiable {
    case all = "全部"
    case yellow = "黄色"
    case red = "红色"
    case blue = "蓝色"
    case annotation = "批注"

    var id: String { rawValue }

    var tint: HighlightTint? {
        switch self {
        case .all: nil
        case .yellow: .yellow
        case .red: .red
        case .blue: .blue
        case .annotation: nil
        }
    }

    func matches(_ record: HighlightRecord) -> Bool {
        switch self {
        case .all: true
        case .annotation: record.markKind == .annotation
        case .yellow, .red, .blue:
            record.markKind == .highlight && record.tint == tint
        }
    }
}

private struct HighlightFilterSelector: View {
    @Binding var selection: HighlightListFilter

    var body: some View {
        HStack(spacing: 4) {
            Button { selection = .all } label: {
                Image(systemName: "circle.grid.3x3.fill")
                    .foregroundStyle(selection == .all ? Color.primary : Color.secondary)
                    .frame(width: 16, height: 16)
            }
            .help("全部颜色")
            .accessibilityLabel("全部颜色")
            ForEach(HighlightTint.allCases) { tint in
                Button { selection = filter(for: tint) } label: {
                    Circle()
                        .fill(Color(nsColor: tint.color.withAlphaComponent(1)))
                        .frame(width: 12, height: 12)
                        .overlay(Circle().stroke(selection.tint == tint ? Color.primary : Color.clear, lineWidth: 1.5))
                        .padding(2)
                }
                .buttonStyle(.plain)
                .help(tint.rawValue)
                .accessibilityLabel("筛选\(tint.rawValue)划线")
            }
            Button { selection = .annotation } label: {
                Image(systemName: "note.text")
                    .foregroundStyle(.green)
                    .overlay(alignment: .bottom) {
                        Capsule().fill(Color.green).frame(width: 14, height: 1.5).offset(y: 2)
                    }
                    .frame(width: 18, height: 18)
                    .background(selection == .annotation ? Color.green.opacity(0.12) : Color.clear, in: RoundedRectangle(cornerRadius: 4))
            }
            .buttonStyle(.plain)
            .help("只看批注")
            .accessibilityLabel("筛选批注")
        }
    }

    private func filter(for tint: HighlightTint) -> HighlightListFilter {
        switch tint {
        case .yellow: .yellow
        case .red: .red
        case .blue: .blue
        }
    }
}

private struct SidebarView: View {
    @EnvironmentObject private var model: ReaderModel
    @Binding var showManualOutline: Bool
    @State private var highlightSearch = ""
    @State private var highlightFilter: HighlightListFilter = .all
    @State private var showsOutlineSummaries = false
    @State private var expandedSummaryIDs: Set<UUID> = []
    @State private var showsOutlineTools = false
    @State private var pendingSummaryDeletionID: UUID?

    var body: some View {
        VStack(spacing: 0) {
            Picker("导航", selection: $model.selectedSidebar) {
                ForEach(availableSidebarSections) { section in
                    Image(systemName: section.symbol).tag(section)
                }
            }
            .pickerStyle(.segmented)
            .padding(10)

            Divider()

            switch model.selectedSidebar {
            case .outline: outlineList
            case .thumbnails: thumbnailList
            case .bookmarks: bookmarkList
            case .highlights: highlightList
            case .characters: characterList
            case .search: searchList
            }
        }
        .background(.regularMaterial)
        .onChange(of: model.documentURL) { _, _ in
            showsOutlineTools = false
            showsOutlineSummaries = false
            expandedSummaryIDs.removeAll()
            model.summaryStartPage = ""
            model.summaryEndPage = ""
        }
        .onChange(of: model.aiCompanionMode) { _, _ in
            expandedSummaryIDs.removeAll()
        }
        .onChange(of: model.bookCategory) { _, category in
            showsOutlineSummaries = false
            expandedSummaryIDs.removeAll()
            if category != .fiction, model.selectedSidebar == .characters {
                model.selectedSidebar = .outline
            }
            if category != .fiction { model.characterManagementVisible = false }
        }
        .onChange(of: model.selectedSidebar) { _, section in
            if section != .characters { model.characterManagementVisible = false }
        }
    }

    private var availableSidebarSections: [SidebarSection] {
        SidebarSection.allCases.filter { $0 != .characters || model.bookCategory == .fiction }
    }

    private var thumbnailList: some View {
        List(0..<model.pageCount, id: \.self) { pageIndex in
            Button { model.go(to: pageIndex) } label: {
                HStack(alignment: .center, spacing: 10) {
                    if let page = model.document?.page(at: pageIndex) {
                        Image(nsImage: page.thumbnail(of: CGSize(width: 72, height: 96), for: .cropBox))
                            .resizable()
                            .scaledToFit()
                            .frame(width: 58, height: 78)
                            .background(.white)
                            .shadow(radius: 1)
                    }
                    VStack(alignment: .leading, spacing: 3) {
                        Text("第 \(pageIndex + 1) 页")
                        if pageIndex == model.currentPageIndex {
                            Text("当前页").font(.caption).foregroundStyle(.blue)
                        }
                    }
                    Spacer()
                }
            }
            .buttonStyle(.plain)
            .listRowBackground(pageIndex == model.currentPageIndex ? Color.accentColor.opacity(0.10) : Color.clear)
        }
    }

    private var outlineList: some View {
        Group {
            if model.bookCategory == .fiction {
                ZStack {
                    outlineContents
                        .opacity(showsOutlineSummaries ? 0 : 1)
                        .allowsHitTesting(!showsOutlineSummaries)
                        .accessibilityHidden(showsOutlineSummaries)
                    fictionPageRangeSummaryPanel
                        .opacity(showsOutlineSummaries ? 1 : 0)
                        .allowsHitTesting(showsOutlineSummaries)
                        .accessibilityHidden(!showsOutlineSummaries)
                }
                .clipped()
            } else {
                outlineContents
            }
        }
        .frame(minWidth: 0, maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyPageRangeSummaryView: some View {
        VStack(spacing: 10) {
            Image(systemName: "doc.text.magnifyingglass")
                .font(.system(size: 30))
                .foregroundStyle(.secondary)
            Text("还没有概要")
                .font(.headline)
            Text("输入页码范围后生成；每次结果都会保留在这里。")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(20)
        .frame(minWidth: 0, maxWidth: .infinity, maxHeight: .infinity)
    }

    private var outlineContents: some View {
        VStack(spacing: 0) {
            HStack {
                Button {
                    showsOutlineTools.toggle()
                } label: {
                    HStack(spacing: 5) {
                        Label("目录", systemImage: "list.bullet.indent")
                        Image(systemName: showsOutlineTools ? "chevron.down" : "chevron.right")
                            .font(.system(size: 9, weight: .semibold))
                    }
                    .font(.headline)
                }
                .buttonStyle(.plain)
                .help(showsOutlineTools ? "收起目录建立工具" : "显示目录建立工具")
                Spacer()
                Button {
                    if model.bookCategory == .fiction {
                        showFictionSummaryPanel()
                    } else {
                        showsOutlineSummaries.toggle()
                        if !showsOutlineSummaries { expandedSummaryIDs.removeAll() }
                    }
                } label: {
                    Label("概要", systemImage: "list.bullet.rectangle")
                        .foregroundStyle(showsOutlineSummaries ? Color.accentColor : Color.primary)
                }
                .buttonStyle(.borderless)
                .help(model.bookCategory == .fiction
                      ? "按页码范围生成概要"
                      : (showsOutlineSummaries ? "隐藏章节概要" : "显示章节概要的展开按钮"))
            }
            .padding(.horizontal, 10)
            .padding(.top, 10)
            .padding(.bottom, 7)
            if showsOutlineTools {
                HStack(spacing: 7) {
                    Button("自动识别") { model.relocateTOC() }
                        .help("优先使用文档自带目录；没有时自动定位正文中的目录页")
                    Button("手动添加") { model.assistantVisible = true; showManualOutline = true }
                        .disabled(model.zoomLocked && !model.assistantVisible)
                        .help("每行粘贴一条目录，自动提取标题、页码和层级")
                    Button("恢复自带目录") { model.restoreEmbeddedOutline() }
                        .help(model.hasEmbeddedOutline ? "恢复文档自带目录" : "文档无自带目录")
                        .disabled(!model.hasEmbeddedOutline)
                    Spacer(minLength: 0)
                }
                .buttonStyle(.borderless)
                .controlSize(.small)
                .font(.system(size: 12))
                .padding(.horizontal, 10)
                .padding(.bottom, 7)
                .disabled(model.document == nil || model.indexingProgress < 1 || model.isRefiningOutline || model.isLocatingTOC)
            }
            HStack(spacing: 7) {
                if model.isRefiningOutline || model.isLocatingTOC { ProgressView().controlSize(.small) }
                Text(model.outlineStatus).font(.footnote).foregroundStyle(.secondary).lineLimit(1)
                Spacer()
            }
            .padding(.horizontal, 10)
            .padding(.bottom, 8)
            Divider()
            List {
                ForEach(model.outline) { entry in
                    VStack(alignment: .leading, spacing: 5) {
                        HStack(spacing: 4) {
                            if showsOutlineSummaries {
                                Button { toggleSummary(for: entry) } label: {
                                    Image(systemName: expandedSummaryIDs.contains(entry.id) ? "chevron.down" : "chevron.right")
                                        .font(.system(size: 10, weight: .semibold))
                                        .frame(width: 18, height: 18)
                                }
                                .buttonStyle(.plain)
                                .help(expandedSummaryIDs.contains(entry.id) ? "收起概要" : "展开概要")
                            }
                            Button { model.goToOutline(entry) } label: {
                                HStack(spacing: 4) {
                                    Text(entry.title).font(.system(size: 14)).lineLimit(2)
                                    Spacer()
                                    Text("\(model.outlineDisplayPages[entry.id] ?? (entry.pageIndex + 1))")
                                        .font(.system(size: 12))
                                        .foregroundStyle(.secondary)
                                        .monospacedDigit()
                                }
                            }
                            .buttonStyle(.plain)
                        }
                        .padding(.leading, CGFloat(entry.level) * 11)
                        .padding(.vertical, 2)
                        if showsOutlineSummaries, expandedSummaryIDs.contains(entry.id) {
                            chapterSummaryView(for: entry)
                                .padding(.leading, CGFloat(entry.level) * 11 + 22)
                                .padding(.trailing, 4)
                                .padding(.bottom, 5)
                        }
                    }
                    .help(model.outlineWasManuallyEdited ? "手动目录" : (model.outlineRefinedByAI ? "AI 从目录页识别并校准页码" : "文档自带目录"))
                    .listRowInsets(EdgeInsets(top: 3, leading: 8, bottom: 3, trailing: 8))
                }
            }
            .overlay {
                if model.document != nil && model.outline.isEmpty {
                    ContentUnavailableView(
                        model.hasEmbeddedOutline ? "尚无目录" : "文档无自带目录",
                        systemImage: "list.bullet.indent"
                    )
                }
            }
            Divider()
            HStack(spacing: 0) {
                Button { model.createObsidianNotebook() } label: {
                    Label("创建笔记本", systemImage: "book.closed")
                }
                Spacer(minLength: 24)
                Button { model.createObsidianSkeleton() } label: {
                    HStack(spacing: 7) {
                        NoteInsertIcon()
                        Text("添加目录")
                    }
                }
                .disabled(model.outline.isEmpty)
                Spacer(minLength: 24)
                Button { model.openObsidianNote() } label: {
                    Label("打开笔记本", systemImage: "arrow.up.forward.app")
                }
                .disabled(model.obsidianNoteURL == nil)
            }
            .frame(maxWidth: .infinity)
            .buttonStyle(.borderless)
            .padding(10)
            .background(Color.accentColor.opacity(0.035))
        }
    }

    private var fictionPageRangeSummaryPanel: some View {
        VStack(spacing: 0) {
            HStack {
                Button {
                    showsOutlineSummaries = false
                } label: {
                    Label("目录", systemImage: "chevron.left")
                }
                .buttonStyle(.borderless)
                Spacer()
                Label("概要", systemImage: "list.bullet.rectangle")
                    .font(.headline)
            }
            .padding(10)
            Divider()

            VStack(alignment: .leading, spacing: 9) {
                Text("按页码范围生成")
                    .font(.subheadline.weight(.semibold))
                HStack(spacing: 7) {
                    TextField("起始页", text: summaryPageBinding(start: true))
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 78)
                    Text("—").foregroundStyle(.secondary)
                    TextField("结束页", text: summaryPageBinding(start: false))
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 78)
                    Spacer(minLength: 0)
                    Button {
                        generateFictionPageRangeSummary()
                    } label: {
                        if model.isGeneratingPageRangeSummary {
                            ProgressView().controlSize(.small)
                        } else {
                            Text("生成")
                        }
                    }
                    .disabled(validSummaryPageRange == nil || model.isGeneratingPageRangeSummary || model.indexingProgress < 1)
                }
                Text("请输入阅读器页码，范围 1–\(max(model.pageRangeSummaryPageCount, 1))。")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .padding(10)
            Divider()

            if model.pageRangeSummaries.isEmpty {
                emptyPageRangeSummaryView
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        ForEach(model.pageRangeSummaries) { record in
                            VStack(alignment: .leading, spacing: 8) {
                                HStack(spacing: 8) {
                                    Button { model.goToPageRangeSummary(record) } label: {
                                        Label(record.pageLabel, systemImage: "book.pages")
                                            .font(.subheadline.weight(.semibold))
                                    }
                                    .buttonStyle(.plain)
                                    .help("跳转到概要对应的原文")
                                    Spacer(minLength: 0)
                                    Button(role: .destructive) {
                                        pendingSummaryDeletionID = record.id
                                    } label: {
                                        Image(systemName: "trash")
                                    }
                                    .buttonStyle(.borderless)
                                    .help("删除这条概要")
                                    .accessibilityLabel("删除\(record.pageLabel)概要")
                                }
                                Divider()
                                Text(record.summary)
                                    .font(.system(size: 12))
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                                    .contentShape(Rectangle())
                                    .onTapGesture { model.goToPageRangeSummary(record) }
                            }
                            .padding(11)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
                            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.secondary.opacity(0.16)))
                        }
                    }
                    .padding(10)
                }
            }
        }
        .frame(minWidth: 0, maxWidth: .infinity, maxHeight: .infinity)
        .background(.regularMaterial)
        .clipped()
        .confirmationDialog(
            "删除这条概要？",
            isPresented: Binding(
                get: { pendingSummaryDeletionID != nil },
                set: { if !$0 { pendingSummaryDeletionID = nil } }
            )
        ) {
            Button("删除概要", role: .destructive) {
                guard let id = pendingSummaryDeletionID else { return }
                model.deletePageRangeSummary(id: id)
                pendingSummaryDeletionID = nil
            }
            Button("取消", role: .cancel) {
                pendingSummaryDeletionID = nil
            }
        } message: {
            Text("删除后将从当前书籍的阅读记录中移除。")
        }
    }

    private func summaryPageBinding(start: Bool) -> Binding<String> {
        Binding(get: { start ? model.summaryStartPage : model.summaryEndPage }, set: { value in
            model.summaryDraftAnchors = nil
            if start { model.summaryStartPage = value } else { model.summaryEndPage = value }
        })
    }

    private var validSummaryPageRange: ClosedRange<Int>? {
        guard let start = Int(model.summaryStartPage.trimmingCharacters(in: .whitespacesAndNewlines)),
              let end = Int(model.summaryEndPage.trimmingCharacters(in: .whitespacesAndNewlines)),
              start >= 1,
              end >= start,
              end <= model.pageRangeSummaryPageCount else { return nil }
        return start...end
    }

    private func showFictionSummaryPanel() {
        showsOutlineTools = false
        showsOutlineSummaries = true
        if model.summaryStartPage.isEmpty || model.summaryEndPage.isEmpty {
            let current = model.reflowBook == nil ? model.currentPageIndex + 1 : model.reflowPageNumber
            let bounded = min(max(current, 1), max(model.pageRangeSummaryPageCount, 1))
            model.summaryStartPage = String(bounded)
            model.summaryEndPage = String(bounded)
        }
    }

    private func generateFictionPageRangeSummary() {
        guard let range = validSummaryPageRange else { return }
        model.generatePageRangeSummary(startPage: range.lowerBound, endPage: range.upperBound)
    }

    @ViewBuilder
    private func chapterSummaryView(for entry: OutlineEntry) -> some View {
        if model.isGeneratingChapterSummary(for: entry) {
            HStack(spacing: 7) {
                ProgressView().controlSize(.small)
                Text("正在梳理论证…")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 8)
        } else if let summary = model.chapterSummary(for: entry) {
            Group {
                if model.aiCompanionMode == .free {
                    Text(summary)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.vertical, 6)
                } else {
                    ChapterSummaryCards(summary: summary)
                }
            }
                .contextMenu {
                    Button("重新生成") { model.generateChapterSummary(for: entry, refresh: true) }
                }
        } else {
            Text("需要连接 AI 才能生成概要")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .padding(.vertical, 7)
        }
    }

    private func toggleSummary(for entry: OutlineEntry) {
        if expandedSummaryIDs.contains(entry.id) {
            expandedSummaryIDs.remove(entry.id)
        } else {
            expandedSummaryIDs.insert(entry.id)
            model.generateChapterSummary(for: entry)
        }
    }

    private var bookmarkList: some View {
        VStack(spacing: 0) {
            HStack {
                Text("书签").font(.headline)
                Spacer()
                Button { model.addBookmark() } label: {
                    Label("添加本页", systemImage: "bookmark.badge.plus")
                }
                .disabled(model.document == nil)
            }
            .padding(10)
            Divider()
            List {
                ForEach(model.bookmarks.sorted { $0.pageIndex < $1.pageIndex }) { bookmark in
                    HStack(spacing: 8) {
                        Button { model.go(to: bookmark.pageIndex) } label: {
                            Image(systemName: "bookmark.fill").foregroundStyle(.blue)
                        }
                        .buttonStyle(.plain)
                        .help("跳到书签")
                        TextField("书签名称", text: bookmarkTitleBinding(for: bookmark))
                            .textFieldStyle(.plain)
                            .onSubmit { model.statusMessage = "书签名称已保存" }
                        Button("P\(bookmark.pageIndex + 1)") { model.go(to: bookmark.pageIndex) }
                            .buttonStyle(.link)
                            .foregroundStyle(.secondary)
                    }
                    .contextMenu {
                        Button("删除", role: .destructive) { model.removeBookmark(bookmark) }
                    }
                }
            }
            .overlay {
                if model.bookmarks.isEmpty {
                    ContentUnavailableView("还没有书签", systemImage: "bookmark", description: Text("点击上方“添加本页”，或按 ⌘D。"))
                }
            }
        }
    }

    private func bookmarkTitleBinding(for bookmark: BookmarkRecord) -> Binding<String> {
        Binding(
            get: { model.bookmarks.first(where: { $0.id == bookmark.id })?.title ?? bookmark.title },
            set: { model.setBookmarkTitleDraft(id: bookmark.id, title: $0) }
        )
    }

    private var highlightList: some View {
        VStack(spacing: 0) {
            VStack(spacing: 6) {
                HStack(spacing: 6) {
                    TextField("搜索划线或批注", text: $highlightSearch)
                        .textFieldStyle(.roundedBorder)
                    HighlightFilterSelector(selection: $highlightFilter)
                }
                HStack {
                    Text("划线与批注").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button(allVisibleHighlightsSelected ? "取消全选" : "全选") {
                        toggleAllVisibleHighlights()
                    }
                    .buttonStyle(.borderless)
                    .disabled(filteredHighlights.isEmpty)
                }
            }
            .padding(8)
            Divider()
            List {
                ForEach(filteredHighlights) { highlight in
                    HStack(alignment: .top, spacing: 9) {
                        Toggle("", isOn: selectionBinding(for: highlight.id))
                            .labelsHidden()
                            .toggleStyle(.checkbox)
                        Button { model.go(to: highlight.pageIndex) } label: {
                            VStack(alignment: .leading, spacing: 7) {
                                HStack {
                                    Circle().fill(color(for: highlight)).frame(width: 9, height: 9)
                                    if highlight.markKind == .annotation {
                                        Text("批注").font(.caption).foregroundStyle(.green)
                                    }
                                    Text("第 \(highlight.pageIndex + 1) 页").font(.system(size: 12)).foregroundStyle(.secondary)
                                    Spacer()
                                    if highlight.note?.isEmpty == false {
                                        Image(systemName: "text.bubble.fill").foregroundStyle(.blue)
                                    }
                                    if highlight.isInNotes {
                                        Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                                            .help("已加入笔记")
                                    }
                                }
                                Text(highlight.displayText)
                                    .font(.system(size: 14))
                                    .lineSpacing(2)
                                    .lineLimit(highlight.isMergedList ? nil : 3)
                                if let note = highlight.note, !note.isEmpty {
                                    Text(note)
                                        .font(.system(size: 13))
                                        .foregroundStyle(.blue)
                                        .lineSpacing(2)
                                        .lineLimit(highlight.isMergedList ? nil : 2)
                                }
                            }
                        }
                        .buttonStyle(.plain)
                    }
                    .contextMenu {
                        Button("编辑") { model.editHighlight(highlight) }
                        Button("加入笔记") { model.sendHighlightToObsidian(highlight) }
                        Button("删除", role: .destructive) { model.deleteHighlight(highlight) }
                    }
                }
            }
            .overlay {
                if model.highlights.isEmpty {
                    ContentUnavailableView("还没有划线", systemImage: "highlighter", description: Text("拖选文字后选择“划线”。"))
                } else if filteredHighlights.isEmpty {
                    ContentUnavailableView("没有匹配的划线", systemImage: "line.3.horizontal.decrease.circle")
                }
            }
            if !model.selectedHighlightIDs.isEmpty {
                Divider()
                HStack(spacing: 16) {
                    Text("已选 \(model.selectedHighlightIDs.count) 条").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("合并") {
                        model.mergeHighlights(ids: model.selectedHighlightIDs)
                    }
                    .disabled(model.selectedHighlightIDs.count < 2)
                    Button("删除", role: .destructive) {
                        model.deleteHighlights(ids: model.selectedHighlightIDs)
                        model.selectedHighlightIDs.removeAll()
                    }
                    Button {
                        model.sendHighlightsToObsidian(selectedHighlights)
                        model.selectedHighlightIDs.removeAll()
                    } label: {
                        HStack(spacing: 5) { NoteInsertIcon(); Text("加入笔记") }
                    }
                }
                .buttonStyle(.borderless)
                .padding(.horizontal, 10)
                .padding(.vertical, 9)
            }
        }
    }

    private var filteredHighlights: [HighlightRecord] {
        let query = highlightSearch.trimmingCharacters(in: .whitespacesAndNewlines)
        return model.highlights
            .filter { highlightFilter.matches($0) }
            .filter {
                query.isEmpty || $0.text.localizedCaseInsensitiveContains(query) ||
                ($0.note?.localizedCaseInsensitiveContains(query) == true)
            }
            .sorted {
                if $0.pageIndex == $1.pageIndex { return $0.createdAt < $1.createdAt }
                return $0.pageIndex < $1.pageIndex
            }
    }

    private var selectedHighlights: [HighlightRecord] {
        model.highlights.filter { model.selectedHighlightIDs.contains($0.id) }
    }

    private func selectionBinding(for id: UUID) -> Binding<Bool> {
        Binding(
            get: { model.selectedHighlightIDs.contains(id) },
            set: { selected in
                if selected { model.selectedHighlightIDs.insert(id) }
                else { model.selectedHighlightIDs.remove(id) }
            }
        )
    }

    private var allVisibleHighlightsSelected: Bool {
        !filteredHighlights.isEmpty && filteredHighlights.allSatisfy { model.selectedHighlightIDs.contains($0.id) }
    }

    private func toggleAllVisibleHighlights() {
        let ids = Set(filteredHighlights.map(\.id))
        if allVisibleHighlightsSelected {
            model.selectedHighlightIDs.subtract(ids)
        } else {
            model.selectedHighlightIDs.formUnion(ids)
        }
    }

    private var characterList: some View {
        CharacterSidebarContent()
            .environmentObject(model)
    }

    private var searchList: some View {
        VStack(spacing: 0) {
            HStack {
                TextField("搜索全文", text: $model.searchQuery)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { model.performSearch() }
                Button { model.performSearch() } label: { Image(systemName: "arrow.right.circle.fill") }
                    .buttonStyle(.borderless)
            }
            .padding(10)
            Divider()
            List(model.searchResults) { result in
                Button { model.go(toSearchResult: result) } label: {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(highlightedSearchResult(result.text))
                            .lineLimit(4)
                        Text("第 \(result.pageIndex + 1) 页").font(.caption).foregroundStyle(.secondary)
                    }
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func highlightedSearchResult(_ text: String) -> AttributedString {
        var result = AttributedString(text)
        for range in ReaderModel.searchMatchRanges(query: model.searchQuery, in: text) {
            guard let attributedRange = Range(range, in: result) else { continue }
            result[attributedRange].backgroundColor = .yellow
            result[attributedRange].foregroundColor = .black
        }
        return result
    }

    private func color(for highlight: HighlightRecord) -> Color {
        highlight.markKind == .annotation
            ? .green
            : Color(nsColor: highlight.tint.color.withAlphaComponent(1))
    }
}

private struct AssistantPanel: View {
    @EnvironmentObject private var model: ReaderModel
    @State private var showLastRoundUsage = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 9) {
                Text("AI 伴读 · \(model.bookCategory?.rawValue ?? "未分类")")
                    .font(.title3.bold())
                    .fixedSize()
                Spacer(minLength: 4)
                SettingsLink { Image(systemName: "gearshape") }
                    .buttonStyle(.borderless)
                    .help("打开设置")
            }
            .padding(.horizontal, 12)
            .padding(.top, 10)
            HStack(spacing: 9) {
                modelMenu
                if model.aiCompanionMode == .academic { depthMenu }
                usageButton
                Spacer(minLength: 4)
                Text(model.indexingStatus)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .padding(.horizontal, 12)
            .padding(.top, 4)
            .padding(.bottom, 9)
            if model.isImportingDocument || (model.document != nil && model.indexingProgress < 1) {
                ProgressView(value: model.indexingProgress)
                    .progressViewStyle(.linear)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 8)
            }
            Divider()
            APIAssistantPanel()
        }
        .background(.regularMaterial)
    }

    private var modelMenu: some View {
        Menu {
            if model.aiModelChoices.isEmpty {
                Text("先在设置中验证 API Key")
            } else {
                ForEach(model.aiModelChoices, id: \.self) { name in
                    Button {
                        model.selectAIModel(name)
                    } label: {
                        if name == model.aiModel { Label(name, systemImage: "checkmark") }
                        else { Text(name) }
                    }
                }
                Divider()
                Button("刷新模型") { model.refreshAvailableAIModels() }
                    .disabled(!model.hasActiveAPIKey || model.isLoadingAIModels)
            }
        } label: {
            Text(shortModelName)
                .font(.system(size: 12, weight: .medium))
                .lineLimit(1)
                .frame(maxWidth: 118)
        }
        .menuStyle(.borderlessButton)
        .help("切换 API 模型")
    }

    private var depthMenu: some View {
        Menu {
            ForEach(AIReadingDepth.allCases) { depth in
                Button {
                    model.aiReadingDepth = depth
                } label: {
                    if depth == model.aiReadingDepth { Label(depth.rawValue, systemImage: "checkmark") }
                    else { Text(depth.rawValue) }
                }
            }
        } label: {
            Text(model.aiReadingDepth.rawValue)
                .font(.system(size: 12, weight: .medium))
        }
        .menuStyle(.borderlessButton)
        .help(model.aiReadingDepth.detail)
    }

    private var usageButton: some View {
        Button { showLastRoundUsage.toggle() } label: {
            Label("上轮用量", systemImage: "gauge.with.dots.needle.33percent")
                .font(.system(size: 12, weight: .medium))
        }
        .buttonStyle(.borderless)
        .disabled(lastRoundTurn == nil)
        .help("查看上一轮问答的 Token 与缓存数据")
        .popover(isPresented: $showLastRoundUsage, arrowEdge: .top) {
            if let turn = lastRoundTurn { LastRoundUsageView(turn: turn) }
            else { Text("还没有可查看的问答").padding() }
        }
    }

    private var lastRoundTurn: ChatTurn? {
        model.chatTurns.last { $0.role == .assistant }
    }

    private var shortModelName: String {
        guard !model.aiModel.isEmpty else { return "模型" }
        return model.aiModel.count > 18 ? String(model.aiModel.prefix(17)) + "…" : model.aiModel
    }
}

private struct LastRoundUsageView: View {
    let turn: ChatTurn

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("上一轮用量", systemImage: "gauge.with.dots.needle.33percent")
                    .font(.headline)
                Spacer()
                Text(turn.createdAt, style: .time)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Divider()
            metric("模型", turn.requestModel ?? "未记录")
            metric("服务商", turn.requestProvider?.rawValue ?? "未记录")
            metric("阅读深度", turn.requestDepth?.rawValue ?? "未记录")
            metric("读取范围", scopeDescription)
            if let count = turn.contextChunkCount {
                metric("本地证据", "\(count) 个片段" + estimatedContextSuffix)
            }
            Divider()
            if turn.wasServedFromLocalCache {
                Label("本地回答缓存命中，本轮未调用 API，消耗 0 Token。", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            } else if let usage = turn.apiUsage {
                metric("输入 Token", usageValue(usage.inputTokens, usage: usage))
                metric("未缓存输入", usageValue(usage.uncachedInputTokens, usage: usage))
                metric("缓存命中", formatted(usage.cachedInputTokens) + cacheRateSuffix(usage))
                if usage.cacheWriteTokens > 0 { metric("缓存写入", formatted(usage.cacheWriteTokens)) }
                metric("输出 Token", usageValue(usage.outputTokens, usage: usage))
                if usage.reasoningTokens > 0 { metric("推理 Token", formatted(usage.reasoningTokens)) }
                metric("合计", usageValue(usage.totalTokens, usage: usage))
            } else {
                Text("该服务商没有返回标准 usage 数据，因此无法显示准确 Token。")
                    .foregroundStyle(.secondary)
            }
            Text(turn.apiUsage?.isEstimated == true
                 ? "服务商未返回完整 usage；带“约”的数据由本机估算，实际费用以平台账单为准。"
                 : "Token 数来自服务商响应；费用还取决于模型单价与平台计费规则。")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(16)
        .frame(width: 340)
    }

    private var scopeDescription: String {
        (turn.usedWholeBook == true ? "联系全书" : "章节内") + (turn.usedWebSearch == true ? " · 联网" : "")
    }

    private var estimatedContextSuffix: String {
        guard let tokens = turn.estimatedContextTokens else { return "" }
        return " · 约 \(formatted(tokens)) Token"
    }

    private func cacheRateSuffix(_ usage: APIUsage) -> String {
        guard let rate = usage.cacheHitRate else { return "" }
        return "（\(Int((rate * 100).rounded()))%）"
    }

    private func formatted(_ value: Int) -> String {
        value.formatted(.number.grouping(.automatic))
    }

    private func usageValue(_ value: Int, usage: APIUsage) -> String {
        (usage.isEstimated == true ? "约 " : "") + formatted(value)
    }

    private func metric(_ title: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(title).foregroundStyle(.secondary)
            Spacer(minLength: 12)
            Text(value).multilineTextAlignment(.trailing).textSelection(.enabled)
        }
        .font(.callout)
    }
}

private struct APIAssistantPanel: View {
    @EnvironmentObject private var model: ReaderModel
    @StateObject private var speech = SpeechInputService()
    @State private var speechPrefix = ""
    @State private var showDraftBrowser = false
    @State private var showChatNoteSheet = false
    @State private var showConversationOverview = false
    @State private var showDeleteConfirmation = false
    @State private var chatNoteMode: ChatNoteExportMode = .original
    @State private var collapseChatNote = false
    @FocusState private var draftFocused: Bool
    var body: some View {
        VStack(spacing: 0) {
            if apiTurns.isEmpty {
                Spacer()
                Image(systemName: "text.bubble").font(.system(size: 28)).foregroundStyle(.secondary)
                Text("在原文旁边思考").font(.headline).padding(.top, 8)
                Text("全书索引完成后即可提问。\n问题会保留原文位置，默认只发送当前章节的相关片段。")
                    .multilineTextAlignment(.center).foregroundStyle(.secondary).font(.callout).padding()
                Spacer()
            } else {
                VStack(spacing: 0) {
                    HStack {
                        Text("对话").font(.callout).foregroundStyle(.secondary)
                        Spacer()
                        Button(allChatsSelected ? "取消全选" : "全选") { toggleAllChats() }
                            .buttonStyle(.borderless)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 9)
                    Divider()
                    ScrollViewReader { proxy in
                        ZStack(alignment: .trailing) {
                            List {
                                ForEach($model.chatTurns) { $turn in
                                    HStack(alignment: .top, spacing: 10) {
                                        Toggle("", isOn: $turn.selectedForNotes)
                                            .labelsHidden()
                                            .toggleStyle(.checkbox)
                                        VStack(alignment: .leading, spacing: 8) {
                                            HStack {
                                                Text(turn.role == .user ? "你" : "伴读")
                                                if turn.isInNotes {
                                                    Label("已加入", systemImage: "checkmark.circle.fill")
                                                        .foregroundStyle(.green)
                                                }
                                            }
                                            .font(.system(size: 13, weight: .medium))
                                            .foregroundStyle(.secondary)
                                            ResourceAwareMessage(
                                                content: turn.content,
                                                isAssistant: turn.role == .assistant
                                            )
                                                .font(.system(size: 14))
                                            if turn.role == .assistant, turn.wasServedFromLocalCache {
                                                Label("本地缓存 · 未调用 API", systemImage: "bolt.horizontal.circle")
                                                    .font(.caption)
                                                    .foregroundStyle(.green)
                                            } else if turn.role == .assistant, let usage = turn.apiUsage {
                                                Label(usage.compactDescription, systemImage: "gauge.with.dots.needle.33percent")
                                                    .font(.caption)
                                                    .foregroundStyle(.secondary)
                                            }
                                            if turn.role == .user && !turn.pageReferences.isEmpty {
                                                ScrollView(.horizontal, showsIndicators: false) {
                                                    HStack(spacing: 8) {
                                                        ForEach(turn.pageReferences, id: \.self) { page in
                                                            Button("P\(page + 1)") { model.go(to: page) }
                                                                .buttonStyle(.link)
                                                                .font(.system(size: 13))
                                                        }
                                                    }
                                                }
                                            }
                                        }
                                    }
                                    .padding(9)
                                    .background(.background.opacity(0.55), in: RoundedRectangle(cornerRadius: 9))
                                    .listRowInsets(EdgeInsets(top: 4, leading: 11, bottom: 4, trailing: 30))
                                    .listRowSeparator(.hidden)
                                    .id(turn.id)
                                }
                            }
                            Button { showConversationOverview.toggle() } label: {
                                Image(systemName: "rectangle.stack")
                                    .font(.system(size: 14, weight: .medium))
                                    .padding(7)
                                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 7))
                                    .shadow(radius: 2)
                            }
                            .buttonStyle(.plain)
                            .padding(.trailing, 5)
                            .help("对话速览")
                            .onHover { hovering in
                                if hovering { showConversationOverview = true }
                            }
                            .popover(isPresented: $showConversationOverview, arrowEdge: .trailing) {
                                conversationOverview(proxy: proxy)
                            }
                        }
                    }
                    if model.isAnswering {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text(model.isSearchingWeb ? "正在联网查找并整理资源…" : "正在查找原文并生成回答…")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Spacer()
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                    }
                }
            }

            Divider()
            VStack(spacing: 10) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        if model.aiCompanionMode == .academic {
                            QuickQuestion("解释一下", action: "解释")
                            QuickQuestion("联系上下文", action: "上下文")
                            QuickQuestion("链接资源", action: "资源", systemImage: "globe")
                            Toggle(isOn: $model.assistantUsesLJGReadSkill) {
                                Text("ljg-read")
                            }
                            .toggleStyle(.button)
                            .controlSize(.small)
                            .help(model.assistantUsesLJGReadSkill
                                  ? "已开启 ljg-read 伴读 Skill"
                                  : "已关闭 ljg-read；下一轮使用基础原文问答")
                            .onChange(of: model.assistantUsesLJGReadSkill) { _, _ in model.persist() }
                        }
                        Toggle(isOn: $model.assistantUsesWholeBook) {
                            Label("联系全书", systemImage: "books.vertical")
                        }
                        .toggleStyle(.button)
                        .controlSize(.small)
                        .help(model.assistantUsesWholeBook
                              ? "本次将结合全书目录和跨章节相关片段"
                              : "默认只发送当前章节附近的相关原文；点此仅对下一问联系全书")
                    }
                }
                TextEditor(text: $model.assistantDraft)
                    .font(.body)
                    .focused($draftFocused)
                    .scrollContentBackground(.hidden)
                    .padding(7)
                    .frame(minHeight: 76, maxHeight: 150)
                    .background(.background.opacity(0.75), in: RoundedRectangle(cornerRadius: 7))
                    .overlay(RoundedRectangle(cornerRadius: 7).stroke(.separator))
                    .disabled(model.document == nil)
                HStack(spacing: 10) {
                    Button { showDraftBrowser = true } label: {
                        Label("展开", systemImage: "arrow.up.left.and.arrow.down.right")
                    }
                        .disabled(model.document == nil)
                        .help("展开浏览和编辑完整问题")
                        .popover(isPresented: $showDraftBrowser, arrowEdge: .top) {
                            VStack(alignment: .leading, spacing: 10) {
                                Text("完整问题").font(.headline)
                                TextEditor(text: $model.assistantDraft)
                                    .font(.body)
                                    .frame(width: 380, height: 220)
                                    .overlay(RoundedRectangle(cornerRadius: 7).stroke(.separator))
                                HStack {
                                    Text("\(model.assistantDraft.count) 字").font(.caption).foregroundStyle(.secondary)
                                    Spacer()
                                    Button("完成") { showDraftBrowser = false }
                                    Button("发送") {
                                        showDraftBrowser = false
                                        submit()
                                    }
                                    .buttonStyle(.borderedProminent)
                                    .disabled(model.assistantDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || model.isAnswering)
                                }
                            }
                            .padding(14)
                        }
                    Button {
                        let wasRecording = speech.isRecording
                        let preservedDraft = model.assistantDraft
                        if !wasRecording { speechPrefix = model.assistantDraft }
                        Task {
                            await speech.toggle()
                            if wasRecording && model.assistantDraft.isEmpty {
                                model.assistantDraft = preservedDraft
                            }
                        }
                    } label: {
                        Label(speech.isRecording ? "结束" : "语音", systemImage: speech.isRecording ? "waveform.circle.fill" : "mic")
                            .foregroundStyle(speech.isRecording ? Color.red : Color.primary)
                    }
                        .disabled(model.document == nil)
                        .help(speech.status)
                    Spacer()
                    sendButton
                }
                HStack {
                    Text("已选 \(selectedChatCount) 条")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("删除", role: .destructive) { showDeleteConfirmation = true }
                        .disabled(selectedChatCount == 0 || model.isAnswering)
                    Button { showChatNoteSheet = true } label: {
                        HStack(spacing: 5) { NoteInsertIcon(); Text("加入笔记") }
                    }
                        .disabled(selectedChatCount == 0 || model.isExportingChatNote)
                }
            }
            .padding(12)
        }
        .onChange(of: speech.transcript) { _, transcript in
            guard !transcript.isEmpty else { return }
            let separator = speechPrefix.isEmpty || transcript.isEmpty ? "" : " "
            model.assistantDraft = speechPrefix + separator + transcript
        }
        .onChange(of: speech.lastError) { _, error in
            if let error { model.errorMessage = error }
        }
        .sheet(isPresented: $showChatNoteSheet) {
            ChatNoteExportSheet(
                selectedCount: selectedChatCount,
                mode: $chatNoteMode,
                collapsed: $collapseChatNote
            ) {
                showChatNoteSheet = false
                model.sendSelectedChatsToObsidian(mode: chatNoteMode, collapsed: collapseChatNote)
            }
        }
        .confirmationDialog(
            "删除选中的 \(selectedChatCount) 条对话？",
            isPresented: $showDeleteConfirmation,
            titleVisibility: .visible
        ) {
            Button("删除对话", role: .destructive) { model.deleteSelectedChats() }
            Button("取消", role: .cancel) {}
        } message: {
            Text("删除后无法恢复；已经写入 Obsidian 的内容不会被删除。")
        }
        .onDisappear { speech.stop() }
    }

    private var allChatsSelected: Bool {
        !apiTurns.isEmpty && apiTurns.allSatisfy(\.selectedForNotes)
    }

    private var selectedChatCount: Int {
        apiTurns.filter(\.selectedForNotes).count
    }

    private var apiTurns: [ChatTurn] {
        model.chatTurns
    }

    private func toggleAllChats() {
        let shouldSelect = !allChatsSelected
        for index in model.chatTurns.indices {
            model.chatTurns[index].selectedForNotes = shouldSelect
        }
        model.persist()
    }

    @ViewBuilder
    private func conversationOverview(proxy: ScrollViewProxy) -> some View {
        let items = conversationOverviewItems
        VStack(alignment: .leading, spacing: 0) {
            Text("问题速览")
                .font(.headline)
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
            Divider()
            if items.isEmpty {
                Text("还没有问题")
                    .foregroundStyle(.secondary)
                    .padding(14)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                            Button {
                                withAnimation { proxy.scrollTo(item.turnID, anchor: .top) }
                                showConversationOverview = false
                            } label: {
                                HStack(alignment: .top, spacing: 8) {
                                    Text("\(index + 1)")
                                        .font(.caption.monospacedDigit())
                                        .foregroundStyle(.secondary)
                                        .frame(width: 22, alignment: .trailing)
                                    Text(QuestionOverview.preview(item.question, answer: item.answer))
                                        .font(.system(size: 13))
                                        .lineLimit(2)
                                        .multilineTextAlignment(.leading)
                                    Spacer(minLength: 0)
                                }
                                .padding(.horizontal, 10)
                                .padding(.vertical, 7)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.vertical, 5)
                }
            }
        }
        .frame(width: 320, height: min(CGFloat(items.count * 54 + 48), 390))
    }

    private func QuickQuestion(_ title: String, action: String, systemImage: String? = nil) -> some View {
        Button {
            model.applyQuickQuestion(action)
            draftFocused = false
        } label: {
            if let systemImage { Label(title, systemImage: systemImage) }
            else { Text(title) }
        }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(model.document == nil)
    }

    private func submit() {
        let submitted = model.assistantDraft
        model.assistantDraft = ""
        model.submitQuestion(submitted)
    }

    @ViewBuilder
    private var sendButton: some View {
        if model.isAnswering {
            Button { model.cancelAnswer() } label: {
                Label("取消", systemImage: "xmark")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 16)
                    .frame(height: 38)
                    .background(Color.red, in: Capsule())
            }
            .buttonStyle(.plain)
            .help("立即中止当前请求并恢复问题；服务商已处理的部分仍可能计费")
        } else {
            let button = Button { submit() } label: {
                Label("发送", systemImage: "arrow.up")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 16)
                    .frame(height: 38)
                    .background(Color.accentColor, in: Capsule())
            }
            .buttonStyle(.plain)
            .disabled(model.assistantDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || model.document == nil)
            .help(draftFocused ? "输入框内回车换行" : "发送（回车）")

            if draftFocused || showDraftBrowser {
                button
            } else {
                button.keyboardShortcut(.return, modifiers: [])
            }
        }
    }

    private var conversationOverviewItems: [ConversationOverviewItem] {
        let turns = apiTurns
        return turns.indices.compactMap { index in
            guard turns[index].role == .user else { return nil }
            let answer = turns.dropFirst(index + 1).first(where: { $0.role == .assistant })?.content
            return ConversationOverviewItem(turnID: turns[index].id, question: turns[index].content, answer: answer)
        }
    }

}

private struct ConversationOverviewItem: Identifiable {
    var turnID: UUID
    var question: String
    var answer: String?
    var id: UUID { turnID }
}

private struct MarkdownMessage: View {
    let content: String
    var accent: Color = .primary

    var body: some View {
        if let attributed = styledMarkdown() {
            Text(attributed)
                .font(.system(size: 14))
                .lineSpacing(8)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        } else {
            Text(content)
                .font(.system(size: 14))
                .lineSpacing(8)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func styledMarkdown() -> AttributedString? {
        guard var attributed = try? AttributedString(markdown: content) else { return nil }
        let emphasized = attributed.runs.compactMap { run in
            run.inlinePresentationIntent?.contains(.stronglyEmphasized) == true ? run.range : nil
        }
        for range in emphasized {
            attributed[range].foregroundColor = accent
            attributed[range].underlineStyle = .single
        }
        return attributed
    }
}

private struct ResourceLinkItem: Identifiable {
    let id = UUID()
    let title: String
    let url: URL
    let summary: String
}

private struct ResourceAwareMessage: View {
    let content: String
    let isAssistant: Bool

    var body: some View {
        let links = Self.extractLinks(from: content)
        if links.count >= 2 {
            VStack(spacing: 9) {
                ForEach(links) { item in
                    Link(destination: item.url) {
                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: "globe")
                                .font(.title3)
                                .foregroundStyle(.blue)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(item.title).font(.system(size: 14, weight: .semibold))
                                if !item.summary.isEmpty {
                                    Text(item.summary)
                                        .font(.system(size: 13))
                                        .lineSpacing(4)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(2)
                                }
                            }
                            Spacer(minLength: 6)
                            Image(systemName: "arrow.up.right.square")
                                .foregroundStyle(.secondary)
                        }
                        .padding(11)
                        .background(Color.blue.opacity(0.07), in: RoundedRectangle(cornerRadius: 10))
                        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.blue.opacity(0.18)))
                    }
                    .buttonStyle(.plain)
                }
            }
        } else {
            if isAssistant {
                ReadableAIMessage(content: content)
            } else {
                MarkdownMessage(content: content)
            }
        }
    }

    static func extractLinks(from content: String) -> [ResourceLinkItem] {
        guard let expression = try? NSRegularExpression(
            pattern: #"\[([^\]]+)\]\((https?://[^\s\)]+)\)"#
        ) else { return [] }
        let lines = content.components(separatedBy: .newlines)
        var items: [ResourceLinkItem] = []
        var seen = Set<String>()
        for (index, line) in lines.enumerated() where items.count < 5 {
            let range = NSRange(line.startIndex..<line.endIndex, in: line)
            guard let match = expression.firstMatch(in: line, range: range),
                  let titleRange = Range(match.range(at: 1), in: line),
                  let urlRange = Range(match.range(at: 2), in: line) else { continue }
            let urlString = String(line[urlRange])
            guard seen.insert(urlString).inserted, let url = URL(string: urlString) else { continue }
            let afterLink = Range(match.range(at: 0), in: line).map { String(line[$0.upperBound...]) } ?? ""
            var summary = cleaned(afterLink)
            if summary.isEmpty {
                summary = lines.dropFirst(index + 1)
                    .map(cleaned)
                    .first(where: { !$0.isEmpty && !$0.hasPrefix("#") }) ?? ""
            }
            items.append(ResourceLinkItem(
                title: String(line[titleRange]),
                url: url,
                summary: summary
            ))
        }
        return items
    }

    private static func cleaned(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: #"^[\s:：—–\-*]+"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"[*_`]+"#, with: "", options: .regularExpression)
    }
}

private struct AIMessageSection: Identifiable {
    let id = UUID()
    var title: String?
    var body: String
}

private struct ReadableAIMessage: View {
    let content: String
    private let accents: [Color] = [.indigo, .teal, .orange, .purple]

    var body: some View {
        let sections = parse(content)
        VStack(alignment: .leading, spacing: 12) {
            ForEach(Array(sections.enumerated()), id: \.element.id) { index, section in
                let accent = accents[index % accents.count]
                VStack(alignment: .leading, spacing: 8) {
                    if let title = section.title {
                        Text(title)
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(accent)
                    }
                    MarkdownMessage(content: section.body, accent: accent)
                }
                .padding(.vertical, 10)
                .padding(.horizontal, 12)
                .background(accent.opacity(0.055), in: RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(accent.opacity(0.14)))
            }
        }
    }

    private func parse(_ source: String) -> [AIMessageSection] {
        let source = AIResponseFormatter.normalized(source)
        var sections: [AIMessageSection] = []
        var title: String?
        var lines: [String] = []
        func appendCurrent() {
            let body = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            if !body.isEmpty { sections.append(AIMessageSection(title: title, body: body)) }
            lines = []
        }
        for line in source.components(separatedBy: .newlines) {
            if line.range(of: #"^#{2,4}\s+\S"#, options: .regularExpression) != nil {
                appendCurrent()
                title = line.replacingOccurrences(of: #"^#{2,4}\s+"#, with: "", options: .regularExpression)
            } else {
                lines.append(line)
            }
        }
        appendCurrent()
        return sections.isEmpty ? [AIMessageSection(title: nil, body: source)] : sections
    }
}

private struct BookshelfSheet: View {
    @EnvironmentObject private var model: ReaderModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openWindow) private var openWindow
    @State private var pendingDeletionIDs: Set<String> = []
    @State private var selectedProjectIDs: Set<String> = []
    @State private var isSelecting = false
    @State private var selectedFilter: BookshelfFilter = .all
    @State private var showsNewFolder = false
    @State private var newFolderName = ""
    @State private var pendingFolderDeletion: BookshelfFolder?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Label("书架", systemImage: "books.vertical").font(.title2.bold())
                Button {
                    newFolderName = ""
                    showsNewFolder = true
                } label: {
                    Label("新建文件夹", systemImage: "folder.badge.plus")
                }
                Button(isSelecting ? "取消" : "批量管理") {
                    isSelecting.toggle()
                    if !isSelecting { selectedProjectIDs.removeAll() }
                }
                if isSelecting {
                    Button(selectedProjectIDs.isSuperset(of: Set(filteredProjects.map(\.id))) ? "取消全选" : "全选") {
                        let visibleIDs = Set(filteredProjects.map(\.id))
                        if selectedProjectIDs.isSuperset(of: visibleIDs) {
                            selectedProjectIDs.subtract(visibleIDs)
                        } else {
                            selectedProjectIDs.formUnion(visibleIDs)
                        }
                    }
                    .disabled(filteredProjects.isEmpty)
                    Menu {
                        ForEach(model.bookshelfFolders) { folder in
                            Button {
                                organizeSelected(into: folder)
                            } label: {
                                Label(folder.title, systemImage: "folder.badge.plus")
                            }
                        }
                    } label: {
                        Label("整理到文件夹", systemImage: "folder")
                    }
                    .disabled(selectedProjectIDs.isEmpty || model.bookshelfFolders.isEmpty)
                    Menu {
                        Button {
                            categorizeSelected(as: .nonfiction)
                        } label: {
                            Label("非虚构类", systemImage: "text.book.closed")
                        }
                        Button {
                            categorizeSelected(as: .fiction)
                        } label: {
                            Label("虚构类", systemImage: "theatermasks")
                        }
                    } label: {
                        Label("修改分类", systemImage: "tag")
                    }
                    .disabled(selectedProjectIDs.isEmpty)
                    Button(role: .destructive) {
                        pendingDeletionIDs = selectedProjectIDs
                    } label: {
                        Label("删除", systemImage: "trash")
                    }
                    .disabled(selectedProjectIDs.isEmpty)
                }
                Spacer()
                Text("\(filteredProjects.count) 本")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Button("完成") { dismiss() }
            }
            .padding(16)
            Divider()
            HSplitView {
                List(selection: $selectedFilter) {
                    Label("全部书籍", systemImage: "books.vertical").tag(BookshelfFilter.all)
                    Section("书籍类型") {
                        Label("非虚构类", systemImage: "text.book.closed")
                            .tag(BookshelfFilter.category(.nonfiction))
                        Label("虚构类", systemImage: "theatermasks")
                            .tag(BookshelfFilter.category(.fiction))
                    }
                    Section("文件夹") {
                        ForEach(model.bookshelfFolders) { folder in
                            HStack {
                                Label(folder.title, systemImage: "folder")
                                Spacer()
                                if isSelecting {
                                    Button(role: .destructive) {
                                        pendingFolderDeletion = folder
                                    } label: {
                                        Image(systemName: "trash")
                                    }
                                    .buttonStyle(.borderless)
                                    .help("删除文件夹，书籍仍保留在书架")
                                    .accessibilityLabel("删除文件夹“\(folder.title)”")
                                }
                            }
                                .tag(BookshelfFilter.folder(folder.id))
                        }
                    }
                }
                .frame(minWidth: 175, idealWidth: 190, maxWidth: 230)

                Group {
                    if model.cachedProjects.isEmpty {
                        ContentUnavailableView(
                            "书架还是空的",
                            systemImage: "books.vertical",
                            description: Text("打开 PDF、EPUB、AZW3 或 MOBI 后，书籍会以封面形式保存在这里。")
                        )
                    } else if filteredProjects.isEmpty {
                        ContentUnavailableView("这个文件夹是空的", systemImage: "folder")
                    } else {
                        ScrollView {
                            LazyVGrid(
                                columns: Array(repeating: GridItem(.fixed(150), spacing: 22), count: 4),
                                alignment: .leading,
                                spacing: 24
                            ) {
                                ForEach(filteredProjects) { project in
                                    projectCard(project)
                                }
                            }
                            .padding(22)
                            .frame(maxWidth: .infinity, alignment: .topLeading)
                        }
                    }
                }
                .frame(minWidth: 700, maxWidth: .infinity, maxHeight: .infinity)
                .layoutPriority(1)
            }
        }
        .frame(width: 980, height: 650)
        .onAppear { model.refreshCachedProjects() }
        .alert("新建文件夹", isPresented: $showsNewFolder) {
            TextField("文件夹名称", text: $newFolderName)
            Button("取消", role: .cancel) {}
            Button("建立") { model.createBookshelfFolder(named: newFolderName) }
        } message: {
            Text("文件夹只整理书架，不会移动原始书籍文件。")
        }
        .alert(
            pendingFolderDeletion.map { "删除文件夹“\($0.title)”？" } ?? "删除文件夹？",
            isPresented: Binding(
                get: { pendingFolderDeletion != nil },
                set: { if !$0 { pendingFolderDeletion = nil } }
            )
        ) {
            Button("取消", role: .cancel) { pendingFolderDeletion = nil }
            Button("删除文件夹", role: .destructive) {
                guard let folder = pendingFolderDeletion else { return }
                model.deleteBookshelfFolder(folder)
                if selectedFilter == .folder(folder.id) { selectedFilter = .all }
                pendingFolderDeletion = nil
            }
        } message: {
            Text("只删除文件夹；其中的书仍保留在书架中。")
        }
        .confirmationDialog(
            pendingDeletionIDs.count > 1
                ? "删除所选的 \(pendingDeletionIDs.count) 本书及其全部缓存？"
                : "删除这本书及其全部缓存？",
            isPresented: Binding(
                get: { !pendingDeletionIDs.isEmpty },
                set: { if !$0 { pendingDeletionIDs.removeAll() } }
            ),
            titleVisibility: .visible
        ) {
            Button("删除缓存", role: .destructive) {
                model.deleteCachedProjects(model.cachedProjects.filter { pendingDeletionIDs.contains($0.id) })
                selectedProjectIDs.subtract(pendingDeletionIDs)
                pendingDeletionIDs.removeAll()
            }
            Button("取消", role: .cancel) { pendingDeletionIDs.removeAll() }
        } message: {
            Text("阅读进度、目录、概要、划线、批注、AI 对话及排版/OCR/索引缓存都会被清除。原始文档和 Obsidian 笔记不会被删除；再次打开时会作为全新项目重新处理。")
        }
    }

    private var filteredProjects: [CachedProject] {
        switch selectedFilter {
        case .all: model.cachedProjects
        case .category(let category): model.cachedProjects.filter { $0.category == category }
        case .folder(let id): model.cachedProjects.filter { $0.assignedFolderIDs.contains(id) }
        }
    }

    private var selectedProjects: [CachedProject] {
        model.cachedProjects.filter { selectedProjectIDs.contains($0.id) }
    }

    private func projectCard(_ project: CachedProject) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                if isSelecting { toggleSelection(project) } else { open(project) }
            } label: {
                ZStack {
                    RoundedRectangle(cornerRadius: 5)
                        .fill(Color(nsColor: .controlBackgroundColor))
                    if let image = coverImage(for: project) {
                        Image(nsImage: image)
                            .resizable()
                            .scaledToFill()
                    } else {
                        VStack(spacing: 10) {
                            Image(systemName: project.isAvailable ? "book.closed.fill" : "questionmark.folder")
                                .font(.system(size: 36))
                            Text(project.title)
                                .font(.caption.bold())
                                .multilineTextAlignment(.center)
                                .lineLimit(4)
                                .padding(.horizontal, 10)
                        }
                        .foregroundStyle(.secondary)
                    }
                }
                .frame(width: 135, height: 190)
                .clipped()
                .shadow(color: .black.opacity(0.18), radius: 4, y: 3)
                .overlay(alignment: .topTrailing) {
                    if isSelecting {
                        Image(systemName: selectedProjectIDs.contains(project.id) ? "checkmark.circle.fill" : "circle")
                            .font(.title2)
                            .foregroundStyle(selectedProjectIDs.contains(project.id) ? Color.accentColor : Color.white)
                            .shadow(radius: 2)
                            .padding(7)
                    } else if model.documentURL?.standardizedFileURL.path == project.sourcePath {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.white, Color.accentColor)
                            .padding(7)
                    }
                }
            }
            .buttonStyle(.plain)
            .disabled(!isSelecting && (!project.isAvailable || openDestination(for: project) == .alreadyOpen))

            HStack(spacing: 6) {
                Circle()
                    .fill(project.category.map { Color(nsColor: $0.markerColor) } ?? Color.gray)
                    .frame(width: 8, height: 8)
                Text(project.title).font(.headline).lineLimit(2)
            }
            Text(project.category?.rawValue ?? "未分类")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(width: 140, alignment: .leading)
        .contextMenu {
            Button(openButtonTitle(for: project)) { open(project) }
                .disabled(!project.isAvailable || openDestination(for: project) == .alreadyOpen)
            Menu("所在文件夹") {
                ForEach(model.bookshelfFolders) { folder in
                    let included = project.assignedFolderIDs.contains(folder.id)
                    Button {
                        model.setCachedProjects(
                            [project],
                            in: folder.id,
                            included: !included,
                            folderTitle: folder.title
                        )
                    } label: {
                        Label(folder.title, systemImage: included ? "checkmark.circle.fill" : "folder.badge.plus")
                    }
                }
            }
            Divider()
            Button("删除缓存", role: .destructive) { pendingDeletionIDs = [project.id] }
        }
        .help(project.sourcePath)
    }

    private func toggleSelection(_ project: CachedProject) {
        if selectedProjectIDs.contains(project.id) { selectedProjectIDs.remove(project.id) }
        else { selectedProjectIDs.insert(project.id) }
    }

    private func organizeSelected(into folder: BookshelfFolder) {
        let projects = selectedProjects
        guard !projects.isEmpty else { return }
        model.setCachedProjects(
            projects,
            in: folder.id,
            included: true,
            folderTitle: folder.title
        )
        selectedFilter = .folder(folder.id)
        selectedProjectIDs.removeAll()
        isSelecting = false
    }

    private func categorizeSelected(as category: BookCategory) {
        let projects = selectedProjects
        guard !projects.isEmpty else { return }
        model.setCachedProjects(projects, category: category)
        selectedFilter = .category(category)
        selectedProjectIDs.removeAll()
        isSelecting = false
    }

    private func coverImage(for project: CachedProject) -> NSImage? {
        guard let path = project.coverPath,
              let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              !data.isEmpty else { return nil }
        return NSImage(data: data)
    }

    private func openDestination(for project: CachedProject) -> BookshelfOpenDestination {
        BookshelfOpenPolicy.destination(currentDocumentURL: model.documentURL, project: project)
    }

    private func openButtonTitle(for project: CachedProject) -> String {
        switch openDestination(for: project) {
        case .currentWindow: "打开"
        case .newWindow: "新窗口打开"
        case .alreadyOpen: "已打开"
        }
    }

    private func openButtonHelp(for project: CachedProject) -> String {
        switch openDestination(for: project) {
        case .currentWindow: "在当前空闲阅读窗口中打开"
        case .newWindow: "当前窗口已有项目，将在新窗口中打开"
        case .alreadyOpen: "这是当前窗口正在阅读的项目"
        }
    }

    private func open(_ project: CachedProject) {
        if project.category == nil {
            model.beginImport(project.sourceURL)
            dismiss()
            return
        }
        switch openDestination(for: project) {
        case .currentWindow:
            model.open(project.sourceURL, category: project.category ?? .nonfiction)
            dismiss()
        case .newWindow:
            openWindow(value: project.sourcePath)
            dismiss()
        case .alreadyOpen:
            dismiss()
        }
    }
}

private enum BookshelfFilter: Hashable {
    case all
    case category(BookCategory)
    case folder(UUID)
}

private struct NotesHub: View {
    @EnvironmentObject private var model: ReaderModel
    @Environment(\.dismiss) private var dismiss
    @State private var chatMode: ChatNoteExportMode = .original
    @State private var collapseChat = false
    @State private var showDeleteChats = false

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Label("笔记", systemImage: "note.text").font(.title2.bold())
                Spacer()
                Button("完成") { dismiss() }
            }
            .padding(16)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    GroupBox("Obsidian") {
                        VStack(alignment: .leading, spacing: 10) {
                            HStack {
                                Image(systemName: model.obsidianVaultPath.isEmpty ? "circle" : "checkmark.circle.fill")
                                    .foregroundStyle(model.obsidianVaultPath.isEmpty ? Color.secondary : Color.green)
                                Text(model.obsidianVaultPath.isEmpty
                                     ? "尚未连接 Vault"
                                     : URL(fileURLWithPath: model.obsidianVaultPath).lastPathComponent)
                                Spacer()
                                Button("选择 Vault…") { model.chooseObsidianVault() }
                            }
                            TextField("笔记目录", text: $model.obsidianFolder)
                                .textFieldStyle(.roundedBorder)
                            HStack {
                                Button { model.createObsidianSkeleton() } label: {
                                    Text("添加目录")
                                }
                                    .disabled(model.obsidianVaultPath.isEmpty)
                                Button("打开笔记") { model.openObsidianNote() }
                                    .disabled(model.obsidianNoteURL == nil)
                                Spacer()
                                SettingsLink { Label("设置", systemImage: "gearshape") }
                            }
                        }
                        .padding(6)
                    }

                    GroupBox("加入已有内容") {
                        VStack(alignment: .leading, spacing: 12) {
                            HStack {
                                Text("划线与批注")
                                Spacer()
                                Text("已选 \(selectedHighlights.count) 条").foregroundStyle(.secondary)
                                Button(allPendingHighlightsSelected ? "取消" : "全选未加入") { togglePendingHighlights() }
                                    .disabled(pendingHighlights.isEmpty)
                                Button { model.sendHighlightsToObsidian(selectedHighlights) } label: {
                                    HStack(spacing: 5) { NoteInsertIcon(); Text("加入笔记") }
                                }
                                    .disabled(selectedHighlights.isEmpty)
                            }
                            Divider()
                            HStack {
                                Text("AI 对话")
                                Spacer()
                                Text("已选 \(selectedChatCount) 条").foregroundStyle(.secondary)
                                Button(allPendingChatsSelected ? "取消" : "全选未加入") { togglePendingChats() }
                                    .disabled(pendingChats.isEmpty)
                                Button("删除", role: .destructive) { showDeleteChats = true }
                                    .disabled(currentModeChats.allSatisfy { !$0.selectedForNotes })
                            }
                            Picker("写入方式", selection: $chatMode) {
                                ForEach(ChatNoteExportMode.allCases) { Text($0.rawValue).tag($0) }
                            }
                            .pickerStyle(.segmented)
                            HStack {
                                Toggle("默认折叠", isOn: $collapseChat)
                                Spacer()
                                if model.isExportingChatNote { ProgressView().controlSize(.small) }
                                Button {
                                    model.sendSelectedChatsToObsidian(mode: chatMode, collapsed: collapseChat)
                                } label: {
                                    HStack(spacing: 5) { NoteInsertIcon(); Text("加入笔记") }
                                }
                                .disabled(selectedChatCount == 0 || model.isExportingChatNote)
                            }
                        }
                        .padding(6)
                    }

                }
                .padding(16)
            }
        }
        .frame(width: 640, height: 520)
        .confirmationDialog("删除选中的对话？", isPresented: $showDeleteChats) {
            Button("删除对话", role: .destructive) { model.deleteSelectedChats() }
            Button("取消", role: .cancel) {}
        } message: {
            Text("已经写入 Obsidian 的内容不会被删除。")
        }
    }

    private var selectedHighlights: [HighlightRecord] {
        model.highlights.filter { model.selectedHighlightIDs.contains($0.id) && !$0.isInNotes }
    }

    private var selectedChatCount: Int {
        currentModeChats.filter { $0.selectedForNotes && !$0.isInNotes }.count
    }

    private var pendingHighlights: [HighlightRecord] {
        model.highlights.filter { !$0.isInNotes }
    }

    private var pendingChats: [ChatTurn] {
        currentModeChats.filter { !$0.isInNotes }
    }

    private var currentModeChats: [ChatTurn] {
        model.chatTurns
    }

    private var allPendingHighlightsSelected: Bool {
        !pendingHighlights.isEmpty && pendingHighlights.allSatisfy { model.selectedHighlightIDs.contains($0.id) }
    }

    private var allPendingChatsSelected: Bool {
        !pendingChats.isEmpty && pendingChats.allSatisfy(\.selectedForNotes)
    }

    private func togglePendingHighlights() {
        let ids = Set(pendingHighlights.map(\.id))
        model.selectedHighlightIDs = allPendingHighlightsSelected ? [] : ids
    }

    private func togglePendingChats() {
        let shouldSelect = !allPendingChatsSelected
        for index in model.chatTurns.indices {
            model.chatTurns[index].selectedForNotes = shouldSelect && !model.chatTurns[index].isInNotes
        }
        model.persist()
    }

}

private struct ChatNoteExportSheet: View {
    @Environment(\.dismiss) private var dismiss
    let selectedCount: Int
    @Binding var mode: ChatNoteExportMode
    @Binding var collapsed: Bool
    let onConfirm: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("对话加入笔记").font(.headline)
            Text("已选 \(selectedCount) 条").foregroundStyle(.secondary)
            Picker("内容", selection: $mode) {
                ForEach(ChatNoteExportMode.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            Toggle("默认折叠", isOn: $collapsed)
            HStack {
                Button("取消") { dismiss() }
                Spacer()
                Button(action: onConfirm) {
                    HStack(spacing: 5) { NoteInsertIcon(); Text("确认加入") }
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(20)
        .frame(width: 400)
    }
}

private extension ChapterSummarySectionKind {
    var accent: Color {
        switch self {
        case .question: .orange
        case .argument: .blue
        case .conclusion: .green
        case .relation: .purple
        }
    }
}

private struct ChapterSummaryCards: View {
    let summary: String

    private var sections: [ChapterSummarySection] {
        ChapterSummaryParser.parse(summary)
    }

    private var hasCompleteStructure: Bool {
        let kinds = Set(sections.map(\.kind))
        return kinds.contains(.question) && kinds.contains(.argument) && kinds.contains(.conclusion)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if sections.isEmpty || !hasCompleteStructure {
                Text(summary.replacingOccurrences(of: "\\n", with: "\n"))
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            } else {
                ForEach(sections) { section in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 6) {
                            Circle().fill(section.kind.accent).frame(width: 7, height: 7)
                            Text(section.kind.rawValue)
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(section.kind.accent)
                        }
                        ForEach(Array(section.points.enumerated()), id: \.offset) { _, point in
                            HStack(alignment: .firstTextBaseline, spacing: 6) {
                                Text("•").foregroundStyle(section.kind.accent)
                                emphasizedText(point, accent: section.kind.accent)
                                    .lineSpacing(3)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                    .padding(9)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(section.kind.accent.opacity(0.09), in: RoundedRectangle(cornerRadius: 8))
                }
            }
        }
        .font(.system(size: 13))
    }

    private func emphasizedText(_ point: String, accent: Color) -> Text {
        var value = (try? AttributedString(
            markdown: point,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        )) ?? AttributedString(point)
        var foundStrong = false
        for run in value.runs {
            if run.inlinePresentationIntent?.contains(.stronglyEmphasized) == true {
                foundStrong = true
                value[run.range].underlineStyle = .single
                value[run.range].foregroundColor = accent
            }
        }
        if !foundStrong,
           let colon = value.characters.firstIndex(where: { $0 == "：" || $0 == ":" }),
           value.characters.distance(from: value.characters.startIndex, to: colon) <= 16 {
            let end = value.characters.index(after: colon)
            let range = value.characters.startIndex..<end
            value[range].font = .system(size: 13, weight: .semibold)
            value[range].underlineStyle = .single
            value[range].foregroundColor = accent
        }
        return Text(value)
    }
}

private struct ManualOutlineDraft: Identifiable {
    var id = UUID()
    var title: String
    var pdfPage: Int
    var level: Int
}

private struct ManualOutlinePanel: View {
    @EnvironmentObject private var model: ReaderModel
    let onClose: () -> Void
    @State private var drafts: [ManualOutlineDraft] = []
    @State private var pastedText = ""
    @State private var parseStatus = ""
    @State private var selectedDraftIDs: Set<UUID> = []
    @State private var batchLevel = 0
    @State private var showBatchDeleteConfirmation = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("手动添加目录").font(.headline)
                Spacer()
                Button {
                    pasteFromClipboard()
                } label: {
                    Label("从剪贴板粘贴", systemImage: "doc.on.clipboard")
                }
                Button(action: onClose) {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.borderless)
                .help("关闭")
            }
            Text("每行粘贴一条目录，并保留该行的标题和页码。支持页码在标题前后、点线、斜杠、独立页码列和交错双栏。")
                .font(.callout).foregroundStyle(.secondary)
            TextEditor(text: $pastedText)
                .font(.system(size: 13))
                .frame(height: 118)
                .padding(6)
                .background(.background, in: RoundedRectangle(cornerRadius: 7))
                .overlay(RoundedRectangle(cornerRadius: 7).stroke(.separator))
            HStack(spacing: 7) {
                Button("解析文字") { parsePastedText() }
                    .buttonStyle(.borderedProminent)
                    .disabled(pastedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                if !parseStatus.isEmpty {
                    Text(parseStatus).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
            }
            Divider()
            HStack {
                Text("目录条目").font(.headline)
                Text("识别后仍可改标题、文档页和层级，也可上下移动").font(.caption).foregroundStyle(.secondary)
                Spacer()
            }
            HStack(spacing: 9) {
                Button(selectedDraftIDs.count == drafts.count && !drafts.isEmpty ? "取消全选" : "全选") {
                    selectedDraftIDs = selectedDraftIDs.count == drafts.count
                        ? []
                        : Set(drafts.map(\.id))
                }
                .buttonStyle(.borderless)
                Text("已选 \(selectedDraftIDs.count) 项")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Picker("批量层级", selection: $batchLevel) {
                    ForEach(0..<6, id: \.self) { level in
                        Text("\(level + 1)").tag(level)
                    }
                }
                .frame(width: 92)
                .disabled(selectedDraftIDs.isEmpty)
                .onChange(of: batchLevel) { _, _ in applyBatchLevel() }
                Button(role: .destructive) {
                    showBatchDeleteConfirmation = true
                } label: {
                    Label("删除", systemImage: "trash")
                }
                .disabled(selectedDraftIDs.isEmpty)
            }
            List {
                ForEach($drafts) { $draft in
                    let draftID = draft.id
                    VStack(alignment: .leading, spacing: 7) {
                        HStack(spacing: 7) {
                            Toggle("", isOn: Binding(
                                get: { selectedDraftIDs.contains(draftID) },
                                set: { selected in
                                    if selected { selectedDraftIDs.insert(draftID) }
                                    else { selectedDraftIDs.remove(draftID) }
                                }
                            ))
                            .labelsHidden()
                            .toggleStyle(.checkbox)
                            TextField("标题", text: $draft.title)
                        }
                        HStack(spacing: 8) {
                            TextField("文档页", value: $draft.pdfPage, format: .number)
                                .frame(width: 68)
                            HStack(spacing: 3) {
                                Button { draft.level = max(draft.level - 1, 0) } label: {
                                    Image(systemName: "arrow.up")
                                }
                                .disabled(draft.level == 0)
                                .help("提升一级")
                                Text("第 \(draft.level + 1) 级")
                                    .font(.caption)
                                    .frame(width: 48)
                                Button { draft.level = min(draft.level + 1, 5) } label: {
                                    Image(systemName: "arrow.down")
                                }
                                .disabled(draft.level == 5)
                                .help("下沉一级")
                            }
                            .buttonStyle(.borderless)
                            Spacer()
                            Button { move(draftID, by: -1) } label: { Image(systemName: "arrow.up") }
                                .disabled(drafts.first?.id == draftID)
                                .help("上移")
                            Button { move(draftID, by: 1) } label: { Image(systemName: "arrow.down") }
                                .disabled(drafts.last?.id == draftID)
                                .help("下移")
                            Button { insertRow(after: draftID) } label: { Image(systemName: "plus") }
                                .help("在下方插入")
                            Button(role: .destructive) {
                                removeDraft(draftID)
                            } label: {
                                Image(systemName: "trash")
                            }
                            .buttonStyle(.borderless)
                        }
                    }
                    .padding(.vertical, 3)
                }
            }
            .frame(minHeight: 260)
            HStack {
                Button { addRow() } label: { Label("添加条目", systemImage: "plus") }
                Spacer()
                Button("取消") { onClose() }
                Button("保存目录") {
                    let entries = drafts.map {
                        OutlineEntry(id: $0.id, title: $0.title, pageIndex: max($0.pdfPage - 1, 0), level: $0.level, generated: true)
                    }
                    model.applyManualOutline(entries)
                    onClose()
                }
                .buttonStyle(.borderedProminent)
                .disabled(drafts.allSatisfy { $0.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })
            }
        }
        .padding(10)
        .background(.regularMaterial)
        .onAppear {
            guard drafts.isEmpty else { return }
            drafts = model.outline.map {
                ManualOutlineDraft(id: $0.id, title: $0.title, pdfPage: $0.pageIndex + 1, level: $0.level)
            }
            if drafts.isEmpty { addRow() }
        }
        .confirmationDialog(
            "删除选中的 \(selectedDraftIDs.count) 条目录？",
            isPresented: $showBatchDeleteConfirmation,
            titleVisibility: .visible
        ) {
            Button("删除目录", role: .destructive) { deleteSelectedDrafts() }
            Button("取消", role: .cancel) {}
        } message: {
            Text("点击“保存目录”后，删除结果才会写入当前目录。")
        }
    }

    private func addRow() {
        drafts.append(ManualOutlineDraft(title: "", pdfPage: min(model.currentPageIndex + 1, max(model.pageCount, 1)), level: 0))
    }

    private func insertRow(after id: UUID) {
        guard let index = drafts.firstIndex(where: { $0.id == id }) else { return }
        let previous = drafts[index]
        drafts.insert(
            ManualOutlineDraft(title: "", pdfPage: previous.pdfPage, level: previous.level),
            at: index + 1
        )
    }

    private func removeDraft(_ id: UUID) {
        selectedDraftIDs.remove(id)
        // Let the row's Binding action unwind before changing the collection
        // that owns it. Removing the final bound row synchronously can make
        // SwiftUI resolve an index that no longer exists.
        DispatchQueue.main.async {
            drafts.removeAll { $0.id == id }
        }
    }

    private func move(_ id: UUID, by offset: Int) {
        guard let source = drafts.firstIndex(where: { $0.id == id }) else { return }
        let destination = source + offset
        guard drafts.indices.contains(destination) else { return }
        let item = drafts.remove(at: source)
        drafts.insert(item, at: destination)
    }

    private func parsePastedText() {
        let entries = model.previewPastedOutline(pastedText)
        guard !entries.isEmpty else {
            parseStatus = "未识别到有效条目"
            return
        }
        drafts = entries.map {
            ManualOutlineDraft(id: $0.id, title: $0.title, pdfPage: $0.pageIndex + 1, level: $0.level)
        }
        selectedDraftIDs.removeAll()
        parseStatus = "已识别并校准 \(entries.count) 条"
    }

    private func pasteFromClipboard() {
        guard let text = NSPasteboard.general.string(forType: .string),
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            parseStatus = "剪贴板没有文字"
            return
        }
        pastedText = text
        parsePastedText()
    }

    private func applyBatchLevel() {
        for index in drafts.indices where selectedDraftIDs.contains(drafts[index].id) {
            drafts[index].level = batchLevel
        }
        parseStatus = "已修改 \(selectedDraftIDs.count) 项层级"
    }

    private func deleteSelectedDrafts() {
        let deletedCount = selectedDraftIDs.count
        drafts.removeAll { selectedDraftIDs.contains($0.id) }
        selectedDraftIDs.removeAll()
        parseStatus = "已删除 \(deletedCount) 条目录"
    }
}

private struct StatusBar: View {
    @EnvironmentObject private var model: ReaderModel
    @Binding var pageField: String

    var body: some View {
        ZStack {
            HStack {
                if let feedback = model.noteFeedbackMessage {
                    Label(feedback, systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                } else {
                    Image(systemName: model.document == nil ? "circle" : "checkmark.circle.fill")
                        .foregroundStyle(model.document == nil ? Color.secondary : Color.green)
                    Text(model.statusMessage)
                }
                Spacer()
                if model.document != nil {
                    Text(model.documentURL?.deletingPathExtension().lastPathComponent ?? model.documentTitle).lineLimit(1)
                }
            }
            if model.document != nil {
                if model.reflowBook != nil {
                    HStack(spacing: 8) {
                        Button { model.turnReflowPage(by: -1) } label: { Image(systemName: "chevron.left") }
                            .disabled(model.reflowPageNumber <= 1)
                        Text(reflowPageLabel).monospacedDigit().frame(minWidth: 74)
                        Button { model.turnReflowPage(by: 1) } label: { Image(systemName: "chevron.right") }
                            .disabled(model.reflowPageNumber + model.reflowSpreadCount > model.reflowPageCount)
                    }
                    .buttonStyle(.borderless)
                } else {
                    HStack(spacing: 8) {
                        Button { model.changePage(by: -1) } label: { Image(systemName: "chevron.up") }
                            .disabled(model.currentPageIndex <= 0)
                        TextField("页", text: $pageField)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 48)
                            .multilineTextAlignment(.center)
                            .onSubmit {
                                if let page = Int(pageField) { model.go(to: page - 1) }
                            }
                        Text(model.pdfTwoPages
                             ? "–\(min(model.currentPageIndex + 2, model.pageCount)) / \(model.pageCount)"
                             : "/ \(model.pageCount)").monospacedDigit()
                        Button { model.changePage(by: 1) } label: { Image(systemName: "chevron.down") }
                            .disabled(model.currentPageIndex + (model.pdfTwoPages ? 2 : 1) >= model.pageCount)
                    }
                    .buttonStyle(.borderless)
                }
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 10)
        .frame(height: 34)
        .background(.bar)
    }

    private var reflowPageLabel: String {
        let start = model.reflowPageNumber
        let end = min(model.reflowPageCount, start + model.reflowSpreadCount - 1)
        return end > start ? "\(start)–\(end) / \(model.reflowPageCount)" : "\(start) / \(model.reflowPageCount)"
    }
}
