import PDFKit
import SwiftUI

private struct SelectionActionBar: View {
    let selectedTint: HighlightTint
    let onHighlight: (HighlightTint) -> Void
    let onAnnotate: () -> Void
    let onCopy: () -> Void
    let onAsk: () -> Void

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: "highlighter")
                .foregroundStyle(.secondary)
                .help("选择颜色即可划线")
            ForEach(HighlightTint.allCases) { tint in
                Button { onHighlight(tint) } label: {
                    Circle()
                        .fill(Color(nsColor: tint.color.withAlphaComponent(1)))
                        .frame(width: 18, height: 18)
                        .overlay(Circle().stroke(selectedTint == tint ? Color.primary : .clear, lineWidth: 1.5))
                }
                .buttonStyle(.plain)
                .help("\(tint.rawValue)划线")
            }
            Divider().frame(height: 22)
            Button(action: onAnnotate) {
                AnnotationActionIcon()
            }
            .buttonStyle(.borderless)
            .help("添加绿色下划线批注")
            Divider().frame(height: 22)
            Button(action: onCopy) {
                Image(systemName: "doc.on.doc")
                    .font(.system(size: 16))
            }
            .buttonStyle(.borderless)
            .help("复制选中文字")
            Divider().frame(height: 22)
            Button(action: onAsk) {
                Label("提问", systemImage: "bubble.left")
                    .font(.system(size: 13))
            }
            .buttonStyle(.borderless)
            .help("发送到右侧当前伴读方式")
        }
        .padding(.horizontal, 10)
        .frame(height: 42)
    }
}

private struct AnnotationActionIcon: View {
    var body: some View {
        Image(systemName: "note.text")
            .font(.system(size: 18))
            .foregroundStyle(.green)
            .overlay(alignment: .bottom) {
                Capsule().fill(Color.green).frame(width: 19, height: 2).offset(y: 3)
            }
            .accessibilityLabel("批注")
    }
}

private struct InlineAnnotationEditor: View {
    @State private var note: String
    let onSend: (String) -> Void

    init(note: String, onSend: @escaping (String) -> Void) {
        _note = State(initialValue: note)
        self.onSend = onSend
    }

    var body: some View {
        HStack(spacing: 8) {
            AnnotationTextInput(text: $note, onCommit: { onSend(note) })
                .frame(height: 52)
            Button { onSend(note) } label: {
                Image(systemName: "arrow.up.circle.fill").font(.title2)
            }
            .buttonStyle(.plain)
            .help("保存批注")
        }
        .padding(9)
        .frame(width: 430, height: 74)
        .background(Color.green.opacity(0.09), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.green.opacity(0.75), lineWidth: 1.5))
    }
}

private struct AnnotationTextInput: NSViewRepresentable {
    @Binding var text: String
    let onCommit: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true

        let textView = CommitTextView()
        textView.delegate = context.coordinator
        textView.commitHandler = onCommit
        textView.string = text
        textView.font = .systemFont(ofSize: 14)
        textView.insertionPointColor = .systemGreen
        textView.drawsBackground = false
        textView.isRichText = false
        textView.isHorizontallyResizable = false
        textView.isVerticallyResizable = true
        textView.autoresizingMask = [.width]
        textView.textContainerInset = NSSize(width: 4, height: 5)
        textView.textContainer?.widthTracksTextView = true
        scrollView.documentView = textView
        DispatchQueue.main.async { textView.window?.makeFirstResponder(textView) }
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let textView = scrollView.documentView as? CommitTextView else { return }
        textView.commitHandler = onCommit
        if textView.string != text { textView.string = text }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: AnnotationTextInput
        init(_ parent: AnnotationTextInput) { self.parent = parent }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            parent.text = textView.string
        }
    }

    final class CommitTextView: NSTextView {
        var commitHandler: (() -> Void)?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard window != nil else { return }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.window?.makeFirstResponder(self)
            }
        }

        override func keyDown(with event: NSEvent) {
            let isReturn = event.keyCode == 36 || event.keyCode == 76
            guard isReturn, !hasMarkedText() else {
                super.keyDown(with: event)
                return
            }
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            if flags.contains(.shift) {
                insertNewline(nil)
            } else {
                commitHandler?()
            }
        }
    }
}

final class CompanionPDFView: PDFView, NSPopoverDelegate {
    var highlightTint: HighlightTint = .yellow
    var highlightModeEnabled = false
    var zoomLocked = false {
        didSet {
            guard zoomLocked != oldValue else { return }
            if zoomLocked {
                lockedScaleFactor = scaleFactor
                lockedHorizontalOrigin = enclosedScrollView?.contentView.bounds.origin.x
                previousHorizontalScrollerVisibility = enclosedScrollView?.hasHorizontalScroller
                enclosedScrollView?.horizontalScrollElasticity = .none
                enclosedScrollView?.hasHorizontalScroller = false
                enclosedScrollView?.allowsMagnification = false
                updateLockObservation()
                enforceNavigationLock()
            } else {
                lockedScaleFactor = nil
                lockedHorizontalOrigin = nil
                if let previousHorizontalScrollerVisibility {
                    enclosedScrollView?.hasHorizontalScroller = previousHorizontalScrollerVisibility
                }
                previousHorizontalScrollerVisibility = nil
                enclosedScrollView?.horizontalScrollElasticity = .automatic
                enclosedScrollView?.allowsMagnification = true
                stopLockObservation()
            }
        }
    }
    var onHighlight: ((String, [HighlightFragment], HighlightTint) -> HighlightRecord?)?
    var onAnnotate: ((String, [HighlightFragment], String) -> HighlightRecord?)?
    var onUpdateAnnotation: ((UUID, String) -> Void)?
    var onConvertToAnnotation: ((UUID, String) -> Void)?
    var onCancelAnnotation: (() -> Void)?
    var onEditMark: ((UUID) -> Void)?
    var onRecolorHighlight: ((UUID, HighlightTint) -> Void)?
    var onResolveHighlight: ((UUID) -> HighlightRecord?)?
    var onCopySelection: ((String) -> Void)?
    var onAskSelection: ((String, Int) -> Void)?
    var onNavigate: ((Int) -> Void)?
    var onSelectionContinuationChanged: ((Int) -> Void)?
    private var lockedScaleFactor: CGFloat?
    private var lockedHorizontalOrigin: CGFloat?
    private var previousHorizontalScrollerVisibility: Bool?
    private weak var observedClipView: NSClipView?
    private var isEnforcingLock = false
    private var selectionStartPoint: CGPoint?
    private var clickedHighlightID: UUID?
    private var pendingExistingHighlightID: UUID?
    private var pendingSelectionText: String?
    private var pendingSelectionFragments: [HighlightFragment] = []
    private var pendingSelectionSegmentCount = 0
    private var continuedSelectionTexts: [String] = []
    private var continuedSelectionFragments: [HighlightFragment] = []
    private var continuedSelectionSegmentCount = 0
    private var isContinuingSelection = false
    private var continuationPreviewAnnotations: [(page: PDFPage, annotation: PDFAnnotation)] = []
    private var selectionPopover: NSPopover?
    private var annotationPopover: NSPopover?
    private var annotationWasCommitted = false
    private var editingAnnotationID: UUID?

    override var acceptsFirstResponder: Bool { true }

    override func mouseDown(with event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if (flags.contains(.command) || isContinuingSelection),
           pendingExistingHighlightID == nil,
           pendingSelectionText != nil {
            stagePendingSelectionForContinuation()
        }
        selectionStartPoint = nil
        clickedHighlightID = nil
        pendingExistingHighlightID = nil
        let viewPoint = convert(event.locationInWindow, from: nil)
        if let page = page(for: viewPoint, nearest: true) {
            let pagePoint = convert(viewPoint, to: page)
            if let annotation = page.annotation(at: pagePoint),
               (annotation.type == "Highlight" || annotation.type == "Underline"),
               let name = annotation.userName,
               let id = UUID(uuidString: name) {
                clickedHighlightID = id
            }
        }
        selectionStartPoint = viewPoint
        super.mouseDown(with: event)
    }

    override func mouseUp(with event: NSEvent) {
        super.mouseUp(with: event)
        let endPoint = convert(event.locationInWindow, from: nil)
        let distance = selectionStartPoint.map { hypot(endPoint.x - $0.x, endPoint.y - $0.y) } ?? 0
        if distance >= 3 || event.clickCount >= 2,
           captureCurrentSelection() {
            pendingExistingHighlightID = nil
            combineContinuedSelectionIntoPending()
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            let keepsSelecting = flags.contains(.command)
            if highlightModeEnabled {
                if keepsSelecting {
                    isContinuingSelection = true
                    refreshContinuationPreview(pendingSelectionFragments)
                    onSelectionContinuationChanged?(pendingSelectionSegmentCount)
                    clearSelection()
                    return
                }
                isContinuingSelection = false
                commitPendingHighlight(tint: highlightTint)
                return
            }
            isContinuingSelection = keepsSelecting
            onSelectionContinuationChanged?(keepsSelecting ? pendingSelectionSegmentCount : 0)
            showSelectionPopover(at: endPoint)
            return
        }
        if let clickedHighlightID,
           let record = onResolveHighlight?(clickedHighlightID) {
            pendingExistingHighlightID = clickedHighlightID
            pendingSelectionText = record.inlineText
            pendingSelectionFragments = record.allFragments
            selectWholeHighlight(record)
            showSelectionPopover(at: endPoint)
        }
    }

    private func commitPendingHighlight(tint: HighlightTint) {
        selectionPopover?.close()
        if let pendingExistingHighlightID {
            onRecolorHighlight?(pendingExistingHighlightID, tint)
            clearSelection()
            clearPendingSelection()
            return
        }
        guard let document, let text = pendingSelectionText, !pendingSelectionFragments.isEmpty else { return }
        highlightTint = tint
        let record = onHighlight?(text, pendingSelectionFragments, tint)
        for fragment in pendingSelectionFragments {
            guard let page = document.page(at: fragment.pageIndex) else { continue }
            let bounds = fragment.bounds.cgRect
            let annotation = PDFAnnotation(bounds: bounds, forType: .highlight, withProperties: nil)
            annotation.color = highlightTint.color
            annotation.userName = record?.id.uuidString
            page.addAnnotation(annotation)
        }
        clearSelection()
        clearPendingSelection()
    }

    private func sendPendingSelectionToQuestion() {
        selectionPopover?.close()
        guard let text = pendingSelectionText, let pageIndex = pendingSelectionFragments.first?.pageIndex else { return }
        onAskSelection?(text, pageIndex)
        clearSelection()
        clearPendingSelection()
    }

    private func copyPendingSelection() {
        selectionPopover?.close()
        guard let text = pendingSelectionText else { return }
        let normalized = HighlightTextNormalizer.inline(text)
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(normalized, forType: .string)
        onCopySelection?(normalized)
        clearSelection()
        clearPendingSelection()
    }

    private func annotatePendingSelection() {
        selectionPopover?.close()
        let note = pendingExistingHighlightID
            .flatMap { onResolveHighlight?($0)?.note } ?? ""
        showAnnotationEditor(note: note)
    }

    func presentAnnotationEditor(for record: HighlightRecord) {
        guard annotationPopover?.isShown != true || editingAnnotationID != record.id else { return }
        if let existing = annotationPopover {
            existing.delegate = nil
            existing.close()
            annotationPopover = nil
        }
        pendingExistingHighlightID = record.id
        pendingSelectionText = record.inlineText
        pendingSelectionFragments = record.allFragments
        selectWholeHighlight(record)
        showAnnotationEditor(note: record.note ?? "")
    }

    private func showAnnotationEditor(note: String) {
        guard !pendingSelectionFragments.isEmpty else { return }
        annotationPopover?.close()
        annotationWasCommitted = false
        editingAnnotationID = pendingExistingHighlightID
        let popover = NSPopover()
        popover.behavior = .transient
        popover.delegate = self
        popover.contentSize = NSSize(width: 430, height: 74)
        popover.contentViewController = NSHostingController(rootView: InlineAnnotationEditor(
            note: note,
            onSend: { [weak self] note in self?.commitPendingAnnotation(note: note) }
        ))
        annotationPopover = popover
        let anchor = annotationAnchorRect()
        popover.show(relativeTo: anchor, of: self, preferredEdge: .minY)
    }

    private func annotationAnchorRect() -> NSRect {
        guard let fragment = pendingSelectionFragments.last,
              let page = document?.page(at: fragment.pageIndex) else {
            return NSRect(x: bounds.midX, y: bounds.midY, width: 1, height: 1)
        }
        return convert(fragment.bounds.cgRect, from: page)
    }

    private func commitPendingAnnotation(note: String) {
        let cleanNote = note.trimmingCharacters(in: .whitespacesAndNewlines)
        annotationWasCommitted = true
        if let id = pendingExistingHighlightID,
           let record = onResolveHighlight?(id) {
            if record.markKind == .annotation {
                onUpdateAnnotation?(id, cleanNote)
            } else {
                onConvertToAnnotation?(id, cleanNote)
            }
        } else if let text = pendingSelectionText {
            _ = onAnnotate?(text, pendingSelectionFragments, cleanNote)
        }
        annotationPopover?.close()
        clearSelection()
        clearPendingSelection()
    }

    func popoverDidClose(_ notification: Notification) {
        guard notification.object as? NSPopover === annotationPopover else { return }
        if !annotationWasCommitted { onCancelAnnotation?() }
        annotationPopover = nil
        annotationWasCommitted = false
        editingAnnotationID = nil
        clearSelection()
        clearPendingSelection()
    }

    private func clearPendingSelection() {
        removeContinuationPreviewAnnotations()
        pendingSelectionText = nil
        pendingSelectionFragments = []
        pendingSelectionSegmentCount = 0
        continuedSelectionTexts = []
        continuedSelectionFragments = []
        continuedSelectionSegmentCount = 0
        isContinuingSelection = false
        selectionStartPoint = nil
        clickedHighlightID = nil
        pendingExistingHighlightID = nil
        onSelectionContinuationChanged?(0)
    }

    private func captureCurrentSelection() -> Bool {
        guard let document,
              let selection = currentSelection,
              let text = selection.string?.trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty else { return false }
        let fragments = HighlightFragmentNormalizer.normalize(selection.selectionsByLine().compactMap { line -> HighlightFragment? in
            guard let page = line.pages.first else { return nil }
            let bounds = line.bounds(for: page)
            guard !bounds.isEmpty else { return nil }
            return HighlightFragment(pageIndex: document.index(for: page), bounds: bounds)
        })
        guard !fragments.isEmpty else { return false }
        pendingSelectionText = text
        pendingSelectionFragments = fragments
        pendingSelectionSegmentCount = 1
        return true
    }

    private func stagePendingSelectionForContinuation() {
        guard let text = pendingSelectionText, !pendingSelectionFragments.isEmpty else { return }
        selectionPopover?.close()
        refreshContinuationPreview(pendingSelectionFragments)
        continuedSelectionTexts.append(HighlightTextNormalizer.inline(text))
        continuedSelectionFragments.append(contentsOf: pendingSelectionFragments)
        continuedSelectionSegmentCount += max(1, pendingSelectionSegmentCount)
        pendingSelectionText = nil
        pendingSelectionFragments = []
        pendingSelectionSegmentCount = 0
        pendingExistingHighlightID = nil
        isContinuingSelection = true
        clearSelection()
        onSelectionContinuationChanged?(continuedSelectionSegmentCount)
    }

    private func refreshContinuationPreview(_ fragments: [HighlightFragment]) {
        removeContinuationPreviewAnnotations()
        guard let document else { return }
        for fragment in HighlightFragmentNormalizer.normalize(fragments) {
            guard let page = document.page(at: fragment.pageIndex) else { continue }
            let annotation = PDFAnnotation(
                bounds: fragment.bounds.cgRect,
                forType: .highlight,
                withProperties: nil
            )
            annotation.color = NSColor.systemBlue.withAlphaComponent(0.22)
            annotation.userName = "reading-companion-continuation-preview"
            annotation.shouldPrint = false
            page.addAnnotation(annotation)
            continuationPreviewAnnotations.append((page, annotation))
        }
    }

    private func removeContinuationPreviewAnnotations() {
        for item in continuationPreviewAnnotations {
            item.page.removeAnnotation(item.annotation)
        }
        continuationPreviewAnnotations.removeAll()
    }

    private func combineContinuedSelectionIntoPending() {
        guard !continuedSelectionTexts.isEmpty else { return }
        if let text = pendingSelectionText {
            continuedSelectionTexts.append(HighlightTextNormalizer.inline(text))
        }
        continuedSelectionFragments.append(contentsOf: pendingSelectionFragments)
        pendingSelectionText = continuedSelectionTexts.joined(separator: "\n")
        pendingSelectionFragments = HighlightFragmentNormalizer.normalize(continuedSelectionFragments)
        pendingSelectionSegmentCount = continuedSelectionSegmentCount + max(1, pendingSelectionSegmentCount)
        continuedSelectionTexts = []
        continuedSelectionFragments = []
        continuedSelectionSegmentCount = 0
    }

    func resetSelectionContinuation() {
        selectionPopover?.close()
        clearSelection()
        clearPendingSelection()
    }

    private func selectWholeHighlight(_ record: HighlightRecord) {
        guard let document else { return }
        var combined: PDFSelection?
        for fragment in record.allFragments {
            guard let page = document.page(at: fragment.pageIndex),
                  let selection = page.selection(for: fragment.bounds.cgRect) else { continue }
            if let combined { combined.add(selection) } else { combined = selection }
        }
        currentSelection = combined
    }

    private func showSelectionPopover(at point: CGPoint) {
        selectionPopover?.close()
        let popover = NSPopover()
        popover.behavior = .transient
        popover.contentSize = NSSize(width: 460, height: 48)
        popover.contentViewController = NSHostingController(rootView: SelectionActionBar(
            selectedTint: highlightTint,
            onHighlight: { [weak self] tint in self?.commitPendingHighlight(tint: tint) },
            onAnnotate: { [weak self] in self?.annotatePendingSelection() },
            onCopy: { [weak self] in self?.copyPendingSelection() },
            onAsk: { [weak self] in self?.sendPendingSelectionToQuestion() }
        ))
        selectionPopover = popover
        popover.show(relativeTo: NSRect(x: point.x, y: point.y, width: 1, height: 1), of: self, preferredEdge: .maxY)
    }

    override func magnify(with event: NSEvent) {
        guard !zoomLocked else { return }
        super.magnify(with: event)
    }

    override func smartMagnify(with event: NSEvent) {
        guard !zoomLocked else { return }
        super.smartMagnify(with: event)
    }

    override func scrollWheel(with event: NSEvent) {
        if zoomLocked {
            scrollVerticallyWithoutHorizontalMotion(event)
            return
        }
        super.scrollWheel(with: event)
    }

    override func swipe(with event: NSEvent) {
        guard !zoomLocked else { return }
        super.swipe(with: event)
    }

    override func layout() {
        super.layout()
        if zoomLocked { updateLockObservation() }
        enforceNavigationLock()
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53,
           (isContinuingSelection || pendingSelectionText != nil || !continuedSelectionTexts.isEmpty) {
            selectionPopover?.close()
            annotationPopover?.close()
            clearSelection()
            clearPendingSelection()
            return
        }
        super.keyDown(with: event)
        enforceNavigationLock()
        reportCurrentPage()
    }

    private var enclosedScrollView: NSScrollView? {
        func find(in view: NSView) -> NSScrollView? {
            if let scrollView = view as? NSScrollView { return scrollView }
            for subview in view.subviews {
                if let found = find(in: subview) { return found }
            }
            return nil
        }
        return find(in: self)
    }

    private func enforceNavigationLock() {
        guard zoomLocked, !isEnforcingLock else { return }
        isEnforcingLock = true
        defer { isEnforcingLock = false }
        if let lockedScaleFactor, abs(scaleFactor - lockedScaleFactor) > 0.0001 {
            autoScales = false
            scaleFactor = lockedScaleFactor
        }
        if let scrollView = enclosedScrollView, let lockedHorizontalOrigin {
            var origin = scrollView.contentView.bounds.origin
            if abs(origin.x - lockedHorizontalOrigin) > 0.5 {
                origin.x = lockedHorizontalOrigin
                scrollView.contentView.scroll(to: origin)
                scrollView.reflectScrolledClipView(scrollView.contentView)
            }
        }
    }

    private func scrollVerticallyWithoutHorizontalMotion(_ event: NSEvent) {
        guard abs(event.scrollingDeltaY) >= 0.01,
              let scrollView = enclosedScrollView,
              let lockedHorizontalOrigin else { return }
        let clipView = scrollView.contentView
        var proposed = clipView.bounds
        proposed.origin.x = lockedHorizontalOrigin
        proposed.origin.y -= event.scrollingDeltaY
        var constrained = clipView.constrainBoundsRect(proposed)
        constrained.origin.x = lockedHorizontalOrigin
        clipView.scroll(to: constrained.origin)
        scrollView.reflectScrolledClipView(clipView)
        reportCurrentPage()
    }

    private func updateLockObservation() {
        guard let clipView = enclosedScrollView?.contentView, observedClipView !== clipView else { return }
        stopLockObservation()
        observedClipView = clipView
        clipView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(clipBoundsChanged),
            name: NSView.boundsDidChangeNotification,
            object: clipView
        )
    }

    private func stopLockObservation() {
        if let observedClipView {
            NotificationCenter.default.removeObserver(
                self,
                name: NSView.boundsDidChangeNotification,
                object: observedClipView
            )
        }
        observedClipView = nil
    }

    @objc private func clipBoundsChanged(_ notification: Notification) {
        enforceNavigationLock()
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    func reportCurrentPage() {
        guard let currentPage, let document else { return }
        onNavigate?(document.index(for: currentPage))
    }
}

struct PDFReaderView: NSViewRepresentable {
    @ObservedObject var model: ReaderModel

    func makeCoordinator() -> Coordinator { Coordinator(model: model) }

    func makeNSView(context: Context) -> CompanionPDFView {
        let view = CompanionPDFView()
        view.backgroundColor = .windowBackgroundColor
        view.displaysPageBreaks = true
        view.pageShadowsEnabled = true
        view.autoScales = true
        view.minScaleFactor = 0.2
        view.maxScaleFactor = 6
        view.onHighlight = { [weak model] text, fragments, tint in
            model?.recordHighlight(text: text, fragments: fragments, tint: tint)
        }
        view.onAnnotate = { [weak model] text, fragments, note in
            model?.recordAnnotation(text: text, fragments: fragments, note: note)
        }
        view.onUpdateAnnotation = { [weak model] id, note in model?.updateAnnotation(id: id, note: note) }
        view.onConvertToAnnotation = { [weak model] id, note in model?.convertHighlightToAnnotation(id: id, note: note) }
        view.onCancelAnnotation = { [weak model] in model?.pendingAnnotation = nil }
        view.onEditMark = { [weak model] id in
            guard let record = model?.highlights.first(where: { $0.id == id }) else { return }
            model?.editHighlight(record)
        }
        view.onRecolorHighlight = { [weak model] id, tint in model?.recolorHighlight(id: id, tint: tint) }
        view.onResolveHighlight = { [weak model] id in model?.highlights.first(where: { $0.id == id }) }
        view.onCopySelection = { [weak model] _ in model?.statusMessage = "已复制选中文字" }
        view.onAskSelection = { [weak model] text, pageIndex in
            model?.prepareQuestion(from: text, pageIndex: pageIndex)
        }
        view.onSelectionContinuationChanged = { [weak model] count in
            guard count > 0 else { return }
            model?.statusMessage = "已连续选择 \(count) 段；按住 ⌘ 可继续跨页选择，松开 ⌘ 完成本次选择"
        }
        view.onNavigate = { [weak model] page in model?.didNavigate(to: page) }
        NotificationCenter.default.addObserver(
            context.coordinator,
            selector: #selector(Coordinator.pageChanged),
            name: .PDFViewPageChanged,
            object: view
        )
        return view
    }

    func updateNSView(_ view: CompanionPDFView, context: Context) {
        if view.document !== model.document {
            view.resetSelectionContinuation()
            view.document = model.document
            context.coordinator.lastTarget = nil
            context.coordinator.lastSearchQuery = nil
        }
        synchronizeHighlights(in: view)
        view.displayMode = .singlePageContinuous
        view.displaysAsBook = false
        view.highlightTint = model.highlightTint
        view.highlightModeEnabled = model.highlightModeEnabled
        view.zoomLocked = model.zoomLocked
        if let record = model.pendingAnnotation {
            view.presentAnnotationEditor(for: record)
        }

        if context.coordinator.lastFitMode != model.fitMode {
            switch model.fitMode {
            case .page:
                view.autoScales = true
            case .width:
                view.autoScales = false
                view.scaleFactor = view.scaleFactorForSizeToFit * 1.32
            case .custom:
                view.autoScales = false
                view.scaleFactor = model.zoomScale
            }
            context.coordinator.lastFitMode = model.fitMode
        } else if model.fitMode == .custom, abs(view.scaleFactor - model.zoomScale) > 0.001 {
            view.autoScales = false
            view.scaleFactor = model.zoomScale
        }

        if let target = model.navigationTarget,
           target != context.coordinator.lastTarget,
           let page = model.document?.page(at: target) {
            view.go(to: page)
            context.coordinator.lastTarget = target
        }

        if context.coordinator.lastSearchQuery != model.searchHighlightQuery {
            let query = model.searchHighlightQuery.trimmingCharacters(in: .whitespacesAndNewlines)
            let selections = query.isEmpty ? [] : searchSelections(for: query, in: model.document)
            selections.forEach { $0.color = NSColor.systemYellow.withAlphaComponent(0.68) }
            view.highlightedSelections = selections
            context.coordinator.lastSearchQuery = model.searchHighlightQuery
        }
    }

    private func searchSelections(for query: String, in document: PDFDocument?) -> [PDFSelection] {
        guard let document else { return [] }
        var selections: [PDFSelection] = []
        for pageIndex in 0..<document.pageCount {
            guard let page = document.page(at: pageIndex), let text = page.string else { continue }
            for range in ReaderModel.searchMatchRanges(query: query, in: text) {
                if let selection = page.selection(for: NSRange(range, in: text)) {
                    selections.append(selection)
                }
            }
        }
        return selections
    }

    private func synchronizeHighlights(in view: CompanionPDFView) {
        guard let document = view.document else { return }
        let activeTypes = Dictionary(uniqueKeysWithValues: model.highlights.map {
            (
                $0.id.uuidString,
                $0.markKind == .annotation ? PDFAnnotationSubtype.underline.rawValue : PDFAnnotationSubtype.highlight.rawValue
            )
        })
        for index in 0..<document.pageCount {
            guard let page = document.page(at: index) else { continue }
            for annotation in page.annotations where annotation.type == "Highlight" || annotation.type == "Underline" {
                if let name = annotation.userName,
                   UUID(uuidString: name) != nil,
                   activeTypes[name] != annotation.type {
                    page.removeAnnotation(annotation)
                }
            }
        }
        for record in model.highlights {
            let annotationType: PDFAnnotationSubtype = record.markKind == .annotation ? .underline : .highlight
            let annotationColor = record.markKind == .annotation
                ? NSColor.systemGreen.withAlphaComponent(0.9)
                : record.tint.color
            for fragment in record.allFragments {
                guard let page = document.page(at: fragment.pageIndex) else { continue }
                let bounds = fragment.bounds.cgRect
                let existing = page.annotations.first { annotation in
                    annotation.type == annotationType.rawValue && annotation.userName == record.id.uuidString
                        && annotation.bounds.equalTo(bounds)
                }
                if let existing {
                    existing.color = annotationColor
                    existing.contents = record.note
                    continue
                }
                let annotation = PDFAnnotation(bounds: bounds, forType: annotationType, withProperties: nil)
                annotation.color = annotationColor
                annotation.userName = record.id.uuidString
                annotation.contents = record.note
                page.addAnnotation(annotation)
            }
        }
    }

    @MainActor
    final class Coordinator: NSObject {
        weak var model: ReaderModel?
        var lastTarget: Int?
        var lastFitMode: ReaderFitMode?
        var lastSearchQuery: String?

        init(model: ReaderModel) { self.model = model }

        @objc func pageChanged(_ notification: Notification) {
            guard let view = notification.object as? CompanionPDFView else { return }
            view.reportCurrentPage()
        }

        deinit { NotificationCenter.default.removeObserver(self) }
    }
}
