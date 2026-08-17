import Foundation

struct PageText: Codable, Hashable {
    var pageIndex: Int
    var text: String
    var cameFromOCR: Bool
    /// PDF page label when the file declares one (for example "ix" or "23").
    /// A declared label is a stronger printed-page anchor than OCR title matching.
    var pageLabel: String? = nil
}

struct TextChunk: Identifiable, Codable, Hashable {
    var id = UUID()
    var pageIndex: Int
    var chapterTitle: String?
    var text: String
    var chapterPath: [String]? = nil
}

struct PDFMarkdownCacheEnvelope: Codable {
    var version: Int
    var sourceFingerprint: String
    var pages: [PageText]
    var indexVersion: Int? = nil
    var outlineSignature: String? = nil
    var chunks: [TextChunk]? = nil
}

enum PDFMarkdownDocument {
    static let cacheVersion = 2

    static func compactPages(_ pages: [PageText]) -> [PageText] {
        let repeatingEdges = repeatedEdgeLines(in: pages)
        return pages.map { page in
            let source = page.text.components(separatedBy: .newlines).filter {
                !repeatingEdges.contains(edgeKey($0))
            }.joined(separator: "\n")
            return PageText(
                pageIndex: page.pageIndex,
                text: compact(source),
                cameFromOCR: page.cameFromOCR,
                pageLabel: page.pageLabel
            )
        }
    }

    static func render(title: String, pages: [PageText], outline: [OutlineEntry]) -> String {
        var lines = ["# \(title)", ""]
        var headingsByPage: [Int: [OutlineEntry]] = [:]
        for entry in outline { headingsByPage[entry.pageIndex, default: []].append(entry) }
        for page in pages where !page.text.isEmpty {
            for entry in headingsByPage[page.pageIndex] ?? [] {
                lines.append(String(repeating: "#", count: min(max(entry.level + 2, 2), 6)) + " " + entry.title)
                lines.append("")
            }
            lines.append("<!-- P\(page.pageIndex + 1) -->")
            lines.append(page.text)
            lines.append("")
        }
        return lines.joined(separator: "\n")
    }

    private static func compact(_ source: String) -> String {
        OCRTextNormalizer.removeSpuriousCJKSpaces(source)
            .replacingOccurrences(of: #"[ \t]+"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"(?<=\p{L})-\s*\n\s*(?=\p{L})"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"(?<=[。！？.!?；;：:])\s*\n\s*"#, with: "\n", options: .regularExpression)
            .replacingOccurrences(of: #"(?<![。！？.!?；;：:])\s*\n\s*(?=\S)"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"\n{3,}"#, with: "\n\n", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func repeatedEdgeLines(in pages: [PageText]) -> Set<String> {
        guard pages.count >= 4 else { return [] }
        var counts: [String: Int] = [:]
        for page in pages {
            let lines = page.text.components(separatedBy: .newlines).filter { !$0.isEmpty }
            for line in Array(lines.prefix(1)) + Array(lines.suffix(1)) {
                let key = edgeKey(line)
                guard key.count >= 2, key.count <= 90, !key.allSatisfy(\.isNumber) else { continue }
                counts[key, default: 0] += 1
            }
        }
        let threshold = max(3, Int((Double(pages.count) * 0.12).rounded(.up)))
        return Set(counts.compactMap { $0.value >= threshold ? $0.key : nil })
    }

    private static func edgeKey(_ line: String) -> String {
        line.lowercased()
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"\b[ivxlcdm0-9]+\b"#, with: "#", options: [.regularExpression, .caseInsensitive])
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

enum LocalIndex {
    /// Bump whenever chunk boundaries, normalization, or chapter assignment changes.
    static let cacheVersion = 2

    static func makeChunks(
        pages: [PageText],
        outline: [OutlineEntry],
        targetLength: Int = 1_200,
        overlap: Int = 180
    ) -> [TextChunk] {
        var chunks: [TextChunk] = []
        let paths = outlinePaths(outline)
        for page in pages where !page.text.isEmpty {
            let normalized = OCRTextNormalizer.removeSpuriousCJKSpaces(page.text)
                .replacingOccurrences(of: #"[ \t]+"#, with: " ", options: .regularExpression)
                .replacingOccurrences(of: #"\n{3,}"#, with: "\n\n", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !normalized.isEmpty else { continue }

            for segment in pageSegments(normalized, pageIndex: page.pageIndex, outline: outline, paths: paths) {
                var start = segment.text.startIndex
                while start < segment.text.endIndex {
                    let proposedEnd = segment.text.index(start, offsetBy: targetLength, limitedBy: segment.text.endIndex) ?? segment.text.endIndex
                    let end = preferredBreak(in: segment.text, start: start, proposedEnd: proposedEnd)
                    let text = String(segment.text[start..<end]).trimmingCharacters(in: .whitespacesAndNewlines)
                    if !text.isEmpty {
                        chunks.append(TextChunk(pageIndex: page.pageIndex, chapterTitle: segment.path.last, text: text, chapterPath: segment.path.isEmpty ? nil : segment.path))
                    }
                    guard end < segment.text.endIndex else { break }
                    start = segment.text.index(end, offsetBy: -min(overlap, segment.text.distance(from: start, to: end)))
                }
            }
        }
        return chunks
    }

    static func retrieve(_ query: String, from chunks: [TextChunk], limit: Int = 8) -> [TextChunk] {
        let queryFrequency = tokenFrequencies(in: query)
        guard !queryFrequency.isEmpty else { return Array(chunks.prefix(limit)) }
        let documentFrequencies = chunks.reduce(into: [String: Int]()) { result, chunk in
            for token in tokenFrequencies(in: chunk.text).keys { result[token, default: 0] += 1 }
        }
        let lengths = chunks.map { tokenFrequencies(in: $0.text).values.reduce(0, +) }
        let averageLength = max(Double(lengths.reduce(0, +)) / Double(max(lengths.count, 1)), 1)
        let documentCount = Double(chunks.count)

        return zip(chunks, lengths)
            .map { pair -> (TextChunk, Double) in
                let (chunk, length) = pair
                let frequencies = tokenFrequencies(in: chunk.text)
                var score = 0.0
                for (token, queryCount) in queryFrequency {
                    guard let frequency = frequencies[token], frequency > 0 else { continue }
                    let containing = Double(documentFrequencies[token] ?? 0)
                    let inverseFrequency = log(1 + (documentCount - containing + 0.5) / (containing + 0.5))
                    let normalizedFrequency = Double(frequency) * 2.2
                        / (Double(frequency) + 1.2 * (0.25 + 0.75 * Double(length) / averageLength))
                    score += inverseFrequency * normalizedFrequency * min(1.6, 1 + log(Double(queryCount)))
                }
                let normalizedQuery = HighlightTextNormalizer.inline(query).lowercased()
                if chunk.chapterTitle.map({ normalizedQuery.contains(HighlightTextNormalizer.inline($0).lowercased()) }) == true {
                    score += 5
                }
                if let path = chunk.chapterPath {
                    score += Double(path.filter {
                        normalizedQuery.contains(HighlightTextNormalizer.inline($0).lowercased())
                    }.count) * 2
                }
                let compactChunk = HighlightTextNormalizer.inline(chunk.text).lowercased()
                if normalizedQuery.count >= 8, compactChunk.contains(String(normalizedQuery.prefix(160))) { score += 12 }
                return (chunk, score)
            }
            .filter { $0.1 > 0 }
            .sorted {
                if $0.1 == $1.1 { return $0.0.pageIndex < $1.0.pageIndex }
                return $0.1 > $1.1
            }
            .prefix(limit)
            .map(\.0)
    }

    /// Removes repeated chunk overlap and enforces a token-shaped context
    /// budget before any text leaves the Mac. This keeps evidence density high
    /// without relying on a fixed page or character count.
    static func prepareForPrompt(_ chunks: [TextChunk], tokenBudget: Int) -> [TextChunk] {
        guard tokenBudget > 0 else { return [] }
        var result: [TextChunk] = []
        var remaining = tokenBudget
        var seen = Set<String>()
        for original in chunks {
            var chunk = original
            if let related = result.last(where: {
                $0.pageIndex == chunk.pageIndex && effectivePath(for: $0) == effectivePath(for: chunk)
            }) {
                chunk.text = removingRepeatedBoundary(previous: related.text, current: chunk.text)
            }
            let key = HighlightTextNormalizer.inline(chunk.text).lowercased()
            guard !key.isEmpty, seen.insert(key).inserted else { continue }
            let metadataCost = 12 + (chunk.chapterTitle.map(estimatedTokenCount) ?? 0)
            let available = remaining - metadataCost
            guard available >= 80 else { break }
            if estimatedTokenCount(chunk.text) > available {
                chunk.text = prefix(chunk.text, fittingTokenBudget: available)
            }
            guard !chunk.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
            remaining -= metadataCost + estimatedTokenCount(chunk.text)
            result.append(chunk)
        }
        return result
    }

    static func estimatedTokenCount(_ text: String) -> Int {
        var units = 0.0
        var latinRun = 0
        func flushLatin() {
            if latinRun > 0 { units += max(1, Double(latinRun) / 4); latinRun = 0 }
        }
        for scalar in text.unicodeScalars {
            if (0x4E00...0x9FFF).contains(scalar.value) || (0x3400...0x4DBF).contains(scalar.value) {
                flushLatin(); units += 1
            } else if CharacterSet.alphanumerics.contains(scalar) {
                latinRun += 1
            } else if CharacterSet.whitespacesAndNewlines.contains(scalar) {
                flushLatin()
            } else {
                flushLatin(); units += 0.35
            }
        }
        flushLatin()
        return max(Int(ceil(units)), text.isEmpty ? 0 : 1)
    }

    static func retrieveForReading(
        _ query: String,
        focusPageIndex: Int?,
        from chunks: [TextChunk],
        limit: Int = 14,
        wholeBook: Bool = false,
        scope: ReadingContextScope = .standard
    ) -> [TextChunk] {
        guard !chunks.isEmpty else { return [] }
        let retrievalPool: [TextChunk]
        if !wholeBook, let focusPageIndex {
            let pageChunks = chunks.filter { $0.pageIndex == focusPageIndex }
            let focusChunk = retrieve(query, from: pageChunks, limit: 1).first
                ?? pageChunks.first
                ?? chunks.last(where: { $0.pageIndex <= focusPageIndex })
            if let focusChunk, let focusPath = effectivePath(for: focusChunk), !focusPath.isEmpty {
                let hasDescendants = chunks.contains { chunk in
                    guard let path = effectivePath(for: chunk) else { return false }
                    return path.count > focusPath.count && path.starts(with: focusPath)
                }
                let scopePath = hasDescendants || focusPath.count == 1 ? focusPath : Array(focusPath.dropLast())
                retrievalPool = chunks.filter { effectivePath(for: $0)?.starts(with: scopePath) == true }
            } else {
                retrievalPool = chunks.filter { abs($0.pageIndex - focusPageIndex) <= 3 }
            }
        } else {
            retrievalPool = chunks
        }
        let allowedIDs = Set(retrievalPool.map(\.id))
        let seedLimit: Int
        let neighborRadius: Int
        switch scope {
        case .explanation:
            seedLimit = wholeBook ? 4 : 3
            neighborRadius = 0
        case .standard:
            seedLimit = wholeBook ? 7 : 5
            neighborRadius = 1
        case .context:
            seedLimit = wholeBook ? 10 : 7
            neighborRadius = 2
        }
        let semanticSeeds = retrieve(query, from: retrievalPool, limit: seedLimit)
        var selectedIndices = Set<Int>()

        for seed in semanticSeeds {
            guard let index = chunks.firstIndex(where: { $0.id == seed.id }) else { continue }
            for candidate in max(0, index - neighborRadius)...min(chunks.count - 1, index + neighborRadius) {
                if wholeBook || allowedIDs.contains(chunks[candidate].id) { selectedIndices.insert(candidate) }
            }
        }
        if let focusPageIndex {
            let pageRadius = scope == .context ? 2 : (scope == .standard ? 1 : 0)
            for (index, chunk) in chunks.enumerated() where abs(chunk.pageIndex - focusPageIndex) <= pageRadius {
                if wholeBook || allowedIDs.contains(chunk.id) { selectedIndices.insert(index) }
            }
        }
        if selectedIndices.isEmpty {
            return Array(retrievalPool.prefix(adaptiveLimit(requested: limit, scope: scope, wholeBook: wholeBook)))
        }
        let focus = focusPageIndex ?? semanticSeeds.first?.pageIndex
        var prioritized: [Int] = []
        if let focusPageIndex,
           let bestFocus = retrieve(query, from: chunks.filter { $0.pageIndex == focusPageIndex }, limit: 1).first,
           let index = chunks.firstIndex(where: { $0.id == bestFocus.id }),
           selectedIndices.contains(index) {
            prioritized.append(index)
        }
        for seed in semanticSeeds {
            guard let index = chunks.firstIndex(where: { $0.id == seed.id }),
                  selectedIndices.contains(index),
                  !prioritized.contains(index) else { continue }
            prioritized.append(index)
        }
        let remaining = selectedIndices.filter { !prioritized.contains($0) }.sorted { lhs, rhs in
            if let focus {
                let leftDistance = abs(chunks[lhs].pageIndex - focus)
                let rightDistance = abs(chunks[rhs].pageIndex - focus)
                if leftDistance != rightDistance { return leftDistance < rightDistance }
            }
            return lhs < rhs
        }
        prioritized.append(contentsOf: remaining)
        let chosen = Set(prioritized.prefix(adaptiveLimit(requested: limit, scope: scope, wholeBook: wholeBook)))
        return chunks.indices.filter { chosen.contains($0) }.map { chunks[$0] }
    }

    private struct PageSegment {
        var text: String
        var path: [String]
    }

    private static func outlinePaths(_ outline: [OutlineEntry]) -> [UUID: [String]] {
        var result: [UUID: [String]] = [:]
        var stack: [String] = []
        for entry in outline {
            let level = min(max(entry.level, 0), stack.count)
            stack = Array(stack.prefix(level))
            stack.append(entry.title)
            result[entry.id] = stack
        }
        return result
    }

    private static func pageSegments(
        _ text: String,
        pageIndex: Int,
        outline: [OutlineEntry],
        paths: [UUID: [String]]
    ) -> [PageSegment] {
        let indexed = Array(outline.enumerated())
        let previousPath = indexed
            .filter { $0.element.pageIndex < pageIndex }
            .max { lhs, rhs in
                if lhs.element.pageIndex != rhs.element.pageIndex {
                    return lhs.element.pageIndex < rhs.element.pageIndex
                }
                return lhs.offset < rhs.offset
            }
            .flatMap { paths[$0.element.id] } ?? []
        let entries = indexed.filter { $0.element.pageIndex == pageIndex }
        guard !entries.isEmpty else { return [PageSegment(text: text, path: previousPath)] }

        var anchors: [(index: String.Index, path: [String])] = []
        var searchStart = text.startIndex
        for item in entries {
            guard let path = paths[item.element.id],
                  let anchor = headingAnchor(for: item.element.title, in: text, after: searchStart) else { continue }
            anchors.append((anchor, path))
            searchStart = text.index(after: anchor)
        }
        guard !anchors.isEmpty else {
            return [PageSegment(text: text, path: paths[entries[0].element.id] ?? previousPath)]
        }

        var segments: [PageSegment] = []
        if anchors[0].index > text.startIndex {
            let prefix = String(text[text.startIndex..<anchors[0].index]).trimmingCharacters(in: .whitespacesAndNewlines)
            if !prefix.isEmpty {
                segments.append(PageSegment(text: prefix, path: previousPath.isEmpty ? anchors[0].path : previousPath))
            }
        }
        for offset in anchors.indices {
            let start = anchors[offset].index
            let end = offset + 1 < anchors.count ? anchors[offset + 1].index : text.endIndex
            let body = String(text[start..<end]).trimmingCharacters(in: .whitespacesAndNewlines)
            if !body.isEmpty { segments.append(PageSegment(text: body, path: anchors[offset].path)) }
        }
        return segments.isEmpty ? [PageSegment(text: text, path: anchors[0].path)] : segments
    }

    private static func headingAnchor(
        for title: String,
        in text: String,
        after start: String.Index
    ) -> String.Index? {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty,
           let range = text.range(of: trimmed, options: [.caseInsensitive, .widthInsensitive], range: start..<text.endIndex) {
            return range.lowerBound
        }
        let titleKey = headingKey(trimmed)
        guard titleKey.count >= 3 else { return nil }
        var match: String.Index?
        text.enumerateSubstrings(in: start..<text.endIndex, options: [.byLines, .substringNotRequired]) { _, range, _, stop in
            let lineKey = headingKey(String(text[range]))
            guard lineKey.count >= 3 else { return }
            let shorter = min(lineKey.count, titleKey.count)
            let longer = max(lineKey.count, titleKey.count)
            if Double(shorter) / Double(longer) >= 0.65,
               (lineKey.contains(titleKey) || titleKey.contains(lineKey)) {
                match = range.lowerBound
                stop = true
            }
        }
        return match
    }

    private static func headingKey(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .widthInsensitive], locale: Locale(identifier: "zh_CN"))
            .filter { character in
                character.unicodeScalars.allSatisfy {
                    CharacterSet.alphanumerics.contains($0) || (0x4E00...0x9FFF).contains($0.value)
                }
            }
    }

    private static func effectivePath(for chunk: TextChunk) -> [String]? {
        if let path = chunk.chapterPath, !path.isEmpty { return path }
        return chunk.chapterTitle.map { [$0] }
    }

    private static func adaptiveLimit(requested: Int, scope: ReadingContextScope, wholeBook: Bool) -> Int {
        let cap: Int
        switch scope {
        case .explanation: cap = wholeBook ? 6 : 4
        case .standard: cap = wholeBook ? 10 : 6
        case .context: cap = wholeBook ? 14 : 9
        }
        return max(1, min(requested, cap))
    }

    private static func preferredBreak(in text: String, start: String.Index, proposedEnd: String.Index) -> String.Index {
        guard proposedEnd < text.endIndex else { return text.endIndex }
        let searchStart = text.index(proposedEnd, offsetBy: -min(180, text.distance(from: start, to: proposedEnd)))
        let window = text[searchStart..<proposedEnd]
        if let breakIndex = window.lastIndex(where: { ".!?。！？\n".contains($0) }) {
            return text.index(after: breakIndex)
        }
        return proposedEnd
    }

    private static func tokenFrequencies(in text: String) -> [String: Int] {
        let lowered = text.lowercased()
        let words = lowered
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { $0.count >= 2 && $0.count <= 40 }
        let han = lowered.filter { character in
            character.unicodeScalars.contains { scalar in (0x4E00...0x9FFF).contains(scalar.value) }
        }
        var result: [String: Int] = [:]
        for word in words { result[word, default: 0] += 1 }
        let chars = Array(han)
        for index in chars.indices {
            result[String(chars[index]), default: 0] += 1
            if index + 1 < chars.count { result[String(chars[index...index + 1]), default: 0] += 1 }
        }
        return result
    }

    private static func removingRepeatedBoundary(previous: String, current: String) -> String {
        let maximum = min(260, min(previous.count, current.count))
        guard maximum >= 24 else { return current }
        for length in stride(from: maximum, through: 24, by: -1) {
            if previous.suffix(length) == current.prefix(length) {
                return String(current.dropFirst(length)).trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        return current
    }

    private static func prefix(_ text: String, fittingTokenBudget budget: Int) -> String {
        guard estimatedTokenCount(text) > budget else { return text }
        var low = 1
        var high = text.count
        while low < high {
            let middle = (low + high + 1) / 2
            if estimatedTokenCount(String(text.prefix(middle))) <= budget { low = middle } else { high = middle - 1 }
        }
        let candidate = String(text.prefix(low))
        if let boundary = candidate.lastIndex(where: { "。！？.!?；;\n".contains($0) }),
           candidate.distance(from: candidate.startIndex, to: boundary) >= low / 2 {
            return String(candidate[...boundary]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return candidate.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
