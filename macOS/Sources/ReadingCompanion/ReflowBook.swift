import Foundation

struct ReflowBook: Codable, Hashable, Sendable {
    let title: String
    let sections: [ReflowSection]
}

struct ReflowSection: Codable, Hashable, Sendable, Identifiable {
    let id: String
    let resourcePath: String
    let title: String?
    let html: String
    let startPageIndex: Int
}

struct ReflowReadingPosition: Codable, Hashable, Sendable {
    let sectionID: String
    let offset: Int
    let pageNumber: Int
    let viewportWidth: Double
    let viewportHeight: Double
    let scale: Double
    let spread: Int
}

struct ReflowTextAnchor: Codable, Hashable, Sendable {
    let sectionID: String
    let startOffset: Int
    let endOffset: Int
    let prefix: String?
    let suffix: String?
}

enum ReflowBookBuilder {
    static func build(
        publication: EPUBPublication,
        sectionStartPages: [String: Int]
    ) -> ReflowBook {
        let navigationTitles = Dictionary(
            publication.navigation.map {
                (canonicalPath($0.relativePath), $0.title.trimmingCharacters(in: .whitespacesAndNewlines))
            },
            uniquingKeysWith: { first, _ in first }
        )
        let sections = publication.sections.enumerated().compactMap { index, section -> ReflowSection? in
            guard let data = try? Data(contentsOf: section.fileURL), !data.isEmpty else {
                return nil
            }
            let source: String
            if data.starts(with: [0xFF, 0xFE]) || data.starts(with: [0xFE, 0xFF]) {
                source = String(data: data, encoding: .utf16) ?? ""
            } else {
                source = String(decoding: data, as: UTF8.self)
            }
            guard !source.isEmpty else { return nil }
            let canonical = canonicalPath(section.relativePath)
            let body = bodyHTML(from: source)
            let cleaned = sanitize(
                body,
                baseDirectory: section.fileURL.deletingLastPathComponent(),
                publicationRoot: publication.extractionDirectory
            )
            guard !cleaned.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            return ReflowSection(
                id: "rc-section-\(index)",
                resourcePath: canonical,
                title: navigationTitles[canonical],
                html: cleaned,
                startPageIndex: sectionStartPages[canonical] ?? 0
            )
        }
        return ReflowBook(title: publication.title, sections: sections)
    }

    private static func bodyHTML(from source: String) -> String {
        guard let expression = try? NSRegularExpression(
            pattern: #"(?is)<body\b[^>]*>(.*?)</body\s*>"#
        ), let match = expression.firstMatch(
            in: source,
            range: NSRange(source.startIndex..., in: source)
        ), match.numberOfRanges > 1,
           let range = Range(match.range(at: 1), in: source) else {
            return source
        }
        return String(source[range])
    }

    private static func sanitize(_ source: String, baseDirectory: URL, publicationRoot: URL) -> String {
        var html = replacingMatches(
            in: source,
            pattern: #"(?is)<(script|style|iframe|object|embed)\b[^>]*>.*?</\1\s*>"#,
            template: ""
        )
        html = replacingMatches(
            in: html,
            pattern: #"(?is)<(script|style|iframe|object|embed)\b[^>]*/\s*>"#,
            template: ""
        )
        html = replacingMatches(
            in: html,
            pattern: #"\s(?:style|on[a-z]+)\s*=\s*(?:\"[^\"]*\"|'[^']*')"#,
            template: ""
        )
        html = embedImages(in: html, baseDirectory: baseDirectory, publicationRoot: publicationRoot)
        // Network resources are not fetched from imported books. Ordinary links
        // remain visible and readable, without the blue/dotted reference styling.
        html = replacingMatches(
            in: html,
            pattern: #"(?i)\s(?:src|href)\s*=\s*([\"'])\s*(?:javascript:|https?://|file:)[^\"']*\1"#,
            template: ""
        )
        return html
    }

    private static func embedImages(in source: String, baseDirectory: URL, publicationRoot: URL) -> String {
        guard let expression = try? NSRegularExpression(
            pattern: #"(?i)\b(src|(?:xlink:)?href)\s*=\s*([\"'])([^\"']+)\2"#
        ) else { return source }
        var html = source
        let matches = expression.matches(in: source, range: NSRange(source.startIndex..., in: source)).reversed()
        for match in matches {
            guard match.numberOfRanges > 3,
                  let wholeRange = Range(match.range(at: 0), in: html),
                  let nameRange = Range(match.range(at: 1), in: html),
                  let pathRange = Range(match.range(at: 3), in: html) else { continue }
            let attributeName = String(html[nameRange])
            if attributeName.lowercased() != "src" {
                let prefix = html[..<wholeRange.lowerBound]
                guard let tagStart = prefix.lastIndex(of: "<") else { continue }
                let tagPrefix = html[tagStart..<wholeRange.lowerBound]
                guard tagPrefix.range(of: #"(?i)^<\s*image\b"#, options: .regularExpression) != nil else { continue }
            }
            let rawPath = String(html[pathRange])
            guard !rawPath.lowercased().hasPrefix("data:"),
                  !rawPath.contains("://") else { continue }
            let withoutFragment = rawPath.components(separatedBy: "#").first ?? rawPath
            let withoutQuery = withoutFragment.components(separatedBy: "?").first ?? withoutFragment
            let path = withoutQuery.removingPercentEncoding ?? withoutQuery
            guard let candidate = localResource(
                path: path,
                baseDirectory: baseDirectory,
                publicationRoot: publicationRoot
            ),
                  let data = try? Data(contentsOf: candidate),
                  !data.isEmpty,
                  data.count <= 25 * 1_024 * 1_024 else { continue }
            let replacement = "\(attributeName)=\"data:\(mimeType(for: candidate));base64,\(data.base64EncodedString())\""
            html.replaceSubrange(wholeRange, with: replacement)
        }
        return html
    }

    private static func localResource(path: String, baseDirectory: URL, publicationRoot: URL) -> URL? {
        guard !path.isEmpty else { return nil }
        let root = publicationRoot.standardizedFileURL
        let candidate = baseDirectory.appendingPathComponent(path).standardizedFileURL
        let rootPrefix = root.path.hasSuffix("/") ? root.path : root.path + "/"
        guard candidate.path.hasPrefix(rootPrefix) else { return nil }
        if FileManager.default.fileExists(atPath: candidate.path) { return candidate }

        let relative = String(candidate.path.dropFirst(rootPrefix.count))
        var resolved = root
        for component in relative.split(separator: "/").map(String.init) {
            guard let names = try? FileManager.default.contentsOfDirectory(atPath: resolved.path),
                  let actual = names.first(where: {
                      $0.localizedCaseInsensitiveCompare(component) == .orderedSame
                  }) else { return nil }
            resolved.appendPathComponent(actual)
        }
        return resolved.standardizedFileURL.path.hasPrefix(rootPrefix) ? resolved : nil
    }

    private static func mimeType(for url: URL) -> String {
        switch url.pathExtension.lowercased() {
        case "jpg", "jpeg": "image/jpeg"
        case "gif": "image/gif"
        case "webp": "image/webp"
        case "svg": "image/svg+xml"
        default: "image/png"
        }
    }

    private static func replacingMatches(in source: String, pattern: String, template: String) -> String {
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return source }
        return expression.stringByReplacingMatches(
            in: source,
            range: NSRange(source.startIndex..., in: source),
            withTemplate: template
        )
    }

    private static func canonicalPath(_ value: String) -> String {
        let path = value.components(separatedBy: "#").first ?? value
        return path.removingPercentEncoding ?? path
    }
}
