import CryptoKit
import Foundation

actor OpenAIService {
    private struct CompletionResult {
        var text: String
        var usage: APIUsage?
        var wasTruncated: Bool
    }

    private struct APIErrorEnvelope: Decodable {
        struct APIError: Decodable {
            var message: String?
            var type: String?
            var code: String?
        }
        var error: APIError
    }

    struct ResponseEnvelope: Decodable {
        struct IncompleteDetails: Decodable {
            var reason: String?
        }
        struct Output: Decodable {
            struct Content: Decodable { var type: String; var text: String? }
            var type: String
            var content: [Content]?
        }
        var output: [Output]
        var status: String?
        var incompleteDetails: IncompleteDetails?

        private enum CodingKeys: String, CodingKey {
            case output, status
            case incompleteDetails = "incomplete_details"
        }
    }

    struct ChatCompletionEnvelope: Decodable {
        struct Choice: Decodable {
            struct Message: Decodable {
                var content: String?

                init(from decoder: Decoder) throws {
                    let container = try decoder.container(keyedBy: CodingKeys.self)
                    if let text = try? container.decode(String.self, forKey: .content) {
                        content = text
                    } else if let blocks = try? container.decode([TextBlock].self, forKey: .content) {
                        content = blocks.compactMap(\.text).joined()
                    } else {
                        content = nil
                    }
                }

                private enum CodingKeys: String, CodingKey { case content }
                private struct TextBlock: Decodable { var text: String? }
            }
            var message: Message
            var finishReason: String?

            private enum CodingKeys: String, CodingKey {
                case message
                case finishReason = "finish_reason"
            }
        }
        var choices: [Choice]
    }

    private struct AnthropicMessageEnvelope: Decodable {
        struct ContentBlock: Decodable {
            var type: String
            var text: String?
        }
        var content: [ContentBlock]
        var stopReason: String?

        private enum CodingKeys: String, CodingKey {
            case content
            case stopReason = "stop_reason"
        }
    }

    private struct ChatCompletionStreamEnvelope: Decodable {
        struct Choice: Decodable {
            struct Delta: Decodable { var content: String? }
            var delta: Delta
        }
        var choices: [Choice]
    }

    private struct OutlinePayload: Decodable {
        struct Entry: Decodable {
            var title: String
            var printedPage: Int?
            var level: Int
            var pageStyle: PrintedPageStyle?

            enum CodingKeys: String, CodingKey {
                case title, level
                case printedPage = "printed_page"
                case pageStyle = "page_style"
            }
        }
        var entries: [Entry]
    }

    func ask(
        question: String,
        context: [TextChunk],
        priorTurns: [ChatTurn],
        model: String,
        apiKey: String,
        provider: AIProvider,
        readingDepth: AIReadingDepth,
        usesWebSearch: Bool = false,
        usesWholeBook: Bool = false,
        bookOutline: [OutlineEntry] = [],
        cacheIdentity: String
    ) async throws -> ChatTurn {
        let questionPayload = ReadingQuestionParser.parse(question)
        var focusWasMarked = false
        let excerpts = context.map { chunk in
            var text = chunk.text
            var focusLabel = ""
            if !focusWasMarked, let focus = questionPayload.focusedPassage,
               let range = text.range(of: focus, options: [.caseInsensitive, .widthInsensitive]) {
                text.replaceSubrange(range, with: "⟦焦点⟧\(focus)⟦/焦点⟧")
                focusWasMarked = true
            } else if !focusWasMarked, let focus = questionPayload.focusedPassage {
                let compactText = HighlightTextNormalizer.inline(text).lowercased()
                let compactFocus = HighlightTextNormalizer.inline(focus).lowercased()
                if compactFocus.count >= 8, compactText.contains(compactFocus) {
                    focusLabel = "⟦焦点所在片段⟧\n"
                    focusWasMarked = true
                }
            }
            let heading = chunk.chapterTitle.map { "## \($0)\n" } ?? ""
            return "\(heading)[P\(chunk.pageIndex + 1)]\n\(focusLabel)\(text)"
        }.joined(separator: "\n\n")
        let fallbackFocus = questionPayload.focusedPassage.flatMap { focus in
            focusWasMarked ? nil : "焦点原文 [P\(questionPayload.pageNumber ?? 0)]：\n\(focus)\n\n"
        } ?? ""
        let history = priorTurns.dropLast().suffix(readingDepth.historyLimit).map { turn in
            let content = turn.role == .user ? ReadingQuestionParser.parse(turn.content).request : turn.content
            return "\(turn.role.rawValue): \(content)"
        }.joined(separator: "\n\n")
        let outlineMap = bookOutline.prefix(180).map {
            "\(String(repeating: "  ", count: min($0.level, 5)))- P\($0.pageIndex + 1) \($0.title)"
        }.joined(separator: "\n")
        let scope = usesWholeBook
            ? "全书结构（只作定位，判断仍以检索原文为证据）：\n\(outlineMap)\n\n"
            : ""
        let historyBlock = history.isEmpty ? "" : "同一选段的对话：\n\(history)\n\n"
        let input = """
        \(scope)\(historyBlock)\(fallbackFocus)相关原文（本地从 PDF 转换并检索出的紧凑 Markdown）：
        \(excerpts)

        \(questionPayload.request)
        """
        let searchInstructions = usesWebSearch
            ? """
            \n需要联网查找相关资源。只精选 3–5 个结果，优先官方页面、博物馆/展览机构、发行方、创作者主页和高质量专业资料，并按质量从高到低排列。
            每项严格使用两行：第一行 `### [资源名称](完整 URL)`；第二行只用一句话说明它与原文的关系和为什么值得看。不要追加更多链接、搜索过程或泛泛建议。
            """
            : ""
        let turnInstructions = Self.ljgReadTurnInstructions(
            priorTurns: priorTurns,
            usesWebSearch: usesWebSearch
        )
        let responseBudgetInstructions = Self.responseBudgetInstructions(for: readingDepth)
        let completion = try await completeText(
            system: Self.companionInstructions + responseBudgetInstructions + turnInstructions + searchInstructions,
            input: input,
            model: model,
            apiKey: apiKey,
            provider: provider,
            maxTokens: readingDepth.outputLimit,
            reasoningEffort: readingDepth.reasoningEffort,
            usesWebSearch: usesWebSearch,
            promptCacheKey: Self.promptCacheKey(model: model, cacheIdentity: cacheIdentity),
            timeout: 120
        )
        return ChatTurn(
            role: .assistant,
            content: completion.text,
            pageReferences: Array(Set(context.map(\.pageIndex))).sorted(),
            apiUsage: completion.usage,
            requestModel: model,
            requestProvider: provider,
            requestDepth: readingDepth,
            contextChunkCount: context.count,
            estimatedContextTokens: context.reduce(0) { $0 + LocalIndex.estimatedTokenCount($1.text) },
            usedWholeBook: usesWholeBook,
            usedWebSearch: usesWebSearch
        )
    }

    func condenseConversation(
        _ turns: [ChatTurn],
        model: String,
        apiKey: String,
        provider: AIProvider
    ) async throws -> String {
        let transcript = turns.map { turn in
            "\(turn.role == .user ? "读者" : "伴读")：\(turn.content)"
        }.joined(separator: "\n\n")
        let initialLimit = Self.condensedConversationTokenLimit(for: transcript)
        var completion = try await completeText(
            system: Self.condensedConversationInstructions,
            input: transcript,
            model: model,
            apiKey: apiKey,
            provider: provider,
            maxTokens: initialLimit,
            reasoningEffort: "low",
            timeout: 120
        )
        if Self.condensedConversationNeedsRetry(
            transcript: transcript,
            output: completion.text,
            wasTruncated: completion.wasTruncated
        ) {
            let retryLimit = min(16_000, max(initialLimit * 2, initialLimit + 2_000))
            completion = try await completeText(
                system: Self.condensedConversationInstructions + "\n这次必须在输出上限以内完整收束，正文控制在原文的 25%–35%；逐组覆盖全部问答。宁可进一步压缩措辞，也不能截断句子、遗漏独立结论或停在未完成的列表中。",
                input: transcript,
                model: model,
                apiKey: apiKey,
                provider: provider,
                maxTokens: retryLimit,
                reasoningEffort: "low",
                timeout: 180
            )
        }
        guard !completion.wasTruncated else { throw ServiceError.truncatedResponse }
        guard !Self.condensedConversationIsClearlyIncomplete(transcript: transcript, output: completion.text) else {
            throw ServiceError.incompleteCondensation
        }
        return completion.text
    }

    static let condensedConversationInstructions = """
    把选中的阅读对话整理成简洁但完整的中文笔记，目标长度约为原对话正文的 30%；不要再套用固定的 220 字或 800 字上限，短对话也不必为了凑足比例而重复。
    每组问答都必须保留：核心问题、直接答案、关键概念区分、支撑答案的主要论证或证据、最终结论；不同问答中的独立观点不得因篇幅而遗漏。
    删除寒暄、铺垫、重复、例行解释和相同观点的改写。使用短标题与项目符号，每条只承担一个逻辑动作；禁止补写对话中没有的事实，也禁止留下未完成的句子或列表。
    """

    static func condensedConversationTokenLimit(for transcript: String) -> Int {
        let sourceTokens = LocalIndex.estimatedTokenCount(transcript)
        let target = Int(ceil(Double(sourceTokens) * 0.30))
        let headroom = max(500, Int(ceil(Double(target) * 0.50)))
        return min(12_000, max(1_200, target + headroom))
    }

    static func condensedConversationNeedsRetry(
        transcript: String,
        output: String,
        wasTruncated: Bool
    ) -> Bool {
        wasTruncated || condensedConversationIsClearlyIncomplete(transcript: transcript, output: output)
    }

    static func condensedConversationIsClearlyIncomplete(transcript: String, output: String) -> Bool {
        let sourceTokens = LocalIndex.estimatedTokenCount(transcript)
        guard sourceTokens >= 800 else { return false }
        let outputTokens = LocalIndex.estimatedTokenCount(output)
        return outputTokens < max(160, Int(Double(sourceTokens) * 0.18))
    }

    func generateInlineChapterSummary(
        chapterTitle: String,
        context: [TextChunk],
        previousChapter: (String, [TextChunk])?,
        nextChapter: (String, [TextChunk])?,
        model: String,
        apiKey: String,
        provider: AIProvider
    ) async throws -> String {
        let source = Self.boundedChapterSource(context)
        let instructions = Self.inlineChapterSummaryInstructions
        let previous = previousChapter.map {
            "上一同级章节：\($0.0)\n\(Self.boundedChapterSource($0.1, limit: 4_000))"
        } ?? "上一同级章节：无"
        let next = nextChapter.map {
            "下一同级章节：\($0.0)\n\(Self.boundedChapterSource($0.1, limit: 4_000))"
        } ?? "下一同级章节：无"
        let input = "当前章节：\(chapterTitle)\n\n\(previous)\n\n\(next)\n\n当前章节原文：\n\(source)"
        var completion = try await completeText(
            system: instructions,
            input: input,
            model: model,
            apiKey: apiKey,
            provider: provider,
            maxTokens: 3_000,
            reasoningEffort: "low",
            timeout: 180
        )
        if completion.wasTruncated || !Self.chapterSummaryIsComplete(completion.text) {
            completion = try await completeText(
                system: instructions + "\n上一次结果未完整覆盖必选结构。本次必须完整输出问题、至少三步论证和结论，并在输出上限前自然结束；可以缩短措辞，但不能省略或截断必选项目。",
                input: input,
                model: model,
                apiKey: apiKey,
                provider: provider,
                maxTokens: 6_000,
                reasoningEffort: "low",
                timeout: 240
            )
        }
        guard !completion.wasTruncated, Self.chapterSummaryIsComplete(completion.text) else {
            throw ServiceError.incompleteChapterSummary
        }
        return completion.text
    }

    static func boundedChapterSource(_ chunks: [TextChunk], limit: Int = 36_000) -> String {
        guard !chunks.isEmpty, limit > 0 else { return "" }
        let blocks = chunks.map { "[第 \($0.pageIndex + 1) 页]\n\($0.text)\n\n" }
        let fullLength = blocks.reduce(0) { $0 + $1.count }
        if fullLength <= limit { return blocks.joined() }

        // Long chapters used to keep only their beginning. Select evenly over
        // the entire chapter so the same budget covers its opening, turns and
        // conclusion, then restore source order before sending it to the model.
        let averageLength = max(1, fullLength / blocks.count)
        let targetCount = max(2, min(blocks.count, limit / averageLength))
        var candidates = [0, blocks.count - 1]
        if targetCount > 2 {
            for position in 1..<(targetCount - 1) {
                let index = Int((Double(position) * Double(blocks.count - 1) / Double(targetCount - 1)).rounded())
                candidates.append(index)
            }
        }
        var selected = Set<Int>()
        var used = 0
        for index in candidates {
            guard selected.insert(index).inserted else { continue }
            if used + blocks[index].count <= limit {
                used += blocks[index].count
            } else {
                selected.remove(index)
            }
        }
        if selected.isEmpty, let first = blocks.first {
            return String(first.prefix(limit))
        }
        return selected.sorted().map { blocks[$0] }.joined()
    }

    static func chapterSummaryIsComplete(_ source: String) -> Bool {
        let sections = ChapterSummaryParser.parse(source)
        guard sections.first(where: { $0.kind == .question })?.points.isEmpty == false,
              let argument = sections.first(where: { $0.kind == .argument }), argument.points.count >= 3,
              sections.first(where: { $0.kind == .conclusion })?.points.isEmpty == false else {
            return false
        }
        return true
    }

    static let inlineChapterSummaryInstructions = """
    你是章节结构编辑。严格依据提供的原文揭示本章的问题、论证运动和章际位置，不得补写文本没有的观点。
    输出下面三个必选一级项目，不写自然段、开场白、标题或结束语：
    - **问题**
      - 作者在本章试图解决的核心问题；必要时补一个从属问题
    - **论证**
      1. 起点或前提
      2. 关键推进、证据或转折
      3. 如何抵达结论
    - **结论**
      - 本章最终建立了什么判断，以及它成立的条件或边界
    只有输入中确实提供了相邻章节的原文，而且原文能直接支持联系时，才追加：
    - **章际关系**
      - 承上：本章接过上一章原文中的什么问题
      - 启下：本章为下一章原文中的什么任务作准备
    如果只能依据相邻章节标题猜测，必须完全省略“章际关系”，不得输出“仅据标题判断”、全书起点或全书收束。
    每个一级项目和每个子项目必须各自独占一行，禁止把多个项目串在同一行。每个子项目用 `**` 只标出一个最关键的概念、判断或逻辑动作（2–16 字），不要把整句加粗。每点使用短语或紧凑句；论证部分保持逻辑顺序；关键判断尽量附 PDF 页码 `P数字`。根据章节复杂度控制在 500–900 字；必须完整写完必选结构，不能留下半句话、未完成列表或悬空标题。
    """

    struct ProviderDetection: Sendable {
        let provider: AIProvider
        let models: [String]
    }

    func detectProvider(apiKey: String) async throws -> ProviderDetection {
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard AIProvider.looksLikeCompleteAPIKey(key) else { throw ServiceError.invalidAPIKeyFormat }

        var firstConnectivityError: Error?
        for provider in AIProvider.detectionCandidates(for: key) {
            do {
                let models = try await availableModels(apiKey: key, provider: provider)
                guard !models.isEmpty else { continue }
                try await verifyCredential(apiKey: key, provider: provider, models: models)
                return ProviderDetection(provider: provider, models: models)
            } catch let error as ServiceError {
                switch error {
                case .invalidAPIKey, .permissionDenied, .invalidResponse, .requestFailed:
                    continue
                default:
                    if firstConnectivityError == nil { firstConnectivityError = error }
                }
            } catch {
                if firstConnectivityError == nil { firstConnectivityError = error }
            }
        }
        if let firstConnectivityError { throw firstConnectivityError }
        throw ServiceError.providerNotDetected
    }

    func validateCustomRelay(
        apiKey: String,
        baseURL: URL,
        directEndpoint: URL? = nil,
        protocol apiProtocol: CustomAPIProtocol = .openAIChat,
        authentication: CustomAPIAuthentication = .bearer,
        modelHint: String = ""
    ) async throws -> [String] {
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard authentication == .none || AIProvider.looksLikeCompleteAPIKey(key) else {
            throw ServiceError.invalidAPIKeyFormat
        }
        var modelsRequest = URLRequest(url: baseURL.appendingPathComponent("models"))
        modelsRequest.httpMethod = "GET"
        authentication.apply(to: &modelsRequest, apiKey: key)
        if apiProtocol == .anthropicMessages {
            modelsRequest.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        }
        modelsRequest.timeoutInterval = 30
        if let modelsData = try? await perform(modelsRequest),
           let models = try? decodedTextModels(from: modelsData), !models.isEmpty {
            return models
        }

        let explicitModel = modelHint.trimmingCharacters(in: .whitespacesAndNewlines)
        let inferredModel = directEndpoint.flatMap(Self.azureDeploymentName(from:))
        guard let model = [explicitModel, inferredModel ?? ""].first(where: { !$0.isEmpty }) else {
            throw ServiceError.customModelRequired
        }
        let endpoint = CustomRelayConfiguration.endpointURL(
            baseURL: baseURL,
            directEndpoint: directEndpoint,
            protocol: apiProtocol
        )
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        authentication.apply(to: &request, apiKey: key)
        if apiProtocol == .anthropicMessages {
            request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        }
        let body: [String: Any]
        switch apiProtocol {
        case .automatic, .openAIChat:
            body = ["model": model, "messages": [["role": "user", "content": "Reply with 1"]], "max_tokens": 1]
        case .openAIResponses:
            body = ["model": model, "input": "Reply with 1", "max_output_tokens": 16]
        case .anthropicMessages:
            body = ["model": model, "messages": [["role": "user", "content": "Reply with 1"]], "max_tokens": 1]
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        request.timeoutInterval = 45
        _ = try await perform(request)
        return [model]
    }

    private static func azureDeploymentName(from url: URL) -> String? {
        let components = url.pathComponents
        guard let index = components.firstIndex(of: "deployments"), components.indices.contains(index + 1) else {
            return nil
        }
        return components[index + 1]
    }

    private func verifyCredential(apiKey: String, provider: AIProvider, models: [String]) async throws {
        switch provider {
        case .openRouter:
            var request = URLRequest(url: provider.baseURL.appendingPathComponent("auth/key"))
            request.httpMethod = "GET"
            provider.applyAuthentication(to: &request, apiKey: apiKey)
            request.timeoutInterval = 20
            _ = try await perform(request)
        case .aiHubMix:
            // AIHUBMix may return its default public model catalogue when a
            // request is not authenticated. A one-token call is therefore the
            // only reliable way to distinguish its `sk-` keys from other
            // providers without asking the user to choose a platform.
            let preferred = models.first(where: { $0.localizedCaseInsensitiveContains("gpt-4o-mini") })
                ?? models.first(where: { $0.localizedCaseInsensitiveContains("flash") })
                ?? models[0]
            var request = URLRequest(url: provider.chatCompletionsURL)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            provider.applyAuthentication(to: &request, apiKey: apiKey)
            request.httpBody = try JSONSerialization.data(withJSONObject: [
                "model": preferred,
                "messages": [["role": "user", "content": "1"]],
                "max_tokens": 1,
                "stream": false
            ])
            request.timeoutInterval = 30
            _ = try await perform(request)
        default:
            break
        }
    }

    private func completeText(
        system: String,
        input: String,
        model: String,
        apiKey: String,
        provider: AIProvider,
        maxTokens: Int,
        reasoningEffort: String,
        usesWebSearch: Bool = false,
        promptCacheKey: String? = nil,
        timeout: TimeInterval
    ) async throws -> CompletionResult {
        if usesWebSearch && !provider.supportsWebSearch {
            throw ServiceError.webSearchUnsupported(provider.rawValue)
        }

        switch provider.apiStyle {
        case .responses:
            var body: [String: Any] = [
                "model": model,
                "instructions": system,
                "input": input,
                "max_output_tokens": maxTokens
            ]
            if Self.supportsReasoningEffort(model) {
                body["reasoning"] = ["effort": reasoningEffort]
            }
            if provider == .openAI, let promptCacheKey {
                body["prompt_cache_key"] = promptCacheKey
            }
            if usesWebSearch { body["tools"] = [["type": "web_search"]] }
            var request = URLRequest(url: provider.responsesURL)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            provider.applyAuthentication(to: &request, apiKey: apiKey)
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
            request.timeoutInterval = timeout
            let data = try await perform(request)
            let envelope = try JSONDecoder().decode(ResponseEnvelope.self, from: data)
            guard let text = Self.outputText(from: envelope),
                  !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw ServiceError.emptyResponse
            }
            return CompletionResult(
                text: text,
                usage: Self.resolvedUsage(from: data, system: system, input: input, output: text),
                wasTruncated: envelope.status == "incomplete"
                    || envelope.incompleteDetails?.reason == "max_output_tokens"
            )

        case .chatCompletions:
            let requestModel = provider == .aiHubMix && usesWebSearch && !model.hasSuffix(":surfing")
                ? model + ":surfing"
                : model
            var body: [String: Any] = [
                "model": requestModel,
                "messages": [
                    ["role": "system", "content": system],
                    ["role": "user", "content": input]
                ],
                "stream": false
            ]
            if provider == .aiHubMix {
                body["max_completion_tokens"] = maxTokens
                if Self.supportsReasoningEffort(model) { body["reasoning_effort"] = reasoningEffort }
            } else if provider == .customRelay, Self.supportsReasoningEffort(model) {
                body["max_completion_tokens"] = maxTokens
            } else {
                body["max_tokens"] = maxTokens
            }
            if provider == .openRouter, let promptCacheKey {
                body["prompt_cache_key"] = promptCacheKey
            }
            if provider == .openRouter && usesWebSearch {
                body["tools"] = [[
                    "type": "openrouter:web_search",
                    "parameters": ["max_results": 5]
                ]]
            }
            var request = URLRequest(url: provider.chatCompletionsURL)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            provider.applyAuthentication(to: &request, apiKey: apiKey)
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
            request.timeoutInterval = timeout
            let data = try await perform(request)
            let envelope = try JSONDecoder().decode(ChatCompletionEnvelope.self, from: data)
            let text = envelope.choices.compactMap(\.message.content).joined()
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw ServiceError.emptyResponse
            }
            return CompletionResult(
                text: text,
                usage: Self.resolvedUsage(from: data, system: system, input: input, output: text),
                wasTruncated: envelope.choices.contains {
                    ["length", "max_tokens", "max_output_tokens"].contains($0.finishReason ?? "")
                }
            )

        case .anthropicMessages:
            let systemValue: Any
            if provider == .anthropic, promptCacheKey != nil {
                systemValue = [[
                    "type": "text",
                    "text": system,
                    "cache_control": ["type": "ephemeral"]
                ]]
            } else {
                systemValue = system
            }
            var body: [String: Any] = [
                "model": model,
                "system": systemValue,
                "messages": [["role": "user", "content": input]],
                "max_tokens": maxTokens
            ]
            if usesWebSearch {
                body["tools"] = [[
                    "type": "web_search_20250305",
                    "name": "web_search",
                    "max_uses": 3
                ]]
            }
            var request = URLRequest(url: provider.messagesURL)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            provider.applyAuthentication(to: &request, apiKey: apiKey)
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
            request.timeoutInterval = timeout
            let data = try await perform(request)
            let envelope = try JSONDecoder().decode(AnthropicMessageEnvelope.self, from: data)
            let text = envelope.content.filter { $0.type == "text" }.compactMap(\.text).joined()
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw ServiceError.emptyResponse
            }
            return CompletionResult(
                text: text,
                usage: Self.resolvedUsage(from: data, system: system, input: input, output: text),
                wasTruncated: envelope.stopReason == "max_tokens"
            )
        }
    }

    private static func supportsReasoningEffort(_ model: String) -> Bool {
        let id = model.lowercased()
        return id.hasPrefix("gpt-5") || id.hasPrefix("o1") || id.hasPrefix("o3") || id.hasPrefix("o4")
    }

    private static func promptCacheKey(model: String, cacheIdentity: String) -> String {
        let digest = SHA256.hash(data: Data(("ljg-read-v1.3\u{1F}" + model + "\u{1F}" + cacheIdentity).utf8))
            .prefix(12).map { String(format: "%02x", $0) }.joined()
        return "reading-companion-\(digest)"
    }

    static func decodedUsage(from data: Data) -> APIUsage? {
        guard let object = try? JSONSerialization.jsonObject(with: data),
              let root = object as? [String: Any],
              let usage = usageDictionary(in: root) else { return nil }
        func integer(_ value: Any?) -> Int? {
            if let value = value as? NSNumber { return value.intValue }
            if let value = value as? Int { return value }
            if let value = value as? Double { return Int(value.rounded()) }
            if let value = value as? String, let number = Double(value) { return Int(number.rounded()) }
            return nil
        }
        func number(_ keys: String...) -> Int {
            for key in keys {
                if let value = integer(usage[key]) { return value }
            }
            return 0
        }
        let inputDetails = (usage["input_tokens_details"] ?? usage["prompt_tokens_details"] ?? usage["inputTokensDetails"]) as? [String: Any]
        let outputDetails = (usage["output_tokens_details"] ?? usage["completion_tokens_details"] ?? usage["outputTokensDetails"]) as? [String: Any]
        func detail(_ object: [String: Any]?, _ key: String) -> Int {
            integer(object?[key]) ?? 0
        }
        let input = number("input_tokens", "prompt_tokens", "inputTokens", "promptTokens", "promptTokenCount", "prompt_eval_count")
        let output = number("output_tokens", "completion_tokens", "outputTokens", "completionTokens", "candidatesTokenCount", "eval_count")
        let cached = max(
            detail(inputDetails, "cached_tokens"),
            number("cache_read_input_tokens", "cached_input_tokens", "cacheReadInputTokens")
        )
        let cacheWrite = max(
            detail(inputDetails, "cache_write_tokens"),
            number("cache_creation_input_tokens", "cache_write_input_tokens", "cacheCreationInputTokens")
        )
        let reasoning = max(
            detail(outputDetails, "reasoning_tokens"),
            number("reasoning_tokens", "reasoningTokens", "thoughtsTokenCount")
        )
        let total = max(number("total_tokens", "totalTokens", "totalTokenCount"), input + output)
        guard total > 0 || cached > 0 || cacheWrite > 0 else { return nil }
        return APIUsage(
            inputTokens: input,
            outputTokens: output,
            totalTokens: total,
            cachedInputTokens: cached,
            cacheWriteTokens: cacheWrite,
            reasoningTokens: reasoning
        )
    }

    private static func usageDictionary(in root: [String: Any]) -> [String: Any]? {
        for key in ["usage", "usageMetadata", "token_usage", "tokenUsage"] {
            if let usage = root[key] as? [String: Any] { return usage }
        }
        for key in ["data", "response", "result", "meta", "metadata"] {
            if let nested = root[key] as? [String: Any], let usage = usageDictionary(in: nested) {
                return usage
            }
        }
        return nil
    }

    /// Some relays omit usage or return only a total. Never present missing
    /// fields as a measured zero: fill them with a clearly labelled local
    /// estimate while preserving every value the provider did report.
    static func resolvedUsage(
        from data: Data,
        system: String,
        input: String,
        output: String
    ) -> APIUsage {
        let estimatedInput = LocalIndex.estimatedTokenCount(system)
            + LocalIndex.estimatedTokenCount(input) + 24
        let estimatedOutput = LocalIndex.estimatedTokenCount(output)
        guard var usage = decodedUsage(from: data) else {
            return APIUsage(
                inputTokens: estimatedInput,
                outputTokens: estimatedOutput,
                totalTokens: estimatedInput + estimatedOutput,
                isEstimated: true
            )
        }
        var estimated = false
        if usage.inputTokens <= 0 {
            usage.inputTokens = estimatedInput
            estimated = true
        }
        if usage.outputTokens <= 0 {
            usage.outputTokens = estimatedOutput
            estimated = true
        }
        usage.totalTokens = max(usage.totalTokens, usage.inputTokens + usage.outputTokens)
        if estimated { usage.isEstimated = true }
        return usage
    }

    func validate(apiKey: String, model: String, provider: AIProvider) async throws -> [String] {
        let models = try await availableModels(apiKey: apiKey, provider: provider)
        return models
    }

    func availableModels(apiKey: String, provider: AIProvider) async throws -> [String] {
        var request = URLRequest(url: provider.modelsURL)
        request.httpMethod = "GET"
        provider.applyAuthentication(to: &request, apiKey: apiKey)
        request.timeoutInterval = 30
        let data = try await perform(request)
        return try decodedTextModels(from: data)
    }

    private func decodedTextModels(from data: Data) throws -> [String] {
        guard let json = try? JSONSerialization.jsonObject(with: data) else { throw ServiceError.invalidResponse }
        let rows: [[String: Any]]
        if let dictionary = json as? [String: Any], let data = dictionary["data"] as? [[String: Any]] {
            rows = data
        } else if let array = json as? [[String: Any]] {
            rows = array
        } else if let dictionary = json as? [String: Any], let models = dictionary["models"] as? [[String: Any]] {
            rows = models
        } else if let dictionary = json as? [String: Any],
                  let output = dictionary["output"] as? [String: Any],
                  let models = output["models"] as? [[String: Any]] {
            rows = models
        } else {
            throw ServiceError.invalidResponse
        }
        let excluded = ["embedding", "moderation", "whisper", "tts", "dall-e", "image", "audio", "realtime", "transcribe"]
        let identifiers = rows.compactMap { row in
            (row["id"] ?? row["model"] ?? row["model_name"] ?? row["name"]) as? String
        }
        let filtered = Array(Set(identifiers.filter { id in
            !excluded.contains { id.localizedCaseInsensitiveContains($0) }
        })).sorted()
        return filtered
    }

    func modelCatalog(for provider: AIProvider) async throws -> [String] {
        guard let url = provider.modelCatalogURL else { return [] }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 30
        let data = try await perform(request)
        struct Catalog: Decodable {
            struct Model: Decodable {
                var modelID: String
                var types: String?
                var inputModalities: String?

                enum CodingKeys: String, CodingKey {
                    case types
                    case modelID = "model_id"
                    case inputModalities = "input_modalities"
                }
            }
            var data: [Model]
        }
        guard let catalog = try? JSONDecoder().decode(Catalog.self, from: data) else {
            throw ServiceError.invalidResponse
        }
        let excluded = ["embedding", "moderation", "whisper", "tts", "dall-e", "image", "audio", "realtime", "transcribe", "video"]
        return Array(Set(catalog.data.compactMap { item -> String? in
            guard item.types?.localizedCaseInsensitiveContains("llm") != false,
                  item.inputModalities?.localizedCaseInsensitiveContains("text") != false,
                  !excluded.contains(where: { item.modelID.localizedCaseInsensitiveContains($0) }) else { return nil }
            return item.modelID
        })).sorted()
    }

    func generateOutlineFromTOC(
        pages: [PageText],
        tocPageIndices: [Int],
        model: String,
        apiKey: String,
        provider: AIProvider
    ) async throws -> [OutlineEntry] {
        guard !pages.isEmpty else { throw ServiceError.invalidOutline }
        guard !tocPageIndices.isEmpty else { throw ServiceError.tocPagesNotFound }
        let contents = TOCPageTextBuilder.build(pages: pages, pageIndices: tocPageIndices)
        guard !contents.isEmpty else { throw ServiceError.tocPagesNotFound }
        let localCandidates = TOCReliableParser.parse(contents)
        let schema: [String: Any] = [
            "type": "object",
            "properties": [
                "entries": [
                    "type": "array",
                    "items": [
                        "type": "object",
                        "properties": [
                            "title": ["type": "string"],
                            "printed_page": ["type": ["integer", "null"]],
                            "page_style": ["type": ["string", "null"], "enum": ["arabic", "roman", NSNull()]],
                            "level": ["type": "integer", "minimum": 0, "maximum": 5]
                        ],
                        "required": ["title", "printed_page", "page_style", "level"],
                        "additionalProperties": false
                    ]
                ]
            ],
            "required": ["entries"],
            "additionalProperties": false
        ]
        let instructions = """
        你是目录抄录与结构化工具。输入只包含已定位的连续目录页全文。
        目录页是唯一事实来源：只返回目录页明确列出的篇、部、章、节、序言、结语、附录等条目，严禁根据正文常识补写、改写或推断任何标题。
        OCR 文字已经依据页面坐标重建阅读顺序：双栏按“左栏从上到下，再右栏从上到下”，传统竖排按“从右栏到左栏、每栏从上到下”。不要把左右两栏同一高度的文字横向拼成一条。
        按目录页原顺序和原文字样完整抄录；合并因 OCR 换行而拆开的同一条目，排除“目录”页标题、页眉、页脚、单独页码、作者名与书名。
        一个 entries 元素只能对应一个目录条目。如果同一 OCR 行中出现两个章节序号、两个尾页码，或“前一条页码 + 后一条标题”，必须拆成两个元素，不得把双栏的相邻条目混成一个标题。
        若“目录/目次”因 OCR 紧贴或穿插在第一条前，先移除这几个页标题字，再完整保留后面的第一条；绝不能因此丢弃首条。
        必须从目录首页标题下方的第一条有效条目开始。序、前言、引言、导言即使很短或使用罗马页码也属于目录条目，不得因为它位于第一行而漏掉。
        printed_page 必须是该条目在目录页末尾印刷的页码；罗马数字请换算为整数。page_style 对阿拉伯数字填 arabic、罗马数字填 roman；确实没有页码时两者才填 null。
        “上篇/下篇、第一部分/第二部分、卷”等分组标题即使没有印刷页码也必须单独保留为条目；没有页码的分组标题使用紧随其后的第一个目录条目的页码与 page_style。
        level 0 表示篇/部或最高层，1 表示章，2 表示节，依次类推。
        返回前在内部核对：第一条、最后一条和跨页连接处是否都已覆盖。绝不能返回目录页上没有出现的标题。
        """
        let candidateHint = localCandidates.enumerated().map { index, entry in
            "\(index + 1). \(entry.title)\(entry.printedPage.map { " · \($0)" } ?? "")"
        }.joined(separator: "\n")
        let input = """
        请逐行读取以下 \(tocPageIndices.count) 个目录页的完整文字并结构化。

        本地逐行扫描得到的防漏候选如下。它只用于提醒你核对首条和换行条目，最终仍必须以目录原文为准：
        \(candidateHint.isEmpty ? "（无候选，请完全依照原文）" : candidateHint)

        目录原文：
        \(contents)
        """
        _ = schema // Documents the intended portable JSON shape for providers without strict schemas.
        let text = try await completeText(
            system: instructions + "\n只输出一个 JSON 对象，根字段必须是 entries；不要输出 Markdown 代码围栏或任何解释。",
            input: input,
            model: model,
            apiKey: apiKey,
            provider: provider,
            maxTokens: 8_000,
            reasoningEffort: provider.outlineReasoningEffort,
            timeout: 240
        )
        guard let json = Self.jsonObjectData(from: text.text) else {
            throw ServiceError.emptyResponse
        }
        let payload = try JSONDecoder().decode(OutlinePayload.self, from: json)
        var seen = Set<String>()
        let rawAIEntries = payload.entries.compactMap { entry -> TOCSourceEntry? in
            let title = TOCInputNormalizer.cleanEntryTitle(entry.title)
            guard title.count >= 2, title.count <= 180 else { return nil }
            let key = "\(entry.printedPage.map(String.init) ?? "nil")|\(entry.level)|\(title.lowercased())"
            guard seen.insert(key).inserted else { return nil }
            return TOCSourceEntry(
                title: title,
                printedPage: entry.printedPage,
                level: min(max(entry.level, 0), 5),
                pageStyle: entry.pageStyle
            )
        }
        let aiEntries = rawAIEntries.flatMap { entry -> [TOCSourceEntry] in
            let pageSuffix = entry.printedPage.map { " \($0)" } ?? ""
            let separated = TOCTextParser.parse(entry.title + pageSuffix)
            guard separated.count > 1 else { return [entry] }
            return separated.map { candidate in
                TOCSourceEntry(
                    title: candidate.title,
                    printedPage: candidate.printedPage,
                    level: candidate.level,
                    pageStyle: candidate.pageStyle
                )
            }
        }
        // 本地逐行结果守住首条与原顺序，AI 负责补漏并修正等价条目的层级。
        let sourceEntries = TOCSourceMerger.merge(primary: localCandidates, secondary: aiEntries)
        let entries = TOCPageResolver.resolve(sourceEntries, tocPageIndices: tocPageIndices, pages: pages)
        guard !entries.isEmpty, entries.count <= 2_000 else {
            throw ServiceError.invalidOutline
        }
        return entries
    }

    static func outputText(from envelope: ResponseEnvelope) -> String? {
        let parts = envelope.output
            .flatMap { $0.content ?? [] }
            .filter { $0.type == "output_text" }
            .compactMap(\.text)
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        guard !parts.isEmpty else { return nil }
        return parts.joined(separator: "\n\n")
    }

    static func jsonObjectData(from text: String) -> Data? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let start = trimmed.firstIndex(of: "{"), let end = trimmed.lastIndex(of: "}"), start <= end else {
            return nil
        }
        return String(trimmed[start...end]).data(using: .utf8)
    }

    static func isRetryableNetworkError(_ code: URLError.Code) -> Bool {
        switch code {
        case .networkConnectionLost, .timedOut, .cannotConnectToHost, .cannotFindHost, .dnsLookupFailed:
            true
        default:
            false
        }
    }

    static func chatStreamDelta(from line: String) -> String? {
        guard line.hasPrefix("data:") else { return nil }
        let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
        guard payload != "[DONE]", let data = payload.data(using: .utf8),
              let event = try? JSONDecoder().decode(ChatCompletionStreamEnvelope.self, from: data) else {
            return nil
        }
        return event.choices.compactMap(\.delta.content).joined()
    }

    private func performStreamingChat(_ originalRequest: URLRequest, provider: AIProvider) async throws -> String {
        let maximumAttempts = 3
        for attempt in 1...maximumAttempts {
            var request = originalRequest
            if attempt == maximumAttempts,
               let originalURL = originalRequest.url,
               let fallbackURL = provider.fallbackURL(for: originalURL) {
                request.url = fallbackURL
            }
            do {
                let (bytes, response) = try await URLSession.shared.bytes(for: request)
                guard let http = response as? HTTPURLResponse else { throw ServiceError.invalidResponse }
                guard (200..<300).contains(http.statusCode) else {
                    var errorData = Data()
                    for try await byte in bytes.prefix(1_000_000) { errorData.append(byte) }
                    if [502, 503, 504].contains(http.statusCode), attempt < maximumAttempts {
                        try await Self.retryDelay(after: attempt)
                        continue
                    }
                    throw Self.httpError(data: errorData, statusCode: http.statusCode)
                }

                var result = ""
                var nonStreamingPayload = ""
                for try await line in bytes.lines {
                    if line.trimmingCharacters(in: .whitespacesAndNewlines) == "data: [DONE]" { break }
                    if line.hasPrefix("data:") {
                        if let delta = Self.chatStreamDelta(from: line) { result += delta }
                    } else if !line.hasPrefix(":") {
                        nonStreamingPayload += line
                    }
                }
                if result.isEmpty,
                   let data = nonStreamingPayload.data(using: .utf8),
                   let envelope = try? JSONDecoder().decode(ChatCompletionEnvelope.self, from: data) {
                    result = envelope.choices.compactMap(\.message.content).joined()
                }
                guard !result.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    throw ServiceError.emptyResponse
                }
                return result
            } catch let error as URLError {
                guard error.code != .cancelled else { throw error }
                if Self.isRetryableNetworkError(error.code), attempt < maximumAttempts {
                    try await Self.retryDelay(after: attempt)
                    continue
                }
                throw Self.serviceError(for: error, attempts: attempt, host: request.url?.host)
            }
        }
        throw ServiceError.serverUnavailable
    }

    private func perform(_ request: URLRequest) async throws -> Data {
        let maximumAttempts = 3
        for attempt in 1...maximumAttempts {
            do {
                let (data, response) = try await URLSession.shared.data(for: request)
                guard let http = response as? HTTPURLResponse else { throw ServiceError.invalidResponse }
                if [502, 503, 504].contains(http.statusCode), attempt < maximumAttempts {
                    try await Self.retryDelay(after: attempt)
                    continue
                }
                guard (200..<300).contains(http.statusCode) else {
                    throw Self.httpError(data: data, statusCode: http.statusCode)
                }
                return data
            } catch let error as URLError {
                guard error.code != .cancelled else { throw error }
                if Self.isRetryableNetworkError(error.code), attempt < maximumAttempts {
                    try await Self.retryDelay(after: attempt)
                    continue
                }
                throw Self.serviceError(for: error, attempts: attempt, host: request.url?.host)
            }
        }
        throw ServiceError.serverUnavailable
    }

    private static func httpError(data: Data, statusCode: Int) -> ServiceError {
        let apiError = try? JSONDecoder().decode(APIErrorEnvelope.self, from: data).error
        let code = apiError?.code ?? ""
        let safeMessage = errorMessage(from: data)
        switch statusCode {
        case 401:
            return .invalidAPIKey
        case 403:
            return .permissionDenied(safeMessage)
        case 402:
            return .insufficientCredits
        case 429 where code == "credit_balance_exhausted":
            return .insufficientCredits
        case 429:
            return .rateLimited
        case 500...599:
            return .serverUnavailable
        default:
            return .requestFailed(safeMessage ?? "HTTP \(statusCode)")
        }
    }

    static func errorMessage(from data: Data) -> String? {
        if let message = (try? JSONDecoder().decode(APIErrorEnvelope.self, from: data))?.error.message {
            return String(message.prefix(300))
        }
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        if let message = object["message"] as? String { return String(message.prefix(300)) }
        if let error = object["error"] as? String { return String(error.prefix(300)) }
        return nil
    }

    private static func retryDelay(after attempt: Int) async throws {
        try await Task.sleep(nanoseconds: UInt64(attempt) * 600_000_000)
    }

    private static func serviceError(for error: URLError, attempts: Int, host: String?) -> ServiceError {
        switch error.code {
        case .notConnectedToInternet, .dataNotAllowed, .internationalRoamingOff:
            .offline
        case .timedOut:
            .networkTimedOut(attempts)
        case .networkConnectionLost:
            .networkInterrupted(attempts)
        case .cannotConnectToHost, .cannotFindHost, .dnsLookupFailed:
            .cannotReachService(host ?? "AI 服务", error.errorCode, attempts)
        case .secureConnectionFailed, .serverCertificateHasBadDate, .serverCertificateUntrusted,
             .serverCertificateHasUnknownRoot, .serverCertificateNotYetValid, .clientCertificateRejected:
            .secureConnectionFailed(host ?? "AI 服务", error.errorCode)
        default:
            .transportFailure(error.errorCode, String(error.localizedDescription.prefix(200)))
        }
    }

    static let companionInstructions = """
    <ljg_read_protocol version="1.2.0" skill="ljg-read">
    你是 Reading Companion，严格执行 ljg-read：不是替读者读，而是陪读者走进原文；默认中文，原文始终在场。把本协议视为每一轮都已触发的 ljg-read 技能，而不是可选的写作风格。

    证据边界：涉及文本判断必须引用提供的页码；明确标记“原文”“我的推断”“外部资料”。片段不足时直接说证据不足，绝不编造页码、章节、引文或作者观点。
    文本校读：用户粘贴的 PDF 文字可能有 OCR 错字、断词和多余空格。先根据相邻原文在内部谨慎复原；有把握的修复直接用于理解，不得在回答中列出或解释“修正了哪些 OCR 错误”。只有歧义会实质改变结论时，才简短说明两种可能读法。
    结构阅读：先判断用户实际问了几个相连的问题，再还原它们为何属于同一条逻辑链。需要定位时，在内部把材料区分为 [骨] 核心论点、[肌] 证据/例子、[筋] 过渡；输出只呈现真正有助理解的结构，并说明前文如何来到这里、当前段完成什么论证动作、后文将接过什么任务。
    概念定位：解释术语时，不只给词典定义；必须说明“它在这段文字里具体指什么”。遇到“X、Y、Z 是否都属于 A”一类问题，要区分理论来源、研究对象、分析层级、操作方法、证据和结论，禁止把亲缘关系误写成上下位关系。
    论证重建：优先从原文恢复“问题 -> 区分 -> 推进 -> 结论”的链条。只有结构确实复杂时才使用简短树状图；图后必须用一句话说清最容易混淆的边界。
    解释与翻译：英文难句按需区分“直译（信）/意译（达）/点睛（雅）”，首次出现的关键术语保留英文原词与一句话定义；中文文本不做多余翻译。
    读者参与：不要把伴读退化为“用户问、工具答”。先给足够具体、可校验的回答，再从作者前提、论证跳跃、概念边界或读者刚形成的判断中，只提出一个无法靠复述原文回答的碰撞问题。问题必须承接本轮最关键的区分，迫使读者选择判断标准或承担一个推论。读者回应后，先把他刚提出的标准压成一句可检验命题，再把它套回原文，而不是泛泛赞同或重新讲一遍。
    写作质量与版式：先用 1–2 句直接回答；在不损失关键区分、证据与论证链的前提下删去复述。正文使用 2–3 个由问题自然生成的 `###` 小标题；标题前后必须空一行。并列判断必须分点，每点只承担一个逻辑动作，项目之间换行；每段不超过 2 句，不得把多个段落挤在同一行。每节只把 1–2 个真正承重的概念或区分写成 `**关键词/短句**`，不要整段加粗。短引文紧贴分析；避免空泛开场、重复总结、机械输出固定栏目，也不要展示内部推理过程。结尾的碰撞问题单独成节，保持一句。
    节奏命令：支持“快进 / 展开 / 等一下”。读者说“快进”时只给一句摘要和关键词；说“展开”或“等一下”时进入精读、注疏和压力测试。
    注疏克制：同构、对手、源流三种视角每次只选最有价值的一条；清楚标记外部知识，不垄断解释权。
    输出使用适合应用阅读的 Markdown；保留 ljg-read 的方法与边界，不输出 Org 文件语法。
    </ljg_read_protocol>
    """

    static func responseBudgetInstructions(for depth: AIReadingDepth) -> String {
        let target: String
        switch depth {
        case .economical: target = "约 700–1,000 个汉字，最多 3 个短节"
        case .balanced: target = "约 1,200–1,800 个汉字，最多 4 个短节"
        case .deep: target = "约 2,000–3,000 个汉字，最多 6 个短节"
        }
        return """

        <response_budget max_output_tokens="\(depth.outputLimit)">
        本轮可见答案目标为\(target)；max_output_tokens 仅作为包含推理与正文在内的 API 安全上限。这是生成前的篇幅规划，不是生成后的裁剪：先在内部确定完整结论和最短论证路线，再开始输出。
        必须在上限到来前自然收束。内容过多时，主动删除次要例子、重复解释和低价值分支，但必须保留直接答案、必要证据、关键区分与论证闭环；若本轮协议要求碰撞问题，也必须完整写完。
        禁止写到一半停止；不得留下半句话、未完成列表、悬空标题、未闭合 Markdown 或“下文继续”。最后一个字符必须属于一条已经完成的句子。
        </response_budget>
        """
    }

    static func ljgReadTurnInstructions(
        priorTurns: [ChatTurn],
        usesWebSearch: Bool
    ) -> String {
        if usesWebSearch {
            return """

            <ljg_read_turn mode="resource_search">
            本轮只完成精选资源卡片，不追加碰撞问题；外部资料必须和原文判断分开。
            </ljg_read_turn>
            """
        }
        let previousAssistant = priorTurns.dropLast().last(where: { $0.role == .assistant })
        let isReaderReply = previousAssistant.map {
            $0.content.contains("### 碰撞") || $0.content.trimmingCharacters(in: .whitespacesAndNewlines).hasSuffix("？")
        } ?? false
        if isReaderReply {
            return """

            <ljg_read_turn mode="reader_reply">
            这是读者对上一轮碰撞问题的回应。先把读者刚提出的区分、标准或因果判断压成一句清楚命题，再把这个命题套回原文检验，指出它让原文中哪一处变得更清楚；不要只说“你抓住了要害”。然后只走一个分支：
            - 读者接受作者观点：给出最强反驳做压力测试，并追问读者如何回应。
            - 读者不确定或只表达不适：帮他定位到具体句子，并区分“不认同结论 / 论证有跳跃 / 不接受前提”，只问一个最能缩小范围的问题。
            - 读者提出明确反驳：判断它击中前提、推理还是证据；若成立，追问“作者补上这一点后论证是否仍成立”；若源于误读，并排放回原文让读者自行校验。
            如果读者发现了概念层级、判断对象或举证责任的变化，要明确命名这个变化，并检查作者是否在两个对象之间发生了偷换。不要重复上一轮说明，不要另起炉灶，不要一次问多个问题。末尾用 `### 碰撞` 单独放置唯一的下一问。
            </ljg_read_turn>
            """
        }
        return """

        <ljg_read_turn mode="new_question">
        先完成以下内部检查再作答，但不要机械照抄步骤名称，也不要为了显得完整而输出无关栏目：
        1. 校正会改变理解的 OCR 错字或断句；
        2. 把用户的多个疑问拆开，再指出它们为什么其实相关；
        3. 用短引文确认原文直接说了什么，并把推断与原文明确分开；
        4. 区分理论来源、判断对象、分析层级、操作方法、证据与结论；尤其检查“亲缘关系”是否被误当成“上下位关系”；
        5. 定位前文提出的问题、当前段的论证动作与目标、下文接过的任务；
        6. 先用一句话回答读者，再用最短的结构复现作者如何得出它。只有关系至少有三个节点时才画层级或因果图。
        内部比较三种候选：作者要求读者接受的隐含前提、最可能的推理跳跃、最强反对意见；只选对当前读者最有杀伤力的一项。
        回答末尾必须用 `### 碰撞` 提出唯一一个具体问题。这个问题要迫使读者作出判断或连接自身经验，不能只是“你怎么看”或让读者复述原文。学术文本锚定既有认知，哲学文本锚定日常决定，散文锚定感受，新闻锚定立场。
        </ljg_read_turn>
        """
    }

    enum ServiceError: LocalizedError {
        case invalidAPIKeyFormat
        case providerNotDetected
        case webSearchUnsupported(String)
        case invalidAPIKey
        case permissionDenied(String?)
        case insufficientCredits
        case rateLimited
        case serverUnavailable
        case invalidResponse
        case customModelListUnavailable
        case customModelRequired
        case offline
        case networkTimedOut(Int)
        case networkInterrupted(Int)
        case cannotReachService(String, Int, Int)
        case secureConnectionFailed(String, Int)
        case transportFailure(Int, String)
        case modelUnavailable(String)
        case tocPagesNotFound
        case invalidOutline
        case requestFailed(String)
        case emptyResponse
        case truncatedResponse
        case incompleteCondensation
        case incompleteChapterSummary

        var errorDescription: String? {
            switch self {
            case .invalidAPIKeyFormat: "这不像完整的 API Key。请粘贴平台生成的真实密钥，不要使用示例、星号遮罩或带空格的内容。"
            case .providerNotDetected: "无法识别这个 API Key 所属的平台。请确认密钥有效、账户已有 API 权限，并允许当前网络访问服务商。"
            case .webSearchUnsupported(let provider): "\(provider) 当前接口不支持应用内联网搜索；普通伴读仍可使用。"
            case .invalidAPIKey: "API Key 无效或已失效。请在“设置 > AI”中粘贴完整密钥并重新识别；本次运行中的密钥已清除。"
            case .permissionDenied(let detail): detail.map { "AI 服务商拒绝了请求：\($0)" }
                ?? "AI 服务商拒绝了请求。请检查密钥与模型权限。"
            case .insufficientCredits: "AI 服务商账户余额不足，请在对应平台补充额度。"
            case .rateLimited: "AI 服务请求过于频繁，请稍后重试。"
            case .serverUnavailable: "AI 服务暂时不可用，请稍后重试。"
            case .invalidResponse: "AI 服务商返回了无法识别的网络响应。"
            case .customModelListUnavailable: "中转站没有返回可用模型列表。请确认 Base URL 指向 OpenAI 兼容接口，并支持 /models。"
            case .customModelRequired: "该接口没有开放模型列表。请填写平台给出的模型 ID 或 Azure Deployment 名称后再次连接。"
            case .offline: "Mac 当前无法连接互联网。目录页 OCR 已保留；恢复网络后再次点击目录识别即可。"
            case .networkTimedOut(let attempts): "等待 AI 服务响应超时（网络错误 -1001，已尝试 \(attempts) 次）。目录页 OCR 已保留，请稍后重试或换一个响应更快的模型。"
            case .networkInterrupted(let attempts): "AI 服务连接在响应完成前被中断（网络错误 -1005，已尝试 \(attempts) 次）。目录页 OCR 已保留，请稍后再次识别。"
            case .cannotReachService(let host, let code, let attempts): "无法连接 \(host)（网络错误 \(code)，已尝试 \(attempts) 次）。请检查网络、代理或 DNS 后重试。"
            case .secureConnectionFailed(let host, let code): "无法与 \(host) 建立安全连接（网络错误 \(code)）。请检查系统时间、代理或证书设置。"
            case .transportFailure(let code, let detail): "AI 网络请求失败（错误 \(code)）：\(detail)"
            case .modelUnavailable(let model): "当前密钥在所选服务商中无法使用模型“\(model)”。请从该平台的模型列表复制准确的模型 ID，或检查密钥的模型权限。"
            case .tocPagesNotFound: "没有定位到可信的目录页。请确认 PDF 中确实包含印刷目录页，且 OCR 已完成。"
            case .invalidOutline: "AI 没有从目录页生成可映射的章节目录。请检查目录页 OCR 和印刷页码是否清晰。"
            case .requestFailed(let detail): "AI 请求失败：\(detail)"
            case .emptyResponse: "AI 服务商返回了空响应。"
            case .truncatedResponse: "AI 两次都在整理完成前达到输出上限，因此没有写入不完整的笔记。请减少本次选择的对话数量后重试。"
            case .incompleteCondensation: "AI 返回的整理内容明显不完整，因此没有写入笔记。请减少本次选择的对话数量，或切换更适合长文本的模型后重试。"
            case .incompleteChapterSummary: "AI 两次都没有完整生成章节概要，因此没有保存残缺结果。请切换更适合长文本的模型后重新生成。"
            }
        }
    }
}
