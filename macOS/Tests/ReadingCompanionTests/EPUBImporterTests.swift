import Foundation
import Testing
import UniformTypeIdentifiers
@testable import ReadingCompanion

@Suite("EPUB importing")
struct EPUBImporterTests {
    @MainActor
    @Test func importsNavigationCreatesReflowSectionsAndSearchIndex() async throws {
        let fixture = try makeEPUBFixture(includeNavigation: true)
        defer {
            EPUBImporter.removeCache(for: fixture)
            try? FileManager.default.removeItem(at: fixture)
        }

        let imported = try await EPUBImporter.importBook(at: fixture)

        #expect(imported.title == "测试书籍")
        #expect(imported.reflowBook.sections.count == 2)
        #expect(imported.reflowBook.sections[0].html.contains("流式排版测试文字"))
        #expect(imported.reflowBook.sections[1].html.contains("第二章正文"))
        #expect(imported.reflowBook.sections[0].startPageIndex < imported.reflowBook.sections[1].startPageIndex)
        #expect(imported.document.pageCount >= 2)
        #expect(imported.coverPNGData?.isEmpty == false)
        #expect(abs(EPUBImporter.pageSize.width - 419.527559) < 0.001)
        #expect(abs(EPUBImporter.pageSize.height - 595.275591) < 0.001)
        for pageIndex in 0..<imported.document.pageCount {
            let bounds = imported.document.page(at: pageIndex)?.bounds(for: .mediaBox)
            #expect(abs((bounds?.width ?? 0) - EPUBImporter.pageSize.width) < 0.001)
            #expect(abs((bounds?.height ?? 0) - EPUBImporter.pageSize.height) < 0.001)
        }
        #expect(imported.outline.map(\.title) == ["第一章", "第二章"])
        #expect(imported.outline[0].pageIndex < imported.outline[1].pageIndex)
        let allText = (0..<imported.document.pageCount)
            .compactMap { imported.document.page(at: $0)?.string }
            .joined(separator: "\n")
        #expect(allText.contains("流式排版测试文字"))
        #expect(allText.contains("第二章正文"))

        let nativeMatches = imported.document.findString(
            "第二章正文",
            withOptions: [.caseInsensitive, .diacriticInsensitive]
        )
        let paintedMatches = PDFSearchHighlighter.selections(
            for: "第二章正文",
            in: imported.document
        )
        #expect(paintedMatches.count == nativeMatches.count)
        #expect(zip(paintedMatches, nativeMatches).allSatisfy { painted, native in
            guard let paintedPage = painted.pages.first, let nativePage = native.pages.first else { return false }
            return imported.document.index(for: paintedPage) == imported.document.index(for: nativePage)
                && painted.bounds(for: paintedPage).equalTo(native.bounds(for: nativePage))
        })

        let cached = try await EPUBImporter.importBook(at: fixture)
        #expect(cached.outline.map(\.title) == ["第一章", "第二章"])
        #expect(cached.document.pageCount == imported.document.pageCount)
        #expect(cached.reflowBook == imported.reflowBook)
        #expect(cached.coverPNGData == imported.coverPNGData)
    }

    @MainActor
    @Test func reportsVisibleImportStagesBeforeIndexing() async throws {
        let fixture = try makeEPUBFixture(includeNavigation: true)
        defer {
            EPUBImporter.removeCache(for: fixture)
            try? FileManager.default.removeItem(at: fixture)
        }
        var updates: [(Double, String)] = []
        _ = try await EPUBImporter.importBook(at: fixture) { value, message in
            updates.append((value, message))
        }
        #expect(updates.count >= 5)
        #expect(updates.first?.0 == 0.05)
        #expect(updates.last?.0 == 0.98)
        #expect(updates.contains { $0.1.contains("排版正文") })
        #expect(zip(updates, updates.dropFirst()).allSatisfy { pair in pair.0.0 <= pair.1.0 })
    }

    @MainActor
    @Test func anEPUBWithoutNavigationUsesTheExistingManualOutlineFlow() async throws {
        let fixture = try makeEPUBFixture(includeNavigation: false)
        defer {
            EPUBImporter.removeCache(for: fixture)
            try? FileManager.default.removeItem(at: fixture)
        }

        let imported = try await EPUBImporter.importBook(at: fixture)
        #expect(imported.outline.isEmpty)

        let model = ReaderModel()
        model.open(fixture)
        for _ in 0..<300 where model.document == nil {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(model.document != nil)
        model.applyManualOutline([
            OutlineEntry(title: "手动第一章", pageIndex: 0, level: 0, generated: true)
        ])
        #expect(model.outline.map(\.title) == ["手动第一章"])
        #expect(model.outlineWasManuallyEdited)
    }

    @MainActor
    @Test func acceptsFinderStyleEPUBDragAndDrop() async throws {
        let fixture = try makeEPUBFixture(includeNavigation: true)
        defer {
            EPUBImporter.removeCache(for: fixture)
            try? FileManager.default.removeItem(at: fixture)
        }

        let provider = try #require(NSItemProvider(contentsOf: fixture))
        let model = ReaderModel()
        #expect(model.acceptDroppedURLs([provider]))
        for _ in 0..<100 where model.pendingImportURL == nil {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(model.document == nil)
        model.confirmPendingImport(as: .fiction)
        for _ in 0..<300 where model.document == nil {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(model.documentURL?.standardizedFileURL == fixture.standardizedFileURL)
        #expect(model.documentKind == .epub)
        #expect(model.bookCategory == .fiction)
        #expect(model.aiCompanionMode == .free)
        #expect(model.reflowBook?.sections.count == 2)
        #expect(model.outline.map(\.title) == ["第一章", "第二章"])
        let bounds = model.document?.page(at: 0)?.bounds(for: .mediaBox)
        #expect(abs((bounds?.width ?? 0) - EPUBImporter.pageSize.width) < 0.001)
        #expect(abs((bounds?.height ?? 0) - EPUBImporter.pageSize.height) < 0.001)
    }

    @MainActor
    @Test func mobiAndAZW3UseTheSameReflowPipeline() async throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let mobi = root.appendingPathComponent("Vendor/libmobi-0.12/tests/samples/sample-ncx.mobi")
        let azw3 = FileManager.default.temporaryDirectory
            .appendingPathComponent("ReadingCompanion-\(UUID().uuidString).azw3")
        try FileManager.default.copyItem(at: mobi, to: azw3)
        defer {
            EPUBImporter.removeCache(for: mobi)
            EPUBImporter.removeCache(for: azw3)
            try? FileManager.default.removeItem(at: azw3)
        }

        let mobiBook = try await KindleBookImporter.importBook(at: mobi)
        let azw3Book = try await KindleBookImporter.importBook(at: azw3)
        #expect(!mobiBook.reflowBook.sections.isEmpty)
        #expect(!azw3Book.reflowBook.sections.isEmpty)
        #expect(mobiBook.document.pageCount > 0)
        #expect(azw3Book.document.pageCount > 0)
    }

    @Test func embedsParentDirectoryImagesCaseInsensitivelyIncludingSVGReferences() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ReadingCompanionImageFixture-\(UUID().uuidString)", isDirectory: true)
        let textDirectory = root.appendingPathComponent("OEBPS/Text", isDirectory: true)
        let imageDirectory = root.appendingPathComponent("OEBPS/Images", isDirectory: true)
        try FileManager.default.createDirectory(at: textDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: imageDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let image = imageDirectory.appendingPathComponent("Plate One.png")
        try Data([0x89, 0x50, 0x4E, 0x47]).write(to: image)
        let chapter = textDirectory.appendingPathComponent("chapter.xhtml")
        try Data(#"<html><body><img src="../images/Plate%20One.PNG?edition=1#figure"/><svg><image xlink:href="../Images/Plate%20One.png"/></svg></body></html>"#.utf8).write(to: chapter)
        let publication = EPUBPublication(
            title: "图片书",
            extractionDirectory: root,
            sections: [EPUBSection(relativePath: "Text/chapter.xhtml", fileURL: chapter)],
            navigation: [],
            coverImageData: nil
        )
        let html = try #require(ReflowBookBuilder.build(publication: publication, sectionStartPages: [:]).sections.first?.html)
        #expect(html.components(separatedBy: "data:image/png;base64,").count - 1 == 2)
        #expect(!html.localizedCaseInsensitiveContains("../images"))
    }

    private func makeEPUBFixture(includeNavigation: Bool) throws -> URL {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("ReadingCompanionEPUBFixture-\(UUID().uuidString)", isDirectory: true)
        let meta = root.appendingPathComponent("META-INF", isDirectory: true)
        let book = root.appendingPathComponent("OEBPS", isDirectory: true)
        try fileManager.createDirectory(at: meta, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: book, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: root) }

        try Data("application/epub+zip".utf8).write(to: root.appendingPathComponent("mimetype"))
        try Data("""
        <?xml version="1.0"?>
        <container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
          <rootfiles><rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/></rootfiles>
        </container>
        """.utf8).write(to: meta.appendingPathComponent("container.xml"))

        let navItem = includeNavigation
            ? #"<item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/>"#
            : ""
        try Data("""
        <?xml version="1.0" encoding="UTF-8"?>
        <package xmlns="http://www.idpf.org/2007/opf" version="3.0">
          <metadata xmlns:dc="http://purl.org/dc/elements/1.1/"><dc:title>测试书籍</dc:title></metadata>
          <manifest>
            \(navItem)
            <item id="c1" href="chapter1.xhtml" media-type="application/xhtml+xml"/>
            <item id="c2" href="chapter2.xhtml" media-type="application/xhtml+xml"/>
          </manifest>
          <spine><itemref idref="c1"/><itemref idref="c2"/></spine>
        </package>
        """.utf8).write(to: book.appendingPathComponent("content.opf"))
        try Data("""
        <html xmlns="http://www.w3.org/1999/xhtml"><body>
          <h1>第一章</h1><p>流式排版测试文字。这里是一段适合阅读的正文。</p>
        </body></html>
        """.utf8).write(to: book.appendingPathComponent("chapter1.xhtml"))
        try Data("""
        <html xmlns="http://www.w3.org/1999/xhtml"><body>
          <h1>第二章</h1><p>第二章正文。窗口宽度变化时这些文字应当实时重新换行。</p>
        </body></html>
        """.utf8).write(to: book.appendingPathComponent("chapter2.xhtml"))
        if includeNavigation {
            try Data("""
            <html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops"><body>
              <nav epub:type="toc"><ol>
                <li><a href="chapter1.xhtml">第一章</a></li>
                <li><a href="chapter2.xhtml">第二章</a></li>
              </ol></nav>
            </body></html>
            """.utf8).write(to: book.appendingPathComponent("nav.xhtml"))
        }

        let target = fileManager.temporaryDirectory
            .appendingPathComponent("ReadingCompanion-\(UUID().uuidString).epub")
        let zip = Process()
        zip.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        zip.currentDirectoryURL = root
        zip.arguments = ["-X", "-q", "-r", target.path, "mimetype", "META-INF", "OEBPS"]
        try zip.run()
        zip.waitUntilExit()
        guard zip.terminationStatus == 0 else { throw EPUBImportError.extractionFailed("测试 EPUB 创建失败") }
        return target
    }
}
