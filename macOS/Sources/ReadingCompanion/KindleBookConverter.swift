import Foundation

enum KindleBookConversionError: LocalizedError {
    case converterUnavailable
    case invalidContainer
    case encrypted
    case conversionFailed(String)
    case missingOutput

    var errorDescription: String? {
        switch self {
        case .converterUnavailable:
            "安装包缺少 AZW3/MOBI 解码组件，请重新安装完整版本。"
        case .invalidContainer:
            "这份文件不是有效的 AZW3 或 MOBI 电子书。"
        case .encrypted:
            "这份 Kindle 电子书带有 DRM 加密，无法导入。请使用无 DRM 的 AZW3/MOBI 文件。"
        case .conversionFailed(let detail):
            "AZW3/MOBI 解码失败：\(detail)"
        case .missingOutput:
            "AZW3/MOBI 已完成解析，但没有生成可阅读的书籍内容。"
        }
    }
}

struct ConvertedKindleBook: Sendable {
    let epubURL: URL
    let workingDirectory: URL
}

/// Offline bridge from Kindle containers to the EPUB import pipeline. The
/// bundled `mobitool` and dynamic libmobi are LGPL-3.0-or-later and run as a
/// separate process; no book content is sent over the network.
enum KindleBookConverter {
    static func convertToEPUB(_ sourceURL: URL) async throws -> ConvertedKindleBook {
        try await Task.detached(priority: .userInitiated) {
            try convertSynchronously(sourceURL)
        }.value
    }

    private static func convertSynchronously(_ sourceURL: URL) throws -> ConvertedKindleBook {
        try validateSource(sourceURL)
        guard let executable = converterExecutableURL() else {
            throw KindleBookConversionError.converterUnavailable
        }

        let outputDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ReadingCompanion-Kindle-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        do {
            let process = Process()
            process.executableURL = executable
            process.arguments = ["-e", "-o", outputDirectory.path, sourceURL.path]
            let output = Pipe()
            process.standardOutput = output
            process.standardError = output
            do {
                try process.run()
            } catch {
                throw KindleBookConversionError.conversionFailed(error.localizedDescription)
            }
            let outputData = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            let message = String(data: outputData, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

            guard process.terminationStatus == 0 else {
                if message.localizedCaseInsensitiveContains("encrypted") {
                    throw KindleBookConversionError.encrypted
                }
                let concise = message.components(separatedBy: .newlines).suffix(4).joined(separator: " ")
                throw KindleBookConversionError.conversionFailed(
                    concise.isEmpty ? "文件损坏、格式不受支持或含有加密内容" : concise
                )
            }
            let generated = try FileManager.default.contentsOfDirectory(
                at: outputDirectory,
                includingPropertiesForKeys: [.fileSizeKey],
                options: [.skipsHiddenFiles]
            ).first { $0.pathExtension.lowercased() == "epub" }
            guard let generated else { throw KindleBookConversionError.missingOutput }
            return ConvertedKindleBook(epubURL: generated, workingDirectory: outputDirectory)
        } catch {
            try? FileManager.default.removeItem(at: outputDirectory)
            throw error
        }
    }

    private static func validateSource(_ sourceURL: URL) throws {
        let values = try? sourceURL.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
        guard values?.isRegularFile == true,
              let size = values?.fileSize,
              size > 78,
              size <= 1_073_741_824,
              let handle = try? FileHandle(forReadingFrom: sourceURL) else {
            throw KindleBookConversionError.invalidContainer
        }
        defer { try? handle.close() }
        try? handle.seek(toOffset: 60)
        let signature = try? handle.read(upToCount: 8)
        guard signature == Data("BOOKMOBI".utf8) || signature == Data("TEXtREAd".utf8) else {
            throw KindleBookConversionError.invalidContainer
        }
    }

    private static func converterExecutableURL() -> URL? {
        var candidates: [URL] = []
        if let resources = Bundle.main.resourceURL {
            candidates.append(resources.appendingPathComponent("BookConverter/mobitool"))
        }
        let projectRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        candidates.append(projectRoot.appendingPathComponent("Resources/BookConverter/mobitool"))
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }
}

@MainActor
enum KindleBookImporter {
    static func importBook(
        at sourceURL: URL,
        progress: BookImportProgressHandler? = nil
    ) async throws -> EPUBImportResult {
        progress?(0.04, "正在检查 \(sourceURL.pathExtension.uppercased()) 缓存…")
        if let cached = EPUBImporter.cachedBook(for: sourceURL) {
            progress?(0.98, "正在恢复电子书排版与目录…")
            return cached
        }
        progress?(0.10, "正在离线解码 \(sourceURL.pathExtension.uppercased())…")
        let converted = try await KindleBookConverter.convertToEPUB(sourceURL)
        defer { try? FileManager.default.removeItem(at: converted.workingDirectory) }
        try Task.checkCancellation()
        progress?(0.30, "解码完成，正在读取目录与正文…")
        return try await EPUBImporter.importBook(
            at: converted.epubURL,
            cacheIdentityURL: sourceURL,
            progress: { value, message in
                progress?(0.30 + value * 0.68, message)
            }
        )
    }
}
