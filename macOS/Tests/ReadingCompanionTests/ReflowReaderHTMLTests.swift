import Foundation
import Testing
import WebKit
@testable import ReadingCompanion

@Suite("Reflow reader pagination")
struct ReflowReaderHTMLTests {
    @MainActor
    @Test func embeddedImageLoadsAndFitsInsideTheReadingPage() async throws {
        let png = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII="
        let book = ReflowBook(title: "图片测试", sections: [
            ReflowSection(
                id: "rc-section-image",
                resourcePath: "image.xhtml",
                title: nil,
                html: "<img id=\"fixture-image\" src=\"data:image/png;base64,\(png)\" width=\"2400\" height=\"3600\">",
                startPageIndex: 0
            )
        ])
        let configuration = WKWebViewConfiguration()
        let sink = ScriptMessageSink()
        configuration.userContentController.add(sink, name: "readerNavigation")
        configuration.userContentController.add(sink, name: "readerSelection")
        configuration.userContentController.add(sink, name: "readerMark")
        let webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 820, height: 700), configuration: configuration)
        webView.loadHTMLString(ReflowReaderHTML.make(for: book), baseURL: nil)
        try await waitForLayout(in: webView)

        let metrics = try #require(try await webView.evaluateJavaScript(
            "(()=>{const i=document.getElementById('fixture-image'),r=i.getBoundingClientRect();return {complete:i.complete,naturalWidth:i.naturalWidth,width:r.width,height:r.height,limit:parseFloat(getComputedStyle(document.documentElement).getPropertyValue('--reader-content-height'))};})()"
        ) as? [String: Any])
        #expect(metrics["complete"] as? Bool == true)
        #expect((metrics["naturalWidth"] as? NSNumber)?.intValue == 1)
        #expect((metrics["width"] as? NSNumber)?.doubleValue ?? 0 > 0)
        #expect((metrics["height"] as? NSNumber)?.doubleValue ?? 0 > 0)
        #expect((metrics["height"] as? NSNumber)?.doubleValue ?? .infinity <= ((metrics["limit"] as? NSNumber)?.doubleValue ?? 0) * 0.82 + 1)
    }

    @MainActor
    @Test func readerOriginatedTurnClearsTheOldNavigationTarget() {
        let model = ReaderModel()
        model.currentPageIndex = 4
        model.navigationTarget = 4
        model.didNavigate(to: 5)
        #expect(model.currentPageIndex == 5)
        #expect(model.navigationTarget == nil)
    }

    @MainActor
    @Test func paginatesTurnsForwardAndUsesTextOnlyMarkRects() async throws {
        let paragraph = "林默正在验证动态分页和逐行划线。字号与阅读区发生变化后，林默的名字仍然应当正确高亮。"
        let sectionHTML = (0..<90).map { "<p>\($0) \(paragraph) \(paragraph)</p>" }.joined()
        let book = ReflowBook(title: "分页测试", sections: [
            ReflowSection(
                id: "rc-section-0",
                resourcePath: "chapter.xhtml",
                title: "第一章",
                html: "<h1>第一章</h1>\(sectionHTML)",
                startPageIndex: 0
            )
        ])
        let configuration = WKWebViewConfiguration()
        let sink = ScriptMessageSink()
        configuration.userContentController.add(sink, name: "readerNavigation")
        configuration.userContentController.add(sink, name: "readerSelection")
        configuration.userContentController.add(sink, name: "readerMark")
        let webView = WKWebView(
            frame: CGRect(x: 0, y: 0, width: 820, height: 700),
            configuration: configuration
        )
        webView.loadHTMLString(ReflowReaderHTML.make(for: book), baseURL: nil)
        try await waitForLayout(in: webView)

        let pageCount = try #require(try await webView.evaluateJavaScript(
            "document.querySelectorAll('.reader-page').length"
        ) as? Int)
        #expect(pageCount > 3)
        let mappedRange = try #require(try await webView.evaluateJavaScript(
            "window.readerTextForPageRange(0,document.querySelectorAll('.reader-page').length-1)"
        ) as? [String: Any])
        #expect((mappedRange["pageCount"] as? NSNumber)?.intValue == pageCount)
        let mappedPages = try #require(mappedRange["pages"] as? [String])
        #expect(mappedPages.count == pageCount)
        #expect(mappedPages.first?.contains("第一章") == true)
        #expect(mappedPages.filter { !$0.isEmpty }.count > 3)
        #expect(mappedPages.first != mappedPages.last)

        let initialLeft = try #require(try await webView.evaluateJavaScript(
            "document.querySelector('.reader-page').getBoundingClientRect().left"
        ) as? Double)
        _ = try await webView.evaluateJavaScript(
            "document.getElementById('viewport').dispatchEvent(new WheelEvent('wheel',{deltaY:120,cancelable:true}));"
        )
        try await Task.sleep(for: .milliseconds(220))
        let forwardLeft = try #require(try await webView.evaluateJavaScript(
            "document.querySelector('.reader-page').getBoundingClientRect().left"
        ) as? Double)
        #expect(forwardLeft < initialLeft - 300)

        _ = try await webView.evaluateJavaScript(
            "document.getElementById('viewport').dispatchEvent(new WheelEvent('wheel',{deltaY:-120,cancelable:true}));"
        )
        try await Task.sleep(for: .milliseconds(220))
        let returnedLeft = try #require(try await webView.evaluateJavaScript(
            "document.querySelector('.reader-page').getBoundingClientRect().left"
        ) as? Double)
        #expect(abs(returnedLeft - initialLeft) < 3)

        _ = try await webView.evaluateJavaScript("window.readerTurn(1)")
        try await Task.sleep(for: .milliseconds(220))
        let pageBeforeSearch = try #require(try await webView.evaluateJavaScript(
            "document.querySelector('.reader-page').getBoundingClientRect().left"
        ) as? Double)
        _ = try await webView.evaluateJavaScript("window.readerFind('第一章')")
        try await Task.sleep(for: .milliseconds(80))
        let pageAfterSearch = try #require(try await webView.evaluateJavaScript(
            "document.querySelector('.reader-page').getBoundingClientRect().left"
        ) as? Double)
        #expect(abs(pageAfterSearch - pageBeforeSearch) < 1)

        _ = try await webView.evaluateJavaScript(
            "window.readerGoToSearch('89','rc-section-0',0.99,'89 这是用于验证动态分页和逐行划线的正文',0)"
        )
        try await Task.sleep(for: .milliseconds(100))
        let explicitResultLeft = try #require(try await webView.evaluateJavaScript(
            "document.querySelector('.reader-page').getBoundingClientRect().left"
        ) as? Double)
        #expect(explicitResultLeft < pageBeforeSearch - 300)
        _ = try await webView.evaluateJavaScript("window.readerFind('')")

        _ = try await webView.evaluateJavaScript("window.readerSetSpreadCount(2)")
        try await Task.sleep(for: .milliseconds(250))
        // Layout changes now preserve reading position. This geometry check starts at page one.
        _ = try await webView.evaluateJavaScript("window.readerGoToLocation(0)")
        let visiblePages = try #require(try await webView.evaluateJavaScript(
            "[...document.querySelectorAll('.reader-page')].filter(p=>{const r=p.getBoundingClientRect();return r.left>=0&&r.right<=innerWidth+1}).length"
        ) as? Int)
        #expect(visiblePages == 2)

        _ = try await webView.evaluateJavaScript(
            "window.readerApplyMarks([{id:'stored-mark',sectionID:'rc-section-0',start:100,end:300,kind:'highlight',tint:'黄色'}])"
        )
        let markMetrics = try #require(try await webView.evaluateJavaScript(
            "(()=>{const rs=[...document.querySelectorAll('.mark-rect')].map(x=>x.getBoundingClientRect());return {count:rs.length,maxWidth:Math.max(...rs.map(r=>r.width)),maxHeight:Math.max(...rs.map(r=>r.height))};})()"
        ) as? [String: Any])
        let markCount = (markMetrics["count"] as? NSNumber)?.intValue ?? 0
        let maxWidth = (markMetrics["maxWidth"] as? NSNumber)?.doubleValue ?? 10_000
        let maxHeight = (markMetrics["maxHeight"] as? NSNumber)?.doubleValue ?? 10_000
        #expect(markCount >= 2)
        #expect(maxWidth < 390)
        #expect(maxHeight < 30)
        _ = try await webView.evaluateJavaScript(
            "(()=>{const r=document.querySelector('.mark-yellow').getBoundingClientRect();document.elementFromPoint(r.left+r.width/2,r.top+r.height/2).dispatchEvent(new MouseEvent('click',{bubbles:true,cancelable:true,clientX:r.left+r.width/2,clientY:r.top+r.height/2}));})()"
        )
        for _ in 0..<50 where sink.lastMarkID == nil { try await Task.sleep(for: .milliseconds(10)) }
        #expect(sink.lastMarkID == "stored-mark")

        _ = try await webView.evaluateJavaScript(
            "window.readerApplyCharacters([{id:'person-1',names:['林默','阿默'],color:'rgba(20,120,220,0.34)'}])"
        )
        try await waitForCharacterHighlights(in: webView)
        let characterMetrics = try #require(try await webView.evaluateJavaScript(
            "(()=>{const rs=[...document.querySelectorAll('.mark-character')];const hs=rs.map(x=>x.getBoundingClientRect().height);return {count:Number(document.getElementById('book').dataset.characterRangeCount||0),visibleCount:rs.length,firstCount:Number(document.getElementById('book').dataset.characterFirstCount||0),style:document.getElementById('reader-character-highlight-style').textContent,domSpans:document.querySelectorAll('.character-name').length,color:rs[0]?.style.background||'',minHeight:Math.min(...hs),maxHeight:Math.max(...hs)};})()"
        ) as? [String: Any])
        #expect((characterMetrics["count"] as? NSNumber)?.intValue ?? 0 > 2)
        #expect((characterMetrics["visibleCount"] as? NSNumber)?.intValue ?? 0 > 0)
        #expect((characterMetrics["firstCount"] as? NSNumber)?.intValue == 1)
        #expect((characterMetrics["color"] as? String ?? "").contains("20"))
        #expect((characterMetrics["style"] as? String ?? "").contains("text-shadow"))
        #expect((characterMetrics["domSpans"] as? NSNumber)?.intValue == 0)
        let characterMinHeight = (characterMetrics["minHeight"] as? NSNumber)?.doubleValue ?? 0
        let characterMaxHeight = (characterMetrics["maxHeight"] as? NSNumber)?.doubleValue ?? 1_000
        #expect(characterMaxHeight < 23)
        #expect(characterMaxHeight - characterMinHeight < 1)
        #expect(abs(characterMaxHeight - maxHeight) < 1)
        #expect(!ReflowReaderHTML.make(for: book).contains("selection-tools"))
    }

    @MainActor
    private func waitForLayout(in webView: WKWebView) async throws {
        for _ in 0..<150 {
            if !webView.isLoading,
               let count = try? await webView.evaluateJavaScript(
                   "document.querySelectorAll('.reader-page').length"
               ) as? Int,
               count > 0 {
                try await Task.sleep(for: .milliseconds(180))
                return
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        let detail = (try? await webView.evaluateJavaScript(
            "document.body?.dataset?.readerError || ('ready='+document.readyState+',configure='+typeof window.readerSetSpreadCount)"
        ) as? String) ?? "未知错误"
        Issue.record("WebKit 动态分页没有在预期时间内完成：\(detail)")
    }

    @MainActor
    private func waitForCharacterHighlights(in webView: WKWebView) async throws {
        for _ in 0..<150 {
            if let ready = try? await webView.evaluateJavaScript(
                "document.getElementById('book').dataset.charactersReady === 'true'"
            ) as? Bool, ready {
                return
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        Issue.record("人物高亮没有在预期时间内完成")
    }
}

@MainActor
private final class ScriptMessageSink: NSObject, WKScriptMessageHandler {
    var lastMarkID: String?
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        if message.name == "readerMark" { lastMarkID = (message.body as? [String: Any])?["id"] as? String }
    }
}
