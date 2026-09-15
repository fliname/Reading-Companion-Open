import AppKit
import SwiftUI
import WebKit

struct ReflowReaderView: NSViewRepresentable {
    @ObservedObject var model: ReaderModel
    let showsTwoPages: Bool

    func makeCoordinator() -> Coordinator { Coordinator(model: model) }

    func makeNSView(context: Context) -> WKWebView {
        let controller = WKUserContentController()
        controller.add(context.coordinator, name: "readerNavigation")
        controller.add(context.coordinator, name: "readerSelection")
        controller.add(context.coordinator, name: "readerMark")
        let configuration = WKWebViewConfiguration()
        configuration.userContentController = controller
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.setValue(false, forKey: "drawsBackground")
        context.coordinator.webView = webView
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        let coordinator = context.coordinator
        coordinator.model = model
        guard let book = model.reflowBook else { return }
        let identity = "\(model.documentURL?.path ?? "")|\(book.title)|\(book.sections.count)|\(book.sections.first?.resourcePath ?? "")|\(book.sections.last?.resourcePath ?? "")"
        if coordinator.loadedIdentity != identity {
            coordinator.loadedIdentity = identity
            coordinator.isReady = false
            coordinator.pendingScale = model.zoomScale
            coordinator.pendingLocation = model.navigationTarget
            coordinator.pendingQuery = model.searchHighlightQuery
            coordinator.pendingSpreadCount = showsTwoPages ? 2 : 1
            coordinator.pendingSearchNavigationCommand = model.searchNavigationCommand
            coordinator.pendingSearchNavigationTarget = model.searchNavigationTarget
            coordinator.pendingPageRangeSummaryRequest = model.pageRangeSummaryRequest
            coordinator.pendingCharacters = model.characterHighlightsEnabled ? model.characters : []
            webView.loadHTMLString(ReflowReaderHTML.make(for: book), baseURL: nil)
            return
        }
        coordinator.setSpreadCount(showsTwoPages ? 2 : 1)
        coordinator.setScale(model.zoomScale)
        coordinator.turnPageIfNeeded(command: model.reflowTurnCommand, direction: model.reflowTurnDirection)
        coordinator.applyMarks(model.highlights)
        coordinator.applyCharacters(model.characterHighlightsEnabled ? model.characters : [])
        coordinator.setSearchQuery(model.searchHighlightQuery)
        if let page = model.navigationTarget { coordinator.navigate(to: page) }
        coordinator.navigateToSearchResultIfNeeded(
            command: model.searchNavigationCommand,
            target: model.searchNavigationTarget
        )
        coordinator.resolvePageRangeSummaryIfNeeded(model.pageRangeSummaryRequest)
        coordinator.navigateToAnchorIfNeeded()
        coordinator.synchronizeReferences()
    }

    final class Coordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate, NSPopoverDelegate {
        var model: ReaderModel
        weak var webView: WKWebView?
        var loadedIdentity: String?
        var isReady = false
        var pendingScale = 1.0
        var pendingLocation: Int?
        var pendingQuery = ""
        var pendingSpreadCount = 1
        var pendingSearchNavigationCommand = 0
        var pendingSearchNavigationTarget: SearchRecord?
        var pendingPageRangeSummaryRequest: PageRangeSummaryRequest?
        var pendingCharacters: [BookCharacter] = []
        private var appliedScale = -1.0
        private var appliedMarks = ""
        private var appliedCharacters = ""
        private var appliedQuery = "\u{0}"
        private var appliedSpreadCount = 0
        private var appliedTurnCommand = 0
        private var appliedSearchNavigationCommand = 0
        private var appliedPageRangeSummaryRequestID: UUID?
        private var lastNavigationRequest: Int?
        private var initializedNavigation = false
        private var layoutRevision = -1
        private var referenceSignature = ""
        private var referenceGeneration = 0
        private var appliedAnchorCommand = 0
        private var selectionPopover: NSPopover?
        private var activeSelection: ReflowSelection?
        private var activeHighlightID: UUID?

        init(model: ReaderModel) { self.model = model }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            isReady = true
            appliedSpreadCount = pendingSpreadCount
            appliedScale = pendingScale
            let saved = model.reflowReadingPosition.flatMap { try? JSONEncoder().encode($0) }
                .flatMap { String(data: $0, encoding: .utf8) } ?? "null"
            webView.evaluateJavaScript("window.readerConfigure(\(pendingScale),\(pendingSpreadCount),\(saved),\(pendingLocation ?? model.currentPageIndex));")
            applyMarks(model.highlights, force: true)
            applyCharacters(pendingCharacters, force: true)
            setSearchQuery(pendingQuery, force: true)
            lastNavigationRequest = pendingLocation
            navigateToSearchResultIfNeeded(
                command: pendingSearchNavigationCommand,
                target: pendingSearchNavigationTarget,
                force: true
            )
            resolvePageRangeSummaryIfNeeded(pendingPageRangeSummaryRequest, force: true)
        }

        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void
        ) {
            if navigationAction.navigationType == .linkActivated,
               let url = navigationAction.request.url,
               url.scheme?.lowercased() != "about" {
                decisionHandler(.cancel)
                return
            }
            decisionHandler(.allow)
        }

        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            switch message.name {
            case "readerNavigation":
                guard isReady, let body = message.body as? [String: Any],
                      body["initialized"] as? Bool == true,
                      let location = (body["location"] as? NSNumber)?.intValue else { return }
                if location != lastNavigationRequest { lastNavigationRequest = nil }
                model.updateReflowPagination(
                    pageNumber: (body["pageNumber"] as? NSNumber)?.intValue ?? 1,
                    pageCount: (body["pageCount"] as? NSNumber)?.intValue ?? 1,
                    spreadCount: (body["spreadCount"] as? NSNumber)?.intValue ?? 1
                )
                initializedNavigation = true
                layoutRevision = (body["layoutRevision"] as? NSNumber)?.intValue ?? 0
                let position = (body["position"] as? [String: Any]).flatMap { try? JSONSerialization.data(withJSONObject: $0) }
                    .flatMap { try? JSONDecoder().decode(ReflowReadingPosition.self, from: $0) }
                let positionChanged = position != model.reflowReadingPosition
                model.reflowReadingPosition = position
                model.didNavigate(to: location)
                if positionChanged { model.persist() }
                synchronizeReferences()
            case "readerSelection":
                guard let selection = ReflowSelection(message.body) else {
                    closeSelectionPopover(clearSelection: false)
                    return
                }
                activeHighlightID = nil
                activeSelection = selection
                showSelectionActions(for: selection)
            case "readerMark":
                guard let body = message.body as? [String: Any],
                      let rawID = body["id"] as? String,
                      let id = UUID(uuidString: rawID),
                      let record = model.highlights.first(where: { $0.id == id }),
                      let selection = ReflowSelection(record: record, payload: body) else { return }
                activeHighlightID = id
                activeSelection = selection
                showSelectionActions(for: selection)
            default: break
            }
        }

        func setSpreadCount(_ count: Int, force: Bool = false) {
            pendingSpreadCount = count == 2 ? 2 : 1
            guard isReady, force || appliedSpreadCount != pendingSpreadCount else { return }
            appliedSpreadCount = pendingSpreadCount
            webView?.evaluateJavaScript("window.readerSetSpreadCount(\(pendingSpreadCount));")
        }

        func setScale(_ scale: Double, force: Bool = false) {
            pendingScale = scale
            guard isReady, force || abs(appliedScale - scale) > 0.001 else { return }
            appliedScale = scale
            let bounded = min(max(scale, 0.65), 2.25)
            webView?.evaluateJavaScript("window.readerSetScale(\(bounded));")
        }

        func turnPageIfNeeded(command: Int, direction: Int) {
            guard isReady, command != appliedTurnCommand else { return }
            appliedTurnCommand = command
            webView?.evaluateJavaScript("window.readerTurn(\(direction >= 0 ? 1 : -1));")
        }

        func navigate(to location: Int, force: Bool = false) {
            pendingLocation = location
            guard isReady, force || lastNavigationRequest != location else { return }
            lastNavigationRequest = location
            webView?.evaluateJavaScript("window.readerGoToLocation(\(location));")
        }

        func setSearchQuery(_ query: String, force: Bool = false) {
            pendingQuery = query
            guard isReady, force || appliedQuery != query else { return }
            appliedQuery = query
            webView?.evaluateJavaScript("window.readerFind(\(Self.jsonString(query)));")
        }

        func navigateToSearchResultIfNeeded(
            command: Int,
            target: SearchRecord?,
            force: Bool = false
        ) {
            pendingSearchNavigationCommand = command
            pendingSearchNavigationTarget = target
            guard isReady, let target,
                  force || command != appliedSearchNavigationCommand,
                  let book = model.reflowBook,
                  !book.sections.isEmpty else { return }
            appliedSearchNavigationCommand = command
            let sections = book.sections.sorted { $0.startPageIndex < $1.startPageIndex }
            let sectionIndex = sections.lastIndex { $0.startPageIndex <= target.pageIndex } ?? 0
            let section = sections[sectionIndex]
            let nextStart = sectionIndex + 1 < sections.count
                ? sections[sectionIndex + 1].startPageIndex
                : max(model.pageCount, section.startPageIndex + 1)
            let span = max(nextStart - section.startPageIndex, 1)
            let ratio = min(max(
                (Double(target.pageIndex - section.startPageIndex) + 0.5) / Double(span),
                0
            ), 0.999)
            let script = "window.readerGoToSearch(" + [
                Self.jsonString(target.query ?? model.searchHighlightQuery),
                Self.jsonString(section.id),
                String(ratio),
                Self.jsonString(target.text),
                String(target.pageIndex)
            ].joined(separator: ",") + ");"
            webView?.evaluateJavaScript(script)
        }

        func resolvePageRangeSummaryIfNeeded(
            _ request: PageRangeSummaryRequest?,
            force: Bool = false
        ) {
            pendingPageRangeSummaryRequest = request
            guard isReady, let request, let webView,
                  force || appliedPageRangeSummaryRequestID != request.id else { return }
            appliedPageRangeSummaryRequestID = request.id
            let script = "window.readerTextForPageRange(\(request.startPage - 1),\(request.endPage - 1));"
            Task { @MainActor [weak self, weak webView] in
                guard let self, let webView else { return }
                do {
                    guard let result = try await webView.evaluateJavaScript(script) as? [String: Any],
                          let values = result["pages"] as? [Any] else {
                        self.model.failPageRangeSummaryResolution(request.id)
                        return
                    }
                    let pages = values.map { ($0 as? String) ?? "" }
                    self.model.resolvePageRangeSummaryRequest(
                        request,
                        renderedPageTexts: pages,
                        anchors: (result["anchors"] as? [[String: Any]])
                            .flatMap { try? JSONSerialization.data(withJSONObject: $0) }
                            .flatMap { try? JSONDecoder().decode([ReflowTextAnchor].self, from: $0) }
                    )
                } catch {
                    self.model.failPageRangeSummaryResolution(request.id)
                }
            }
        }

        func navigateToAnchorIfNeeded() {
            guard isReady, model.reflowAnchorCommand != appliedAnchorCommand,
                  let anchor = model.reflowAnchorTarget else { return }
            appliedAnchorCommand = model.reflowAnchorCommand
            webView?.evaluateJavaScript("window.readerGoToAnchor({sectionID:\(Self.jsonString(anchor.sectionID)),offset:\(anchor.startOffset)});")
        }

        func synchronizeReferences() {
            guard isReady, initializedNavigation, let webView else { return }
            func anchorsJSON(_ anchors: [ReflowTextAnchor]?) -> Any {
                guard let anchors, let data = try? JSONEncoder().encode(anchors),
                      let object = try? JSONSerialization.jsonObject(with: data) else { return NSNull() }
                return object
            }
            let outlines: [[String: Any]] = model.outline.map {
                ["id": $0.id.uuidString, "title": $0.title, "location": $0.pageIndex]
            }
            let summaries: [[String: Any]] = model.pageRangeSummaries.map {
                ["id": $0.id.uuidString, "startPage": $0.startPage, "endPage": $0.endPage,
                 "anchors": anchorsJSON($0.reflowAnchors)]
            }
            var draft: Any = NSNull()
            if let start = Int(model.summaryStartPage), let end = Int(model.summaryEndPage),
               start >= 1, end >= start {
                draft = ["id": "draft", "startPage": start, "endPage": end,
                         "anchors": anchorsJSON(model.summaryDraftAnchors)] as [String: Any]
            }
            let payload: [String: Any] = ["outline": outlines, "summaries": summaries, "draft": draft]
            guard let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]),
                  let json = String(data: data, encoding: .utf8) else { return }
            let signature = "\(layoutRevision)|\(json)"
            guard signature != referenceSignature else { return }
            referenceSignature = signature
            referenceGeneration += 1
            let generation = referenceGeneration
            let sourceURL = model.documentURL
            Task { @MainActor [weak self, weak webView] in
                guard let self, let webView else { return }
                guard let value = try? await webView.evaluateJavaScript("window.readerResolveReferences(\(json));"),
                      generation == self.referenceGeneration, self.model.documentURL == sourceURL,
                      let data = try? JSONSerialization.data(withJSONObject: value),
                      let result = try? JSONDecoder().decode(ReflowReferenceResult.self, from: data) else { return }
                let pages = Dictionary(uniqueKeysWithValues: result.outline.map { ($0.id, $0.pageNumber) })
                if self.model.outlineDisplayPages != pages { self.model.outlineDisplayPages = pages }
                self.model.outlineReflowAnchors = Dictionary(uniqueKeysWithValues: result.outline.map { ($0.id, $0.anchor) })
                var changed = false
                for item in result.summaries {
                    guard let id = UUID(uuidString: item.id),
                          let index = self.model.pageRangeSummaries.firstIndex(where: { $0.id == id }) else { continue }
                    var record = self.model.pageRangeSummaries[index]
                    record.startPage = item.startPage
                    record.endPage = item.endPage
                    record.reflowAnchors = item.anchors
                    if record != self.model.pageRangeSummaries[index] {
                        self.model.pageRangeSummaries[index] = record
                        changed = true
                    }
                }
                if let draft = result.draft {
                    self.model.summaryDraftAnchors = draft.anchors
                    if self.model.summaryStartPage != String(draft.startPage) { self.model.summaryStartPage = String(draft.startPage) }
                    if self.model.summaryEndPage != String(draft.endPage) { self.model.summaryEndPage = String(draft.endPage) }
                }
                if changed { self.model.persist() }
            }
        }

        func applyCharacters(_ characters: [BookCharacter], force: Bool = false) {
            pendingCharacters = characters
            let payload: [[String: Any]] = characters.map {
                ["id": $0.id.uuidString, "names": $0.allNames, "color": $0.cssColor]
            }
            guard let data = try? JSONSerialization.data(withJSONObject: payload),
                  let json = String(data: data, encoding: .utf8),
                  isReady, force || appliedCharacters != json else { return }
            appliedCharacters = json
            webView?.evaluateJavaScript("window.readerApplyCharacters(\(json));")
        }

        func applyMarks(_ records: [HighlightRecord], force: Bool = false) {
            let payload: [[String: Any]] = records.flatMap { record in
                record.allReflowAnchors.map { anchor in
                    ["id": record.id.uuidString, "sectionID": anchor.sectionID,
                     "start": anchor.startOffset, "end": anchor.endOffset,
                     "kind": record.markKind.rawValue, "tint": record.tint.rawValue]
                }
            }
            guard let data = try? JSONSerialization.data(withJSONObject: payload),
                  let json = String(data: data, encoding: .utf8),
                  isReady, force || appliedMarks != json else { return }
            appliedMarks = json
            webView?.evaluateJavaScript("window.readerApplyMarks(\(json));")
        }

        private func showSelectionActions(for selection: ReflowSelection) {
            guard let webView else { return }
            selectionPopover?.close()
            let popover = NSPopover()
            popover.behavior = .transient
            popover.delegate = self
            popover.contentViewController = NSHostingController(rootView: SelectionActionBar(
                selectedTint: activeHighlightID.flatMap { id in
                    model.highlights.first(where: { $0.id == id })?.tint
                } ?? model.highlightTint,
                onHighlight: { [weak self] tint in self?.commitHighlight(tint: tint) },
                onAnnotate: { [weak self] in self?.showAnnotationEditor() },
                onCopy: { [weak self] in self?.copySelection() },
                onAsk: { [weak self] in self?.askAboutSelection() }
            ))
            selectionPopover = popover
            let clampedX = min(max(selection.rect.midX, 1), max(webView.bounds.width - 1, 1))
            // JS getClientRects 返回以视口左上为原点的坐标。WKWebView 是
            // flipped view（同样是左上原点），无需再做 Y 轴翻转；否则页面
            // 偏下方的选区会被锚定到视图顶部附近。
            let anchor: NSRect
            if webView.isFlipped {
                anchor = NSRect(
                    x: clampedX,
                    y: min(max(selection.rect.minY, 0), max(webView.bounds.height - selection.rect.height, 0)),
                    width: 1,
                    height: max(selection.rect.height, 1)
                )
            } else {
                anchor = NSRect(
                    x: clampedX,
                    y: max(0, webView.bounds.height - selection.rect.maxY),
                    width: 1,
                    height: max(selection.rect.height, 1)
                )
            }
            let belowEdge: NSRectEdge = webView.isFlipped ? .maxY : .minY
            popover.show(relativeTo: anchor, of: webView, preferredEdge: belowEdge)
        }

        private func showAnnotationEditor() {
            guard let popover = selectionPopover else { return }
            let note = activeHighlightID.flatMap { id in
                model.highlights.first(where: { $0.id == id })?.note
            } ?? ""
            popover.contentViewController = NSHostingController(rootView: InlineAnnotationEditor(
                note: note, onSend: { [weak self] note in self?.commitAnnotation(note: note) }
            ))
        }

        private func commitHighlight(tint: HighlightTint) {
            guard let selection = activeSelection else { return }
            if let id = activeHighlightID {
                model.recolorHighlight(id: id, tint: tint)
            } else {
                model.recordReflowHighlight(text: selection.text, pageIndex: selection.location,
                                            anchor: selection.anchor, anchors: selection.anchors, tint: tint)
            }
            applyMarks(model.highlights, force: true)
            closeSelectionPopover(clearSelection: true)
        }

        private func commitAnnotation(note: String) {
            guard let selection = activeSelection else { return }
            if let id = activeHighlightID {
                model.convertHighlightToAnnotation(id: id, note: note)
            } else {
                model.recordReflowAnnotation(text: selection.text, pageIndex: selection.location,
                                             anchor: selection.anchor, anchors: selection.anchors, note: note)
            }
            applyMarks(model.highlights, force: true)
            closeSelectionPopover(clearSelection: true)
        }

        private func copySelection() {
            guard let selection = activeSelection else { return }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(selection.text, forType: .string)
            model.statusMessage = "已复制选中文字"
            closeSelectionPopover(clearSelection: true)
        }

        private func askAboutSelection() {
            guard let selection = activeSelection else { return }
            model.prepareQuestion(from: selection.text, pageIndex: selection.location)
            closeSelectionPopover(clearSelection: true)
        }

        private func closeSelectionPopover(clearSelection: Bool) {
            selectionPopover?.close()
            selectionPopover = nil
            activeSelection = nil
            activeHighlightID = nil
            if clearSelection { webView?.evaluateJavaScript("window.readerClearSelection();") }
        }

        func popoverDidClose(_ notification: Notification) { selectionPopover = nil }

        private static func jsonString(_ value: String) -> String {
            guard let data = try? JSONSerialization.data(withJSONObject: [value]),
                  let array = String(data: data, encoding: .utf8) else { return "\"\"" }
            return String(array.dropFirst().dropLast())
        }
    }
}

private struct ReflowSelection {
    let text: String
    let location: Int
    let anchor: ReflowTextAnchor
    let anchors: [ReflowTextAnchor]
    let rect: CGRect

    init?(_ value: Any) {
        guard let body = value as? [String: Any], let text = body["text"] as? String,
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let sectionID = body["sectionID"] as? String,
              let start = (body["start"] as? NSNumber)?.intValue,
              let end = (body["end"] as? NSNumber)?.intValue,
              let location = (body["location"] as? NSNumber)?.intValue,
              let x = (body["x"] as? NSNumber)?.doubleValue,
              let y = (body["y"] as? NSNumber)?.doubleValue,
              let width = (body["width"] as? NSNumber)?.doubleValue,
              let height = (body["height"] as? NSNumber)?.doubleValue else { return nil }
        self.text = text
        self.location = location
        anchor = ReflowTextAnchor(sectionID: sectionID, startOffset: start, endOffset: end,
                                  prefix: body["prefix"] as? String, suffix: body["suffix"] as? String)
        anchors = (body["anchors"] as? [[String: Any]])?.compactMap { item in
            guard let section = item["sectionID"] as? String,
                  let start = (item["start"] as? NSNumber)?.intValue,
                  let end = (item["end"] as? NSNumber)?.intValue else { return nil }
            return ReflowTextAnchor(sectionID: section, startOffset: start, endOffset: end,
                                    prefix: item["prefix"] as? String, suffix: item["suffix"] as? String)
        } ?? [anchor]
        rect = CGRect(x: x, y: y, width: width, height: height)
    }

    init?(record: HighlightRecord, payload: [String: Any]) {
        guard let anchor = record.reflowAnchor ?? record.reflowAnchors?.first,
              let x = (payload["x"] as? NSNumber)?.doubleValue,
              let y = (payload["y"] as? NSNumber)?.doubleValue,
              let width = (payload["width"] as? NSNumber)?.doubleValue,
              let height = (payload["height"] as? NSNumber)?.doubleValue else { return nil }
        text = record.displayText
        location = record.pageIndex
        self.anchor = anchor
        anchors = record.allReflowAnchors
        rect = CGRect(x: x, y: y, width: width, height: height)
    }
}

private struct ReflowReferenceResult: Decodable {
    struct Outline: Decodable {
        let id: UUID
        let pageNumber: Int
        let anchor: ReflowTextAnchor
    }
    struct Range: Decodable {
        let id: String
        let startPage: Int
        let endPage: Int
        let anchors: [ReflowTextAnchor]
    }
    let outline: [Outline]
    let summaries: [Range]
    let draft: Range?
}
