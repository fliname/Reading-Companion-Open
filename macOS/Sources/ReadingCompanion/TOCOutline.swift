import Foundation

enum PrintedPageStyle: String, Codable, Hashable, CaseIterable {
    case arabic
    case roman
}

struct TOCSourceEntry: Codable, Hashable {
    var title: String
    var printedPage: Int?
    var level: Int
    var pageStyle: PrintedPageStyle? = nil
}

enum TOCPageDetector {
    static func locate(in pages: [PageText]) -> [Int] {
        guard !pages.isEmpty else { return [] }
        let profiles = pages.map(profile)
        let explicitSeeds = profiles.enumerated().filter { $0.element.hasContentsHeading }
        let seedPosition: Int?
        if let best = explicitSeeds.max(by: {
            seedScore($0.element, pageCount: pages.count) < seedScore($1.element, pageCount: pages.count)
        }) {
            // “目录 / Contents / 目次”本身就是强证据，不再要求页码必须与标题处于同一 OCR 行。
            seedPosition = best.offset
        } else {
            // OCR 漏掉目录标题时，依靠“短条目 + 密集尾页码/独立页码列 + 章节行”的组合兜底。
            // 限制在前半本，避免将书末索引和参考文献误判为目录。
            seedPosition = profiles.enumerated()
                .filter {
                    $0.element.isStrongTOCPage &&
                    $0.element.pageIndex < max(pages.count / 2, 1)
                }
                .max(by: {
                    seedScore($0.element, pageCount: pages.count) < seedScore($1.element, pageCount: pages.count)
                })?
                .offset
        }
        guard let seedPosition else { return [] }
        return expand(from: seedPosition, profiles: profiles)
    }

    static func locate(startingAt pageIndex: Int, in pages: [PageText]) -> [Int] {
        let profiles = pages.map(profile)
        guard let seedPosition = profiles.firstIndex(where: { $0.pageIndex == pageIndex }) else { return [] }
        return expand(from: seedPosition, profiles: profiles)
    }

    /// Finds printed directory pages from the pasted entries themselves, so
    /// manual page calibration never depends on a user-entered PDF page range.
    static func inferManualPages(for entries: [TOCSourceEntry], in pages: [PageText]) -> [Int] {
        guard !entries.isEmpty, !pages.isEmpty else { return [] }
        var selected = Set(locate(in: pages))
        let profiles = Dictionary(uniqueKeysWithValues: pages.map { ($0.pageIndex, profile($0)) })
        var matchesByPage: [Int: Int] = [:]
        let earlyLimit = min(pages.count, max(80, Int(ceil(Double(pages.count) * 0.35))))

        for page in pages {
            let pageText = TOCInputNormalizer.comparisonKey(page.text)
            let matches = entries.reduce(into: 0) { count, entry in
                let alternatives = [
                    TOCInputNormalizer.comparisonKey(entry.title),
                    TOCInputNormalizer.comparisonKey(titleWithoutSequence(entry.title))
                ].filter { $0.count >= 2 }
                if alternatives.contains(where: pageText.contains) { count += 1 }
            }
            matchesByPage[page.pageIndex] = matches
            guard let pageProfile = profiles[page.pageIndex] else { continue }
            let early = page.pageIndex < earlyLimit
            let enoughCoverage = early && (entries.count <= 2
                ? matches == entries.count && matches >= 2
                : matches >= min(3, entries.count))
            let pairedDirectoryLines = matches >= 2 && (
                pageProfile.hasContentsHeading ||
                (early && (pageProfile.pageNumberSignalCount >= 2 || pageProfile.entryCount >= 2))
            )
            if enoughCoverage || pairedDirectoryLines { selected.insert(page.pageIndex) }
        }

        var changed = true
        while changed {
            changed = false
            for page in pages where !selected.contains(page.pageIndex) {
                let adjacent = selected.contains(page.pageIndex - 1) || selected.contains(page.pageIndex + 1)
                guard adjacent, matchesByPage[page.pageIndex, default: 0] >= 1,
                      let pageProfile = profiles[page.pageIndex],
                      pageProfile.pageNumberSignalCount >= 1 || pageProfile.entryCount >= 1 else { continue }
                selected.insert(page.pageIndex)
                changed = true
            }
        }
        return selected.sorted()
    }

    private static func titleWithoutSequence(_ title: String) -> String {
        title.replacingOccurrences(
            of: #"^(?:(?:第\s*[0-9一二三四五六七八九十百千零〇两]+\s*[篇部卷章节])|(?:chapter|part|section)\s+\S+|(?:\d+(?:\.\d+)*))[\s、.．:：\-]*"#,
            with: "",
            options: [.regularExpression, .caseInsensitive]
        )
    }

    private static func expand(from seedPosition: Int, profiles: [Profile]) -> [Int] {
        var selectedPositions = Set([seedPosition])
        var cursor = seedPosition - 1
        while cursor >= 0, seedPosition - cursor <= 4 {
            let candidate = profiles[cursor]
            if candidate.isContinuation {
                selectedPositions.insert(cursor)
            } else {
                break
            }
            cursor -= 1
        }

        cursor = seedPosition + 1
        var misses = 0
        while cursor < profiles.count, cursor - seedPosition <= 20, misses < 2 {
            let candidate = profiles[cursor]
            if candidate.isContinuation {
                selectedPositions.insert(cursor)
                misses = 0
            } else {
                misses += 1
            }
            cursor += 1
        }
        guard let first = selectedPositions.min(), let last = selectedPositions.max() else { return [] }
        // 若中间某页 OCR 信号较弱，仍保留在连续目录页范围内，避免漏交整页内容。
        return (first...last).map { profiles[$0].pageIndex }
    }

    private struct Profile {
        var pageIndex: Int
        var hasContentsHeading: Bool
        var entryCount: Int
        var dotLeaderCount: Int
        var pageNumberSignalCount: Int
        var structuralTitleCount: Int
        var shortLineRatio: Double
        var nonEmptyLineCount: Int

        var isContinuation: Bool {
            hasContentsHeading ||
            dotLeaderCount >= 2 ||
            pageNumberSignalCount >= 4 ||
            structuralTitleCount >= 4 ||
            (entryCount >= 2 && shortLineRatio >= 0.55)
        }

        var isStrongTOCPage: Bool {
            (dotLeaderCount >= 3 && entryCount >= 3) ||
            (pageNumberSignalCount >= 6 && shortLineRatio >= 0.60) ||
            (structuralTitleCount >= 4 && pageNumberSignalCount >= 3)
        }
    }

    private static func profile(_ page: PageText) -> Profile {
        let lines = page.text.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let headingPattern = #"^(?:(?:目\s*[录錄次])(?:\s*contents)?|contents|table\s+of\s+contents|sommaire|inhaltsverzeichnis|índice|indice|目録)(?:\s+[0-9ivxlcdm]+)?$"#
        let hasHeading = lines.prefix(30).contains {
            $0.folding(options: [.diacriticInsensitive, .widthInsensitive], locale: .current)
                .range(of: headingPattern, options: [.regularExpression, .caseInsensitive]) != nil
        }
        let entryPattern = #"^.{2,160}?(?:\.{2,}|…{1,}|·{2,}|\s{2,})\s*(?:[0-9]{1,4}|[ivxlcdm]{1,10})\s*$"#
        let compactEntryPattern = #"^(?:第.{1,20}[篇部卷章节]|chapter\s+\S+|part\s+\S+|[0-9]{1,3}(?:\.[0-9]{1,3}){0,3}\s+\S).{1,120}\s+[0-9]{1,4}\s*$"#
        let sameLineEntryCount = lines.filter {
            $0.range(of: entryPattern, options: [.regularExpression, .caseInsensitive]) != nil ||
            $0.range(of: compactEntryPattern, options: [.regularExpression, .caseInsensitive]) != nil
        }.count
        let structuralTitleCount = lines.filter {
            $0.range(
                of: #"^(?:第.{1,60}[篇部卷章节]|chapter\s+\S+|part\s+\S+|[0-9]{1,3}(?:\.[0-9]{1,3}){0,3}\s+\S)"#,
                options: [.regularExpression, .caseInsensitive]
            ) != nil
        }.count
        let numberOnlyCount = lines.filter {
            $0.range(of: #"^[\[（(]?\s*(?:[0-9]{1,4}|[ivxlcdm]{1,10})\s*[\]）)]?$"#, options: [.regularExpression, .caseInsensitive]) != nil
        }.count
        let trailingPageCount = lines.filter {
            $0.count <= 180 && $0.range(
                of: #"(?:\.{1,}|…{1,}|·{1,}|[-—:/／]|\s)\s*(?:[0-9]{1,4}|[ivxlcdm]{1,10})\s*$"#,
                options: [.regularExpression, .caseInsensitive]
            ) != nil
        }.count
        let pairedSplitEntries = min(structuralTitleCount, numberOnlyCount)
        let entryCount = max(max(sameLineEntryCount, pairedSplitEntries), trailingPageCount)
        let dotLeaderCount = lines.filter {
            $0.range(of: #"(?:\.{2,}|…{1,}|·{2,})\s*(?:[0-9]{1,4}|[ivxlcdm]{1,10})\s*$"#,
                       options: [.regularExpression, .caseInsensitive]) != nil
        }.count
        let shortLineCount = lines.filter { (2...100).contains($0.count) }.count
        let shortLineRatio = lines.isEmpty ? 0 : Double(shortLineCount) / Double(lines.count)
        return Profile(
            pageIndex: page.pageIndex,
            hasContentsHeading: hasHeading,
            entryCount: entryCount,
            dotLeaderCount: dotLeaderCount,
            pageNumberSignalCount: max(sameLineEntryCount, trailingPageCount) + numberOnlyCount,
            structuralTitleCount: structuralTitleCount,
            shortLineRatio: shortLineRatio,
            nonEmptyLineCount: lines.count
        )
    }

    private static func seedScore(_ profile: Profile, pageCount: Int) -> Double {
        let earlyBonus = 4.0 * (1.0 - Double(profile.pageIndex) / Double(max(pageCount, 1)))
        return (profile.hasContentsHeading ? 20 : 0)
            + Double(profile.entryCount * 3)
            + Double(profile.dotLeaderCount * 2)
            + Double(profile.pageNumberSignalCount)
            + Double(profile.structuralTitleCount)
            + profile.shortLineRatio * 3
            + earlyBonus
    }
}

enum TOCPageTextBuilder {
    static func build(pages: [PageText], pageIndices: [Int]) -> String {
        let byIndex = Dictionary(uniqueKeysWithValues: pages.map { ($0.pageIndex, $0) })
        return pageIndices.compactMap { index in
            guard let page = byIndex[index] else { return nil }
            let text = page.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }
            return "[目录页 · PDF 物理页 \(index + 1)]\n\(text)"
        }.joined(separator: "\n\n--- 下一目录页 ---\n\n")
    }
}

/// Canonicalizes OCR/PDF text before either the automatic or manual TOC
/// parser interprets whitespace and numbers. Structural parsing must happen
/// after this stage: OCR often emits one printed page number as `1 9`, and a
/// vertical `目录` heading as `目`/`录` prefixes on the first two entries.
enum TOCInputNormalizer {
    static func normalize(_ source: String, legacyAutomatic: Bool = false) -> String {
        var compatibility = source.precomposedStringWithCompatibilityMapping
            .replacingOccurrences(of: "\u{00A0}", with: " ")
            .replacingOccurrences(of: "\u{200B}", with: "")
            .replacingOccurrences(of: "\u{2060}", with: "")
        if !legacyAutomatic {
            compatibility = compatibility
            .replacingOccurrences(
                of: #"(?i)\b(part|chapter|section)(?=[0-9ivxlcdm]+(?:\s|$|[\p{Han}]))"#,
                with: "$1 ",
                options: .regularExpression
            )
            .replacingOccurrences(
                of: #"(?im)^\s*c\s+ontents\s*$"#,
                with: "Contents",
                options: .regularExpression
            )
        }
        var lines = compatibility.components(separatedBy: .newlines)
            .map(joinSpacedTrailingPageDigits)
        stripVerticalContentsHeading(from: &lines)
        stripFlattenedVerticalContentsHeading(from: &lines)
        return lines.joined(separator: "\n")
    }

    static func cleanEntryTitle(_ source: String, legacyAutomatic: Bool = false) -> String {
        var title = OCRTextNormalizer.normalize(source.precomposedStringWithCompatibilityMapping)
            .replacingOccurrences(of: #"\s*([•·])\s*"#, with: "$1", options: .regularExpression)
            .replacingOccurrences(of: #"[.·…\s]+$"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        // OCR normalization deliberately removes artificial CJK spacing. A
        // TOC sequence marker is structural, however, so restore one readable
        // boundary between the leading sequence and its title.
        let sequencePatterns = [
            #"^(第\s*[0-9一二三四五六七八九十百千零〇两]+\s*(?:部分|篇|部|卷|章|节))(?=\S)"#,
            #"^([上中下前后](?:篇|部|卷))(?=\S)"#,
            #"^([0-9]{1,3}(?:\.[0-9]{1,3})+)(?=[\p{Han}A-Za-z])"#,
            #"^([0-9]{1,3})(?=[\p{Han}A-Za-z])"#,
            #"^([0-9一二三四五六七八九十百千零〇两]+[、．。)）])(?=\S)"#
        ]
        for pattern in sequencePatterns {
            title = title.replacingOccurrences(
                of: pattern,
                with: "$1 ",
                options: .regularExpression
            )
        }
        if !legacyAutomatic {
            title = title.replacingOccurrences(
                of: #"^(part|chapter|section)\s*([0-9ivxlcdm]+)\s*(?=\S)"#,
                with: "$1 $2 ",
                options: [.regularExpression, .caseInsensitive]
            )
        }
        return title
    }

    static func comparisonKey(_ text: String) -> String {
        text.precomposedStringWithCompatibilityMapping.lowercased().unicodeScalars.filter {
            CharacterSet.alphanumerics.contains($0) || (0x4E00...0x9FFF).contains($0.value)
        }.map(String.init).joined()
    }

    private static func joinSpacedTrailingPageDigits(_ line: String) -> String {
        guard let expression = try? NSRegularExpression(
            pattern: #"(?<![0-9])((?:[0-9][ \t\x{3000}]+){1,3}[0-9])[ \t\x{3000}]*$"#
        ) else { return line }
        let fullRange = NSRange(line.startIndex..<line.endIndex, in: line)
        guard let match = expression.firstMatch(in: line, range: fullRange),
              let range = Range(match.range(at: 1), in: line) else { return line }
        let joined = line[range].filter(\.isNumber)
        var result = line
        result.replaceSubrange(range, with: joined)
        return result
    }

    private static func stripVerticalContentsHeading(from lines: inout [String]) {
        let meaningful = lines.indices.filter {
            !lines[$0].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        guard meaningful.count >= 2 else { return }
        let first = meaningful[0]
        let second = meaningful[1]
        guard leadingToken(in: lines[first]) == "目",
              ["录", "錄"].contains(leadingToken(in: lines[second])) else { return }
        lines[first] = removingLeadingToken(from: lines[first])
        lines[second] = removingLeadingToken(from: lines[second])
    }

    /// Some searchable PDFs flatten the whole printed TOC page to one line,
    /// leaving the vertical heading as `目 first-entry /001 录 second-entry
    /// /019`. Remove only those standalone heading glyphs; the surrounding
    /// page-number pattern prevents ordinary uses of 目/录 from being changed.
    private static func stripFlattenedVerticalContentsHeading(from lines: inout [String]) {
        for index in lines.indices {
            let original = lines[index]
            var line = original
            line = line.replacingOccurrences(
                of: #"^\s*目\s+(?=\S.{0,160}?(?:[/／]|\.{1,}|…|·)\s*[0-9]{1,4}(?:\s|$))"#,
                with: "",
                options: .regularExpression
            )
            line = line.replacingOccurrences(
                of: #"(?<=[0-9])\s+[录錄]\s+(?=\S.{0,160}?(?:[/／]|\.{1,}|…|·)\s*[0-9]{1,4}(?:\s|$))"#,
                with: " ",
                options: .regularExpression
            )
            if line != original {
                // After removing the vertical 目/录 glyphs, recover the line
                // boundaries that a searchable PDF flattened away.
                var previous: String
                repeat {
                    previous = line
                    line = line.replacingOccurrences(
                        of: #"((?:[/／]|(?<![0-9])\.)\s*[0-9]{1,4})\s+(?=\S)"#,
                        with: "$1\n",
                        options: .regularExpression
                    )
                } while line != previous
            }
            lines[index] = line
        }
    }

    private static func leadingToken(in line: String) -> String {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.first.map(String.init) ?? ""
    }

    private static func removingLeadingToken(from line: String) -> String {
        let indentation = line.prefix { $0 == " " || $0 == "\t" || $0 == "\u{3000}" }
        var body = line.dropFirst(indentation.count)
        guard !body.isEmpty else { return line }
        body.removeFirst()
        return String(indentation) + body.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

enum TOCTextParser {
    static func parse(_ source: String, legacyAutomatic: Bool = false) -> [TOCSourceEntry] {
        let cleanedLines = TOCInputNormalizer.normalize(source, legacyAutomatic: legacyAutomatic)
            .components(separatedBy: .newlines)
            .map(cleanLine)
            .flatMap(splitCombinedEntries)
            .filter { !$0.isEmpty && !isNoise($0) }
        let lines = pairDetachedPageColumns(in: cleanedLines, legacyAutomatic: legacyAutomatic)

        if legacyAutomatic {
            return parseLegacyAutomatic(lines)
        }

        var pendingTitles: [String] = []
        var pendingLeadingPage: (value: Int, style: PrintedPageStyle)?
        var lastParsedPage: Int?
        var parsed: [(title: String, page: Int?, style: PrintedPageStyle?)] = []
        for line in lines {
            if isUnpagedDivisionTitle(line) {
                // Book titles and stray “Contents” fragments that precede the
                // first real part have no page and must not steal a later
                // detached page number from the next numbered entry.
                pendingTitles.removeAll()
                pendingLeadingPage = nil
                parsed.append((line, nil, nil))
                continue
            }
            if let page = pageOnly(line) {
                if !pendingTitles.isEmpty {
                    parsed.append((pendingTitles.removeLast(), page.value, page.style))
                    lastParsedPage = page.value
                } else if lastParsedPage == nil || page.value >= lastParsedPage! {
                    // Some OCR engines emit the right-aligned page number a
                    // few pixels above its title, so it arrives first. Keep a
                    // single plausible leading page; a decreasing number is
                    // usually the printed footer of the TOC page itself.
                    pendingLeadingPage = page
                }
                continue
            }
            if let (titleFragment, page) = titleAndPage(line) {
                pendingLeadingPage = nil
                var title = titleFragment
                if !looksLikeEntryStart(titleFragment), let continuationOf = pendingTitles.last {
                    title = continuationOf + " " + titleFragment
                    pendingTitles.removeLast()
                }
                parsed.append((title, page.value, page.style))
                lastParsedPage = page.value
                continue
            }
            if let leadingPage = pendingLeadingPage,
               looksLikeEntryStart(line) || pendingTitles.isEmpty {
                parsed.append((line, leadingPage.value, leadingPage.style))
                lastParsedPage = leadingPage.value
                pendingLeadingPage = nil
                continue
            }
            if looksLikeEntryStart(line) || pendingTitles.isEmpty {
                pendingTitles.append(line)
            } else if line.count <= 90, let last = pendingTitles.indices.last {
                pendingTitles[last] += " " + line
            } else {
                pendingTitles.append(line)
            }
        }
        parsed.append(contentsOf: pendingTitles.map { ($0, nil, nil) })
        parsed = inheritingPagesForDivisions(in: parsed)

        let hasPartLevel = parsed.contains { rawLevel(for: $0.title, hasPartLevel: true) == 0 && isPart($0.title) }
        var seen = Set<String>()
        return parsed.compactMap { item in
            let title = cleanTitle(item.title)
            guard title.count >= 2, title.count <= 180 else { return nil }
            guard item.page != nil || looksLikeEntryStart(title) else { return nil }
            let key = normalize(title) + "|" + (item.page.map(String.init) ?? "nil")
            guard seen.insert(key).inserted else { return nil }
            return TOCSourceEntry(
                title: title,
                printedPage: item.page,
                level: rawLevel(for: title, hasPartLevel: hasPartLevel),
                pageStyle: item.style
            )
        }
    }

    private static func parseLegacyAutomatic(_ lines: [String]) -> [TOCSourceEntry] {
        var pendingTitles: [String] = []
        var parsed: [(title: String, page: Int?, style: PrintedPageStyle?)] = []
        for line in lines {
            if isUnpagedDivisionTitle(line, legacyAutomatic: true) {
                parsed.append((line, nil, nil))
                continue
            }
            if let page = pageOnly(line) {
                guard !pendingTitles.isEmpty else { continue }
                parsed.append((pendingTitles.removeFirst(), page.value, page.style))
                continue
            }
            if let (titleFragment, page) = titleAndPage(line) {
                var title = titleFragment
                if !looksLikeEntryStart(titleFragment), let continuationOf = pendingTitles.last {
                    title = continuationOf + " " + titleFragment
                    pendingTitles.removeLast()
                }
                parsed.append((title, page.value, page.style))
                continue
            }
            if looksLikeEntryStart(line) || pendingTitles.isEmpty {
                pendingTitles.append(line)
            } else if line.count <= 90, let last = pendingTitles.indices.last {
                pendingTitles[last] += " " + line
            } else {
                pendingTitles.append(line)
            }
        }
        parsed.append(contentsOf: pendingTitles.map { ($0, nil, nil) })
        parsed = inheritingPagesForDivisions(in: parsed, legacyAutomatic: true)

        let hasPartLevel = parsed.contains { rawLevel(for: $0.title, hasPartLevel: true) == 0 && isPart($0.title) }
        var seen = Set<String>()
        return parsed.compactMap { item in
            let title = cleanTitle(item.title, legacyAutomatic: true)
            guard title.count >= 2, title.count <= 180 else { return nil }
            guard item.page != nil || looksLikeEntryStart(title) else { return nil }
            let key = normalize(title) + "|" + (item.page.map(String.init) ?? "nil")
            guard seen.insert(key).inserted else { return nil }
            return TOCSourceEntry(
                title: title,
                printedPage: item.page,
                level: rawLevel(for: title, hasPartLevel: hasPartLevel),
                pageStyle: item.style
            )
        }
    }

    private static func cleanLine(_ line: String) -> String {
        let halfWidth = line.applyingTransform(.fullwidthToHalfwidth, reverse: false) ?? line
        let withoutHeading = halfWidth.replacingOccurrences(
            of: #"^\s*(?:目\s*[录錄次]|contents|table\s+of\s+contents)\s*(?=\S)"#,
            with: "",
            options: [.regularExpression, .caseInsensitive]
        )
        return withoutHeading
            .replacingOccurrences(
                of: #"[／/]+\s*(?=(?:p\.?\s*)?[(（\[【{]?\s*(?:[0-9]{1,4}|[ivxlcdm]{1,10})\s*[)）\]】}]?\s*$)"#,
                with: " ",
                options: [.regularExpression, .caseInsensitive]
            )
            .replacingOccurrences(of: #"^[•●▪◆◇※*#]+\s*"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"[\t ]+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Layout-aware OCR may emit the title column first and the page-number
    /// column afterwards. Pair equal adjacent runs before continuation-line
    /// joining can collapse all titles into one entry.
    private static func pairDetachedPageColumns(
        in lines: [String],
        legacyAutomatic: Bool = false
    ) -> [String] {
        guard lines.count >= 4 else { return lines }
        var result = lines
        var index = 0
        while index < result.count {
            guard pageOnly(result[index]) != nil else {
                index += 1
                continue
            }
            let pageStart = index
            var pageEnd = pageStart
            while pageEnd < result.count, pageOnly(result[pageEnd]) != nil { pageEnd += 1 }
            let pageCount = pageEnd - pageStart
            guard pageCount >= 2 else {
                index = pageEnd
                continue
            }
            var titleStart = pageStart
            var ordinaryTitleCount = 0
            var validBlock = true
            while titleStart > 0, ordinaryTitleCount < pageCount {
                titleStart -= 1
                let candidate = result[titleStart]
                guard pageOnly(candidate) == nil, titleAndPage(candidate) == nil,
                      (2...180).contains(candidate.count) else {
                    validBlock = false
                    break
                }
                if !isUnpagedDivisionTitle(candidate, legacyAutomatic: legacyAutomatic) { ordinaryTitleCount += 1 }
            }
            guard validBlock, ordinaryTitleCount == pageCount else {
                index = pageEnd
                continue
            }
            let titles = Array(result[titleStart..<pageStart])
            let pages = Array(result[pageStart..<pageEnd])
            let areStandaloneTitles = titles.allSatisfy {
                pageOnly($0) == nil && titleAndPage($0) == nil && (2...180).contains($0.count)
            }
            guard areStandaloneTitles else {
                index = pageEnd
                continue
            }
            var pageIndex = 0
            let paired = titles.map { title -> String in
                guard !isUnpagedDivisionTitle(title, legacyAutomatic: legacyAutomatic) else { return title }
                defer { pageIndex += 1 }
                return "\(title) \(pages[pageIndex])"
            }
            result.replaceSubrange(titleStart..<pageEnd, with: paired)
            index = titleStart + paired.count
        }
        return result
    }

    /// PDF text layers and OCR occasionally flatten two columns into one physical
    /// line ("first entry 1 second entry 12"). Split at strong TOC entry starts
    /// before the ordinary continuation-line state machine sees the text.
    private static func splitCombinedEntries(_ line: String) -> [String] {
        guard line.count >= 6 else { return [line] }
        let startPattern = #"(?i)(?<![\p{Han}A-Za-z])(?:第\s*[0-9一二三四五六七八九十百千零〇两]+\s*[篇部卷章节]|chapter\s+(?:[0-9ivxlcdm]+)|part\s+(?:[0-9ivxlcdm]+)|section\s+(?:[0-9]+(?:\.[0-9]+)*)|[0-9]{1,3}(?:\.[0-9]{1,3})+\s+(?=\S)|序言|前言|引言|导言|导论|绪论|结语|后记|附录|参考文献|索引)"#
        guard let expression = try? NSRegularExpression(pattern: startPattern),
              expression.numberOfMatches(in: line, range: NSRange(line.startIndex..<line.endIndex, in: line)) >= 2 else {
            return splitAfterCompletedEntry(in: line)
        }
        let matches = expression.matches(in: line, range: NSRange(line.startIndex..<line.endIndex, in: line))
        var boundaries = matches.compactMap { Range($0.range, in: line)?.lowerBound }
        if let first = boundaries.first, first > line.startIndex {
            let prefix = String(line[..<first]).trimmingCharacters(in: .whitespacesAndNewlines)
            if !prefix.isEmpty, !isNoise(prefix) { boundaries.insert(line.startIndex, at: 0) }
        }
        boundaries.append(line.endIndex)
        return zip(boundaries, boundaries.dropFirst()).compactMap { start, end in
            let fragment = String(line[start..<end]).trimmingCharacters(in: .whitespacesAndNewlines)
            return fragment.isEmpty ? nil : fragment
        }
    }

    private static func splitAfterCompletedEntry(in line: String) -> [String] {
        let namedBoundary = #"(?i)(?<=[0-9ivxlcdm])\s+(?=(?:序言|前言|引言|导言|导论|绪论|结语|后记|附录|参考文献|索引)(?:\s|。|$))"#
        var marked = line.replacingOccurrences(of: namedBoundary, with: "\n", options: [.regularExpression, .caseInsensitive])
        // Some PDF text layers flatten an entire row from two columns. Dot
        // leaders/slashes make the first page number a trustworthy boundary
        // even when the second title has no “第一章/1.1” prefix.
        let leaderBoundary = #"(?i)(((?:(?<![0-9])\.|\.{2,}|…+|·{2,}|[/／]))\s*(?:[0-9]{1,4}|[ivxlcdm]{1,10}))\s+(?=\S.{1,160}?(?:(?<![0-9])\.|\.{2,}|…+|·{2,}|[/／])\s*(?:[0-9]{1,4}|[ivxlcdm]{1,10})\s*$)"#
        marked = marked.replacingOccurrences(of: leaderBoundary, with: "$1\n", options: [.regularExpression, .caseInsensitive])
        return marked.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    private static func isNoise(_ line: String) -> Bool {
        if line.hasPrefix("[目录页 · PDF 物理页") || line.hasPrefix("--- 下一目录页") { return true }
        return line.range(
            of: #"^(?:目\s*[录錄次]|contents|table of contents|目録)$"#,
            options: [.regularExpression, .caseInsensitive]
        ) != nil
    }

    private static func titleAndPage(_ line: String) -> (String, (value: Int, style: PrintedPageStyle))? {
        let pattern = #"^(.{1,180}?)(?:(?<![0-9])\.|\.{2,}|…+|·{2,}|[/／]+|\s{2,}|[-—–]\s*|\s+)(?:p\.?\s*)?[(（\[【{]?\s*([0-9]{1,4}|[ivxlcdm]{1,10})\s*[)）\]】}]?\s*$"#
        guard let expression = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
              let match = expression.firstMatch(in: line, range: NSRange(line.startIndex..<line.endIndex, in: line)),
              let titleRange = Range(match.range(at: 1), in: line),
              let pageRange = Range(match.range(at: 2), in: line),
              let page = parsePage(String(line[pageRange])) else { return nil }
        let title = String(line[titleRange]).trimmingCharacters(in: .whitespacesAndNewlines)
        return title.isEmpty ? nil : (title, page)
    }

    private static func pageOnly(_ line: String) -> (value: Int, style: PrintedPageStyle)? {
        guard line.range(
            of: #"^(?:[/／]\s*)?(?:p\.?\s*)?(?:[/／]\s*)?[(（\[【{]?\s*(?:[0-9]{1,4}|[ivxlcdm]{1,10})\s*[)）\]】}]?$"#,
            options: [.regularExpression, .caseInsensitive]
        ) != nil else { return nil }
        let token = line
            .replacingOccurrences(of: #"(?i)^[/／]?\s*p\.?\s*[/／]?\s*"#, with: "", options: .regularExpression)
        return parsePage(token)
    }

    private static func parsePage(_ token: String) -> (value: Int, style: PrintedPageStyle)? {
        let cleaned = token
            .lowercased()
            .trimmingCharacters(in: CharacterSet(charactersIn: "()[]{}（）【】,，、:：/／. "))
            .replacingOccurrences(of: #"^(?:p\.?\s*)"#, with: "", options: [.regularExpression, .caseInsensitive])
        if let value = Int(cleaned), value > 0 { return (value, .arabic) }
        let values: [Character: Int] = ["i": 1, "v": 5, "x": 10, "l": 50, "c": 100, "d": 500, "m": 1_000]
        let characters = Array(cleaned)
        guard !characters.isEmpty, characters.allSatisfy({ values[$0] != nil }) else { return nil }
        var total = 0
        for index in characters.indices {
            let value = values[characters[index]]!
            if index + 1 < characters.count, value < values[characters[index + 1]]! { total -= value }
            else { total += value }
        }
        return total > 0 ? (total, .roman) : nil
    }

    private static func looksLikeEntryStart(_ title: String) -> Bool {
        title.range(
            of: #"^(?:第.{1,30}(?:部分|篇|部|卷|章|节)|[上中下前后](?:篇|部|卷)|chapter\s+\S+|part\s+\S+|(?:[0-9]+\.)*[0-9]+\s+|序言|前言|引言|导言|导论|绪论|结语|后记|附录|参考文献|索引)"#,
            options: [.regularExpression, .caseInsensitive]
        ) != nil
    }

    private static func isPart(_ title: String) -> Bool {
        title.range(of: #"^(?:第.{1,20}(?:部分|篇|部|卷)|[上中下前后](?:篇|部|卷)|part\s+\S+)"#, options: [.regularExpression, .caseInsensitive]) != nil
    }

    private static func isUnpagedDivisionTitle(_ title: String, legacyAutomatic: Bool = false) -> Bool {
        isPart(TOCInputNormalizer.cleanEntryTitle(title, legacyAutomatic: legacyAutomatic)) && titleAndPage(title) == nil
    }

    private static func inheritingPagesForDivisions(
        in parsed: [(title: String, page: Int?, style: PrintedPageStyle?)],
        legacyAutomatic: Bool = false
    ) -> [(title: String, page: Int?, style: PrintedPageStyle?)] {
        var result = parsed
        var nextPage: (value: Int, style: PrintedPageStyle?)?
        for index in result.indices.reversed() {
            if let page = result[index].page {
                nextPage = (page, result[index].style)
            } else if isUnpagedDivisionTitle(result[index].title, legacyAutomatic: legacyAutomatic), let nextPage {
                result[index].page = nextPage.value
                result[index].style = nextPage.style
            }
        }
        return result
    }

    private static func rawLevel(for title: String, hasPartLevel: Bool) -> Int {
        if isPart(title) { return 0 }
        if title.range(of: #"^(?:第.{1,30}章|chapter\s+\S+)"#, options: [.regularExpression, .caseInsensitive]) != nil {
            return hasPartLevel ? 1 : 0
        }
        if title.range(of: #"^第.{1,30}节"#, options: .regularExpression) != nil {
            return hasPartLevel ? 2 : 1
        }
        if let match = title.range(of: #"^[0-9]+(?:\.[0-9]+)*"#, options: .regularExpression) {
            return min(title[match].filter { $0 == "." }.count, 5)
        }
        return 0
    }

    private static func cleanTitle(_ source: String, legacyAutomatic: Bool = false) -> String {
        TOCInputNormalizer.cleanEntryTitle(source, legacyAutomatic: legacyAutomatic)
    }

    private static func normalize(_ text: String) -> String {
        TOCInputNormalizer.comparisonKey(text)
    }
}

/// Parser for the deliberately simple format used by the manual paste sheet.
/// Unlike OCR parsing, every non-empty line is one entry and leading spaces are
/// meaningful: zero spaces is level 0, one space is level 1, and so on.
enum ManualTOCTextParser {
    private struct Candidate {
        var originalIndex: Int
        var level: Int
        var tokens: [String]
        var numberIndices: [Int]
    }

    private struct ParsedLine {
        var originalIndex: Int
        var entry: TOCSourceEntry
        var orderKey: [Int]?
    }

    static func parse(_ source: String, legacyPageParsing: Bool = false) -> [TOCSourceEntry] {
        let candidates = TOCInputNormalizer.normalize(source, legacyAutomatic: legacyPageParsing)
            .components(separatedBy: .newlines)
            .enumerated()
            .compactMap { makeCandidate(index: $0.offset, line: $0.element, legacyPageParsing: legacyPageParsing) }
        guard !candidates.isEmpty else { return [] }

        let sequencePosition = preferredSequencePosition(in: candidates)
        let parsed = candidates.compactMap { parse($0, sequencePosition: sequencePosition, legacyPageParsing: legacyPageParsing) }
        return TOCHierarchyInferer.apply(to: reorderNumberedEntries(parsed).map(\.entry))
    }

    private static func makeCandidate(index: Int, line: String, legacyPageParsing: Bool) -> Candidate? {
        let halfWidth = line.applyingTransform(.fullwidthToHalfwidth, reverse: false) ?? line
        let level = leadingIndentLevel(in: halfWidth)
        let rawBody = halfWidth.drop(while: { $0 == " " || $0 == "\t" || $0 == "\u{3000}" })
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let body = separateAttachedFields(in: rawBody)
        guard !body.isEmpty, !isHeading(String(body)) else { return nil }

        let separated = body
            .replacingOccurrences(
                of: #"(?<=[^0-9pP])\.(?=\s*[0-9]{1,4}\s*$)"#,
                with: " ",
                options: .regularExpression
            )
            .replacingOccurrences(of: #"(?:\.{2,}|…+|·{2,}|\||[/／]+)"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"^[•●▪◆◇※*#]+\s*"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        let tokens = separated.split(separator: " ").map(String.init)
        guard tokens.count >= 2 else { return nil }
        let numberIndices = tokens.indices.filter { pageValue(from: tokens[$0]) != nil }
        guard !numberIndices.isEmpty else { return nil }
        if !legacyPageParsing,
           numberIndices.count == 1,
           numberIndices[0] == 1,
           tokens.count > 2,
           ["part", "chapter", "section"].contains(tokens[0].lowercased()) {
            return nil
        }
        return Candidate(originalIndex: index, level: min(level, 5), tokens: tokens, numberIndices: numberIndices)
    }

    private static func separateAttachedFields(in source: String) -> String {
        var result = source
        result = result.replacingOccurrences(
            of: #"(?<=\S)([(（\[【{]\s*(?:[0-9]{1,4}|[ivxlcdm]{1,10})\s*[)）\]】}])\s*$"#,
            with: " $1",
            options: [.regularExpression, .caseInsensitive]
        )
        result = result.replacingOccurrences(
            of: #"(?<=\S)(第[0-9]{1,4}页)\s*$"#,
            with: " $1",
            options: .regularExpression
        )
        result = result.replacingOccurrences(
            of: #"(?<![pP]\.)(?<=[^0-9\s])([0-9]{1,4})\s*$"#,
            with: " $1",
            options: .regularExpression
        )
        result = result.replacingOccurrences(
            of: #"^([0-9]{1,4})(?=第|[\p{Han}A-Za-z])"#,
            with: "$1 ",
            options: .regularExpression
        )
        result = result.replacingOccurrences(
            of: #"^([0-9]+(?:\.[0-9]+)+)(?=[^0-9.\s])"#,
            with: "$1 ",
            options: .regularExpression
        )
        return result
    }

    private static func leadingIndentLevel(in line: String) -> Int {
        var count = 0
        for character in line {
            if character == " " || character == "\t" || character == "\u{3000}" { count += 1 }
            else { break }
        }
        return count
    }

    private static func preferredSequencePosition(in candidates: [Candidate]) -> Int {
        let firstValues = candidates.compactMap { candidate -> Int? in
            guard candidate.numberIndices.count >= 2,
                  let first = candidate.numberIndices.first else { return nil }
            return sequenceKey(from: candidate.tokens[first])?.first
        }
        let lastValues = candidates.compactMap { candidate -> Int? in
            guard candidate.numberIndices.count >= 2,
                  let last = candidate.numberIndices.last else { return nil }
            return sequenceKey(from: candidate.tokens[last])?.first
        }
        let firstScore = sequenceScore(firstValues)
        let lastScore = sequenceScore(lastValues)
        // When both columns look equally sequential, prefer the conventional
        // "number title page" format.
        return lastScore > firstScore + 0.15 ? -1 : 0
    }

    private static func sequenceScore(_ values: [Int]) -> Double {
        guard values.count >= 2 else { return 0 }
        let unique = Set(values)
        guard unique.count == values.count, let minimum = unique.min(), let maximum = unique.max() else { return 0 }
        let density = Double(unique.count) / Double(max(maximum - minimum + 1, 1))
        let startsNearOne = minimum <= 2 ? 0.35 : 0
        return density + startsNearOne
    }

    private static func parse(_ candidate: Candidate, sequencePosition: Int, legacyPageParsing: Bool) -> ParsedLine? {
        let numeric = candidate.numberIndices
        let pageIndex: Int
        let sequenceIndex: Int?
        if numeric.count == 1 {
            pageIndex = numeric[0]
            sequenceIndex = nil
        } else if sequencePosition == -1 {
            sequenceIndex = numeric.last
            pageIndex = numeric.first!
        } else {
            sequenceIndex = numeric.first
            pageIndex = numeric.last!
        }

        guard let page = pageValue(from: candidate.tokens[pageIndex]) else { return nil }
        var titleTokens = candidate.tokens.enumerated().compactMap { offset, token in
            (offset == pageIndex || offset == sequenceIndex) ? nil : token
        }
        guard !titleTokens.isEmpty else { return nil }

        let explicitSequence = sequenceIndex.map { candidate.tokens[$0] }
        if let explicitSequence {
            let sequence = cleanSequenceToken(explicitSequence)
            if !legacyPageParsing,
               let first = titleTokens.first?.lowercased(),
               ["chapter", "part", "section"].contains(first) {
                titleTokens.insert(sequence, at: min(1, titleTokens.count))
            } else {
                titleTokens.insert(sequence, at: 0)
            }
        }
        let title = TOCInputNormalizer.cleanEntryTitle(
            titleTokens.joined(separator: " "),
            legacyAutomatic: legacyPageParsing
        )
        guard title.count >= 2, title.count <= 180 else { return nil }

        let key = explicitSequence.flatMap(sequenceKey(from:)) ?? sequenceKeyFromTitle(title)
        return ParsedLine(
            originalIndex: candidate.originalIndex,
            entry: TOCSourceEntry(
                title: title,
                printedPage: page.value,
                level: candidate.level,
                pageStyle: page.style
            ),
            orderKey: key
        )
    }

    private static func reorderNumberedEntries(_ parsed: [ParsedLine]) -> [ParsedLine] {
        let printedPages = parsed.compactMap(\.entry.printedPage)
        if printedPages.count == parsed.count,
           zip(printedPages, printedPages.dropFirst()).allSatisfy({ $1 >= $0 }) {
            // A coherent pasted list is already in reading order. Sequence
            // numbers may share prefixes (`1`, `1.1`) and must not disturb it.
            return parsed
        }
        let numberedPositions = parsed.indices.filter { parsed[$0].orderKey != nil }
        guard numberedPositions.count >= 2 else { return parsed }
        let keys = numberedPositions.compactMap { parsed[$0].orderKey }
        guard Set(keys.map { $0.map(String.init).joined(separator: ".") }).count == keys.count else {
            return parsed
        }
        let sorted = numberedPositions.map { parsed[$0] }.sorted {
            if $0.orderKey! == $1.orderKey! { return $0.originalIndex < $1.originalIndex }
            return $0.orderKey!.lexicographicallyPrecedes($1.orderKey!)
        }
        var result = parsed
        for (position, replacement) in zip(numberedPositions, sorted) { result[position] = replacement }
        return result
    }

    private static func pageValue(from token: String) -> (value: Int, style: PrintedPageStyle)? {
        var cleaned = token.lowercased()
            .trimmingCharacters(in: CharacterSet(charactersIn: "()[]{}（）【】,，、:：/／"))
        cleaned = cleaned.replacingOccurrences(of: #"^(?:页码[:：]?|p\.?)(?=\d|[ivxlcdm])"#, with: "", options: [.regularExpression, .caseInsensitive])
        cleaned = cleaned.replacingOccurrences(of: #"^第(?=[0-9]+页$)"#, with: "", options: .regularExpression)
        cleaned = cleaned.replacingOccurrences(of: #"页$"#, with: "", options: .regularExpression)
        if let value = Int(cleaned), value > 0 { return (value, .arabic) }
        let values: [Character: Int] = ["i": 1, "v": 5, "x": 10, "l": 50, "c": 100, "d": 500, "m": 1_000]
        let characters = Array(cleaned)
        guard !characters.isEmpty, characters.allSatisfy({ values[$0] != nil }) else { return nil }
        var total = 0
        for index in characters.indices {
            let value = values[characters[index]]!
            if index + 1 < characters.count, value < values[characters[index + 1]]! { total -= value }
            else { total += value }
        }
        return total > 0 ? (total, .roman) : nil
    }

    private static func sequenceKey(from token: String) -> [Int]? {
        let cleaned = cleanSequenceToken(token).lowercased()
        if cleaned.range(of: #"^\d+(?:\.\d+)*$"#, options: .regularExpression) != nil {
            return cleaned.split(separator: ".").compactMap { Int($0) }
        }
        if let value = chineseNumber(cleaned) { return [value] }
        return nil
    }

    private static func sequenceKeyFromTitle(_ title: String) -> [Int]? {
        let patterns = [
            #"^第\s*([0-9一二三四五六七八九十百千零〇两]+)\s*[篇部卷章节]"#,
            #"^(?:chapter|part|section)\s+([0-9]+)"#,
            #"^([0-9]+(?:\.[0-9]+)*)\s*"#
        ]
        for pattern in patterns {
            guard let expression = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
                  let match = expression.firstMatch(in: title, range: NSRange(title.startIndex..<title.endIndex, in: title)),
                  let range = Range(match.range(at: 1), in: title) else { continue }
            let token = String(title[range])
            if let key = sequenceKey(from: token) { return key }
        }
        return nil
    }

    private static func cleanSequenceToken(_ token: String) -> String {
        token.trimmingCharacters(in: CharacterSet(charactersIn: "()[]{}（）【】,，、:："))
            .replacingOccurrences(of: #"[、．。]$"#, with: "", options: .regularExpression)
    }

    private static func chineseNumber(_ token: String) -> Int? {
        let digits: [Character: Int] = ["零": 0, "〇": 0, "一": 1, "二": 2, "两": 2, "三": 3, "四": 4, "五": 5, "六": 6, "七": 7, "八": 8, "九": 9]
        let units: [Character: Int] = ["十": 10, "百": 100, "千": 1_000]
        guard !token.isEmpty, token.allSatisfy({ digits[$0] != nil || units[$0] != nil }) else { return nil }
        var total = 0
        var current = 0
        for character in token {
            if let digit = digits[character] { current = digit }
            else if let unit = units[character] {
                total += max(current, 1) * unit
                current = 0
            }
        }
        return total + current
    }

    private static func isHeading(_ line: String) -> Bool {
        if line.hasPrefix("[目录页 · PDF 物理页") || line.hasPrefix("--- 下一目录页") { return true }
        return line.range(of: #"^(?:目\s*[录錄次]|contents|table\s+of\s+contents|目録)$"#, options: [.regularExpression, .caseInsensitive]) != nil
    }
}

/// Manual TOC recovery for the common OCR failure where the title column and
/// the page-number column are copied separately. The title list remains the
/// source of ordering and hierarchy; the number list is segmented globally so
/// a flattened string such as `5192122242932353845454960` can still be matched
/// against twelve rows without treating it as one enormous page number.
enum ManualPaginationRestart: Equatable {
    case automatic
    case never
    case after(Int)
}

struct ManualTOCSeparatedParseResult: Equatable {
    var entries: [TOCSourceEntry]
    var recognizedPageCount: Int
    var missingEntryIndices: [Int]
    var discardedDigitCount: Int
    var restartAfter: Int?
}

enum ManualTOCSeparatedParser {
    static func parse(
        titles titleSource: String,
        pages pageSource: String,
        restart: ManualPaginationRestart = .automatic,
        maximumPage: Int
    ) -> ManualTOCSeparatedParseResult {
        var entries = ManualTOCTitleParser.parse(titleSource)
        guard !entries.isEmpty else {
            return ManualTOCSeparatedParseResult(
                entries: [],
                recognizedPageCount: 0,
                missingEntryIndices: [],
                discardedDigitCount: pageSource.filter(\.isNumber).count,
                restartAfter: nil
            )
        }

        let matched = ManualTOCPageNumberParser.match(
            pageSource,
            expectedCount: entries.count,
            preferredMissing: Set(entries.indices.filter { isUnpagedDivision(entries[$0].title) }),
            restart: restart,
            maximumPage: maximumPage
        )
        let missing = matched.values.indices.filter { matched.values[$0] == nil }
        for index in entries.indices {
            entries[index].printedPage = matched.values[index]
            entries[index].pageStyle = matched.values[index] == nil ? nil : .arabic
        }

        // Keep every title visible even when OCR omitted a page number. A
        // missing row inherits the nearest following page (then the previous
        // page as a last resort) and remains listed in the diagnostics so the
        // user can correct it before saving.
        var following: (Int, PrintedPageStyle?)?
        for index in entries.indices.reversed() {
            if let page = entries[index].printedPage {
                following = (page, entries[index].pageStyle)
            } else if let following {
                entries[index].printedPage = following.0
                entries[index].pageStyle = following.1
            }
        }
        var preceding: (Int, PrintedPageStyle?)?
        for index in entries.indices {
            if let page = entries[index].printedPage {
                preceding = (page, entries[index].pageStyle)
            } else if let preceding {
                entries[index].printedPage = preceding.0
                entries[index].pageStyle = preceding.1
            }
        }

        return ManualTOCSeparatedParseResult(
            entries: TOCHierarchyInferer.apply(to: entries),
            recognizedPageCount: matched.values.compactMap { $0 }.count,
            missingEntryIndices: missing,
            discardedDigitCount: matched.discardedDigitCount,
            restartAfter: matched.restartAfter
        )
    }

    private static func isUnpagedDivision(_ title: String) -> Bool {
        title.range(
            of: #"^(?:第.{1,20}(?:部分|篇|部|卷)|[上中下前后](?:篇|部|卷)|part\s+\S+)"#,
            options: [.regularExpression, .caseInsensitive]
        ) != nil
    }
}

enum ManualTOCTitleParser {
    static func parse(_ source: String) -> [TOCSourceEntry] {
        let normalized = TOCInputNormalizer.normalize(source)
        let rawLines = normalized.components(separatedBy: .newlines)
            .flatMap(splitFlattenedNumberedEntries)
        var seen = Set<String>()
        let entries = rawLines.compactMap { raw -> TOCSourceEntry? in
            let halfWidth = raw.applyingTransform(.fullwidthToHalfwidth, reverse: false) ?? raw
            let level = min(leadingIndent(in: halfWidth), 5)
            var title = halfWidth.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty, !isHeading(title), !isPageNoise(title) else { return nil }
            title = title
                .replacingOccurrences(
                    of: #"(?:\.{2,}|…+|·{2,}|[/／]+|\s{2,})\s*[(（\[【{]?\s*(?:[0-9]{1,4}|[ivxlcdm]{1,10})\s*[)）\]】}]?\s*$"#,
                    with: "",
                    options: [.regularExpression, .caseInsensitive]
                )
                .replacingOccurrences(of: #"^[•●▪◆◇※*#]+\s*"#, with: "", options: .regularExpression)
            title = TOCInputNormalizer.cleanEntryTitle(title)
            guard (2...180).contains(title.count) else { return nil }
            let key = TOCInputNormalizer.comparisonKey(title)
            guard seen.insert(key).inserted else { return nil }
            return TOCSourceEntry(title: title, printedPage: nil, level: level, pageStyle: nil)
        }
        return TOCHierarchyInferer.apply(to: entries)
    }

    private static func splitFlattenedNumberedEntries(_ source: String) -> [String] {
        let line = source.trimmingCharacters(in: .whitespacesAndNewlines)
        guard line.count >= 6 else { return line.isEmpty ? [] : [line] }
        let pattern = #"(?i)(?<![\p{Han}A-Za-z0-9])(?=(?:第\s*[0-9一二三四五六七八九十百千零〇两]+\s*[篇部卷章节]|[上中下前后](?:篇|部|卷)|chapter\s+[0-9ivxlcdm]+|part\s+[0-9ivxlcdm]+|section\s+[0-9]+(?:\.[0-9]+)*|[0-9]{1,3}(?:\.[0-9]{1,3})+\s*[^0-9]))"#
        guard let expression = try? NSRegularExpression(pattern: pattern),
              expression.numberOfMatches(in: line, range: NSRange(line.startIndex..<line.endIndex, in: line)) >= 2 else {
            return [line]
        }
        let boundaries = expression.matches(in: line, range: NSRange(line.startIndex..<line.endIndex, in: line))
            .compactMap { Range($0.range, in: line)?.lowerBound }
        var starts = boundaries
        if starts.first != line.startIndex { starts.insert(line.startIndex, at: 0) }
        starts.append(line.endIndex)
        return zip(starts, starts.dropFirst()).compactMap { start, end in
            let fragment = String(line[start..<end]).trimmingCharacters(in: .whitespacesAndNewlines)
            return fragment.isEmpty ? nil : fragment
        }
    }

    private static func leadingIndent(in line: String) -> Int {
        line.prefix { $0 == " " || $0 == "\t" || $0 == "\u{3000}" }.count
    }

    private static func isHeading(_ source: String) -> Bool {
        source.range(
            of: #"^(?:目\s*[录錄次]|contents|table\s+of\s+contents|目録)$"#,
            options: [.regularExpression, .caseInsensitive]
        ) != nil
    }

    private static func isPageNoise(_ source: String) -> Bool {
        source.range(
            of: #"^(?:[/／\s.,，、;；:：()（）\[\]【】{}]*[0-9ivxlcdm]+)+[/／\s.,，、;；:：()（）\[\]【】{}]*$"#,
            options: [.regularExpression, .caseInsensitive]
        ) != nil
    }
}

enum ManualTOCPageNumberParser {
    struct Match: Equatable {
        var values: [Int?]
        var discardedDigitCount: Int
        var restartAfter: Int?
    }

    private struct State {
        var position: Int
        var values: [Int?]
        var last: Int?
        var restartAfter: Int?
        var cost: Double
        var discarded: Int
    }

    static func match(
        _ source: String,
        expectedCount: Int,
        preferredMissing: Set<Int> = [],
        restart: ManualPaginationRestart = .automatic,
        maximumPage: Int
    ) -> Match {
        guard expectedCount > 0 else { return Match(values: [], discardedDigitCount: 0, restartAfter: nil) }
        let upperBound = max(maximumPage, 99)
        if let lineMatch = matchOnePagePerLine(
            source,
            expectedCount: expectedCount,
            restart: restart,
            upperBound: upperBound
        ) {
            return lineMatch
        }
        let digits = source.compactMap(\.wholeNumberValue)
        guard !digits.isEmpty else {
            return Match(values: Array(repeating: nil, count: expectedCount), discardedDigitCount: 0, restartAfter: nil)
        }
        var beam = [State(position: 0, values: [], last: nil, restartAfter: nil, cost: 0, discarded: 0)]

        for slot in 0..<expectedCount {
            var next: [State] = []
            for state in beam {
                let forcedReset = forcedResetAt(slot: slot, restart: restart)
                let comparisonLast = forcedReset ? nil : state.last
                let missingCost = preferredMissing.contains(slot) ? 0.35 : 7.5
                next.append(State(
                    position: state.position,
                    values: state.values + [nil],
                    last: comparisonLast,
                    restartAfter: state.restartAfter,
                    cost: state.cost + missingCost,
                    discarded: state.discarded
                ))

                for skipped in 0...min(2, digits.count - state.position) {
                    let start = state.position + skipped
                    guard start < digits.count else { continue }
                    for length in 1...min(4, digits.count - start) {
                        let slice = digits[start..<(start + length)]
                        guard let value = decimalValue(slice), value > 0, value <= upperBound else { continue }
                        let transition = transitionCost(
                            from: comparisonLast,
                            to: value,
                            slot: slot,
                            currentRestart: state.restartAfter,
                            restart: restart
                        )
                        guard let transition else { continue }
                        let detectedRestart = transition.didRestart ? slot : state.restartAfter
                        next.append(State(
                            position: start + length,
                            values: state.values + [value],
                            last: value,
                            restartAfter: detectedRestart,
                            cost: state.cost + Double(skipped) * 5 + transition.cost + digitShapeCost(slice, value: value),
                            discarded: state.discarded + skipped
                        ))
                    }
                }
            }
            beam = pruned(next, remainingSlots: expectedCount - slot - 1, digitCount: digits.count)
        }

        guard var best = beam.min(by: {
            $0.cost + Double(digits.count - $0.position) * 5
                < $1.cost + Double(digits.count - $1.position) * 5
        }) else {
            return Match(values: Array(repeating: nil, count: expectedCount), discardedDigitCount: digits.count, restartAfter: nil)
        }
        best.discarded += max(digits.count - best.position, 0)
        let split: Int?
        switch restart {
        case .automatic: split = best.restartAfter
        case .never: split = nil
        case let .after(index): split = min(max(index, 1), max(expectedCount - 1, 1))
        }
        best.values = sortedRuns(best.values, splitAfter: split)
        return Match(values: best.values, discardedDigitCount: best.discarded, restartAfter: split)
    }

    /// In the explicit line format every non-empty row represents exactly one
    /// page number. OCR leaders, spaces and labels are ignored, so `……5  1`
    /// becomes page 51 instead of two separate pages 5 and 1.
    private static func matchOnePagePerLine(
        _ source: String,
        expectedCount: Int,
        restart: ManualPaginationRestart,
        upperBound: Int
    ) -> Match? {
        let rows = source.replacingOccurrences(of: "\r\n", with: "\n")
            .components(separatedBy: .newlines)
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        guard rows.count >= 2 else { return nil }
        let digitRows = rows.map { $0.compactMap(\.wholeNumberValue) }
        guard digitRows.allSatisfy({ !$0.isEmpty }) else { return nil }

        var discarded = 0
        var values = digitRows.prefix(expectedCount).map { digits -> Int? in
            guard let value = decimalValue(ArraySlice(digits)), value > 0, value <= upperBound else {
                discarded += digits.count
                return nil
            }
            return value
        }
        if digitRows.count > expectedCount {
            discarded += digitRows.dropFirst(expectedCount).reduce(0) { $0 + $1.count }
        }
        if values.count < expectedCount {
            values.append(contentsOf: Array(repeating: nil, count: expectedCount - values.count))
        }

        let split: Int?
        switch restart {
        case .automatic:
            split = detectedRestart(in: values)
        case .never:
            split = nil
        case let .after(index):
            split = min(max(index, 1), max(expectedCount - 1, 1))
        }
        return Match(
            values: sortedRuns(values, splitAfter: split),
            discardedDigitCount: discarded,
            restartAfter: split
        )
    }

    private static func detectedRestart(in values: [Int?]) -> Int? {
        var previous: Int?
        for (index, value) in values.enumerated() {
            guard let value else { continue }
            if let previous, value < previous, value <= max(12, previous / 2) {
                return index
            }
            previous = value
        }
        return nil
    }

    private static func forcedResetAt(slot: Int, restart: ManualPaginationRestart) -> Bool {
        if case let .after(index) = restart { return slot == index }
        return false
    }

    private static func transitionCost(
        from previous: Int?,
        to value: Int,
        slot: Int,
        currentRestart: Int?,
        restart: ManualPaginationRestart
    ) -> (cost: Double, didRestart: Bool)? {
        guard let previous else { return (0, false) }
        if value >= previous {
            let duplicatePenalty = value == previous ? 0.18 : 0
            let jumpPenalty = value - previous > 180 ? 0.6 : 0
            return (duplicatePenalty + jumpPenalty, false)
        }
        switch restart {
        case .automatic where currentRestart == nil && slot > 0:
            let strongRestart = value <= max(12, previous / 2)
            return strongRestart ? (1.2, true) : (3.8, true)
        case .never, .after, .automatic:
            return nil
        }
    }

    private static func decimalValue(_ digits: ArraySlice<Int>) -> Int? {
        digits.reduce(0) { $0 * 10 + $1 }
    }

    private static func digitShapeCost(_ digits: ArraySlice<Int>, value: Int) -> Double {
        var cost = 0.0
        if digits.count > 1, digits.first == 0 { cost += 0.05 }
        if digits.count == 4, value < 1_000 { cost += 1.5 }
        return cost
    }

    private static func pruned(_ states: [State], remainingSlots: Int, digitCount: Int) -> [State] {
        var bestByKey: [String: State] = [:]
        for state in states {
            let key = "\(state.position)|\(state.last ?? -1)|\(state.restartAfter ?? -1)"
            if let current = bestByKey[key], current.cost <= state.cost { continue }
            bestByKey[key] = state
        }
        return bestByKey.values.sorted {
            let leftRemainder = max(digitCount - $0.position - remainingSlots * 2, 0)
            let rightRemainder = max(digitCount - $1.position - remainingSlots * 2, 0)
            return $0.cost + Double(leftRemainder) * 0.3 < $1.cost + Double(rightRemainder) * 0.3
        }.prefix(700).map { $0 }
    }

    private static func sortedRuns(_ values: [Int?], splitAfter: Int?) -> [Int?] {
        guard let splitAfter, values.indices.contains(splitAfter) else { return sorting(values) }
        return sorting(Array(values[..<splitAfter])) + sorting(Array(values[splitAfter...]))
    }

    private static func sorting(_ values: [Int?]) -> [Int?] {
        let sorted = values.compactMap { $0 }.sorted()
        var iterator = sorted.makeIterator()
        return values.map { $0 == nil ? nil : iterator.next() }
    }
}

/// Infers a coherent hierarchy from the numbering system used by the whole
/// TOC instead of guessing each line independently. This supports Chinese
/// units (`第一部分` / `第1章` / `第一节`), standalone Chinese numerals, and
/// decimal schemes (`1`, `1.1`, `1.1.1`) in the same parser.
enum TOCHierarchyInferer {
    static func apply(to entries: [TOCSourceEntry]) -> [TOCSourceEntry] {
        guard !entries.isEmpty else { return [] }
        let hasPart = entries.contains { unitRank(in: $0.title) == 0 }
        let hasChapter = entries.contains { unitRank(in: $0.title) == 1 }

        return entries.map { entry in
            var result = entry
            let inferred: Int
            if let rank = unitRank(in: entry.title) {
                switch rank {
                case 0: inferred = 0
                case 1: inferred = hasPart ? 1 : 0
                default: inferred = (hasPart ? 1 : 0) + rank - 1
                }
            } else if let depth = decimalDepth(in: entry.title) {
                inferred = min((hasPart && hasChapter ? 1 : 0) + depth, 5)
            } else if isStandaloneEnumeration(entry.title) {
                inferred = hasChapter ? min((hasPart ? 2 : 1), 5) : 0
            } else {
                inferred = entry.level
            }
            // Explicit indentation from pasted text remains authoritative when
            // it expresses a deeper level than the inferred numbering scheme.
            result.level = min(max(max(entry.level, inferred), 0), 5)
            return result
        }
    }

    private static func unitRank(in title: String) -> Int? {
        if title.range(of: #"^(?:第\s*[0-9一二三四五六七八九十百千零〇两]+\s*(?:篇|部|卷|部分)|[上中下前后](?:篇|部|卷)|part\s+\S+)"#, options: [.regularExpression, .caseInsensitive]) != nil { return 0 }
        if title.range(of: #"^(?:第\s*[0-9一二三四五六七八九十百千零〇两]+\s*章|chapter\s+\S+)"#, options: [.regularExpression, .caseInsensitive]) != nil { return 1 }
        if title.range(of: #"^(?:第\s*[0-9一二三四五六七八九十百千零〇两]+\s*节|section\s+\S+)"#, options: [.regularExpression, .caseInsensitive]) != nil { return 2 }
        return nil
    }

    private static func decimalDepth(in title: String) -> Int? {
        guard let range = title.range(of: #"^[0-9]+(?:\.[0-9]+)*"#, options: .regularExpression) else { return nil }
        return min(title[range].filter { $0 == "." }.count, 5)
    }

    private static func isStandaloneEnumeration(_ title: String) -> Bool {
        title.range(
            of: #"^(?:[一二三四五六七八九十百千零〇两]+|[0-9]+)[、.．。)）]\s*\S"#,
            options: .regularExpression
        ) != nil
    }
}

enum TOCSourceMerger {
    static func merge(primary: [TOCSourceEntry], secondary: [TOCSourceEntry]) -> [TOCSourceEntry] {
        guard !primary.isEmpty else { return secondary }
        var result = primary
        for candidate in secondary {
            if let index = result.firstIndex(where: { equivalent($0, candidate) }) {
                if result[index].printedPage == nil { result[index].printedPage = candidate.printedPage }
                if result[index].pageStyle == nil { result[index].pageStyle = candidate.pageStyle }
                result[index].level = candidate.level
                continue
            }
            if let page = candidate.printedPage,
               let insertion = result.lastIndex(where: { ($0.printedPage ?? Int.max) <= page }) {
                result.insert(candidate, at: insertion + 1)
            } else {
                result.append(candidate)
            }
        }
        return result
    }

    private static func equivalent(_ lhs: TOCSourceEntry, _ rhs: TOCSourceEntry) -> Bool {
        let left = normalize(lhs.title)
        let right = normalize(rhs.title)
        if left == right { return true }
        guard lhs.printedPage == rhs.printedPage, min(left.count, right.count) >= 3 else { return false }
        return left.contains(right) || right.contains(left)
    }

    private static func normalize(_ text: String) -> String {
        TOCInputNormalizer.comparisonKey(text)
    }
}

/// Runs the two independent structural interpretations against the same
/// normalized OCR text, then keeps the result with the strongest TOC
/// invariants. This avoids making layout style (one entry per line versus
/// split/flattened columns) a hidden user choice.
enum TOCReliableParser {
    static func parse(
        _ source: String,
        preferLinewise: Bool = false,
        legacyAutomatic: Bool = false
    ) -> [TOCSourceEntry] {
        let linewise = ManualTOCTextParser.parse(source, legacyPageParsing: legacyAutomatic)
        let flexible = TOCTextParser.parse(source, legacyAutomatic: legacyAutomatic)
        let linewiseScore = score(linewise)
        let flexibleScore = score(flexible)
        let primary: [TOCSourceEntry]
        let secondary: [TOCSourceEntry]
        if linewiseScore > flexibleScore || (preferLinewise && abs(linewiseScore - flexibleScore) < 0.001) {
            primary = linewise
            secondary = flexible
        } else {
            primary = flexible
            secondary = linewise
        }
        guard !primary.isEmpty else { return TOCHierarchyInferer.apply(to: secondary) }
        let merged = TOCSourceMerger.merge(primary: primary, secondary: secondary)
        // Candidate union is only accepted when it does not make the printed
        // page sequence less coherent. A noisier parser must never corrupt a
        // complete high-confidence result merely by producing more strings.
        let selected = monotonicRatio(merged) + 0.001 >= monotonicRatio(primary) ? merged : primary
        return TOCHierarchyInferer.apply(to: selected)
    }

    private static func score(_ entries: [TOCSourceEntry]) -> Double {
        guard !entries.isEmpty else { return 0 }
        let complete = entries.filter { $0.printedPage != nil }.count
        let plausibleTitles = entries.filter { (2...120).contains($0.title.count) }.count
        return Double(complete * 6 + plausibleTitles * 2) + monotonicRatio(entries) * 10
    }

    private static func monotonicRatio(_ entries: [TOCSourceEntry]) -> Double {
        let groups = Dictionary(grouping: entries.compactMap { entry -> (PrintedPageStyle, Int)? in
            guard let page = entry.printedPage else { return nil }
            return (entry.pageStyle ?? .arabic, page)
        }, by: { $0.0 })
        let ratios = groups.values.compactMap { values -> Double? in
            let pages = values.map(\.1)
            guard pages.count >= 2 else { return nil }
            let ordered = zip(pages, pages.dropFirst()).filter { $1 >= $0 }.count
            return Double(ordered) / Double(pages.count - 1)
        }
        return ratios.isEmpty ? 1 : ratios.reduce(0, +) / Double(ratios.count)
    }
}

enum TOCPageResolver {
    static func resolve(
        _ sourceEntries: [TOCSourceEntry],
        tocPageIndices: [Int],
        pages: [PageText],
        preserveUnmatched: Bool = false,
        legacyAutomatic: Bool = false
    ) -> [OutlineEntry] {
        guard !sourceEntries.isEmpty, !pages.isEmpty else { return [] }
        let sourceEntries = sourceEntries.map { entry -> TOCSourceEntry in
            guard entry.pageStyle != .roman,
                  let printedPage = entry.printedPage,
                  printedPage > pages.count else { return entry }
            let digits = String(printedPage)
            guard digits.count == 4,
                  digits.first == "1",
                  let corrected = Int(digits.dropFirst()),
                  corrected > 0,
                  corrected <= pages.count else { return entry }
            var correctedEntry = entry
            correctedEntry.printedPage = corrected
            return correctedEntry
        }
        let tocSet = Set(tocPageIndices)
        let firstContentPage = (tocPageIndices.max() ?? -1) + 1
        // Search the whole book except the directory itself: Roman-numbered
        // prefaces often occur before the contents pages, while Arabic body
        // pagination usually begins after them.
        let searchable = pages.filter { !tocSet.contains($0.pageIndex) }

        var matchCandidates: [Int: [Match]] = [:]
        for (entryIndex, entry) in sourceEntries.enumerated() {
            let matches = candidateMatches(for: entry.title, in: searchable)
            guard !matches.isEmpty else { continue }
            matchCandidates[entryIndex] = matches
        }
        let segmentIDs = paginationSegmentIDs(for: sourceEntries)
        let offsetConsensus = legacyAutomatic ? [:] : consistentOffsetsBySegment(
            entries: sourceEntries,
            segmentIDs: segmentIDs,
            candidates: matchCandidates,
            firstContentPage: firstContentPage
        )
        let anchors = chooseMonotonicTitleAnchors(
            entries: sourceEntries,
            segmentIDs: segmentIDs,
            candidates: matchCandidates,
            offsetConsensus: offsetConsensus
        )
        let bodyArabicSegment = sourceEntries.indices.reversed().first {
            sourceEntries[$0].pageStyle != .roman && sourceEntries[$0].printedPage != nil
        }.map { segmentIDs[$0] }
        let labelPages = customPageLabelMap(pages)
        let availablePageIndices = pages.map(\.pageIndex)
        let minimumPageIndex = availablePageIndices.min() ?? 0
        let maximumPageIndex = availablePageIndices.max() ?? 0

        var seen = Set<String>()
        var result: [OutlineEntry] = []
        for (entryIndex, entry) in sourceEntries.enumerated() {
            let title = entry.title.trimmingCharacters(in: .whitespacesAndNewlines)
            guard title.count >= 2, title.count <= 180 else { continue }
            let resolvedPage: Int?
            let segment = segmentIDs[entryIndex]
            if let printed = entry.printedPage,
               let labelPage = labelPages[PageLabelKey(value: printed, style: entry.pageStyle ?? .arabic)],
               entry.pageStyle == .roman || segment == bodyArabicSegment {
                // A declared, non-default PDF page label is authoritative for
                // its pagination run. Earlier Arabic runs are excluded because
                // many books restart page 1 when the main text begins.
                resolvedPage = labelPage
            } else if let anchor = anchors[entryIndex] {
                // A high-confidence title at the beginning of a physical page
                // is stronger than a PDF page label. This is essential for
                // books that restart Arabic numbering after front matter.
                resolvedPage = anchor
            } else if let printed = entry.printedPage,
               let labelPage = labelPages[PageLabelKey(value: printed, style: entry.pageStyle ?? .arabic)] {
                // Repeated Arabic page values are ambiguous. PDF labels belong
                // to the final/body run; earlier Arabic front-matter runs are
                // calibrated from title anchors instead.
                resolvedPage = entry.pageStyle == .roman || segment == bodyArabicSegment
                    ? labelPage
                    : estimatedPage(
                        for: entryIndex,
                        entries: sourceEntries,
                        segmentIDs: segmentIDs,
                        anchors: anchors,
                        firstContentPage: firstContentPage,
                        tocPageIndices: tocPageIndices
                    )
            } else if let estimated = estimatedPage(
                for: entryIndex,
                entries: sourceEntries,
                segmentIDs: segmentIDs,
                anchors: anchors,
                firstContentPage: firstContentPage,
                tocPageIndices: tocPageIndices
            ) {
                resolvedPage = estimated
            } else if preserveUnmatched, let printed = entry.printedPage {
                let fallback = entry.pageStyle == .roman ? printed - 1 : firstContentPage + printed - 1
                resolvedPage = min(max(fallback, minimumPageIndex), maximumPageIndex)
            } else {
                resolvedPage = nil
            }
            guard let rawPageIndex = resolvedPage else { continue }
            let pageIndex = min(max(rawPageIndex, minimumPageIndex), maximumPageIndex)
            let key = "\(normalize(title))|\(pageIndex)"
            guard seen.insert(key).inserted else { continue }
            result.append(OutlineEntry(
                title: title,
                pageIndex: pageIndex,
                level: min(max(entry.level, 0), 5),
                generated: true
            ))
        }
        return result
    }

    private struct Match {
        var pageIndex: Int
        var score: Double
    }

    private struct PageLabelKey: Hashable {
        var value: Int
        var style: PrintedPageStyle
    }

    private static func paginationSegmentIDs(for entries: [TOCSourceEntry]) -> [Int] {
        var result: [Int] = []
        var segment = 0
        var previous: (page: Int, style: PrintedPageStyle)?
        for entry in entries {
            let style = entry.pageStyle ?? .arabic
            if let page = entry.printedPage, page > 0 {
                if let previous {
                    let changedStyle = previous.style != style
                    let restarted = previous.style == style
                        && previous.page - page >= 5
                        && page <= max(3, previous.page / 3)
                    if changedStyle || restarted { segment += 1 }
                }
                previous = (page, style)
            }
            result.append(segment)
        }
        return result
    }

    private static func chooseMonotonicTitleAnchors(
        entries: [TOCSourceEntry],
        segmentIDs: [Int],
        candidates: [Int: [Match]],
        offsetConsensus: [Int: Int]
    ) -> [Int: Int] {
        var result: [Int: Int] = [:]
        for segment in Set(segmentIDs).sorted() {
            var previousEntry: Int?
            var previousPage: Int?
            for index in entries.indices where segmentIDs[index] == segment {
                guard let available = candidates[index], !available.isEmpty else { continue }
                let monotonic = available.filter { previousPage == nil || $0.pageIndex >= previousPage! }
                let pool = monotonic.isEmpty ? available : monotonic
                let selected = pool.max { left, right in
                    anchorScore(left, entryIndex: index, previousEntry: previousEntry, previousPage: previousPage, entries: entries, preferredOffset: offsetConsensus[segment])
                        < anchorScore(right, entryIndex: index, previousEntry: previousEntry, previousPage: previousPage, entries: entries, preferredOffset: offsetConsensus[segment])
                }!
                result[index] = selected.pageIndex
                previousEntry = index
                previousPage = selected.pageIndex
            }
        }
        return result
    }

    private static func anchorScore(
        _ match: Match,
        entryIndex: Int,
        previousEntry: Int?,
        previousPage: Int?,
        entries: [TOCSourceEntry],
        preferredOffset: Int?
    ) -> Double {
        var score = match.score * 20
        if let preferredOffset, let printed = entries[entryIndex].printedPage {
            let distance = abs((match.pageIndex - printed) - preferredOffset)
            score += distance <= 1 ? 5 : -Double(distance) * 0.7
        }
        if let previousEntry, let previousPage,
           let currentPrinted = entries[entryIndex].printedPage,
           let previousPrinted = entries[previousEntry].printedPage,
           currentPrinted >= previousPrinted {
            let printedDelta = currentPrinted - previousPrinted
            let physicalDelta = match.pageIndex - previousPage
            score -= Double(abs(physicalDelta - printedDelta)) * 0.08
        } else {
            // Equal-quality matches favor the first physical occurrence, which
            // is much more likely to be the chapter opening than a later recap.
            score -= Double(match.pageIndex) * 0.0001
        }
        return score
    }

    /// Title matches across several chapters should imply one physical-to-
    /// printed page offset within each pagination run. Voting on that offset
    /// prevents a later running header or recap from stealing an otherwise
    /// correct chapter match, while still allowing front matter to restart.
    private static func consistentOffsetsBySegment(
        entries: [TOCSourceEntry],
        segmentIDs: [Int],
        candidates: [Int: [Match]],
        firstContentPage: Int
    ) -> [Int: Int] {
        guard !entries.isEmpty else { return [:] }
        let finalSegment = segmentIDs.max() ?? 0
        var result: [Int: Int] = [:]
        for segment in Set(segmentIDs) {
            var offsetsByEntry: [Int: [(offset: Int, score: Double)]] = [:]
            for index in entries.indices where segmentIDs[index] == segment {
                guard let printed = entries[index].printedPage, let matches = candidates[index] else { continue }
                offsetsByEntry[index] = matches.map { ($0.pageIndex - printed, $0.score) }
            }
            let preferred = segment == finalSegment ? firstContentPage - 1 : -1
            guard let offset = consistentOffset(offsetsByEntry, preferred: preferred) else { continue }
            let support = offsetSupport(offset, in: offsetsByEntry, preferred: preferred)
            if support.entries >= 2 { result[segment] = offset }
        }
        return result
    }

    private static func estimatedPage(
        for entryIndex: Int,
        entries: [TOCSourceEntry],
        segmentIDs: [Int],
        anchors: [Int: Int],
        firstContentPage: Int,
        tocPageIndices: [Int]
    ) -> Int? {
        guard let printed = entries[entryIndex].printedPage else { return nil }
        let segment = segmentIDs[entryIndex]
        let segmentAnchors = anchors.keys.filter { segmentIDs[$0] == segment }.sorted()
        let before = segmentAnchors.last { $0 < entryIndex }
        let after = segmentAnchors.first { $0 > entryIndex }
        var estimate: Int
        if let before, let after,
           let beforePrinted = entries[before].printedPage,
           let afterPrinted = entries[after].printedPage,
           afterPrinted > beforePrinted {
            let ratio = Double(printed - beforePrinted) / Double(afterPrinted - beforePrinted)
            estimate = Int((Double(anchors[before]!) + ratio * Double(anchors[after]! - anchors[before]!)).rounded())
        } else if let nearest = [before, after].compactMap({ $0 }).min(by: {
            abs(($0) - entryIndex) < abs(($1) - entryIndex)
        }), let anchorPrinted = entries[nearest].printedPage {
            estimate = anchors[nearest]! + printed - anchorPrinted
        } else {
            // Without a title anchor, a run before a later numbering restart is
            // front matter; the final run begins after the located TOC pages.
            let hasLaterSegment = segmentIDs.contains { $0 > segment }
            estimate = hasLaterSegment ? printed - 1 : firstContentPage + printed - 1
        }

        let anchorPages = segmentAnchors.compactMap { anchors[$0] }
        let isFrontMatter = !anchorPages.isEmpty
            ? anchorPages.filter { $0 < firstContentPage }.count > anchorPages.count / 2
            : segmentIDs.contains { $0 > segment }
        if isFrontMatter, let tocStart = tocPageIndices.min() {
            estimate = min(estimate, max(tocStart - 1, 0))
        } else {
            estimate = max(estimate, firstContentPage)
            while tocPageIndices.contains(estimate) { estimate += 1 }
        }
        return estimate
    }

    private static func candidateMatches(for title: String, in pages: [PageText]) -> [Match] {
        let normalizedTitle = normalize(title)
        guard normalizedTitle.count >= 2 else { return [] }
        let alternatives = [normalizedTitle, normalize(titleWithoutSequence(title))]
            .filter { $0.count >= 2 }
        let titleGrams = alternatives.map(bigrams)
        var matches: [Match] = []
        for page in pages {
            let headLines = page.text.components(separatedBy: .newlines).prefix(18).joined(separator: " ")
            let pageHead = normalize(String(headLines.prefix(900)))
            guard !pageHead.isEmpty else { continue }
            let score = alternatives.enumerated().map { index, alternative -> Double in
                if pageHead.contains(alternative) {
                    return pageHead.hasPrefix(alternative) ? 1.0 : 0.94
                }
                let pageGrams = bigrams(String(pageHead.prefix(max(alternative.count * 4, 100))))
                let overlap = titleGrams[index].intersection(pageGrams).count
                return titleGrams[index].isEmpty ? 0 : Double(overlap) / Double(titleGrams[index].count)
            }.max() ?? 0
            if score >= 0.82 { matches.append(Match(pageIndex: page.pageIndex, score: score)) }
        }
        return matches.sorted {
            if $0.score == $1.score { return $0.pageIndex < $1.pageIndex }
            return $0.score > $1.score
        }.prefix(6).map { $0 }
    }

    private static func titleWithoutSequence(_ title: String) -> String {
        title.replacingOccurrences(
            of: #"^(?:(?:第\s*[0-9一二三四五六七八九十百千零〇两]+\s*[篇部卷章节])|(?:chapter|part|section)\s+\S+|(?:\d+(?:\.\d+)*))[\s、.．:：\-]*"#,
            with: "",
            options: [.regularExpression, .caseInsensitive]
        )
    }

    private static func consistentOffset(
        _ candidatesByEntry: [Int: [(offset: Int, score: Double)]],
        preferred: Int?
    ) -> Int? {
        let candidates = Set(candidatesByEntry.values.flatMap { $0.map(\.offset) })
        guard !candidates.isEmpty else { return nil }
        return candidates.max { left, right in
            let lhs = offsetSupport(left, in: candidatesByEntry, preferred: preferred)
            let rhs = offsetSupport(right, in: candidatesByEntry, preferred: preferred)
            if lhs.entries != rhs.entries { return lhs.entries < rhs.entries }
            if abs(lhs.weight - rhs.weight) > 0.001 { return lhs.weight < rhs.weight }
            return lhs.distance > rhs.distance
        }
    }

    private static func offsetSupport(
        _ offset: Int,
        in candidatesByEntry: [Int: [(offset: Int, score: Double)]],
        preferred: Int?
    ) -> (entries: Int, weight: Double, distance: Int) {
        let bestPerEntry = candidatesByEntry.values.compactMap { candidates in
            candidates.filter { abs($0.offset - offset) <= 1 }.map(\.score).max()
        }
        return (bestPerEntry.count, bestPerEntry.reduce(0, +), preferred.map { abs($0 - offset) } ?? 0)
    }

    private static func customPageLabelMap(_ pages: [PageText]) -> [PageLabelKey: Int] {
        let parsed = pages.compactMap { page -> (PageLabelKey, Int, Bool)? in
            guard let label = page.pageLabel, let key = parsePageLabel(label) else { return nil }
            let isDefault = key.style == .arabic && key.value == page.pageIndex + 1
            return (key, page.pageIndex, isDefault)
        }
        guard parsed.contains(where: { !$0.2 }) else { return [:] }
        var result: [PageLabelKey: Int] = [:]
        for (key, pageIndex, _) in parsed where result[key] == nil { result[key] = pageIndex }
        return result
    }

    private static func parsePageLabel(_ source: String) -> PageLabelKey? {
        let token = source.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: #"(?i)^p\.?\s*"#, with: "", options: .regularExpression)
        if let value = Int(token), value > 0 { return PageLabelKey(value: value, style: .arabic) }
        let values: [Character: Int] = ["i": 1, "v": 5, "x": 10, "l": 50, "c": 100, "d": 500, "m": 1_000]
        let characters = Array(token)
        guard !characters.isEmpty, characters.allSatisfy({ values[$0] != nil }) else { return nil }
        var total = 0
        for index in characters.indices {
            let value = values[characters[index]]!
            if index + 1 < characters.count, value < values[characters[index + 1]]! { total -= value }
            else { total += value }
        }
        return total > 0 ? PageLabelKey(value: total, style: .roman) : nil
    }

    private static func normalize(_ text: String) -> String {
        TOCInputNormalizer.comparisonKey(text)
    }

    private static func bigrams(_ text: String) -> Set<String> {
        let characters = Array(text)
        guard characters.count >= 2 else { return Set([text]) }
        return Set((0..<(characters.count - 1)).map { String(characters[$0...$0 + 1]) })
    }
}
