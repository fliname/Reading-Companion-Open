import Foundation
import PDFKit

enum OutlineBuilder {
    static func entries(for document: PDFDocument) -> [OutlineEntry] {
        if let root = document.outlineRoot {
            let native = flatten(root, document: document)
            if isPlausible(native, pageCount: document.pageCount) { return native }
        }
        // 不再扫描正文猜标题。无可信原生目录时，必须等待目录页识别。
        return []
    }

    static func isPlausible(_ entries: [OutlineEntry], pageCount: Int) -> Bool {
        guard !entries.isEmpty, pageCount > 0 else { return false }
        let normalizedTitles = entries.map {
            $0.title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        }
        let pageOnlyPattern = #"^(?:page|p\.?|第)?\s*[ivxlcdm一二三四五六七八九十百千零〇0-9]+\s*(?:页)?$"#
        let pageOnlyCount = normalizedTitles.filter {
            $0.range(of: pageOnlyPattern, options: [.regularExpression, .caseInsensitive]) != nil
        }.count
        if Double(pageOnlyCount) / Double(entries.count) >= 0.45 { return false }

        let uniquePages = Array(Set(entries.map(\.pageIndex)).filter { $0 >= 0 && $0 < pageCount }).sorted()
        if entries.count >= 12,
           Double(uniquePages.count) / Double(pageCount) >= 0.72 {
            return false
        }
        if uniquePages.count >= 12 {
            let consecutive = zip(uniquePages, uniquePages.dropFirst()).filter { next, previous in
                next - previous <= 1
            }.count
            if Double(consecutive) / Double(uniquePages.count - 1) >= 0.82 { return false }
        }

        let uniqueTitleRatio = Double(Set(normalizedTitles).count) / Double(entries.count)
        return uniqueTitleRatio >= 0.35
    }

    private static func flatten(
        _ node: PDFOutline,
        document: PDFDocument,
        level: Int = -1
    ) -> [OutlineEntry] {
        var result: [OutlineEntry] = []
        let destination = node.destination ?? (node.action as? PDFActionGoTo)?.destination
        if level >= 0,
           let label = node.label?.trimmingCharacters(in: .whitespacesAndNewlines),
           !label.isEmpty,
           let page = destination?.page {
            result.append(
                OutlineEntry(
                    title: label,
                    pageIndex: document.index(for: page),
                    level: level,
                    generated: false
                )
            )
        }

        for index in 0..<node.numberOfChildren {
            if let child = node.child(at: index) {
                result.append(contentsOf: flatten(child, document: document, level: level + 1))
            }
        }
        return result
    }

}
