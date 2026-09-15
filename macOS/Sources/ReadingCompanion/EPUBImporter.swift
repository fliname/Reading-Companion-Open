import AppKit
import CryptoKit
import Foundation
import PDFKit

struct EPUBImportResult {
    let document: PDFDocument
    let title: String
    let outline: [OutlineEntry]
    let reflowBook: ReflowBook
    let coverPNGData: Data?
}

typealias BookImportProgressHandler = @MainActor (Double, String) -> Void

enum EPUBImportError: LocalizedError {
    case extractionFailed(String)
    case invalidContainer
    case missingPackage
    case emptyBook
    case renderingFailed

    var errorDescription: String? {
        switch self {
        case .extractionFailed(let detail):
            "无法解包 EPUB：\(detail)"
        case .invalidContainer:
            "这份 EPUB 的容器信息不完整或已经损坏。"
        case .missingPackage:
            "这份 EPUB 缺少书籍清单（OPF）。"
        case .emptyBook:
            "这份 EPUB 中没有可阅读的正文。"
        case .renderingFailed:
            "EPUB 正文无法生成可重排阅读内容。"
        }
    }
}

/// Imports EPUB semantics for the reflow reader and builds a hidden searchable
/// PDFDocument used by the existing index, outline and AI context pipeline.
@MainActor
enum EPUBImporter {
    // Bump whenever cached reflow HTML changes. Version 6 invalidates books
    // cached before local images were embedded and height-constrained.
    static let rendererVersion = 6
    /// ISO 216 A5: 148 × 210 mm, converted at 72 PostScript points per inch.
    static let pageSize = NSSize(width: 419.527559, height: 595.275591)
    static let pageMargins = NSEdgeInsets(top: 42, left: 46, bottom: 50, right: 40)

    static func importBook(
        at sourceURL: URL,
        cacheIdentityURL: URL? = nil,
        progress: BookImportProgressHandler? = nil
    ) async throws -> EPUBImportResult {
        let cacheSourceURL = cacheIdentityURL ?? sourceURL
        progress?(0.05, "正在检查电子书缓存…")
        if let cached = cachedBook(for: cacheSourceURL) {
            progress?(0.98, "正在恢复电子书排版与目录…")
            return cached
        }

        progress?(0.12, "正在解包并读取电子书…")
        let publication = try await Task.detached(priority: .userInitiated) {
            try EPUBArchiveReader.read(sourceURL)
        }.value
        defer { try? FileManager.default.removeItem(at: publication.extractionDirectory) }

        try Task.checkCancellation()
        progress?(0.36, "目录与正文已读取，正在生成阅读排版…")
        let rendered = try await render(publication, progress: progress)
        progress?(0.94, "正在保存电子书排版缓存…")
        try? saveCache(rendered, for: cacheSourceURL)
        progress?(0.98, "电子书导入完成，正在建立全文索引…")
        return rendered
    }

    static func removeCache(for sourceURL: URL) {
        let files = cacheFiles(for: sourceURL)
        for file in [files.pdf, files.metadata] where FileManager.default.fileExists(atPath: file.path) {
            try? FileManager.default.removeItem(at: file)
        }
    }

    static func coverPNGData(at sourceURL: URL, title: String) async -> Data? {
        do {
            let publication = try await Task.detached(priority: .utility) {
                try EPUBArchiveReader.read(sourceURL)
            }.value
            defer { try? FileManager.default.removeItem(at: publication.extractionDirectory) }
            return BookCoverRenderer.pngData(imageData: publication.coverImageData, title: publication.title)
        } catch {
            return BookCoverRenderer.pngData(imageData: nil, title: title)
        }
    }

    private static func render(
        _ publication: EPUBPublication,
        progress: BookImportProgressHandler?
    ) async throws -> EPUBImportResult {
        let document = PDFDocument()
        var sectionStartPages: [String: Int] = [:]
        var sectionPageRanges: [String: Range<Int>] = [:]
        var pageNumber = 1

        for (offset, section) in publication.sections.enumerated() {
            try Task.checkCancellation()
            let canonicalPath = canonicalResourcePath(section.relativePath)
            let sectionStart = document.pageCount
            sectionStartPages[canonicalPath] = sectionStart
            guard let attributed = attributedText(for: section) else { continue }
            let pages = renderSection(attributed, startingAt: pageNumber)
            for page in pages { document.insert(page, at: document.pageCount) }
            sectionPageRanges[canonicalPath] = sectionStart..<document.pageCount
            pageNumber += pages.count
            let completed = offset + 1
            let fraction = 0.40 + 0.42 * Double(completed) / Double(max(publication.sections.count, 1))
            progress?(fraction, "正在排版正文 · \(completed) / \(publication.sections.count)")
            await Task.yield()
        }

        guard document.pageCount > 0 else { throw EPUBImportError.emptyBook }
        document.documentAttributes = [PDFDocumentAttribute.titleAttribute: publication.title]

        var lastMatchedPageBySection: [String: Int] = [:]
        let outline = publication.navigation.compactMap { item -> OutlineEntry? in
            let target = canonicalResourcePath(item.relativePath)
            guard let pageIndex = sectionStartPages[target] else { return nil }
            let title = item.title.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty else { return nil }
            let matchedPage = findTitlePage(
                title,
                in: sectionPageRanges[target] ?? pageIndex..<(pageIndex + 1),
                document: document,
                startingAt: lastMatchedPageBySection[target] ?? pageIndex
            ) ?? pageIndex
            lastMatchedPageBySection[target] = matchedPage
            return OutlineEntry(
                title: title,
                pageIndex: matchedPage,
                level: min(max(item.level, 0), 5),
                generated: false
            )
        }
        progress?(0.87, "正在生成目录与可搜索文字层…")
        installPDFOutline(outline, in: document)
        let reflowBook = ReflowBookBuilder.build(
            publication: publication,
            sectionStartPages: sectionStartPages
        )
        guard !reflowBook.sections.isEmpty else { throw EPUBImportError.emptyBook }
        return EPUBImportResult(
            document: document,
            title: publication.title,
            outline: outline,
            reflowBook: reflowBook,
            coverPNGData: BookCoverRenderer.pngData(
                imageData: publication.coverImageData,
                title: publication.title
            )
        )
    }

    private static func findTitlePage(
        _ title: String,
        in pageRange: Range<Int>,
        document: PDFDocument,
        startingAt: Int
    ) -> Int? {
        let needle = foldedForMatching(title)
        guard !needle.isEmpty else { return nil }
        let ordered = Array(max(pageRange.lowerBound, startingAt)..<pageRange.upperBound)
            + Array(pageRange.lowerBound..<min(max(startingAt, pageRange.lowerBound), pageRange.upperBound))
        return ordered.first { index in
            guard let text = document.page(at: index)?.string else { return false }
            return foldedForMatching(text).contains(needle)
        }
    }

    private static func foldedForMatching(_ value: String) -> String {
        value.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: .current)
            .unicodeScalars
            .filter { CharacterSet.alphanumerics.contains($0) }
            .map(String.init)
            .joined()
    }

    private static func attributedText(for section: EPUBSection) -> NSAttributedString? {
        guard let source = try? Data(contentsOf: section.fileURL), !source.isEmpty else { return nil }
        let prefix = String(data: source.prefix(256), encoding: .ascii)?.lowercased() ?? ""
        let declaredEncoding = (source.starts(with: [0xFF, 0xFE]) || source.starts(with: [0xFE, 0xFF])
            || prefix.contains("utf-16"))
            ? String.Encoding.utf16.rawValue
            : String.Encoding.utf8.rawValue
        let options: [NSAttributedString.DocumentReadingOptionKey: Any] = [
            .documentType: NSAttributedString.DocumentType.html,
            .characterEncoding: declaredEncoding,
            .baseURL: section.fileURL.deletingLastPathComponent()
        ]
        let imported: NSMutableAttributedString
        if let richText = try? NSMutableAttributedString(
            data: source,
            options: options,
            documentAttributes: nil
        ) {
            imported = richText
        } else {
            let decoded = String(decoding: source, as: UTF8.self)
            let plain = decoded
                .replacingOccurrences(of: #"(?is)<br\s*/?>|</p\s*>|</div\s*>|</h[1-6]\s*>"#, with: "\n", options: .regularExpression)
                .replacingOccurrences(of: #"(?is)<[^>]+>"#, with: "", options: .regularExpression)
                .replacingOccurrences(of: "&nbsp;", with: " ")
                .replacingOccurrences(of: "&amp;", with: "&")
                .replacingOccurrences(of: "&lt;", with: "<")
                .replacingOccurrences(of: "&gt;", with: ">")
            guard !plain.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            imported = NSMutableAttributedString(string: plain)
        }

        normalizeTypography(in: imported)
        return imported
    }

    private static func normalizeTypography(in text: NSMutableAttributedString) {
        let whole = NSRange(location: 0, length: text.length)
        guard whole.length > 0 else { return }
        let baseSize: CGFloat = 12.5
        let fallbackFont = NSFont(name: "Songti SC", size: baseSize)
            ?? NSFont.systemFont(ofSize: baseSize)

        text.enumerateAttribute(.font, in: whole) { value, range, _ in
            let original = value as? NSFont
            let oldSize = original?.pointSize ?? baseSize
            let ratio = min(max(oldSize / 12, 0.9), 1.9)
            let newSize = baseSize * ratio
            var descriptor = fallbackFont.fontDescriptor
            if let original {
                let traits = original.fontDescriptor.symbolicTraits
                if traits.contains(.bold) { descriptor = descriptor.withSymbolicTraits(.bold) }
                if traits.contains(.italic) { descriptor = descriptor.withSymbolicTraits(.italic) }
            }
            text.addAttribute(.font, value: NSFont(descriptor: descriptor, size: newSize) ?? fallbackFont, range: range)
        }

        text.enumerateAttribute(.paragraphStyle, in: whole) { value, range, _ in
            let style = ((value as? NSParagraphStyle)?.mutableCopy() as? NSMutableParagraphStyle)
                ?? NSMutableParagraphStyle()
            style.minimumLineHeight = 0
            style.maximumLineHeight = 0
            style.lineHeightMultiple = max(style.lineHeightMultiple, 1.35)
            style.lineSpacing = max(style.lineSpacing, 1.5)
            style.paragraphSpacing = max(style.paragraphSpacing, 6)
            style.hyphenationFactor = 0
            text.addAttribute(.paragraphStyle, value: style, range: range)
        }
        text.addAttributes([
            .foregroundColor: NSColor(calibratedWhite: 0.10, alpha: 1),
            .backgroundColor: NSColor.clear
        ], range: whole)

        text.enumerateAttribute(.attachment, in: whole) { value, range, _ in
            guard let attachment = value as? NSTextAttachment else { return }
            var bounds = attachment.bounds
            guard bounds.width > 0, bounds.height > 0 else { return }
            let contentWidth = pageSize.width - pageMargins.left - pageMargins.right
            let contentHeight = pageSize.height - pageMargins.top - pageMargins.bottom
            let scale = min(1, contentWidth / bounds.width, contentHeight * 0.72 / bounds.height)
            bounds.size = NSSize(width: bounds.width * scale, height: bounds.height * scale)
            attachment.bounds = bounds
            text.addAttribute(.attachment, value: attachment, range: range)
        }
    }

    private static func renderSection(_ attributed: NSAttributedString, startingAt firstPageNumber: Int) -> [PDFPage] {
        guard attributed.length > 0 else { return [] }
        let storage = NSTextStorage(attributedString: attributed)
        let layoutManager = NSLayoutManager()
        layoutManager.usesFontLeading = true
        storage.addLayoutManager(layoutManager)

        let contentSize = NSSize(
            width: pageSize.width - pageMargins.left - pageMargins.right,
            height: pageSize.height - pageMargins.top - pageMargins.bottom
        )
        var containers: [NSTextContainer] = []
        var coveredGlyphs = 0
        while coveredGlyphs < layoutManager.numberOfGlyphs {
            let container = NSTextContainer(containerSize: contentSize)
            container.lineFragmentPadding = 0
            container.widthTracksTextView = true
            container.heightTracksTextView = true
            layoutManager.addTextContainer(container)
            layoutManager.ensureLayout(for: container)
            let range = layoutManager.glyphRange(for: container)
            guard range.length > 0 else { break }
            containers.append(container)
            coveredGlyphs = NSMaxRange(range)
        }

        return containers.enumerated().compactMap { offset, container in
            let pageView = EPUBBookPageView(
                frame: NSRect(origin: .zero, size: pageSize),
                pageNumber: firstPageNumber + offset
            )
            let textFrame = NSRect(
                x: pageMargins.left,
                y: pageMargins.bottom,
                width: contentSize.width,
                height: contentSize.height
            )
            let textView = NSTextView(frame: textFrame, textContainer: container)
            textView.drawsBackground = false
            textView.isEditable = false
            textView.isSelectable = true
            textView.textContainerInset = .zero
            textView.isHorizontallyResizable = false
            textView.isVerticallyResizable = false
            pageView.addSubview(textView)
            let data = pageView.dataWithPDF(inside: pageView.bounds)
            return PDFDocument(data: data)?.page(at: 0)
        }
    }

    private static func installPDFOutline(_ entries: [OutlineEntry], in document: PDFDocument) {
        guard !entries.isEmpty else { return }
        let root = PDFOutline()
        var parents: [Int: PDFOutline] = [-1: root]
        for entry in entries {
            guard let page = document.page(at: entry.pageIndex) else { continue }
            let node = PDFOutline()
            node.label = entry.title
            node.destination = PDFDestination(page: page, at: NSPoint(x: 0, y: page.bounds(for: .cropBox).maxY))
            let level = max(entry.level, 0)
            let parent = stride(from: level - 1, through: -1, by: -1)
                .compactMap { parents[$0] }
                .first ?? root
            parent.insertChild(node, at: parent.numberOfChildren)
            parents[level] = node
            for key in parents.keys where key > level { parents[key] = nil }
        }
        document.outlineRoot = root
    }

    private static func canonicalResourcePath(_ value: String) -> String {
        let path = value.components(separatedBy: "#").first ?? value
        return path.removingPercentEncoding ?? path
    }

    private struct CacheMetadata: Codable {
        let rendererVersion: Int
        let sourceFingerprint: String
        let title: String
        let outline: [OutlineEntry]?
        let reflowBook: ReflowBook?
        let coverPNGData: Data?
    }

    static func cachedBook(for sourceURL: URL) -> EPUBImportResult? {
        let files = cacheFiles(for: sourceURL)
        guard let data = try? Data(contentsOf: files.metadata),
              let metadata = try? JSONDecoder().decode(CacheMetadata.self, from: data),
              metadata.rendererVersion == rendererVersion,
              metadata.sourceFingerprint == sourceFingerprint(sourceURL),
              let reflowBook = metadata.reflowBook,
              let document = PDFDocument(url: files.pdf),
              document.pageCount > 0 else { return nil }
        return EPUBImportResult(
            document: document,
            title: metadata.title,
            outline: metadata.outline ?? OutlineBuilder.entries(for: document),
            reflowBook: reflowBook,
            coverPNGData: metadata.coverPNGData
        )
    }

    private static func saveCache(_ result: EPUBImportResult, for sourceURL: URL) throws {
        let files = cacheFiles(for: sourceURL)
        try FileManager.default.createDirectory(
            at: files.pdf.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        guard result.document.write(to: files.pdf) else { throw EPUBImportError.renderingFailed }
        let metadata = CacheMetadata(
            rendererVersion: rendererVersion,
            sourceFingerprint: sourceFingerprint(sourceURL),
            title: result.title,
            outline: result.outline,
            reflowBook: result.reflowBook,
            coverPNGData: result.coverPNGData
        )
        try JSONEncoder().encode(metadata).write(to: files.metadata, options: .atomic)
    }

    private static func cacheFiles(for sourceURL: URL) -> (pdf: URL, metadata: URL) {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("ReadingCompanionOpen/EPUBCache", isDirectory: true)
        let digest = SHA256.hash(data: Data(sourceURL.standardizedFileURL.path.utf8))
            .map { String(format: "%02x", $0) }.joined()
        return (
            base.appendingPathComponent(digest).appendingPathExtension("pdf"),
            base.appendingPathComponent(digest).appendingPathExtension("json")
        )
    }

    private static func sourceFingerprint(_ url: URL) -> String {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        let size = (attributes?[.size] as? NSNumber)?.int64Value ?? -1
        let modified = (attributes?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        return "\(size)|\(Int64(modified * 1_000))"
    }
}

private final class EPUBBookPageView: NSView {
    let pageNumber: Int

    init(frame frameRect: NSRect, pageNumber: Int) {
        self.pageNumber = pageNumber
        super.init(frame: frameRect)
    }

    required init?(coder: NSCoder) { nil }

    override var isFlipped: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.white.setFill()
        bounds.fill()
        let number = NSAttributedString(
            string: "\(pageNumber)",
            attributes: [
                .font: NSFont.systemFont(ofSize: 8.5),
                .foregroundColor: NSColor.secondaryLabelColor
            ]
        )
        let size = number.size()
        number.draw(at: NSPoint(x: (bounds.width - size.width) / 2, y: 24))
    }
}

struct EPUBPublication: Sendable {
    let title: String
    let extractionDirectory: URL
    let sections: [EPUBSection]
    let navigation: [EPUBNavigationItem]
    let coverImageData: Data?
}

struct EPUBSection: Sendable {
    let relativePath: String
    let fileURL: URL
}

struct EPUBNavigationItem: Sendable {
    let title: String
    let relativePath: String
    let level: Int
}

enum EPUBArchiveReader {
    static func read(_ sourceURL: URL) throws -> EPUBPublication {
        let extractionDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ReadingCompanion-EPUB-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: extractionDirectory, withIntermediateDirectories: true)
        do {
            try extract(sourceURL, to: extractionDirectory)
            let containerURL = extractionDirectory.appendingPathComponent("META-INF/container.xml")
            guard let containerData = try? Data(contentsOf: containerURL),
                  let rootPath = EPUBContainerParser.parse(containerData) else {
                throw EPUBImportError.invalidContainer
            }
            let packageURL = safeURL(relativePath: rootPath, under: extractionDirectory)
            guard let packageData = try? Data(contentsOf: packageURL) else {
                throw EPUBImportError.missingPackage
            }
            let package = EPUBPackageParser.parse(packageData)
            let packageDirectory = packageURL.deletingLastPathComponent()
            let sections = package.spine.compactMap { id -> EPUBSection? in
                guard let item = package.manifest[id], item.mediaType.contains("html") else { return nil }
                let url = safeURL(relativePath: item.href, under: packageDirectory)
                guard FileManager.default.fileExists(atPath: url.path) else { return nil }
                return EPUBSection(relativePath: canonical(item.href), fileURL: url)
            }
            guard !sections.isEmpty else { throw EPUBImportError.emptyBook }

            var navigation: [EPUBNavigationItem] = []
            if let nav = package.manifest.values.first(where: {
                $0.properties.split(whereSeparator: \Character.isWhitespace).contains("nav")
            }) {
                let navURL = safeURL(relativePath: nav.href, under: packageDirectory)
                if let data = try? Data(contentsOf: navURL) {
                    navigation = EPUBNavigationParser.parse(data).map {
                        EPUBNavigationItem(
                            title: $0.title,
                            relativePath: resolve($0.relativePath, relativeTo: nav.href),
                            level: $0.level
                        )
                    }
                }
            }
            if navigation.isEmpty,
               let tocID = package.tocID,
               let ncx = package.manifest[tocID] {
                let ncxURL = safeURL(relativePath: ncx.href, under: packageDirectory)
                if let data = try? Data(contentsOf: ncxURL) {
                    navigation = EPUBNCXParser.parse(data).map {
                        EPUBNavigationItem(
                            title: $0.title,
                            relativePath: resolve($0.relativePath, relativeTo: ncx.href),
                            level: $0.level
                        )
                    }
                }
            }
            let fallbackTitle = sourceURL.deletingPathExtension().lastPathComponent
            let coverItem = package.manifest.values.first(where: {
                $0.properties.split(whereSeparator: \Character.isWhitespace).contains("cover-image")
            }) ?? package.coverID.flatMap { package.manifest[$0] }
                ?? package.manifest.first(where: { id, item in
                    item.mediaType.hasPrefix("image/")
                        && (id.lowercased().contains("cover") || item.href.lowercased().contains("cover"))
                })?.value
            let coverImageData = coverItem.flatMap {
                try? Data(contentsOf: safeURL(relativePath: $0.href, under: packageDirectory))
            }
            return EPUBPublication(
                title: package.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    ? fallbackTitle : package.title,
                extractionDirectory: extractionDirectory,
                sections: sections,
                navigation: navigation,
                coverImageData: coverImageData
            )
        } catch {
            try? FileManager.default.removeItem(at: extractionDirectory)
            throw error
        }
    }

    private static func extract(_ sourceURL: URL, to directory: URL) throws {
        try validateArchivePaths(sourceURL)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-x", "-k", sourceURL.path, directory.path]
        let errorPipe = Pipe()
        process.standardError = errorPipe
        do {
            try process.run()
        } catch {
            throw EPUBImportError.extractionFailed(error.localizedDescription)
        }
        let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let detail = String(data: errorData, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            throw EPUBImportError.extractionFailed(detail?.isEmpty == false ? detail! : "文件不是有效的 EPUB 压缩包")
        }
        try validateExtractedFiles(in: directory)
    }

    private static func validateArchivePaths(_ sourceURL: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        process.arguments = ["-Z1", sourceURL.path]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = Pipe()
        do {
            try process.run()
        } catch {
            throw EPUBImportError.extractionFailed(error.localizedDescription)
        }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw EPUBImportError.extractionFailed("文件不是有效的 EPUB 压缩包")
        }
        let listing = String(data: data, encoding: .utf8) ?? ""
        for entry in listing.components(separatedBy: .newlines) where !entry.isEmpty {
            let components = entry.replacingOccurrences(of: "\\", with: "/").split(separator: "/")
            if entry.hasPrefix("/") || entry.contains("\\") || components.contains("..") {
                throw EPUBImportError.extractionFailed("压缩包包含不安全的文件路径")
            }
        }
    }

    private static func validateExtractedFiles(in directory: URL) throws {
        guard let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isSymbolicLinkKey, .fileSizeKey],
            options: []
        ) else { return }
        var totalSize: Int64 = 0
        for case let fileURL as URL in enumerator {
            let values = try fileURL.resourceValues(forKeys: [.isSymbolicLinkKey, .fileSizeKey])
            if values.isSymbolicLink == true {
                throw EPUBImportError.extractionFailed("压缩包包含不安全的符号链接")
            }
            totalSize += Int64(values.fileSize ?? 0)
            if totalSize > 1_073_741_824 {
                throw EPUBImportError.extractionFailed("解包后的 EPUB 超过 1 GB，已停止导入")
            }
        }
    }

    private static func safeURL(relativePath: String, under root: URL) -> URL {
        let clean = canonical(relativePath)
        let target = root.appendingPathComponent(clean).standardizedFileURL
        let rootPath = root.standardizedFileURL.path + "/"
        return target.path.hasPrefix(rootPath) ? target : root.appendingPathComponent("__invalid_epub_path__")
    }

    private static func resolve(_ href: String, relativeTo documentPath: String) -> String {
        let decoded = href.removingPercentEncoding ?? href
        let base = URL(fileURLWithPath: "/" + documentPath).deletingLastPathComponent()
        return base.appendingPathComponent(decoded.components(separatedBy: "#").first ?? decoded)
            .standardizedFileURL.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    private static func canonical(_ href: String) -> String {
        let path = href.components(separatedBy: "#").first ?? href
        return path.removingPercentEncoding ?? path
    }
}

private struct EPUBManifestItem: Sendable {
    let href: String
    let mediaType: String
    let properties: String
}

private struct EPUBPackage: Sendable {
    var title = ""
    var manifest: [String: EPUBManifestItem] = [:]
    var spine: [String] = []
    var tocID: String?
    var coverID: String?
}

private final class EPUBContainerParser: NSObject, XMLParserDelegate {
    private var rootPath: String?

    static func parse(_ data: Data) -> String? {
        let delegate = EPUBContainerParser()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        parser.parse()
        return delegate.rootPath
    }

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        if elementName.lowercased().hasSuffix("rootfile") {
            rootPath = attributeDict["full-path"]
        }
    }
}

private final class EPUBPackageParser: NSObject, XMLParserDelegate {
    private var package = EPUBPackage()
    private var capturesTitle = false

    static func parse(_ data: Data) -> EPUBPackage {
        let delegate = EPUBPackageParser()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        parser.parse()
        return delegate.package
    }

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes: [String: String] = [:]
    ) {
        let name = elementName.lowercased().components(separatedBy: ":").last ?? elementName
        switch name {
        case "title": capturesTitle = true
        case "meta":
            if attributes["name"]?.lowercased() == "cover" {
                package.coverID = attributes["content"]
            }
        case "item":
            guard let id = attributes["id"], let href = attributes["href"] else { return }
            package.manifest[id] = EPUBManifestItem(
                href: href,
                mediaType: attributes["media-type"] ?? "",
                properties: attributes["properties"] ?? ""
            )
        case "spine": package.tocID = attributes["toc"]
        case "itemref":
            if let idref = attributes["idref"], attributes["linear"]?.lowercased() != "no" {
                package.spine.append(idref)
            }
        default: break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if capturesTitle { package.title += string }
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        let name = elementName.lowercased().components(separatedBy: ":").last ?? elementName
        if name == "title" { capturesTitle = false }
    }
}

private final class EPUBNavigationParser: NSObject, XMLParserDelegate {
    private var items: [EPUBNavigationItem] = []
    private var insideTOC = false
    private var navDepth = 0
    private var listDepth = 0
    private var activeHref: String?
    private var activeTitle = ""

    static func parse(_ data: Data) -> [EPUBNavigationItem] {
        let delegate = EPUBNavigationParser()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        parser.parse()
        return delegate.items
    }

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes: [String: String] = [:]
    ) {
        let name = elementName.lowercased().components(separatedBy: ":").last ?? elementName
        if name == "nav" {
            let kind = attributes.first { key, _ in key.lowercased().hasSuffix("type") }?.value.lowercased() ?? ""
            if kind.contains("toc") { insideTOC = true; navDepth = 1 }
            else if insideTOC { navDepth += 1 }
            return
        }
        guard insideTOC else { return }
        if name == "ol" || name == "ul" { listDepth += 1 }
        if name == "a", let href = attributes["href"] {
            activeHref = href
            activeTitle = ""
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if activeHref != nil { activeTitle += string }
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        let name = elementName.lowercased().components(separatedBy: ":").last ?? elementName
        if name == "a", let href = activeHref {
            items.append(EPUBNavigationItem(
                title: activeTitle.trimmingCharacters(in: .whitespacesAndNewlines),
                relativePath: href,
                level: max(listDepth - 1, 0)
            ))
            activeHref = nil
            activeTitle = ""
        }
        guard insideTOC else { return }
        if name == "ol" || name == "ul" { listDepth = max(listDepth - 1, 0) }
        if name == "nav" {
            navDepth -= 1
            if navDepth <= 0 { insideTOC = false; listDepth = 0 }
        }
    }
}

private final class EPUBNCXParser: NSObject, XMLParserDelegate {
    private var items: [EPUBNavigationItem] = []
    private var capturesLabel = false
    private struct Frame {
        var title = ""
        var href: String?
        let level: Int
        let outputIndex: Int
    }
    private var frames: [Frame] = []

    static func parse(_ data: Data) -> [EPUBNavigationItem] {
        let delegate = EPUBNCXParser()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        parser.parse()
        return delegate.items
    }

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes: [String: String] = [:]
    ) {
        let name = elementName.lowercased().components(separatedBy: ":").last ?? elementName
        if name == "navpoint" {
            let outputIndex = items.count
            items.append(EPUBNavigationItem(title: "", relativePath: "", level: frames.count))
            frames.append(Frame(level: frames.count, outputIndex: outputIndex))
        }
        if name == "text", !frames.isEmpty { capturesLabel = true }
        if name == "content", !frames.isEmpty { frames[frames.count - 1].href = attributes["src"] }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if capturesLabel, !frames.isEmpty { frames[frames.count - 1].title += string }
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        let name = elementName.lowercased().components(separatedBy: ":").last ?? elementName
        if name == "text" { capturesLabel = false }
        if name == "navpoint", let frame = frames.popLast() {
            if let href = frame.href {
                items[frame.outputIndex] = EPUBNavigationItem(
                    title: frame.title.trimmingCharacters(in: .whitespacesAndNewlines),
                    relativePath: href,
                    level: frame.level
                )
            } else {
                items.remove(at: frame.outputIndex)
                for index in frames.indices where frames[index].outputIndex > frame.outputIndex {
                    frames[index] = Frame(
                        title: frames[index].title,
                        href: frames[index].href,
                        level: frames[index].level,
                        outputIndex: frames[index].outputIndex - 1
                    )
                }
            }
        }
    }
}
