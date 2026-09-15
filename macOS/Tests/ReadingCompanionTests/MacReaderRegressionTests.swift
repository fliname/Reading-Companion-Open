import AppKit
import PDFKit
import SwiftUI
import Testing
import WebKit
@testable import ReadingCompanion

@Suite("Mac reader regressions", .serialized)
struct MacReaderRegressionTests {
    @MainActor
    @Test func readerColumnsKeepAllWidthsOnLockAndPanelReplacement() async throws {
        let state = LayoutFixtureState()
        let host = NSHostingView(rootView: LayoutFixture(state: state))
        host.frame = CGRect(x: 0, y: 0, width: 1300, height: 700)
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(150))
        func widths() -> [CGFloat] {
            func find(_ name: String, in view: NSView) -> NSView? {
                if view.identifier?.rawValue == name { return view }
                for child in view.subviews { if let match = find(name, in: child) { return match } }
                return nil
            }
            return ["left", "reader", "right"].map { find($0, in: host)?.frame.width ?? -1 }
        }
        let before = widths()
        #expect(before.allSatisfy { $0 > 200 })
        state.manager = true
        try await Task.sleep(for: .milliseconds(100))
        host.layoutSubtreeIfNeeded()
        #expect(widths() == before)
        state.manager = false
        state.locked = true
        try await Task.sleep(for: .milliseconds(100))
        host.setFrameSize(CGSize(width: 1100, height: 700))
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(150))
        #expect(widths() == before)
        state.locked = false
        try await Task.sleep(for: .milliseconds(150))
        host.layoutSubtreeIfNeeded()
        #expect(widths() != before)
    }

    @MainActor
    @Test func loadingCallbacksCannotOverwriteTheSavedPDFPage() {
        let model = ReaderModel()
        model.document = PDFDocument()
        model.currentPageIndex = 12
        model.navigationTarget = 12
        model.documentStateLoaded = false
        model.didNavigate(to: 0)
        #expect(model.currentPageIndex == 12)
        #expect(model.navigationTarget == 12)
        model.documentStateLoaded = true
        model.didNavigate(to: 13)
        #expect(model.currentPageIndex == 13)
    }

    @MainActor
    @Test func slashAliasesAreOptionalTrimmedAndDeduplicated() {
        let parsed = ReaderModel.parseCharacterBatchLine(" 林默 / 阿默 / 小林 /阿默/林默 ：调查员/译者 ")
        #expect(parsed?.name == "林默")
        #expect(parsed?.aliases == ["阿默", "小林"])
        #expect(parsed?.identity == "调查员/译者")
        #expect(ReaderModel.parseCharacterBatchLine("林默：调查员")?.aliases == [])
        #expect(ReaderModel.parseCharacterBatchLine("林默／阿默：调查员")?.aliases == ["阿默"])
        #expect(ReaderModel.parseCharacterBatchLine("/阿默：调查员") == nil)
    }

    @Test func ocrGapsMergeWithoutBridgingRowsOrColumns() {
        let fragments = [
            HighlightFragment(pageIndex: 0, bounds: CGRect(x: 10, y: 100, width: 40, height: 16)),
            HighlightFragment(pageIndex: 0, bounds: CGRect(x: 58, y: 101, width: 30, height: 15)),
            HighlightFragment(pageIndex: 0, bounds: CGRect(x: 94, y: 100, width: 40, height: 16)),
            HighlightFragment(pageIndex: 0, bounds: CGRect(x: 10, y: 84, width: 124, height: 16)),
            HighlightFragment(pageIndex: 0, bounds: CGRect(x: 230, y: 100, width: 90, height: 16))
        ]
        let normalized = HighlightFragmentNormalizer.normalize(fragments.reversed())
        #expect(normalized.count == 3)
        #expect(normalized.contains { $0.bounds.cgRect.minX == 10 && $0.bounds.cgRect.width == 124 })
        let ink = normalized.map { PDFHighlightGeometry.inkBounds($0.bounds.cgRect) }
        #expect(ink.allSatisfy { $0.height <= 12 })
        #expect(!ink[0].intersects(ink[2]))
    }

    @Test func pdfCropUsesNormalizedPositionAndProportion() {
        let lock = PDFViewportRegion(visible: CGRect(x: 60, y: 160, width: 480, height: 480),
                                     page: CGRect(x: 0, y: 0, width: 600, height: 800))
        let next = lock.rect(in: CGRect(x: 20, y: 30, width: 900, height: 1200))
        #expect(next == CGRect(x: 110, y: 270, width: 720, height: 720))
    }

    @MainActor
    @Test func pdfNavigationKeepsCroppedVerticalRangeAndSupportsTwoUp() async throws {
        let document = PDFDocument()
        for _ in 0..<4 {
            let image = NSImage(size: NSSize(width: 600, height: 800))
            image.lockFocus(); NSColor.white.setFill(); NSRect(x: 0, y: 0, width: 600, height: 800).fill(); image.unlockFocus()
            document.insert(try #require(PDFPage(image: image)), at: document.pageCount)
        }
        let view = CompanionPDFView(frame: CGRect(x: 0, y: 0, width: 480, height: 480))
        view.document = document
        view.displayMode = .singlePageContinuous
        view.autoScales = false
        view.scaleFactor = 1
        view.layoutDocumentView()
        let first = try #require(document.page(at: 0))
        view.go(to: PDFDestination(page: first, at: CGPoint(x: 60, y: 640)))
        try await Task.sleep(for: .milliseconds(100))
        let before = PDFViewportRegion(visible: view.convert(view.bounds, to: first), page: first.bounds(for: .cropBox))
        view.zoomLocked = true
        let next = try #require(document.page(at: 1))
        view.navigate(to: next)
        try await Task.sleep(for: .milliseconds(100))
        let after = PDFViewportRegion(visible: view.convert(view.bounds, to: next), page: next.bounds(for: .cropBox))
        #expect(abs(before.normalized.midY - after.normalized.midY) < 0.03)
        #expect(abs(before.normalized.height - after.normalized.height) < 0.03)
        view.zoomLocked = false
        view.displayMode = .twoUpContinuous
        view.displaysAsBook = false
        view.autoScales = true
        view.layoutDocumentView()
        view.navigate(to: first)
        try await Task.sleep(for: .milliseconds(200))
        #expect(view.displayMode == .twoUpContinuous)
        // PDFKit's offscreen visiblePages cache can report one page; assert actual page geometry.
        let left = view.convert(first.bounds(for: .cropBox), from: first)
        let right = view.convert(next.bounds(for: .cropBox), from: next)
        #expect(view.bounds.contains(left))
        #expect(view.bounds.contains(right))
        #expect(left.maxX < right.minX)
    }

    @MainActor
    @Test func selectionStaysBlueAcrossRightEdgeTurnAndSectionBoundary() async throws {
        let (view, sink) = try await makeReader()
        _ = try await view.evaluateJavaScript("""
        (()=>{const n=document.querySelector('#chapter-a p').firstChild;
        document.querySelector('#chapter-a p').dispatchEvent(new MouseEvent('mousedown',{bubbles:true,button:0}));
        const s=getSelection();s.setBaseAndExtent(n,0,n,12);
        document.dispatchEvent(new Event('selectionchange'));})()
        """)
        try await Task.sleep(for: .milliseconds(70))
        let blue = try #require(try await view.evaluateJavaScript("getComputedStyle(document.querySelector('.mark-preview')).backgroundColor") as? String)
        #expect(blue == "rgba(120, 190, 245, 0.38)")
        let selected = try #require(try await view.evaluateJavaScript("getSelection().toString()") as? String)
        try await Task.sleep(for: .milliseconds(150))
        #expect(try await view.evaluateJavaScript("document.querySelectorAll('.mark-preview').length > 0") as? Bool == true)
        _ = try await view.evaluateJavaScript("document.dispatchEvent(new MouseEvent('mousemove',{bubbles:true,buttons:1,clientX:innerWidth-2,clientY:300}));")
        try await Task.sleep(for: .milliseconds(760))
        _ = try await view.evaluateJavaScript("document.dispatchEvent(new MouseEvent('mouseup',{bubbles:true,button:0}));")
        try await Task.sleep(for: .milliseconds(70))
        let position = try #require(try await view.evaluateJavaScript("window.readerReadingPosition()") as? [String: Any])
        #expect((position["pageNumber"] as? Int ?? 0) > 1)
        #expect(try await view.evaluateJavaScript("getSelection().toString()") as? String != selected)
        #expect(try await view.evaluateJavaScript("document.querySelectorAll('.mark-preview').length > 0") as? Bool == true)
        // Cross-chapter selections must be one action with one anchor per chapter.
        _ = try await view.evaluateJavaScript("""
        (()=>{const a=document.querySelector('#chapter-a p').firstChild,b=document.querySelector('#chapter-b p').firstChild;
        getSelection().setBaseAndExtent(a,0,b,20);
        document.dispatchEvent(new MouseEvent('mouseup',{bubbles:true}));})()
        """)
        try await Task.sleep(for: .milliseconds(70))
        let anchors = try #require(sink.selection?["anchors"] as? [[String: Any]])
        #expect(anchors.count == 2)
        #expect(anchors.first?["sectionID"] as? String == "chapter-a")
        #expect(anchors.last?["sectionID"] as? String == "chapter-b")
        _ = try await view.evaluateJavaScript("window.readerClearSelection()")
        #expect(try await view.evaluateJavaScript("document.querySelectorAll('.mark-preview').length") as? Int == 0)
    }

    @MainActor
    @Test func reopeningAndCharacterChangesKeepTheExactRenderedPage() async throws {
        let (view, _) = try await makeReader()
        for _ in 0..<3 {
            _ = try await view.evaluateJavaScript("window.readerTurn(1)")
            try await Task.sleep(for: .milliseconds(200))
        }
        let saved = try #require(try await view.evaluateJavaScript("window.readerReadingPosition()") as? [String: Any])
        #expect(saved["pageNumber"] as? Int == 4)
        _ = try await view.evaluateJavaScript("window.readerApplyCharacters([{names:['林默'],color:'rgba(20,120,220,.3)'}])")
        try await Task.sleep(for: .milliseconds(100))
        let after = try #require(try await view.evaluateJavaScript("window.readerReadingPosition()") as? [String: Any])
        #expect(after["pageNumber"] as? Int == 4)
        let data = try JSONSerialization.data(withJSONObject: saved)
        let json = try #require(String(data: data, encoding: .utf8))
        let (reopened, _) = try await makeReader(saved: json)
        let restored = try #require(try await reopened.evaluateJavaScript("window.readerReadingPosition()") as? [String: Any])
        #expect(restored["pageNumber"] as? Int == 4)
        #expect(restored["offset"] as? Int == saved["offset"] as? Int)
        let storeURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: storeURL) }
        let store = DocumentStore(directoryURL: storeURL)
        let position = try JSONDecoder().decode(ReflowReadingPosition.self, from: data)
        var state = DocumentState(lastPageIndex: 0)
        state.reflowReadingPosition = position
        let source = storeURL.appendingPathComponent("book.epub")
        try await store.save(state, for: source)
        #expect(await store.load(for: source).reflowReadingPosition == position)
    }

    @MainActor
    @Test func summaryAndOutlinePagesFollowTextWhenLayoutChanges() async throws {
        let (view, _) = try await makeReader()
        _ = try await view.evaluateJavaScript("""
        window.testRange=window.readerTextForPageRange(2,4);
        window.testReferences={outline:[{id:'chapter-b',title:'第二章',location:100}],summaries:[{id:'summary',startPage:3,endPage:5,anchors:window.testRange.anchors}],draft:{id:'draft',startPage:3,endPage:5,anchors:window.testRange.anchors}};
        window.beforeReferences=window.readerResolveReferences(window.testReferences);
        """)
        let before = try #require(try await view.evaluateJavaScript("window.beforeReferences") as? [String: Any])
        let oldOutline = try #require((before["outline"] as? [[String: Any]])?.first?["pageNumber"] as? Int)
        _ = try await view.evaluateJavaScript("window.readerSetScale(1.6)")
        let new = try #require(try await view.evaluateJavaScript("window.readerResolveReferences(window.testReferences)") as? [String: Any])
        let newOutline = try #require((new["outline"] as? [[String: Any]])?.first?["pageNumber"] as? Int)
        #expect(newOutline > oldOutline)
        let range = try #require((new["summaries"] as? [[String: Any]])?.first)
        #expect((range["endPage"] as? Int ?? 0) > 5)
        #expect((new["draft"] as? [String: Any])?["endPage"] as? Int == range["endPage"] as? Int)
        #expect(try await view.evaluateJavaScript("JSON.stringify(window.readerResolveReferences(window.testReferences).summaries[0].anchors)===JSON.stringify(window.testRange.anchors)") as? Bool == true)
        _ = try await view.evaluateJavaScript("const anchor=window.testRange.anchors[0];window.readerGoToAnchor({sectionID:anchor.sectionID,offset:anchor.startOffset});")
        let jumped = try #require(try await view.evaluateJavaScript("window.readerReadingPosition()") as? [String: Any])
        #expect(jumped["pageNumber"] as? Int == range["startPage"] as? Int)
        _ = try await view.evaluateJavaScript("window.readerSetSpreadCount(2)")
        let spread = try #require(try await view.evaluateJavaScript("window.readerResolveReferences(window.testReferences)") as? [String: Any])
        #expect((spread["summaries"] as? [[String: Any]])?.first?["anchors"] != nil)
        view.setFrameSize(CGSize(width: 610, height: 690))
        try await Task.sleep(for: .milliseconds(250))
        #expect(try await view.evaluateJavaScript("JSON.stringify(window.readerResolveReferences(window.testReferences).summaries[0].anchors)===JSON.stringify(window.testRange.anchors)") as? Bool == true)
    }

    @MainActor
    private func makeReader(saved: String = "null") async throws -> (WKWebView, RegressionMessageSink) {
        let text = String(repeating: "林默沿着河边走向城镇，想起昨日与朋友的谈话。", count: 5)
        let body = (0..<35).map { "<p>段落\($0) \(text)</p>" }.joined()
        let book = ReflowBook(title: "回归测试", sections: [
            ReflowSection(id: "chapter-a", resourcePath: "a.xhtml", title: "第一章", html: "<h1>第一章</h1>" + body, startPageIndex: 0),
            ReflowSection(id: "chapter-b", resourcePath: "b.xhtml", title: "第二章", html: "<h1>第二章</h1>" + body, startPageIndex: 100)
        ])
        let sink = RegressionMessageSink()
        let config = WKWebViewConfiguration()
        config.userContentController.add(sink, name: "readerNavigation")
        config.userContentController.add(sink, name: "readerSelection")
        let view = WKWebView(frame: CGRect(x: 0, y: 0, width: 820, height: 690), configuration: config)
        view.loadHTMLString(ReflowReaderHTML.make(for: book), baseURL: nil)
        for _ in 0..<200 {
            if !view.isLoading,
               (try? await view.evaluateJavaScript("typeof window.readerConfigure === 'function'")) as? Bool == true {
                try await Task.sleep(for: .milliseconds(150))
                _ = try await view.evaluateJavaScript("window.readerConfigure(1,1,\(saved),0)")
                try await Task.sleep(for: .milliseconds(120))
                return (view, sink)
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        throw CocoaError(.coderInvalidValue)
    }
}

@MainActor
private final class RegressionMessageSink: NSObject, WKScriptMessageHandler {
    var selection: [String: Any]?
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        if message.name == "readerSelection" { selection = message.body as? [String: Any] }
    }
}

@MainActor
private final class LayoutFixtureState: ObservableObject {
    @Published var locked = false
    @Published var manager = false
}

private struct LayoutFixture: View {
    @ObservedObject var state: LayoutFixtureState
    var body: some View {
        ReaderColumns(leftVisible: true, rightVisible: true, locked: state.locked) {
            LayoutProbe(name: "left")
        } reader: {
            LayoutProbe(name: "reader")
        } right: {
            ZStack {
                LayoutProbe(name: "right")
                if state.manager { Text("人物管理").frame(idealWidth: 500) }
                else { Text("AI 伴读") }
            }
        }
    }
}

private struct LayoutProbe: NSViewRepresentable {
    let name: String
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        view.identifier = NSUserInterfaceItemIdentifier(name)
        return view
    }
    func updateNSView(_ view: NSView, context: Context) {}
}
