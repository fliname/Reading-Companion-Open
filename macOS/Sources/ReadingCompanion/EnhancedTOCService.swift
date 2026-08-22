import Foundation
import PDFKit

enum EnhancedTOCError: LocalizedError {
    case bundledRuntimeMissing
    case commandFailed(stage: String, details: String)
    case outputMissing
    case invalidOutput

    var errorDescription: String? {
        switch self {
        case .bundledRuntimeMissing:
            return "安装包中的增强目录识别组件不完整。请重新安装 Reading Companion。"
        case let .commandFailed(stage, details):
            let suffix = details.isEmpty ? "" : "\n\n\(details)"
            return "\(stage)失败。请检查网络和剩余磁盘空间后重试。\(suffix)"
        case .outputMissing:
            return "增强版面识别没有生成结果。"
        case .invalidOutput:
            return "增强版面识别返回了无法读取的结果。"
        }
    }
}

struct EnhancedTOCPageResult: Equatable {
    var pageIndex: Int
    var text: String
}

enum DoclingTOCJSONParser {
    static func parse(_ data: Data, sourcePageIndices: [Int]) throws -> [EnhancedTOCPageResult] {
        let document = try JSONDecoder().decode(DoclingDocument.self, from: data)
        guard !sourcePageIndices.isEmpty else { return [] }

        var textByPosition: [Int: [String]] = [:]
        for block in document.texts {
            let text = normalizeOCRBlock(block.text)
            guard !text.isEmpty,
                  !isContentsHeading(text),
                  acceptedLabels.contains(block.label ?? "text") else { continue }
            let rawPage = block.prov?.first?.pageNumber ?? 1
            let position: Int
            if (1...sourcePageIndices.count).contains(rawPage) {
                position = rawPage - 1
            } else if sourcePageIndices.indices.contains(rawPage) {
                position = rawPage
            } else {
                continue
            }
            textByPosition[position, default: []].append(text)
        }

        return sourcePageIndices.indices.compactMap { position in
            guard let blocks = textByPosition[position], !blocks.isEmpty else { return nil }
            return EnhancedTOCPageResult(
                pageIndex: sourcePageIndices[position],
                text: blocks.joined(separator: "\n")
            )
        }
    }

    private static let acceptedLabels: Set<String> = [
        "text", "title", "section_header", "list_item", "paragraph"
    ]

    private static func normalizeOCRBlock(_ source: String) -> String {
        source.trimmingCharacters(in: .whitespacesAndNewlines)
            // A printed slash is occasionally recognized as punctuation.
            .replacingOccurrences(
                of: #"[;；:：]\s*(?=[0-9]{1,4}\s*$)"#,
                with: " ",
                options: .regularExpression
            )
            // Apple Vision can read “/092” as “1092”. Preserve it as a page
            // candidate; the resolver later checks it against document length.
            .replacingOccurrences(
                of: #"(?<=[^0-9\s])(?=1[0-9]{3}\s*$)"#,
                with: " ",
                options: .regularExpression
            )
    }

    private static func isContentsHeading(_ source: String) -> Bool {
        source.range(
            of: #"^(?:目|录|錄|目\s*[录錄次](?:\s*contents)?|contents|table\s+of\s+contents)$"#,
            options: [.regularExpression, .caseInsensitive]
        ) != nil
    }

    private struct DoclingDocument: Decodable {
        var texts: [TextBlock]
    }

    private struct TextBlock: Decodable {
        var label: String?
        var text: String
        var prov: [Provenance]?
    }

    private struct Provenance: Decodable {
        var pageNumber: Int

        enum CodingKeys: String, CodingKey {
            case pageNumber = "page_no"
        }
    }
}

actor EnhancedTOCService {
    static let pinnedDoclingVersion = "2.118.1"
    static let pinnedOCRMacVersion = "1.0.1"

    nonisolated static var bundledToolRootURL: URL? {
        Bundle.main.resourceURL?
            .appendingPathComponent("EnhancedTOC", isDirectory: true)
    }

    nonisolated static var legacyToolRootURL: URL {
        let applicationSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let applicationFolder = Bundle.main.bundleIdentifier == "com.ljg.reading-companion-open"
            ? "ReadingCompanionOpen"
            : "ReadingCompanion"
        return applicationSupport
            .appendingPathComponent(applicationFolder, isDirectory: true)
            .appendingPathComponent("Tools/Docling", isDirectory: true)
    }

    nonisolated static var toolRootURL: URL {
        if let bundledToolRootURL,
           FileManager.default.isExecutableFile(
            atPath: bundledToolRootURL.appendingPathComponent("Python/bin/python3.14").path
           ) {
            return bundledToolRootURL
        }
        return legacyToolRootURL
    }

    nonisolated static var pythonURL: URL {
        toolRootURL.appendingPathComponent("Python/bin/python3.14")
    }

    nonisolated static var sitePackagesURL: URL {
        toolRootURL.appendingPathComponent("site-packages", isDirectory: true)
    }

    nonisolated static var layoutModelURL: URL {
        toolRootURL.appendingPathComponent("models/docling-project--docling-layout-heron/model.safetensors")
    }

    nonisolated static var rapidOCRModelURL: URL {
        toolRootURL.appendingPathComponent("models/RapidOcr", isDirectory: true)
    }

    nonisolated static var rapidOCRScriptURL: URL {
        toolRootURL.appendingPathComponent("rapid_toc_ocr.py")
    }

    nonisolated static var isInstalled: Bool {
        FileManager.default.isExecutableFile(atPath: pythonURL.path) &&
            FileManager.default.fileExists(atPath: sitePackagesURL.appendingPathComponent("docling").path) &&
            FileManager.default.fileExists(atPath: layoutModelURL.path)
    }

    func recognize(pdfURL: URL, sourcePageIndices: [Int]) throws -> [EnhancedTOCPageResult] {
        guard Self.isInstalled else { return [] }
        // Automatic TOC recognition intentionally follows the 0.42.16
        // Docling + OCRMac route. RapidOCR remains bundled for other tooling,
        // but is not allowed to change automatic TOC ordering.
        let workspace = pdfURL.deletingLastPathComponent()
        let outputDirectory = workspace.appendingPathComponent("docling-output", isDirectory: true)
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        let models = Self.toolRootURL.appendingPathComponent("models", isDirectory: true)

        var arguments = [
            "convert", pdfURL.path,
            "--to", "json",
            "--output", outputDirectory.path,
            "--ocr",
            "--ocr-engine", "ocrmac",
            "--ocr-lang", "zh-Hans,en-US",
            "--ocr-mode", "full_page",
            "--no-tables",
            "--device", "auto",
            "--document-timeout", "300",
            "--quiet"
        ]
        if FileManager.default.fileExists(atPath: models.path) {
            arguments += ["--artifacts-path", models.path]
        }
        guard Self.isInstalled else { throw EnhancedTOCError.bundledRuntimeMissing }
        try run(
            executable: Self.pythonURL,
            arguments: ["-c", "from docling.cli.main import app; app()"] + arguments,
            stage: "增强版面识别"
        )

        let outputURL = outputDirectory
            .appendingPathComponent(pdfURL.deletingPathExtension().lastPathComponent)
            .appendingPathExtension("json")
        guard FileManager.default.fileExists(atPath: outputURL.path) else {
            throw EnhancedTOCError.outputMissing
        }
        do {
            return try DoclingTOCJSONParser.parse(Data(contentsOf: outputURL), sourcePageIndices: sourcePageIndices)
        } catch {
            throw EnhancedTOCError.invalidOutput
        }
    }

    private func recognizeWithRapidOCR(
        pdfURL: URL,
        sourcePageIndices: [Int]
    ) throws -> [EnhancedTOCPageResult] {
        let requiredModels = [
            "PP-OCRv6_det_small.onnx",
            "ch_ppocr_mobile_v2.0_cls_mobile.onnx",
            "PP-OCRv6_rec_small.onnx"
        ]
        guard FileManager.default.fileExists(atPath: Self.rapidOCRScriptURL.path),
              requiredModels.allSatisfy({
                  FileManager.default.fileExists(atPath: Self.rapidOCRModelURL.appendingPathComponent($0).path)
              }),
              FileManager.default.fileExists(atPath: Self.sitePackagesURL.appendingPathComponent("onnxruntime").path) else {
            return []
        }
        let outputURL = pdfURL.deletingLastPathComponent().appendingPathComponent("rapid-toc.json")
        try run(
            executable: Self.pythonURL,
            arguments: [
                Self.rapidOCRScriptURL.path,
                pdfURL.path,
                outputURL.path,
                Self.rapidOCRModelURL.path
            ],
            stage: "中文目录 OCR"
        )
        let decoded = try JSONDecoder().decode(
            [RapidTOCPage].self,
            from: Data(contentsOf: outputURL)
        )
        return decoded.compactMap { page in
            guard sourcePageIndices.indices.contains(page.pagePosition) else { return nil }
            let observations = (page.lines ?? []).compactMap { line -> OCRLineObservation? in
                guard line.rect.count == 4, line.rect.allSatisfy(\.isFinite) else { return nil }
                return OCRLineObservation(
                    text: line.text,
                    boundingBox: CGRect(x: line.rect[0], y: line.rect[1], width: line.rect[2], height: line.rect[3]),
                    confidence: line.confidence
                )
            }
            let layoutText = OCRLayoutReconstructor.text(from: observations)
            return EnhancedTOCPageResult(
                pageIndex: sourcePageIndices[page.pagePosition],
                text: layoutText.isEmpty ? page.text : layoutText
            )
        }
    }

    private func isReliableRapidResult(_ pages: [EnhancedTOCPageResult]) -> Bool {
        guard !pages.isEmpty else { return false }
        let entries = TOCReliableParser.parse(pages.map(\.text).joined(separator: "\n"))
        let numbered = entries.compactMap(\.printedPage).count
        return entries.count >= 3 && numbered >= max(2, entries.count / 2)
    }

    private struct RapidTOCPage: Decodable {
        var pagePosition: Int
        var text: String
        var lines: [RapidTOCLine]?

        enum CodingKeys: String, CodingKey {
            case pagePosition = "page_position"
            case text
            case lines
        }
    }

    private struct RapidTOCLine: Decodable {
        var text: String
        var rect: [Double]
        var confidence: Float
    }

    private func run(executable: URL, arguments: [String], stage: String) throws {
        let logURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("reading-companion-docling-\(UUID().uuidString).log")
        FileManager.default.createFile(atPath: logURL.path, contents: nil)
        let logHandle = try FileHandle(forWritingTo: logURL)
        defer {
            try? logHandle.close()
            try? FileManager.default.removeItem(at: logURL)
        }

        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.standardOutput = logHandle
        process.standardError = logHandle
        var environment = ProcessInfo.processInfo.environment
        environment["PIP_DISABLE_PIP_VERSION_CHECK"] = "1"
        environment["PYTHONUNBUFFERED"] = "1"
        environment["PYTHONHOME"] = Self.toolRootURL.appendingPathComponent("Python", isDirectory: true).path
        environment["PYTHONPATH"] = Self.sitePackagesURL.path
        environment["HF_HOME"] = Self.toolRootURL.appendingPathComponent("cache/huggingface", isDirectory: true).path
        environment["HF_HUB_OFFLINE"] = "1"
        environment["TRANSFORMERS_OFFLINE"] = "1"
        process.environment = environment
        do {
            try process.run()
        } catch {
            throw EnhancedTOCError.commandFailed(stage: stage, details: error.localizedDescription)
        }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let details = (try? String(contentsOf: logURL, encoding: .utf8))?
                .components(separatedBy: .newlines)
                .suffix(14)
                .joined(separator: "\n") ?? ""
            throw EnhancedTOCError.commandFailed(stage: stage, details: details)
        }
    }

}

extension EnhancedTOCService {
    @MainActor
    static func makeInputPDF(from document: PDFDocument, pageIndices: [Int]) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("reading-companion-toc-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let inputURL = directory.appendingPathComponent("toc-pages.pdf")
        let subset = PDFDocument()
        for pageIndex in pageIndices where (0..<document.pageCount).contains(pageIndex) {
            guard let page = document.page(at: pageIndex)?.copy() as? PDFPage else { continue }
            subset.insert(page, at: subset.pageCount)
        }
        guard subset.pageCount > 0, subset.write(to: inputURL) else {
            throw EnhancedTOCError.outputMissing
        }
        return inputURL
    }
}
