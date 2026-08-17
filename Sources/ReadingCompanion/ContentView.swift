import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @EnvironmentObject private var model: ReaderModel
    @State private var pageField = "1"
    @State private var showNotesHub = false
    @State private var showBookshelf = false
    @State private var showManualOutline = false

    var body: some View {
        VStack(spacing: 0) {
            ReaderToolbar(showNotesHub: $showNotesHub, showBookshelf: $showBookshelf)
            Divider()
            HSplitView {
                if model.leftSidebarVisible {
                    SidebarView(showManualOutline: $showManualOutline)
                        .frame(minWidth: 320, idealWidth: 410, maxWidth: 560)
                }

                readerContent
                    .frame(minWidth: 440)

                if showManualOutline {
                    ManualOutlinePanel(onClose: { showManualOutline = false })
                        .frame(minWidth: 400, idealWidth: 460, maxWidth: 540)
                } else if model.assistantVisible {
                    AssistantPanel()
                        .frame(minWidth: 380, idealWidth: 470, maxWidth: 680)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            StatusBar(pageField: $pageField)
        }
        .alert("Reading Companion Open", isPresented: Binding(
            get: { model.errorMessage != nil },
            set: { if !$0 { model.errorMessage = nil } }
        )) {
            Button("好", role: .cancel) { model.errorMessage = nil }
        } message: {
            Text(model.errorMessage ?? "")
        }
        .sheet(isPresented: $showNotesHub) {
            NotesHub()
                .environmentObject(model)
        }
        .sheet(isPresented: $showBookshelf) {
            BookshelfSheet()
                .environmentObject(model)
        }
        .onChange(of: model.currentPageIndex) { _, page in pageField = "\(page + 1)" }
        .onDrop(of: [UTType.pdf], isTargeted: nil, perform: model.acceptDroppedURLs)
    }

    @ViewBuilder
    private var readerContent: some View {
        if model.document != nil {
            PDFReaderView(model: model)
                .background(Color(nsColor: .underPageBackgroundColor))
        } else {
            ContentUnavailableView {
                Label("打开 PDF 开始伴读", systemImage: "doc.richtext")
            } description: {
                Text("拖放 PDF 到这里，或点击下方按钮。\n文本页会直接索引，扫描页将在本机进行 OCR。")
            } actions: {
                Button("选择 PDF…") { model.presentOpenPanel() }
                    .buttonStyle(.borderedProminent)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(nsColor: .underPageBackgroundColor))
        }
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
            .help("打开缓存项目；项目可在独立窗口中同时阅读")

            Divider().frame(height: 20)

            Menu {
                Button("整页显示") { setFit(.page) }
                Button("适合宽度") { setFit(.width) }
                Button("自定义缩放") { setFit(.custom) }
            } label: {
                Label(fitLabel, systemImage: "rectangle.arrowtriangle.2.inward")
            }
            .menuStyle(.borderlessButton)
            .help("调整页面在阅读区中的大小；选择时会解除锁定")

            Button { adjustZoom(by: -0.1) } label: { Image(systemName: "minus.magnifyingglass") }
                .disabled(model.zoomLocked)
            Text("\(Int(model.zoomScale * 100))%")
                .frame(width: 46)
                .monospacedDigit()
            Button { adjustZoom(by: 0.1) } label: { Image(systemName: "plus.magnifyingglass") }
                .disabled(model.zoomLocked)
            Button { model.rotateCurrentPage() } label: { Image(systemName: "rotate.right") }
                .help("顺时针旋转当前页")
                .disabled(model.document == nil)
            Toggle(isOn: $model.zoomLocked) {
                Image(systemName: model.zoomLocked ? "lock.fill" : "lock.open")
            }
            .toggleStyle(.button)
            .help("锁定横向位置与缩放，只允许上下滚动")

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
        }
        .buttonStyle(.borderless)
        .imageScale(.medium)
        .padding(.horizontal, 12)
        .frame(height: 46)
    }

    private func adjustZoom(by delta: Double) {
        model.fitMode = .custom
        model.zoomScale = min(max(model.zoomScale + delta, 0.2), 6)
    }

    private func setFit(_ fit: ReaderFitMode) {
        model.zoomLocked = false
        model.fitMode = fit
    }

    private var fitLabel: String {
        switch model.fitMode {
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

    var body: some View {
        VStack(spacing: 0) {
            Picker("导航", selection: $model.selectedSidebar) {
                ForEach(SidebarSection.allCases) { section in
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
            case .search: searchList
            }
        }
        .background(.regularMaterial)
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
        VStack(spacing: 0) {
            HStack {
                Label("目录", systemImage: "list.bullet.indent").font(.headline)
                Spacer()
                Button {
                    showsOutlineSummaries.toggle()
                    if !showsOutlineSummaries { expandedSummaryIDs.removeAll() }
                } label: {
                    Label("概要", systemImage: "list.bullet.rectangle")
                        .foregroundStyle(showsOutlineSummaries ? Color.accentColor : Color.primary)
                }
                .buttonStyle(.borderless)
                .help(showsOutlineSummaries ? "隐藏章节概要" : "显示章节概要的展开按钮")
            }
            .padding(.horizontal, 10)
            .padding(.top, 10)
            .padding(.bottom, 7)
            HStack(spacing: 7) {
                Button("自动识别") { model.relocateTOC() }
                    .help("优先使用 PDF 自带目录；没有时自动定位印刷目录页")
                Button("手动添加") { showManualOutline = true }
                    .help("每行粘贴一条目录，自动提取标题、页码和层级")
                Spacer(minLength: 0)
            }
            .buttonStyle(.borderless)
            .controlSize(.small)
            .font(.system(size: 12))
            .padding(.horizontal, 10)
            .padding(.bottom, 7)
            .disabled(model.document == nil || model.indexingProgress < 1 || model.isRefiningOutline || model.isLocatingTOC)
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
                            Button { model.go(to: entry.pageIndex) } label: {
                                HStack(spacing: 4) {
                                    Text(entry.title).font(.system(size: 14)).lineLimit(2)
                                    Spacer()
                                    Text("\(entry.pageIndex + 1)")
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
                    .help(model.outlineWasManuallyEdited ? "手动目录" : (model.outlineRefinedByAI ? "AI 从印刷目录页识别并校准页码" : "PDF 自带目录"))
                    .listRowInsets(EdgeInsets(top: 3, leading: 8, bottom: 3, trailing: 8))
                }
            }
            .overlay {
                if model.document != nil && model.outline.isEmpty {
                    ContentUnavailableView("等待目录", systemImage: "list.bullet.indent", description: Text("可自动识别，或手动添加。"))
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
                        Text("添加目录到笔记")
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
            ChapterSummaryCards(summary: summary)
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
                                Text(highlight.inlineText).font(.system(size: 14)).lineSpacing(2).lineLimit(3)
                                if let note = highlight.note, !note.isEmpty {
                                    Text(note).font(.system(size: 13)).foregroundStyle(.blue).lineSpacing(2).lineLimit(2)
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
                Button { model.go(to: result.pageIndex) } label: {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(result.text).lineLimit(2)
                        Text("第 \(result.pageIndex + 1) 页").font(.caption).foregroundStyle(.secondary)
                    }
                }
                .buttonStyle(.plain)
            }
        }
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
                Text("AI 伴读")
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
                depthMenu
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
            if model.document != nil && model.indexingProgress < 1 {
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
                                        VStack(alignment: .leading, spacing: 10) {
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
                                    .padding(11)
                                    .background(.background.opacity(0.55), in: RoundedRectangle(cornerRadius: 9))
                                    .listRowInsets(EdgeInsets(top: 6, leading: 11, bottom: 6, trailing: 30))
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
            VStack(spacing: 12) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        QuickQuestion("解释一下", action: "解释")
                        QuickQuestion("联系上下文", action: "上下文")
                        QuickQuestion("链接资源", action: "资源", systemImage: "globe")
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
            .padding(14)
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
    @State private var projectPendingDeletion: CachedProject?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Label("书架", systemImage: "books.vertical").font(.title2.bold())
                Spacer()
                Button("完成") { dismiss() }
            }
            .padding(16)
            Divider()
            if model.cachedProjects.isEmpty {
                ContentUnavailableView(
                    "书架还是空的",
                    systemImage: "books.vertical",
                    description: Text("打开 PDF 后，阅读位置、目录、划线和对话会自动成为缓存项目。")
                )
            } else {
                List(model.cachedProjects) { project in
                    HStack(spacing: 12) {
                        Image(systemName: project.isAvailable ? "doc.richtext" : "questionmark.folder")
                            .font(.title2)
                            .foregroundStyle(project.isAvailable ? Color.accentColor : Color.secondary)
                            .frame(width: 30)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(project.title).font(.headline).lineLimit(1)
                            Text(project.sourcePath)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                            Text(project.lastOpenedAt, style: .relative)
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                        Spacer()
                        if model.documentURL?.standardizedFileURL.path == project.sourcePath {
                            Text("当前项目")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Button(role: .destructive) {
                            projectPendingDeletion = project
                        } label: {
                            Label("删除", systemImage: "trash")
                        }
                        .buttonStyle(.bordered)
                        .help("删除该 PDF 的阅读记录、目录、概要、OCR 与索引缓存")
                        Button("新窗口打开") {
                            openWindow(value: project.sourcePath)
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(!project.isAvailable)
                    }
                    .padding(.vertical, 5)
                }
            }
        }
        .frame(width: 650, height: 430)
        .onAppear { model.refreshCachedProjects() }
        .confirmationDialog(
            "删除“\(projectPendingDeletion?.title ?? "")”的全部缓存？",
            isPresented: Binding(
                get: { projectPendingDeletion != nil },
                set: { if !$0 { projectPendingDeletion = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("删除缓存", role: .destructive) {
                guard let project = projectPendingDeletion else { return }
                model.deleteCachedProject(project)
                projectPendingDeletion = nil
            }
            Button("取消", role: .cancel) { projectPendingDeletion = nil }
        } message: {
            Text("阅读进度、目录、概要、划线、批注、AI 对话及 OCR/索引缓存都会被清除。原始 PDF 和 Obsidian 笔记不会被删除；再次打开 PDF 时会作为全新项目重新处理。")
        }
    }
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
    @State private var tocStartPDFPage = 1
    @State private var tocEndPDFPage = 1
    @State private var parseStatus = ""
    @State private var selectedDraftIDs: Set<UUID> = []
    @State private var batchLevel = 0
    @State private var showBatchDeleteConfirmation = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
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
            Text("可对照左侧 PDF 目录页调整。支持页码在标题前后、点线、斜杠、独立页码列和交错双栏。")
                .font(.callout).foregroundStyle(.secondary)
            TextEditor(text: $pastedText)
                .font(.system(size: 13))
                .frame(height: 118)
                .padding(6)
                .background(.background, in: RoundedRectangle(cornerRadius: 7))
                .overlay(RoundedRectangle(cornerRadius: 7).stroke(.separator))
            HStack(spacing: 7) {
                TextField("起始页", value: $tocStartPDFPage, format: .number)
                    .frame(width: 62)
                Text("至")
                TextField("结束页", value: $tocEndPDFPage, format: .number)
                    .frame(width: 62)
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
                Text("识别后仍可改标题、PDF 页和层级，也可上下移动").font(.caption).foregroundStyle(.secondary)
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
                        Text("第 \(level + 1) 级").tag(level)
                    }
                }
                .frame(width: 120)
                Button("应用层级") { applyBatchLevel() }
                    .disabled(selectedDraftIDs.isEmpty)
                Button(role: .destructive) {
                    showBatchDeleteConfirmation = true
                } label: {
                    Label("批量删除", systemImage: "trash")
                }
                .disabled(selectedDraftIDs.isEmpty)
            }
            List {
                ForEach($drafts) { $draft in
                    VStack(alignment: .leading, spacing: 7) {
                        HStack(spacing: 7) {
                            Toggle("", isOn: Binding(
                                get: { selectedDraftIDs.contains(draft.id) },
                                set: { selected in
                                    if selected { selectedDraftIDs.insert(draft.id) }
                                    else { selectedDraftIDs.remove(draft.id) }
                                }
                            ))
                            .labelsHidden()
                            .toggleStyle(.checkbox)
                            TextField("标题", text: $draft.title)
                        }
                        HStack(spacing: 8) {
                            TextField("PDF 页", value: $draft.pdfPage, format: .number)
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
                            Button { move(draft.id, by: -1) } label: { Image(systemName: "arrow.up") }
                                .disabled(drafts.first?.id == draft.id)
                                .help("上移")
                            Button { move(draft.id, by: 1) } label: { Image(systemName: "arrow.down") }
                                .disabled(drafts.last?.id == draft.id)
                                .help("下移")
                            Button { insertRow(after: draft.id) } label: { Image(systemName: "plus") }
                                .help("在下方插入")
                            Button(role: .destructive) {
                                drafts.removeAll { $0.id == draft.id }
                                selectedDraftIDs.remove(draft.id)
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
        .padding(14)
        .background(.regularMaterial)
        .onAppear {
            guard drafts.isEmpty else { return }
            tocStartPDFPage = model.suggestedTOCStartPDFPage
            tocEndPDFPage = model.suggestedTOCEndPDFPage
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

    private func move(_ id: UUID, by offset: Int) {
        guard let source = drafts.firstIndex(where: { $0.id == id }) else { return }
        let destination = source + offset
        guard drafts.indices.contains(destination) else { return }
        let item = drafts.remove(at: source)
        drafts.insert(item, at: destination)
    }

    private func parsePastedText() {
        let entries = model.previewPastedOutline(
            pastedText,
            tocStartPDFPage: tocStartPDFPage,
            tocEndPDFPage: tocEndPDFPage
        )
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
                    Text(model.documentTitle).lineLimit(1)
                }
            }
            if model.document != nil {
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
                    Text("/ \(model.pageCount)").monospacedDigit()
                    Button { model.changePage(by: 1) } label: { Image(systemName: "chevron.down") }
                        .disabled(model.currentPageIndex >= model.pageCount - 1)
                }
                .buttonStyle(.borderless)
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 10)
        .frame(height: 34)
        .background(.bar)
    }
}
