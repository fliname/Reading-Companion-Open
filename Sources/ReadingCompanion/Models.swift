import AppKit
import Foundation

enum AIProvider: String, CaseIterable, Codable, Identifiable, Sendable {
    case openAI = "OpenAI 官方"
    case aiHubMix = "AIHUBMix"
    case anthropic = "Anthropic 官方"
    case googleGemini = "Google Gemini"
    case deepSeek = "DeepSeek 官方"
    case openRouter = "OpenRouter"
    case customRelay = "独立中转站"

    var id: String { rawValue }

    var storageAccount: String {
        switch self {
        case .openAI: "openai"
        case .aiHubMix: "aihubmix"
        case .anthropic: "anthropic"
        case .googleGemini: "google-gemini"
        case .deepSeek: "deepseek"
        case .openRouter: "openrouter"
        case .customRelay: "custom-relay"
        }
    }

    enum APIStyle { case responses, chatCompletions, anthropicMessages }

    var apiStyle: APIStyle {
        switch self {
        case .openAI: .responses
        case .anthropic: .anthropicMessages
        case .customRelay: CustomRelayConfiguration.savedProtocol.apiStyle
        case .aiHubMix, .googleGemini, .deepSeek, .openRouter: .chatCompletions
        }
    }

    var outlineReasoningEffort: String {
        switch self {
        case .openAI: "low"
        case .aiHubMix: "none"
        case .anthropic, .googleGemini, .deepSeek, .openRouter, .customRelay: "low"
        }
    }

    var baseURL: URL {
        switch self {
        case .openAI: URL(string: "https://api.openai.com/v1")!
        case .aiHubMix: URL(string: "https://aihubmix.com/v1")!
        case .anthropic: URL(string: "https://api.anthropic.com/v1")!
        case .googleGemini: URL(string: "https://generativelanguage.googleapis.com/v1beta/openai")!
        case .deepSeek: URL(string: "https://api.deepseek.com")!
        case .openRouter: URL(string: "https://openrouter.ai/api/v1")!
        case .customRelay: CustomRelayConfiguration.savedBaseURL
            ?? URL(string: "https://invalid.local/v1")!
        }
    }

    var fallbackBaseURL: URL? {
        switch self {
        case .openAI: nil
        case .aiHubMix: URL(string: "https://api.aihubmix.com/v1")!
        case .anthropic, .googleGemini, .deepSeek, .openRouter, .customRelay: nil
        }
    }

    var responsesURL: URL {
        if self == .customRelay, let url = CustomRelayConfiguration.savedDirectEndpoint,
           CustomRelayConfiguration.savedProtocol == .openAIResponses { return url }
        return baseURL.appendingPathComponent("responses")
    }
    var chatCompletionsURL: URL {
        if self == .customRelay, let url = CustomRelayConfiguration.savedDirectEndpoint,
           CustomRelayConfiguration.savedProtocol == .openAIChat { return url }
        return baseURL.appendingPathComponent("chat/completions")
    }
    var modelsURL: URL { baseURL.appendingPathComponent("models") }
    var messagesURL: URL {
        if self == .customRelay, let url = CustomRelayConfiguration.savedDirectEndpoint,
           CustomRelayConfiguration.savedProtocol == .anthropicMessages { return url }
        return baseURL.appendingPathComponent("messages")
    }
    var modelCatalogURL: URL? {
        switch self {
        case .openAI: nil
        case .aiHubMix: URL(string: "https://aihubmix.com/api/v1/models?type=llm&modalities=text")!
        case .anthropic, .googleGemini, .deepSeek, .openRouter, .customRelay: nil
        }
    }

    func fallbackURL(for url: URL) -> URL? {
        guard let fallbackBaseURL, url.host == baseURL.host else { return nil }
        let relativePath = url.path.replacingOccurrences(of: baseURL.path + "/", with: "")
        return fallbackBaseURL.appendingPathComponent(relativePath)
    }

    var keyPortalURL: URL {
        switch self {
        case .openAI: URL(string: "https://platform.openai.com/api-keys")!
        case .aiHubMix: URL(string: "https://aihubmix.com/token")!
        case .anthropic: URL(string: "https://platform.claude.com/settings/keys")!
        case .googleGemini: URL(string: "https://aistudio.google.com/app/apikey")!
        case .deepSeek: URL(string: "https://platform.deepseek.com/api_keys")!
        case .openRouter: URL(string: "https://openrouter.ai/settings/keys")!
        case .customRelay: URL(string: "https://example.com")!
        }
    }

    var modelMarketplaceURL: URL {
        switch self {
        case .openAI: URL(string: "https://platform.openai.com/docs/models")!
        case .aiHubMix: URL(string: "https://aihubmix.com/models?lang=zh")!
        case .anthropic: URL(string: "https://platform.claude.com/docs/en/about-claude/models/overview")!
        case .googleGemini: URL(string: "https://ai.google.dev/gemini-api/docs/models")!
        case .deepSeek: URL(string: "https://api-docs.deepseek.com/quick_start/pricing")!
        case .openRouter: URL(string: "https://openrouter.ai/models")!
        case .customRelay: URL(string: "https://example.com")!
        }
    }

    var supportsWebSearch: Bool {
        switch self {
        case .openAI, .aiHubMix, .anthropic, .openRouter: true
        case .googleGemini, .deepSeek, .customRelay: false
        }
    }

    var setupHint: String {
        switch self {
        case .openAI: "Responses API；ChatGPT 订阅不包含 API 额度"
        case .aiHubMix: "聚合平台；模型权限由当前 Key 决定"
        case .anthropic: "使用官方 Messages API"
        case .googleGemini: "使用 Google AI Studio 的 Gemini API Key"
        case .deepSeek: "使用官方 OpenAI 兼容接口"
        case .openRouter: "一个 Key 可调用多个厂商模型"
        case .customRelay: "使用平台提供的 OpenAI 兼容 Base URL"
        }
    }

    func applyAuthentication(to request: inout URLRequest, apiKey: String) {
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        switch self {
        case .anthropic:
            request.setValue(key, forHTTPHeaderField: "x-api-key")
            request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        case .customRelay:
            CustomRelayConfiguration.savedAuthentication.apply(to: &request, apiKey: key)
            if CustomRelayConfiguration.savedProtocol == .anthropicMessages {
                request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
            }
        default:
            request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        }
        if self == .openRouter {
            request.setValue("Reading Companion", forHTTPHeaderField: "X-OpenRouter-Title")
        }
    }

    /// Prefixes are only a fast hint. The final decision is always made by
    /// authenticating against the provider's model-list endpoint.
    static func detectionCandidates(for apiKey: String) -> [AIProvider] {
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if key.hasPrefix("sk-ant-") { return [.anthropic] }
        if key.hasPrefix("sk-or-") { return [.openRouter] }
        if key.hasPrefix("AIza") { return [.googleGemini] }
        if key.hasPrefix("sk-") {
            return [.openAI, .deepSeek, .aiHubMix, .anthropic, .openRouter, .googleGemini]
        }
        return [.openAI, .aiHubMix, .anthropic, .googleGemini, .deepSeek, .openRouter]
    }

    static func looksLikeCompleteAPIKey(_ apiKey: String) -> Bool {
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        return key.count >= 16 && !key.contains("*") && !key.contains(where: \.isWhitespace)
    }

}

enum CustomAPIProtocol: String, CaseIterable, Codable, Identifiable {
    case automatic = "自动识别"
    case openAIChat = "OpenAI Chat Completions"
    case openAIResponses = "OpenAI Responses"
    case anthropicMessages = "Anthropic Messages"

    var id: String { rawValue }

    var apiStyle: AIProvider.APIStyle {
        switch self {
        case .automatic, .openAIChat: .chatCompletions
        case .openAIResponses: .responses
        case .anthropicMessages: .anthropicMessages
        }
    }
}

enum CustomAPIAuthentication: String, CaseIterable, Codable, Identifiable {
    case automatic = "自动识别"
    case bearer = "Bearer Key"
    case apiKeyHeader = "api-key（Azure）"
    case xAPIKey = "x-api-key（Anthropic）"
    case none = "无需密钥（仅本机）"

    var id: String { rawValue }

    func apply(to request: inout URLRequest, apiKey: String) {
        switch self {
        case .automatic, .bearer:
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        case .apiKeyHeader:
            request.setValue(apiKey, forHTTPHeaderField: "api-key")
        case .xAPIKey:
            request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        case .none:
            break
        }
    }
}

enum CustomRelayConfiguration {
    static let enabledKey = "customRelayEnabled"
    static let baseURLKey = "customRelayBaseURL"
    static let modelKey = "customRelayModel"
    static let protocolKey = "customRelayProtocol"
    static let authenticationKey = "customRelayAuthentication"
    static let directEndpointKey = "customRelayDirectEndpoint"

    static var savedProtocol: CustomAPIProtocol {
        CustomAPIProtocol(rawValue: UserDefaults.standard.string(forKey: protocolKey) ?? "") ?? .openAIChat
    }

    static var savedAuthentication: CustomAPIAuthentication {
        CustomAPIAuthentication(rawValue: UserDefaults.standard.string(forKey: authenticationKey) ?? "") ?? .bearer
    }

    static var savedDirectEndpoint: URL? {
        UserDefaults.standard.string(forKey: directEndpointKey).flatMap(URL.init(string:))
    }

    static var savedBaseURL: URL? {
        guard let raw = UserDefaults.standard.string(forKey: baseURLKey) else { return nil }
        return normalizedBaseURL(from: raw)
    }

    static func normalizedBaseURL(from rawValue: String) -> URL? {
        var value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        while value.hasSuffix("/") { value.removeLast() }
        guard var components = URLComponents(string: value),
              isAllowedScheme(components.scheme, host: components.host),
              components.host?.isEmpty == false,
              components.user == nil,
              components.password == nil,
              components.fragment == nil else { return nil }
        var path = components.path
        for suffix in ["/chat/completions", "/responses", "/messages", "/models"] where path.hasSuffix(suffix) {
            path.removeLast(suffix.count)
        }
        while path.hasSuffix("/") { path.removeLast() }
        if path.isEmpty {
            path = components.host?.hasSuffix(".openai.azure.com") == true ? "/openai/v1" : "/v1"
        }
        components.path = path
        components.query = nil
        return components.url
    }

    static func directEndpoint(from rawValue: String) -> URL? {
        let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let components = URLComponents(string: value),
              isAllowedScheme(components.scheme, host: components.host),
              components.user == nil, components.password == nil, components.fragment == nil,
              ["/chat/completions", "/responses", "/messages"].contains(where: { components.path.hasSuffix($0) })
        else { return nil }
        return components.url
    }

    static func resolvedProtocol(for rawValue: String, requested: CustomAPIProtocol) -> CustomAPIProtocol {
        guard requested == .automatic else { return requested }
        let path = URLComponents(string: rawValue.trimmingCharacters(in: .whitespacesAndNewlines))?.path ?? ""
        if path.hasSuffix("/responses") { return .openAIResponses }
        if path.hasSuffix("/messages") || path.localizedCaseInsensitiveContains("anthropic") {
            return .anthropicMessages
        }
        return .openAIChat
    }

    static func resolvedAuthentication(
        for rawValue: String,
        protocol apiProtocol: CustomAPIProtocol,
        requested: CustomAPIAuthentication
    ) -> CustomAPIAuthentication {
        guard requested == .automatic else { return requested }
        let components = URLComponents(string: rawValue.trimmingCharacters(in: .whitespacesAndNewlines))
        if components?.host?.hasSuffix(".openai.azure.com") == true { return .apiKeyHeader }
        if apiProtocol == .anthropicMessages { return .xAPIKey }
        if components?.scheme?.lowercased() == "http",
           ["localhost", "127.0.0.1", "::1"].contains(components?.host?.lowercased() ?? "") { return .none }
        return .bearer
    }

    static func endpointURL(
        baseURL: URL,
        directEndpoint: URL?,
        protocol apiProtocol: CustomAPIProtocol
    ) -> URL {
        if let directEndpoint { return directEndpoint }
        switch apiProtocol {
        case .automatic, .openAIChat: return baseURL.appendingPathComponent("chat/completions")
        case .openAIResponses: return baseURL.appendingPathComponent("responses")
        case .anthropicMessages: return baseURL.appendingPathComponent("messages")
        }
    }

    private static func isAllowedScheme(_ scheme: String?, host: String?) -> Bool {
        if scheme?.lowercased() == "https" { return true }
        guard scheme?.lowercased() == "http" else { return false }
        return ["localhost", "127.0.0.1", "::1"].contains(host?.lowercased() ?? "")
    }
}

struct CustomRelayConnectionInfo: Equatable {
    let apiKey: String
    let baseURL: URL

    private struct Payload: Decodable {
        let type: String
        let key: String
        let url: String

        enum CodingKeys: String, CodingKey {
            case type = "_type"
            case key
            case url
        }
    }

    static func parse(_ rawValue: String) throws -> CustomRelayConnectionInfo {
        let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let openingBrace = value.firstIndex(of: "{"),
              let closingBrace = value.lastIndex(of: "}"),
              openingBrace < closingBrace,
              let data = String(value[openingBrace...closingBrace]).data(using: .utf8),
              let payload = try? JSONDecoder().decode(Payload.self, from: data) else {
            throw CustomRelayConnectionInfoError.invalidJSON
        }
        guard payload.type == "newapi_channel_conn" else {
            throw CustomRelayConnectionInfoError.unsupportedType
        }
        let key = payload.key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard AIProvider.looksLikeCompleteAPIKey(key) else {
            throw CustomRelayConnectionInfoError.invalidAPIKey
        }
        guard let baseURL = CustomRelayConfiguration.normalizedBaseURL(from: payload.url) else {
            throw CustomRelayConnectionInfoError.invalidBaseURL
        }
        return CustomRelayConnectionInfo(apiKey: key, baseURL: baseURL)
    }
}

enum CustomRelayConnectionInfoError: LocalizedError {
    case invalidJSON
    case unsupportedType
    case invalidAPIKey
    case invalidBaseURL

    var errorDescription: String? {
        switch self {
        case .invalidJSON: "无法识别连接信息，请粘贴完整 JSON"
        case .unsupportedType: "连接信息类型不受支持"
        case .invalidAPIKey: "连接信息中的 API Key 不完整"
        case .invalidBaseURL: "连接信息中的 URL 无效或不是 HTTPS"
        }
    }
}

enum SidebarSection: String, CaseIterable, Identifiable {
    case outline = "目录"
    case thumbnails = "缩略图"
    case bookmarks = "书签"
    case highlights = "划线"
    case search = "搜索"

    var id: String { rawValue }

    var symbol: String {
        switch self {
        case .outline: "list.bullet.indent"
        case .thumbnails: "rectangle.grid.1x2"
        case .bookmarks: "bookmark"
        case .highlights: "highlighter"
        case .search: "magnifyingglass"
        }
    }
}

enum ReaderDisplayMode: String, CaseIterable, Identifiable {
    case single = "单页"

    var id: String { rawValue }
}

enum ReaderFitMode: String, CaseIterable, Identifiable {
    case page = "适合页面"
    case width = "适合宽度"
    case custom = "自定义"

    var id: String { rawValue }
}

enum HighlightTint: String, CaseIterable, Codable, Identifiable {
    case yellow = "黄色"
    case red = "红色"
    case blue = "蓝色"

    var id: String { rawValue }

    var color: NSColor {
        switch self {
        case .yellow: NSColor.systemYellow.withAlphaComponent(0.48)
        case .red: NSColor.systemRed.withAlphaComponent(0.38)
        case .blue: NSColor.systemBlue.withAlphaComponent(0.34)
        }
    }

    var obsidianCallout: String {
        switch self {
        // Built-in Obsidian callouts retain their colors even when the optional
        // Reading Companion CSS snippet has not been enabled.
        case .yellow: "warning"
        case .red: "danger"
        case .blue: "info"
        }
    }
}

enum ReadingMarkKind: String, Codable, Hashable, Sendable {
    case highlight
    case annotation
}

enum ChatNoteExportMode: String, CaseIterable, Identifiable {
    case original = "保留原文"
    case condensed = "整理浓缩"

    var id: String { rawValue }
}

enum AIReadingDepth: String, CaseIterable, Identifiable, Codable {
    case economical = "节省"
    case balanced = "均衡"
    case deep = "深读"

    var id: String { rawValue }
    var contextLimit: Int {
        switch self { case .economical: 6; case .balanced: 9; case .deep: 14 }
    }
    var historyLimit: Int {
        switch self { case .economical: 4; case .balanced: 8; case .deep: 12 }
    }
    var outputLimit: Int {
        switch self { case .economical: 1_500; case .balanced: 3_000; case .deep: 5_000 }
    }
    var reasoningEffort: String {
        switch self { case .economical: "low"; case .balanced: "low"; case .deep: "medium" }
    }
    func contextTokenBudget(scope: ReadingContextScope, wholeBook: Bool) -> Int {
        let base: Int
        switch (self, scope) {
        case (.economical, .explanation): base = 3_200
        case (.economical, .standard): base = 5_000
        case (.economical, .context): base = 6_500
        case (.balanced, .explanation): base = 4_800
        case (.balanced, .standard): base = 7_200
        case (.balanced, .context): base = 9_600
        case (.deep, .explanation): base = 6_500
        case (.deep, .standard): base = 10_000
        case (.deep, .context): base = 14_000
        }
        // Whole-book mode broadens where evidence can come from, not the size
        // of each excerpt. A small allowance prevents the outline from crowding
        // out cross-chapter evidence while keeping a hard ceiling.
        return wholeBook ? Int(Double(base) * 1.12) : base
    }
    var detail: String {
        switch self {
        case .economical: "较短上下文，适合释义和快速问答"
        case .balanced: "质量与消耗平衡，推荐日常使用"
        case .deep: "更多原文与历史，适合复杂论证精读"
        }
    }
}

enum ReadingContextScope: String, Codable {
    case explanation
    case standard
    case context
}

enum QuickQuestionPrompt {
    static let context = "联系上下文"
    static let explanation = "解释一下"
    static let resources = "链接资源"
}

enum QuestionOverview {
    static func preview(_ content: String, answer: String? = nil) -> String {
        let source = section(named: "原文", in: content)
        let question = section(named: "问题", in: content)
            ?? HighlightTextNormalizer.inline(content)
        guard let source, !source.isEmpty else { return compact(question, limit: 54) }

        if let answerSummary = answer.flatMap(answerSummary) {
            return "\(pageLabel(in: content))\(answerSummary)"
        }

        let intent: String
        if question.contains("联系上下文") || question.contains("前文") && question.contains("下文") {
            intent = "承接的问题与论证作用"
        } else if question.contains("解释这个词") || question.contains("关键术语") || question.contains("含义") {
            intent = "含义与关键术语"
        } else if question.contains("联网查找") || question.contains("链接") || question.contains("资源") {
            intent = "相关作品与资源"
        } else {
            return "\(pageLabel(in: content))「\(coreSnippet(source))」· \(compact(question, limit: 32))"
        }
        return "\(pageLabel(in: content))「\(coreSnippet(source))」· \(intent)"
    }

    private static func section(named name: String, in content: String) -> String? {
        let escaped = NSRegularExpression.escapedPattern(for: name)
        let pattern = "(?s)\(escaped)[^：:\\n]{0,20}[：:]\\s*(.*?)(?=\\n\\s*(?:原文|问题)[^：:\\n]{0,20}[：:]|$)"
        guard let expression = try? NSRegularExpression(pattern: pattern),
              let match = expression.firstMatch(in: content, range: NSRange(content.startIndex..<content.endIndex, in: content)),
              let range = Range(match.range(at: 1), in: content) else { return nil }
        let value = HighlightTextNormalizer.inline(String(content[range]))
        return value.isEmpty ? nil : value
    }

    private static func pageLabel(in content: String) -> String {
        guard let expression = try? NSRegularExpression(pattern: #"第\s*(\d+)\s*页"#),
              let match = expression.firstMatch(in: content, range: NSRange(content.startIndex..<content.endIndex, in: content)),
              let range = Range(match.range(at: 1), in: content) else { return "" }
        return "P\(content[range]) · "
    }

    private static func coreSnippet(_ source: String) -> String {
        let pieces = source.split(whereSeparator: { "。！？!?；;\n".contains($0) })
            .map { HighlightTextNormalizer.inline(String($0)) }
            .filter { !$0.isEmpty }
        let preferred = pieces.first(where: { $0.count >= 8 }) ?? pieces.first ?? source
        return compact(preferred, limit: 30)
    }

    private static func answerSummary(_ answer: String) -> String? {
        let cleanedLines = answer
            .replacingOccurrences(of: "\\n", with: "\n")
            .components(separatedBy: .newlines)
            .map {
                $0.replacingOccurrences(of: #"^#{1,6}\s+|^[\-*•]\s+|[*_`]+"#, with: "", options: .regularExpression)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
            .filter {
                !$0.isEmpty && !$0.hasPrefix("碰撞") &&
                $0.range(of: #"^(?:直接回答|先说结论|简单来说|换句话说)[：:]?$"#, options: .regularExpression) == nil
            }
        guard let first = cleanedLines.first else { return nil }
        return keywordDigest(first)
    }

    private static func keywordDigest(_ source: String) -> String {
        var value = source
            .replacingOccurrences(
                of: #"^(?:这段话|这里|作者|原文)(?:的)?(?:核心)?(?:意思|要点|结论|判断)?(?:是|在于|：|:)\s*"#,
                with: "",
                options: .regularExpression
            )
            .replacingOccurrences(of: #"^(?:其实|显然|可以看出|需要注意的是)[，,:：\s]*"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        // 速览是定位器，不是第二份摘要：去掉完整句的胶水，保留对象、关系与判断。
        value = value
            .replacingOccurrences(of: "与", with: "、")
            .replacingOccurrences(of: #"\s*(?:处于|属于|构成了?|意味着|指向|表明)\s*"#, with: " · ", options: .regularExpression)
            .replacingOccurrences(of: #"[\s。！？!?]+$"#, with: "", options: .regularExpression)

        let phrases = value
            .components(separatedBy: CharacterSet(charactersIn: "，,;；。！？!?"))
            .map { compactPhrase($0, limit: 20) }
            .filter {
                !$0.isEmpty &&
                $0.range(of: #"^(?:后续|下文|上文|这一点|具体)(?:再|会|将)?(?:说明|解释|展开|讨论|提到)?$"#, options: .regularExpression) == nil
            }
        let digest = phrases.prefix(2).joined(separator: " · ")
        return compactPhrase(digest.isEmpty ? value : digest, limit: 42)
    }

    private static func compactPhrase(_ source: String, limit: Int) -> String {
        let value = source
            .replacingOccurrences(of: #"^(?:因此|所以|同时|而且|也就是说|换言之)[，,:：\s]*"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard value.count > limit else { return value }
        return String(value.prefix(limit))
    }

    private static func compact(_ source: String, limit: Int) -> String {
        let value = HighlightTextNormalizer.inline(source)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard value.count > limit else { return value }
        return String(value.prefix(limit)) + "…"
    }
}

enum AIResponseFormatter {
    static func normalized(_ source: String) -> String {
        var text = source.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.filter({ $0 == "\n" }).count < 2, text.contains("\\n") {
            text = text.replacingOccurrences(of: "\\n", with: "\n")
        }
        text = text.replacingOccurrences(
            of: #"[ \t]+(?=#{2,4}\s+\S)"#,
            with: "\n\n",
            options: .regularExpression
        )
        text = text.replacingOccurrences(
            of: #"[ \t]+(?=[\-*•]\s+\S)"#,
            with: "\n",
            options: .regularExpression
        )
        text = text.replacingOccurrences(
            of: #"\n{3,}"#,
            with: "\n\n",
            options: .regularExpression
        )
        return text.components(separatedBy: .newlines)
            .map(paragraphizeIfNeeded)
            .joined(separator: "\n")
    }

    private static func paragraphizeIfNeeded(_ line: String) -> String {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.count > 180,
              trimmed.range(of: #"^(?:#{1,6}|[\-*•]|\d+[\.、)])\s*"#, options: .regularExpression) == nil,
              !trimmed.contains("http://"), !trimmed.contains("https://") else {
            return line
        }
        var result = ""
        var sentenceCount = 0
        for character in line {
            result.append(character)
            if "。！？!?；;".contains(character) {
                sentenceCount += 1
                if sentenceCount.isMultiple(of: 2) { result.append("\n\n") }
            }
        }
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

enum ChapterSummarySectionKind: String, CaseIterable, Identifiable {
    case question = "问题"
    case argument = "论证"
    case conclusion = "结论"
    case relation = "章际关系"

    var id: String { rawValue }
}

struct ChapterSummarySection: Identifiable, Equatable {
    var kind: ChapterSummarySectionKind
    var points: [String]
    var id: String { kind.rawValue }
}

enum ChapterSummaryParser {
    static func parse(_ source: String) -> [ChapterSummarySection] {
        var text = source.replacingOccurrences(of: "\\n", with: "\n")
        for kind in ChapterSummarySectionKind.allCases {
            let escaped = NSRegularExpression.escapedPattern(for: kind.rawValue)
            text = text.replacingOccurrences(
                of: #"(?m)(?:^|\s)[\-•]?\s*\*{0,2}"# + escaped + #"\*{0,2}\s*[:：]?\s*"#,
                with: "\n§\(kind.rawValue)§\n",
                options: .regularExpression
            )
        }
        text = text.replacingOccurrences(
            of: #"\s+(?=\d+[\.、\)]\s*)"#,
            with: "\n",
            options: .regularExpression
        )
        text = text.replacingOccurrences(
            of: #"\s+(?=(?:承上|启下)[:：])"#,
            with: "\n",
            options: .regularExpression
        )

        var buckets: [ChapterSummarySectionKind: [String]] = [:]
        var current: ChapterSummarySectionKind?
        for rawLine in text.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty else { continue }
            if line.hasPrefix("§"), line.hasSuffix("§") {
                let name = String(line.dropFirst().dropLast())
                current = ChapterSummarySectionKind(rawValue: name)
                continue
            }
            guard let current else { continue }
            let cleaned = line.replacingOccurrences(
                of: #"^(?:[\-•]|\d+[\.、\)])\s*"#,
                with: "",
                options: .regularExpression
            ).trimmingCharacters(in: .whitespacesAndNewlines)
            if !cleaned.isEmpty { buckets[current, default: []].append(cleaned) }
        }
        return ChapterSummarySectionKind.allCases.compactMap { kind in
            guard let points = buckets[kind], !points.isEmpty else { return nil }
            if kind == .relation,
               points.allSatisfy({ point in
                   point.contains("仅据标题") || point.contains("根据标题") || point.contains("据标题")
               }) {
                return nil
            }
            return ChapterSummarySection(kind: kind, points: points)
        }
    }
}

enum OCRTextNormalizer {
    static func normalize(_ text: String) -> String {
        let withoutCJKSpaces = text.replacingOccurrences(
            of: #"(?<=[\p{Han}0-9，。！？；：、‘’“”（）《》〈〉])[ \t]+(?=[\p{Han}0-9，。！？；：、‘’“”（）《》〈〉])"#,
            with: "",
            options: .regularExpression
        )
        let withoutOCRSpacing = withoutCJKSpaces.replacingOccurrences(
            of: #"(?<=[A-Za-z])[\x{00A0}\x{2000}-\x{200B}\x{202F}\x{2060}]+(?=[A-Za-z])"#,
            with: "",
            options: .regularExpression
        )
        return joinLetterByLetterOCR(in: withoutOCRSpacing)
    }

    static func removeSpuriousCJKSpaces(_ text: String) -> String { normalize(text) }

    private static func joinLetterByLetterOCR(in text: String) -> String {
        guard let expression = try? NSRegularExpression(
            pattern: #"(?i)\b(?:[a-z][ \t]+){2,}[a-z]\b"#
        ) else { return text }
        var result = text
        let range = NSRange(result.startIndex..<result.endIndex, in: result)
        for match in expression.matches(in: result, range: range).reversed() {
            guard let swiftRange = Range(match.range, in: result) else { continue }
            let joined = result[swiftRange].replacingOccurrences(
                of: #"[ \t]+"#,
                with: "",
                options: .regularExpression
            )
            result.replaceSubrange(swiftRange, with: joined)
        }
        return result
    }
}

enum HighlightTextNormalizer {
    static func inline(_ text: String) -> String {
        let lines = text
            .components(separatedBy: .newlines)
            .map { collapseHorizontalWhitespace($0).trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard var result = lines.first else { return "" }
        for line in lines.dropFirst() {
            if result.last == "-", line.first?.isLowercaseASCII == true {
                result.removeLast()
                result += line
            } else if result.last?.isLatinWordCharacter == true,
                      line.first?.isLatinWordCharacter == true {
                result += " " + line
            } else {
                result += line
            }
        }
        return OCRTextNormalizer.normalize(result)
    }

    private static func collapseHorizontalWhitespace(_ text: String) -> String {
        text.replacingOccurrences(of: #"[\t ]+"#, with: " ", options: .regularExpression)
    }
}

enum OCRSelectionTextCorrector {
    static func preferred(original: String, recognized: String) -> String? {
        let originalText = HighlightTextNormalizer.inline(original)
        let recognizedText = HighlightTextNormalizer.inline(recognized)
        let originalKey = comparisonKey(originalText)
        let recognizedKey = comparisonKey(recognizedText)
        guard originalKey.count >= 2, recognizedKey.count >= 2 else { return nil }
        let ratio = Double(recognizedKey.count) / Double(originalKey.count)
        guard (0.55...1.65).contains(ratio) else { return nil }
        let distance = editDistance(Array(originalKey), Array(recognizedKey))
        let similarity = 1 - Double(distance) / Double(max(originalKey.count, recognizedKey.count))
        guard similarity >= 0.58 else { return nil }
        return recognizedText
    }

    private static func comparisonKey(_ text: String) -> String {
        text.lowercased().filter { character in
            character.unicodeScalars.allSatisfy {
                CharacterSet.alphanumerics.contains($0) || (0x4E00...0x9FFF).contains($0.value)
            }
        }
    }

    private static func editDistance(_ lhs: [Character], _ rhs: [Character]) -> Int {
        if lhs.isEmpty { return rhs.count }
        if rhs.isEmpty { return lhs.count }
        var previous = Array(0...rhs.count)
        for (leftIndex, left) in lhs.enumerated() {
            var current = [leftIndex + 1] + Array(repeating: 0, count: rhs.count)
            for (rightIndex, right) in rhs.enumerated() {
                current[rightIndex + 1] = min(
                    current[rightIndex] + 1,
                    previous[rightIndex + 1] + 1,
                    previous[rightIndex] + (left == right ? 0 : 1)
                )
            }
            previous = current
        }
        return previous[rhs.count]
    }
}

private extension Character {
    var isLatinWordCharacter: Bool {
        unicodeScalars.allSatisfy { scalar in
            scalar.isASCII && (CharacterSet.alphanumerics.contains(scalar) || scalar == "_".unicodeScalars.first!)
        }
    }

    var isLowercaseASCII: Bool {
        unicodeScalars.count == 1 && unicodeScalars.allSatisfy { scalar in
            scalar.value >= 97 && scalar.value <= 122
        }
    }
}

struct OutlineEntry: Identifiable, Codable, Hashable {
    var id = UUID()
    var title: String
    var pageIndex: Int
    var level: Int
    var generated: Bool
}

struct BookmarkRecord: Identifiable, Codable, Hashable {
    var id = UUID()
    var title: String
    var pageIndex: Int
    var createdAt = Date()
}

struct PDFRect: Codable, Hashable {
    var x: Double
    var y: Double
    var width: Double
    var height: Double

    init(_ rect: CGRect) {
        x = rect.origin.x
        y = rect.origin.y
        width = rect.width
        height = rect.height
    }

    var cgRect: CGRect { CGRect(x: x, y: y, width: width, height: height) }
}

struct HighlightFragment: Codable, Hashable {
    var pageIndex: Int
    var bounds: PDFRect

    init(pageIndex: Int, bounds: CGRect) {
        self.pageIndex = pageIndex
        self.bounds = PDFRect(bounds)
    }
}

struct HighlightRecord: Identifiable, Codable, Hashable {
    var id = UUID()
    var text: String
    var pageIndex: Int
    var bounds: PDFRect
    var tint: HighlightTint
    var note: String?
    var createdAt = Date()
    // One reader gesture may span several text lines (or pages). Older saved
    // records have no fragments and transparently fall back to their legacy rect.
    var fragments: [HighlightFragment]? = nil
    var noteExportedAt: Date? = nil
    var kind: ReadingMarkKind? = nil

    var allFragments: [HighlightFragment] {
        guard let fragments, !fragments.isEmpty else {
            return [HighlightFragment(pageIndex: pageIndex, bounds: bounds.cgRect)]
        }
        return fragments
    }

    var inlineText: String { HighlightTextNormalizer.inline(text) }
    var isInNotes: Bool { noteExportedAt != nil }
    var markKind: ReadingMarkKind { kind ?? .highlight }
}

struct SearchRecord: Identifiable, Hashable {
    let id = UUID()
    var text: String
    var pageIndex: Int
}

struct ReadingQuestionPayload: Hashable {
    var pageNumber: Int?
    var focusedPassage: String?
    var request: String
}

enum ReadingQuestionParser {
    /// Questions created from a PDF selection use `P12\npassage\n\nrequest`.
    /// Separating the fields lets the API send the selected passage exactly
    /// once while retaining the compact question in conversation history.
    static func parse(_ source: String) -> ReadingQuestionPayload {
        let normalized = source.replacingOccurrences(of: "\r\n", with: "\n")
        let lines = normalized.components(separatedBy: .newlines)
        guard let first = lines.first?.trimmingCharacters(in: .whitespaces),
              first.range(of: #"^P\s*[0-9]+$"#, options: [.regularExpression, .caseInsensitive]) != nil,
              let digits = first.range(of: #"[0-9]+"#, options: .regularExpression).map({ String(first[$0]) }),
              let pageNumber = Int(digits),
              let separator = lines.indices.dropFirst().first(where: {
                  lines[$0].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
              }) else {
            return ReadingQuestionPayload(pageNumber: nil, focusedPassage: nil, request: source)
        }
        let passage = HighlightTextNormalizer.inline(lines[1..<separator].joined(separator: " "))
        let request = lines.dropFirst(separator + 1).joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !passage.isEmpty, !request.isEmpty else {
            return ReadingQuestionPayload(pageNumber: nil, focusedPassage: nil, request: source)
        }
        return ReadingQuestionPayload(pageNumber: pageNumber, focusedPassage: passage, request: request)
    }
}

struct APIUsage: Codable, Hashable {
    var inputTokens: Int
    var outputTokens: Int
    var totalTokens: Int
    var cachedInputTokens: Int = 0
    var cacheWriteTokens: Int = 0
    var reasoningTokens: Int = 0
    /// `true` when the provider omitted standard usage fields and the app had
    /// to estimate one or more values locally.
    var isEstimated: Bool? = nil

    var compactDescription: String {
        let marker = isEstimated == true ? "约 " : ""
        var parts = ["输入 \(marker)\(inputTokens)", "输出 \(marker)\(outputTokens)"]
        if cachedInputTokens > 0 { parts.append("缓存命中 \(cachedInputTokens)") }
        if cacheWriteTokens > 0 { parts.append("缓存写入 \(cacheWriteTokens)") }
        if reasoningTokens > 0 { parts.append("推理 \(reasoningTokens)") }
        return parts.joined(separator: " · ")
    }

    var uncachedInputTokens: Int { max(0, inputTokens - cachedInputTokens) }
    var cacheHitRate: Double? {
        guard inputTokens > 0 else { return nil }
        return min(1, max(0, Double(cachedInputTokens) / Double(inputTokens)))
    }
}

struct ChatTurn: Identifiable, Codable, Hashable {
    enum Role: String, Codable { case user, assistant }

    var id = UUID()
    var role: Role
    var content: String
    var pageReferences: [Int] = []
    /// The page where this question originated. Unlike `pageReferences`, this
    /// is not expanded with retrieved evidence pages, so Obsidian export can
    /// reliably choose the reader's intended chapter.
    var noteAnchorPageIndex: Int? = nil
    var createdAt = Date()
    var selectedForNotes = false
    var noteExportedAt: Date? = nil
    var apiUsage: APIUsage? = nil
    var servedFromLocalCache: Bool? = nil
    var requestModel: String? = nil
    var requestProvider: AIProvider? = nil
    var requestDepth: AIReadingDepth? = nil
    var contextChunkCount: Int? = nil
    var estimatedContextTokens: Int? = nil
    var usedWholeBook: Bool? = nil
    var usedWebSearch: Bool? = nil
    var wasServedFromLocalCache: Bool { servedFromLocalCache == true }
    var isInNotes: Bool { noteExportedAt != nil }
}
