import AppKit
import PDFKit
import Testing
import UniformTypeIdentifiers
@testable import ReadingCompanion

@Suite("PDF drag and drop")
struct PDFDropTests {
    @MainActor
    @Test func acceptsFinderStylePDFFileRepresentation() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ReadingCompanionDrop-\(UUID().uuidString).pdf")
        let image = NSImage(size: NSSize(width: 300, height: 420))
        image.lockFocus()
        NSColor.white.setFill()
        NSRect(origin: .zero, size: image.size).fill()
        image.unlockFocus()
        let document = PDFDocument()
        document.insert(try #require(PDFPage(image: image)), at: 0)
        #expect(document.write(to: url))
        defer { try? FileManager.default.removeItem(at: url) }

        let provider = try #require(NSItemProvider(contentsOf: url))
        let model = ReaderModel()
        #expect(model.acceptDroppedURLs([provider]))
        for _ in 0 ..< 100 where model.pendingImportURL == nil {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(model.documentURL == nil)
        #expect(model.pendingImportURL?.standardizedFileURL == url.standardizedFileURL)
        model.confirmPendingImport(as: .nonfiction)
        for _ in 0 ..< 100 where model.documentURL == nil {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(model.documentURL?.standardizedFileURL == url.standardizedFileURL)
        #expect(model.document?.pageCount == 1)
        #expect(model.bookCategory == .nonfiction)
    }
}
