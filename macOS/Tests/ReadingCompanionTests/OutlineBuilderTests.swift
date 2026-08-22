import PDFKit
import Testing
@testable import ReadingCompanion

@Suite("Reading Companion core logic")
struct ReadingCompanionTests {
    @Test func storesProviderKeysUnderSeparateLocalAccounts() {
        #expect(APIKeyStore.fileName == "credentials.binary-plist")
        #expect(AIProvider.openAI.storageAccount == "openai")
        #expect(AIProvider.aiHubMix.storageAccount == "aihubmix")
        #expect(AIProvider.anthropic.storageAccount == "anthropic")
        #expect(AIProvider.googleGemini.storageAccount == "google-gemini")
        #expect(AIProvider.deepSeek.storageAccount == "deepseek")
        #expect(AIProvider.openRouter.storageAccount == "openrouter")
    }

    @Test func localCredentialStorePersistsAndDeletesWithoutKeychain() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ReadingCompanionCredentialTest-\(UUID().uuidString)", isDirectory: true)
        let store = APIKeyStore(directoryURL: directory)
        let fakeKey = "sk-test-only-not-a-real-secret-123456"
        try await store.save(fakeKey, for: .aiHubMix)
        #expect(try await store.load(for: .aiHubMix) == fakeKey)
        let file = directory.appendingPathComponent(APIKeyStore.fileName)
        let permissions = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber
        #expect(permissions?.intValue == 0o600)
        try await store.delete(for: .aiHubMix)
        #expect(try await store.load(for: .aiHubMix) == nil)
        try? FileManager.default.removeItem(at: directory)
    }

    @Test func usesReasoningValueSupportedByAIHubMixTerra() {
        #expect(AIProvider.aiHubMix.outlineReasoningEffort == "none")
        #expect(AIProvider.aiHubMix.outlineReasoningEffort != "minimal")
    }

    @Test func routesProvidersToSeparateTrustedHosts() {
        #expect(AIProvider.openAI.modelsURL.absoluteString == "https://api.openai.com/v1/models")
        #expect(AIProvider.openAI.responsesURL.absoluteString == "https://api.openai.com/v1/responses")
        #expect(AIProvider.aiHubMix.modelsURL.absoluteString == "https://aihubmix.com/v1/models")
        #expect(AIProvider.aiHubMix.modelCatalogURL?.absoluteString.contains("/api/v1/models") == true)
        #expect(AIProvider.aiHubMix.responsesURL.absoluteString == "https://aihubmix.com/v1/responses")
        #expect(AIProvider.aiHubMix.chatCompletionsURL.absoluteString == "https://aihubmix.com/v1/chat/completions")
        #expect(AIProvider.aiHubMix.fallbackURL(for: AIProvider.aiHubMix.chatCompletionsURL)?.absoluteString == "https://api.aihubmix.com/v1/chat/completions")
        #expect(AIProvider.openAI.baseURL.host != AIProvider.aiHubMix.baseURL.host)
        #expect(AIProvider.anthropic.messagesURL.absoluteString == "https://api.anthropic.com/v1/messages")
        #expect(AIProvider.googleGemini.chatCompletionsURL.absoluteString == "https://generativelanguage.googleapis.com/v1beta/openai/chat/completions")
        #expect(AIProvider.deepSeek.chatCompletionsURL.absoluteString == "https://api.deepseek.com/chat/completions")
        #expect(AIProvider.openRouter.chatCompletionsURL.absoluteString == "https://openrouter.ai/api/v1/chat/completions")
    }

    @Test func APIKeyPrefixesOnlyPrioritizeProviderDetection() {
        #expect(AIProvider.detectionCandidates(for: "sk-ant-example-key-1234567890") == [.anthropic])
        #expect(AIProvider.detectionCandidates(for: "sk-or-example-key-1234567890") == [.openRouter])
        #expect(AIProvider.detectionCandidates(for: "AIzaExampleKey1234567890") == [.googleGemini])
        let generic = AIProvider.detectionCandidates(for: "sk-example-key-1234567890")
        #expect(generic.first == .openAI)
        #expect(generic.contains(.deepSeek))
        #expect(generic.contains(.aiHubMix))
        #expect(AIProvider.looksLikeCompleteAPIKey("sk-example-key-1234567890"))
        #expect(!AIProvider.looksLikeCompleteAPIKey("sk-****"))
    }

    @Test func customRelayBaseURLIsNormalizedAndRequiresHTTPS() {
        #expect(CustomRelayConfiguration.normalizedBaseURL(
            from: " https://relay.example.com/v1/chat/completions/ "
        )?.absoluteString == "https://relay.example.com/v1")
        #expect(CustomRelayConfiguration.normalizedBaseURL(
            from: "https://relay.example.com"
        )?.absoluteString == "https://relay.example.com/v1")
        #expect(CustomRelayConfiguration.normalizedBaseURL(from: "http://relay.example.com/v1") == nil)
        #expect(CustomRelayConfiguration.normalizedBaseURL(from: "https://user:pass@relay.example.com/v1") == nil)
    }

    @Test func customAPIDetectsAzureAndFullProtocolEndpoints() {
        let azure = "https://reader.openai.azure.com/openai/deployments/book-gpt/chat/completions?api-version=2024-10-21"
        #expect(CustomRelayConfiguration.normalizedBaseURL(from: azure)?.absoluteString
            == "https://reader.openai.azure.com/openai/deployments/book-gpt")
        #expect(CustomRelayConfiguration.directEndpoint(from: azure)?.absoluteString == azure)
        #expect(CustomRelayConfiguration.resolvedProtocol(for: azure, requested: .automatic) == .openAIChat)
        #expect(CustomRelayConfiguration.resolvedAuthentication(
            for: azure, protocol: .openAIChat, requested: .automatic
        ) == .apiKeyHeader)

        let responses = "https://ark.cn-beijing.volces.com/api/v3/responses"
        #expect(CustomRelayConfiguration.resolvedProtocol(for: responses, requested: .automatic) == .openAIResponses)
        let anthropic = "https://token-plan.cn-beijing.maas.aliyuncs.com/apps/anthropic/v1/messages"
        #expect(CustomRelayConfiguration.resolvedProtocol(for: anthropic, requested: .automatic) == .anthropicMessages)
        #expect(CustomRelayConfiguration.resolvedAuthentication(
            for: anthropic, protocol: .anthropicMessages, requested: .automatic
        ) == .xAPIKey)
    }

    @Test func customAPIAllowsPlainHTTPOnlyOnThisMac() {
        #expect(CustomRelayConfiguration.normalizedBaseURL(from: "http://localhost:11434/v1")?.absoluteString
            == "http://localhost:11434/v1")
        #expect(CustomRelayConfiguration.resolvedAuthentication(
            for: "http://127.0.0.1:8000/v1", protocol: .openAIChat, requested: .automatic
        ) == .none)
        #expect(CustomRelayConfiguration.normalizedBaseURL(from: "http://relay.example.com/v1") == nil)
    }

    @Test func customAPIAuthenticationUsesExpectedHeaders() {
        var azure = URLRequest(url: URL(string: "https://example.com")!)
        CustomAPIAuthentication.apiKeyHeader.apply(to: &azure, apiKey: "secret")
        #expect(azure.value(forHTTPHeaderField: "api-key") == "secret")
        #expect(azure.value(forHTTPHeaderField: "Authorization") == nil)

        var anthropic = URLRequest(url: URL(string: "https://example.com")!)
        CustomAPIAuthentication.xAPIKey.apply(to: &anthropic, apiKey: "secret")
        #expect(anthropic.value(forHTTPHeaderField: "x-api-key") == "secret")
    }

    @Test func customRelayIsNeverGuessedFromKeyAlone() {
        #expect(!AIProvider.detectionCandidates(for: "sk-example-valid-looking-key").contains(.customRelay))
    }

    @Test func importsNewAPIConnectionInfoAndNormalizesItsURL() throws {
        let raw = #"{"_type":"newapi_channel_conn","key":"sk-test-key-1234567890","url":"https://relay.example.com"}"#
        let info = try CustomRelayConnectionInfo.parse(raw)
        #expect(info.apiKey == "sk-test-key-1234567890")
        #expect(info.baseURL.absoluteString == "https://relay.example.com/v1")
    }

    @Test func rejectsIncompleteOrUnknownRelayConnectionInfo() {
        #expect(throws: CustomRelayConnectionInfoError.self) {
            try CustomRelayConnectionInfo.parse(
                #"{"_type":"another_type","key":"sk-test-key-1234567890","url":"https://relay.example.com"}"#
            )
        }
        #expect(throws: CustomRelayConnectionInfoError.self) {
            try CustomRelayConnectionInfo.parse(
                #"{"_type":"newapi_channel_conn","key":"sk-****","url":"https://relay.example.com"}"#
            )
        }
    }

    @Test func retriesOnlyTransientNetworkFailures() {
        #expect(OpenAIService.isRetryableNetworkError(.networkConnectionLost))
        #expect(OpenAIService.isRetryableNetworkError(.timedOut))
        #expect(OpenAIService.isRetryableNetworkError(.cannotConnectToHost))
        #expect(!OpenAIService.isRetryableNetworkError(.notConnectedToInternet))
        #expect(!OpenAIService.isRetryableNetworkError(.cancelled))
    }

    @Test func extractsJSONObjectFromModelCodeFence() {
        let text = "```json\n{\"entries\":[]}\n```"
        let data = OpenAIService.jsonObjectData(from: text)
        #expect(data.flatMap { String(data: $0, encoding: .utf8) } == "{\"entries\":[]}")
    }

    @Test func collectsTextFromChatCompletionStreamEvent() {
        let line = "data: {\"choices\":[{\"delta\":{\"content\":\"第一章\"}}]}"
        #expect(OpenAIService.chatStreamDelta(from: line) == "第一章")
        #expect(OpenAIService.chatStreamDelta(from: "data: [DONE]") == nil)
        #expect(OpenAIService.chatStreamDelta(from: ": keep-alive") == nil)
    }

    @Test func emptyDocumentProducesNoOutline() {
        let document = PDFDocument()
        #expect(OutlineBuilder.entries(for: document).isEmpty)
    }

    @Test func detectsEmbeddedOutlineWithoutDependingOnSearchablePageText() throws {
        let document = PDFDocument()
        let page = PDFPage()
        document.insert(page, at: 0)
        let root = PDFOutline()
        let chapter = PDFOutline()
        chapter.label = "第一章 扫描页也可带自有目录"
        chapter.destination = PDFDestination(page: page, at: .zero)
        root.insertChild(chapter, at: 0)
        document.outlineRoot = root

        let entry = try #require(OutlineBuilder.entries(for: document).first)
        #expect(entry.title == "第一章 扫描页也可带自有目录")
        #expect(entry.pageIndex == 0)
    }

    @Test func pdfRectRoundTrip() {
        let original = CGRect(x: 12, y: 24, width: 120, height: 18)
        #expect(PDFRect(original).cgRect == original)
    }

    @Test func multiLineGestureRemainsOneLogicalHighlight() {
        let fragments = [
            HighlightFragment(pageIndex: 4, bounds: CGRect(x: 10, y: 100, width: 180, height: 16)),
            HighlightFragment(pageIndex: 4, bounds: CGRect(x: 10, y: 80, width: 140, height: 16))
        ]
        let record = HighlightRecord(
            text: "第一行文字\n第二行文字",
            pageIndex: 4,
            bounds: fragments[0].bounds,
            tint: .yellow,
            fragments: fragments
        )
        let logicalHighlights = [record]
        #expect(logicalHighlights.count == 1)
        #expect(record.allFragments == fragments)
        #expect(record.inlineText == "第一行文字第二行文字")
        #expect(!record.inlineText.contains("\n"))
    }

    @Test func overlappingPDFTextFragmentsCollapseBeforePaintingAndOCR() {
        let fragments = [
            HighlightFragment(pageIndex: 2, bounds: CGRect(x: 10, y: 100, width: 90, height: 16)),
            HighlightFragment(pageIndex: 2, bounds: CGRect(x: 88, y: 100.5, width: 18, height: 15)),
            HighlightFragment(pageIndex: 2, bounds: CGRect(x: 10, y: 80, width: 70, height: 16))
        ]
        let normalized = HighlightFragmentNormalizer.normalize(fragments)
        #expect(normalized.count == 2)
        #expect(normalized[0].bounds.cgRect.minX == 10)
        #expect(normalized[0].bounds.cgRect.maxX == 106)
    }

    @Test func duplicateOCRBoxKeepsOnlyTheCompleteLine() {
        let text = OCRLayoutReconstructor.text(from: [
            OCRLineObservation(
                text: "电",
                boundingBox: CGRect(x: 0.1, y: 0.8, width: 0.08, height: 0.05),
                confidence: 0.72
            ),
            OCRLineObservation(
                text: "电影研究",
                boundingBox: CGRect(x: 0.1, y: 0.8, width: 0.32, height: 0.05),
                confidence: 0.97
            )
        ])
        #expect(text == "电影研究")
    }

    @Test func legacyAutomaticTOCKeepsThe04216OCRRowOrdering() {
        let observations = [
            OCRLineObservation(text: "第一章 起点", boundingBox: CGRect(x: 0.10, y: 0.80, width: 0.48, height: 0.04)),
            OCRLineObservation(text: "1", boundingBox: CGRect(x: 0.82, y: 0.80, width: 0.03, height: 0.04))
        ]
        #expect(OCRLayoutReconstructor.legacyAutomaticTOCText(from: observations) == "第一章 起点\n1")
        #expect(OCRLayoutReconstructor.text(from: observations) == "第一章 起点 1")
    }

    @Test func legacyAutomaticTOCKeepsThe04216EnglishNormalization() {
        let source = "Chapter1 Opening 1\nChapter2 Argument 12"
        let legacy = TOCTextParser.parse(source, legacyAutomatic: true)
        let current = TOCTextParser.parse(source)
        #expect(legacy.map(\.title) == ["Chapter1 Opening", "Chapter2 Argument"])
        #expect(current.map(\.title) == ["Chapter 1 Opening", "Chapter 2 Argument"])
    }

    @Test func normalizesWrappedHighlightTextWithoutDamagingLatinWords() {
        #expect(HighlightTextNormalizer.inline("这是第一行\n接着第二行") == "这是第一行接着第二行")
        #expect(HighlightTextNormalizer.inline("the first line\nthe second line") == "the first line the second line")
        #expect(HighlightTextNormalizer.inline("inter-\nnational") == "international")
    }

    @Test func removesSpuriousOCRSpacesBetweenChineseCharacters() {
        #expect(OCRTextNormalizer.removeSpuriousCJKSpaces("这 是 一 段 文 字") == "这是一段文字")
        #expect(OCRTextNormalizer.removeSpuriousCJKSpaces("问题 ： 如 何 理 解？") == "问题：如何理解？")
        #expect(OCRTextNormalizer.removeSpuriousCJKSpaces("第 4 章") == "第4章")
        #expect(OCRTextNormalizer.removeSpuriousCJKSpaces("OpenAI API") == "OpenAI API")
    }

    @Test func removesSpuriousOCRSpacesInsideEnglishWords() {
        #expect(OCRTextNormalizer.normalize("f i l m theory") == "film theory")
        #expect(OCRTextNormalizer.normalize("cine\u{2009}ma studies") == "cinema studies")
        #expect(OCRTextNormalizer.normalize("OpenAI API") == "OpenAI API")
    }

    @Test func legacyHighlightWithoutFragmentsStillRenders() {
        let bounds = CGRect(x: 12, y: 24, width: 120, height: 18)
        let record = HighlightRecord(text: "旧划线", pageIndex: 2, bounds: PDFRect(bounds), tint: .blue)
        #expect(record.allFragments == [HighlightFragment(pageIndex: 2, bounds: bounds)])
    }

    @Test func obsidianDeepLinkUsesVaultAndRelativeFileWithStrictPlusEncoding() {
        let vault = URL(fileURLWithPath: "/Users/example/Desktop/reading companion + obsidian笔记", isDirectory: true)
        let note = vault.appendingPathComponent("Reading Companion/电影研究导论.md")
        let url = ObsidianDeepLink.openURL(vault: vault, note: note)
        #expect(url != nil)
        #expect(url?.absoluteString.contains("vault=reading%20companion%20%2B%20obsidian") == true)
        let items = url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false)?.queryItems }
        #expect(items?.first(where: { $0.name == "vault" })?.value == "reading companion + obsidian笔记")
        #expect(items?.first(where: { $0.name == "file" })?.value == "Reading Companion/电影研究导论.md")
    }

    @Test func obsidianDeepLinkRejectsNoteOutsideSelectedVault() {
        let vault = URL(fileURLWithPath: "/Users/example/Vault", isDirectory: true)
        let note = URL(fileURLWithPath: "/Users/example/Elsewhere/note.md")
        #expect(ObsidianDeepLink.openURL(vault: vault, note: note) == nil)
    }

    @Test func readsRegisteredObsidianVaultAndFindsContainingRoot() {
        let data = Data(#"{"vaults":{"abc":{"path":"/Users/example/Documents/Obsidian Vault","ts":1,"open":true}}}"#.utf8)
        let registered = ObsidianVaultRegistry.decode(data: data)
        #expect(registered.map(\.path) == ["/Users/example/Documents/Obsidian Vault"])
        let note = URL(fileURLWithPath: "/Users/example/Documents/Obsidian Vault/Reading Companion/book.md")
        #expect(ObsidianVaultRegistry.containingVault(for: note, registered: registered)?.path == "/Users/example/Documents/Obsidian Vault")
        let wrong = URL(fileURLWithPath: "/Users/example/Documents/Obsidian Vault Backup/book.md")
        #expect(ObsidianVaultRegistry.containingVault(for: wrong, registered: registered) == nil)
    }

    @Test func localIndexRetrievesChineseQuestion() {
        let pages = [
            PageText(pageIndex: 0, text: "第一章讨论自由与责任之间的关系。", cameFromOCR: false),
            PageText(pageIndex: 1, text: "第二章转向技术系统与组织效率。", cameFromOCR: false)
        ]
        let chunks = LocalIndex.makeChunks(pages: pages, outline: [])
        let result = LocalIndex.retrieve("自由为什么伴随责任？", from: chunks, limit: 1)
        #expect(result.first?.pageIndex == 0)
    }

    @Test func readingRetrievalKeepsFocusedPassageAndNeighborsInOrder() {
        let chunks = (0..<5).map {
            TextChunk(pageIndex: $0, chapterTitle: "章节", text: $0 == 2 ? "再现研究与符号学" : "相邻论证 \($0)")
        }
        let result = LocalIndex.retrieveForReading("再现研究", focusPageIndex: 2, from: chunks)
        #expect(result.map(\.pageIndex).contains(1))
        #expect(result.map(\.pageIndex).contains(2))
        #expect(result.map(\.pageIndex).contains(3))
        #expect(result.map(\.pageIndex) == result.map(\.pageIndex).sorted())
    }

    @Test func obsidianInsertionPreservesManualNotes() {
        let outline = [OutlineEntry(title: "第一章", pageIndex: 0, level: 0, generated: true)]
        let original = ObsidianNoteBuilder.skeleton(title: "测试书", sourcePath: nil, outline: outline)
            + "\n用户手写内容"
        let record = HighlightRecord(
            text: "原文",
            pageIndex: 0,
            bounds: PDFRect(CGRect(x: 0, y: 0, width: 10, height: 10)),
            tint: .yellow,
            note: "我的批注"
        )
        let merged = ObsidianNoteBuilder.insert(
            block: ObsidianNoteBuilder.highlightBlock(record),
            into: original,
            afterPage: 0
        )
        #expect(merged.contains("用户手写内容"))
        #expect(merged.contains("[!warning]"))
        #expect(merged.contains("[!note]"))
    }

    @Test func obsidianHighlightsKeepTheirOriginalColors() {
        let bounds = PDFRect(CGRect(x: 0, y: 0, width: 10, height: 10))
        let yellow = HighlightRecord(text: "黄", pageIndex: 0, bounds: bounds, tint: .yellow)
        let red = HighlightRecord(text: "红", pageIndex: 0, bounds: bounds, tint: .red)
        let blue = HighlightRecord(text: "蓝", pageIndex: 0, bounds: bounds, tint: .blue)
        #expect(ObsidianNoteBuilder.highlightBlock(yellow).contains("[!warning]"))
        #expect(ObsidianNoteBuilder.highlightBlock(red).contains("[!danger]"))
        #expect(ObsidianNoteBuilder.highlightBlock(blue).contains("[!info]"))
        #expect(!ObsidianNoteBuilder.highlightBlock(yellow).contains("<!--"))
    }

    @Test func annotationsUseTheirOwnGreenObsidianStyle() {
        let record = HighlightRecord(
            text: "需要进一步核对的原文",
            pageIndex: 3,
            bounds: PDFRect(CGRect(x: 0, y: 0, width: 10, height: 10)),
            tint: .yellow,
            note: "我的批注",
            kind: .annotation
        )
        #expect(record.markKind == .annotation)
        #expect(ObsidianNoteBuilder.highlightBlock(record).contains("[!success]"))
        #expect(!ObsidianNoteBuilder.highlightBlock(record).contains("<!--"))
    }

    @Test func companionPromptEmbedsTheLJGReadProtocol() {
        #expect(OpenAIService.companionInstructions.contains("<ljg_read_protocol version=\"1.2.0\" skill=\"ljg-read\">"))
        #expect(OpenAIService.companionInstructions.contains("[骨]"))
        #expect(OpenAIService.companionInstructions.contains("快进 / 展开 / 等一下"))
        #expect(OpenAIService.companionInstructions.contains("原文始终在场"))
        #expect(OpenAIService.companionInstructions.contains("文本校读"))
        #expect(OpenAIService.companionInstructions.contains("研究对象"))
        #expect(OpenAIService.companionInstructions.contains("上下位关系"))
        let firstTurn = OpenAIService.ljgReadTurnInstructions(
            priorTurns: [ChatTurn(role: .user, content: "这段在说什么？")],
            usesWebSearch: false
        )
        #expect(firstTurn.contains("mode=\"new_question\""))
        #expect(firstTurn.contains("### 碰撞"))
        let replyTurn = OpenAIService.ljgReadTurnInstructions(
            priorTurns: [
                ChatTurn(role: .assistant, content: "回答。\n\n### 碰撞\n你接受吗？"),
                ChatTurn(role: .user, content: "我不接受这个前提。")
            ],
            usesWebSearch: false
        )
        #expect(replyTurn.contains("mode=\"reader_reply\""))
        #expect(replyTurn.contains("最强反驳"))
    }

    @Test func inlineChapterSummaryRequiresLogicalPointsAndChapterRelations() {
        let prompt = OpenAIService.inlineChapterSummaryInstructions
        #expect(prompt.contains("不写自然段"))
        #expect(prompt.contains("**问题**"))
        #expect(prompt.contains("**论证**"))
        #expect(prompt.contains("**结论**"))
        #expect(prompt.contains("**章际关系**"))
        #expect(prompt.contains("承上"))
        #expect(prompt.contains("启下"))
        #expect(prompt.contains("独占一行"))
        #expect(prompt.contains("只标出一个最关键"))
        #expect(prompt.contains("只能依据相邻章节标题猜测"))
        #expect(prompt.contains("完全省略“章际关系”"))
        #expect(prompt.contains("250–450 字"))
        #expect(prompt.contains("不能留下半句话"))
    }

    @Test func longChapterSummarySourceCoversBeginningMiddleAndEnd() {
        let chunks = (0..<10).map { index in
            TextChunk(pageIndex: index, chapterTitle: "长章", text: "片段\(index)-" + String(repeating: "内容", count: 90))
        }
        let source = OpenAIService.boundedChapterSource(chunks, limit: 700)
        #expect(source.count <= 700)
        #expect(source.contains("片段0-"))
        #expect(source.contains("片段5-"))
        #expect(source.contains("片段9-"))
    }

    @Test func chapterSummaryCompletenessRequiresAllMandatorySections() {
        let complete = """
        - **问题** 如何界定对象？
        - **论证**
          1. 建立前提
          2. 引入证据
          3. 得出判断
        - **结论** 对象具有历史边界
        """
        #expect(OpenAIService.chapterSummaryIsComplete(complete))
        #expect(!OpenAIService.chapterSummaryIsComplete("- **问题** 如何界定对象？\n- **论证** 1. 建立前提"))
    }

    @Test func chapterSummaryParserRestoresSectionsFromOneLineOutput() {
        let summary = "- **问题** 如何界定电影？ - **论证** 1. 从媒介出发 2. 转向制度条件 3. 得出开放定义 - **结论** 电影是一组实践 - **章际关系** 承上：提出对象 启下：进入形式分析"
        let sections = ChapterSummaryParser.parse(summary)
        #expect(sections.map(\.kind) == [.question, .argument, .conclusion, .relation])
        #expect(sections.first(where: { $0.kind == .argument })?.points.count == 3)
        #expect(sections.first(where: { $0.kind == .relation })?.points.count == 2)
    }

    @Test func chapterSummaryParserDropsRelationBasedOnlyOnTitles() {
        let summary = """
        - **问题** 如何界定电影？
        - **论证** 从媒介出发
        - **结论** 电影是一组实践
        - **章际关系**
          - 承上：仅据标题判断
          - 启下：根据标题推测进入形式分析
        """
        let sections = ChapterSummaryParser.parse(summary)
        #expect(sections.map(\.kind) == [.question, .argument, .conclusion])
    }

    @Test func quickQuestionsOnlyInsertTheirVisibleLabels() {
        #expect(QuickQuestionPrompt.explanation == "解释一下")
        #expect(QuickQuestionPrompt.context == "联系上下文")
        #expect(QuickQuestionPrompt.resources == "链接资源")
    }

    @Test func oldDocumentStateDecodesWithoutCachedChapterSummaries() throws {
        let legacy = Data(#"{"lastPageIndex":2,"bookmarks":[],"highlights":[],"chats":[]}"#.utf8)
        let state = try JSONDecoder().decode(DocumentState.self, from: legacy)
        #expect(state.lastPageIndex == 2)
        #expect(state.chapterSummaries == nil)
        #expect(state.outlineWasManuallyEdited == nil)
    }

    @Test func obsidianAIDiscussionsCanStartCollapsedOrExpanded() {
        let turns = [ChatTurn(role: .user, content: "为什么？"), ChatTurn(role: .assistant, content: "因为。")]
        let collapsed = ObsidianNoteBuilder.aiBlock(turns: turns, pages: [2], collapsed: true)
        let expanded = ObsidianNoteBuilder.aiBlock(turns: turns, pages: [2], collapsed: false)
        #expect(collapsed.contains("> [!example]- AI 讨论"))
        #expect(expanded.contains("> [!example]+ AI 讨论"))
        #expect(collapsed.contains("**问题：**"))
        #expect(collapsed.contains("第 3 页"))
    }

    @Test func chatNoteIncludesQuestionEvenIfItWasPreviouslyMarkedExported() {
        var question = ChatTurn(role: .user, content: "核心问题")
        question.noteExportedAt = Date()
        var answer = ChatTurn(role: .assistant, content: "完整回答的结论与论证")
        answer.selectedForNotes = true
        answer.noteExportedAt = Date()
        let turns = ReaderModel.chatTurnsForNote(from: [question, answer])
        #expect(turns.map(\.content) == ["核心问题", "完整回答的结论与论证"])
    }

    @Test func obsidianAIBlockDoesNotTruncateLongAnswers() {
        let ending = "这是回答最后一句，必须保留。"
        let content = String(repeating: "论证段落包含关键证据。\n\n", count: 800) + ending
        let block = ObsidianNoteBuilder.aiBlock(
            turns: [ChatTurn(role: .assistant, content: content)],
            pages: [8],
            collapsed: true
        )
        #expect(block.contains(ending))
        #expect(block.count > content.count)
    }

    @Test func condensedChatTargetsThirtyPercentWithAdaptiveHeadroom() {
        #expect(OpenAIService.condensedConversationInstructions.contains("30%"))
        #expect(OpenAIService.condensedConversationInstructions.contains("不要再套用固定"))
        let medium = String(repeating: "论", count: 10_000)
        let veryLong = String(repeating: "论", count: 30_000)
        #expect(OpenAIService.condensedConversationTokenLimit(for: "短对话") == 1_200)
        #expect(OpenAIService.condensedConversationTokenLimit(for: medium) == 4_500)
        #expect(OpenAIService.condensedConversationTokenLimit(for: veryLong) == 12_000)
        #expect(OpenAIService.condensedConversationNeedsRetry(
            transcript: String(repeating: "原", count: 2_000),
            output: String(repeating: "摘", count: 120),
            wasTruncated: false
        ))
        #expect(!OpenAIService.condensedConversationNeedsRetry(
            transcript: String(repeating: "原", count: 2_000),
            output: String(repeating: "摘", count: 520),
            wasTruncated: false
        ))
    }

    @Test func outlineNoteLocatorKeepsUnlabelledIntroductionTextInParentChapter() {
        let outline = [
            OutlineEntry(title: "导论", pageIndex: 10, level: 0, generated: true),
            OutlineEntry(title: "1.1 研究对象", pageIndex: 11, level: 1, generated: true),
            OutlineEntry(title: "1.2 研究方法", pageIndex: 11, level: 1, generated: true)
        ]
        let page = """
        这一段没有小标题，先提出全章的问题。
        1.1 研究对象
        第一小节讨论电影文本。
        1.2 研究方法
        第二小节讨论分析路径。
        """
        #expect(OutlineNoteLocator.chapterTitle(
            for: 11,
            sourceText: "这一段没有小标题，先提出全章的问题。",
            pageText: page,
            outline: outline
        ) == "导论")
        #expect(OutlineNoteLocator.chapterTitle(
            for: 11,
            sourceText: "第一小节讨论电影文本。",
            pageText: page,
            outline: outline
        ) == "1.1 研究对象")
        #expect(OutlineNoteLocator.chapterTitle(
            for: 11,
            sourceText: "第二小节讨论分析路径。",
            pageText: page,
            outline: outline
        ) == "1.2 研究方法")
    }

    @Test func parentChapterNoteIsInsertedBeforeItsFirstSubsection() {
        let outline = [
            OutlineEntry(title: "导论", pageIndex: 10, level: 0, generated: true),
            OutlineEntry(title: "1.1 研究对象", pageIndex: 11, level: 1, generated: true),
            OutlineEntry(title: "1.2 研究方法", pageIndex: 12, level: 1, generated: true)
        ]
        let original = ObsidianNoteBuilder.skeleton(title: "测试", sourcePath: nil, outline: outline)
        let merged = ObsidianNoteBuilder.insert(
            block: "导论开头的 AI 讨论",
            into: original,
            afterPage: 11,
            chapterTitle: "导论"
        )
        let parent = merged.range(of: "## 导论")!
        let note = merged.range(of: "导论开头的 AI 讨论")!
        let subsection = merged.range(of: "### 1.1 研究对象")!
        #expect(note.lowerBound > parent.upperBound)
        #expect(note.upperBound < subsection.lowerBound)
    }

    @Test func obsidianInsertionTargetsExactNestedChapterOnSharedPage() {
        let outline = [
            OutlineEntry(title: "第一章", pageIndex: 4, level: 0, generated: true),
            OutlineEntry(title: "第一节", pageIndex: 4, level: 1, generated: true),
            OutlineEntry(title: "第二节", pageIndex: 9, level: 1, generated: true)
        ]
        let original = ObsidianNoteBuilder.skeleton(title: "测试", sourcePath: nil, outline: outline)
        let merged = ObsidianNoteBuilder.insert(
            block: "第一节专属内容",
            into: original,
            afterPage: 4,
            chapterTitle: "第一节"
        )
        guard let firstSection = merged.range(of: "### 第一节"),
              let inserted = merged.range(of: "第一节专属内容"),
              let secondSection = merged.range(of: "### 第二节") else {
            Issue.record("没有找到预期的章节或插入内容")
            return
        }
        #expect(inserted.lowerBound > firstSection.upperBound)
        #expect(inserted.upperBound < secondSection.lowerBound)
    }

    @Test func obsidianServiceSkipsARepeatedOwnedRecord() async throws {
        let noteURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("ReadingCompanionDedup-\(UUID().uuidString).md")
        defer { try? FileManager.default.removeItem(at: noteURL) }
        try ObsidianNoteBuilder.skeleton(title: "测试", sourcePath: nil, outline: [])
            .write(to: noteURL, atomically: true, encoding: .utf8)
        let record = HighlightRecord(
            text: "不可重复",
            pageIndex: 0,
            bounds: PDFRect(CGRect(x: 0, y: 0, width: 10, height: 10)),
            tint: .red
        )
        let block = ObsidianNoteBuilder.highlightBlock(record)
        let service = ObsidianService()
        try await service.append(block: block, afterPage: nil, to: noteURL)
        try await service.append(block: block, afterPage: nil, to: noteURL)
        let markdown = try String(contentsOf: noteURL, encoding: .utf8)
        #expect(markdown.components(separatedBy: block).count - 1 == 1)
    }

    @Test @MainActor func selectedMarksMergeIntoOneBulletedObsidianBlock() throws {
        let first = HighlightRecord(
            text: "第一条原文\n原来的换行",
            pageIndex: 2,
            bounds: PDFRect(CGRect(x: 10, y: 10, width: 80, height: 12)),
            tint: .red,
            note: "第一条批注",
            createdAt: Date(timeIntervalSince1970: 1),
            kind: .highlight
        )
        let second = HighlightRecord(
            text: "第二条原文",
            pageIndex: 3,
            bounds: PDFRect(CGRect(x: 10, y: 30, width: 90, height: 12)),
            tint: .blue,
            note: "第二条批注",
            createdAt: Date(timeIntervalSince1970: 2),
            kind: .annotation
        )
        let model = ReaderModel()
        model.highlights = [second, first]

        let merged = try #require(model.mergeHighlights(ids: [first.id, second.id]))

        #expect(model.highlights.count == 1)
        #expect(merged.tint == .red)
        #expect(merged.markKind == .highlight)
        #expect(merged.allFragments.map(\.pageIndex) == [2, 3])
        #expect(merged.displayText == "• 第一条原文原来的换行\n• 第二条原文")
        #expect(merged.note == "• 第一条批注\n• 第二条批注")
        let block = ObsidianNoteBuilder.highlightBlock(merged)
        #expect(block.components(separatedBy: "[!danger]").count - 1 == 1)
        #expect(block.contains("> • 第一条原文原来的换行\n> • 第二条原文"))
    }

    @Test @MainActor func mixedMarksUseTheFirstActualHighlightColorAndOnlyAllAnnotationsStayGreen() throws {
        let bounds = PDFRect(CGRect(x: 0, y: 0, width: 80, height: 12))
        let annotation = HighlightRecord(
            text: "先出现的批注", pageIndex: 0, bounds: bounds, tint: .yellow,
            createdAt: Date(timeIntervalSince1970: 1), kind: .annotation
        )
        let redHighlight = HighlightRecord(
            text: "第一条划线", pageIndex: 1, bounds: bounds, tint: .red,
            createdAt: Date(timeIntervalSince1970: 2), kind: .highlight
        )
        let blueHighlight = HighlightRecord(
            text: "第二条划线", pageIndex: 2, bounds: bounds, tint: .blue,
            createdAt: Date(timeIntervalSince1970: 3), kind: .highlight
        )
        let model = ReaderModel()
        model.highlights = [annotation, redHighlight, blueHighlight]
        let mixed = try #require(model.mergeHighlights(ids: [annotation.id, redHighlight.id, blueHighlight.id]))
        #expect(mixed.markKind == .highlight)
        #expect(mixed.tint == .red)
        #expect(ObsidianNoteBuilder.highlightBlock(mixed).contains("[!danger]"))

        let secondAnnotation = HighlightRecord(
            text: "另一条批注", pageIndex: 3, bounds: bounds, tint: .blue,
            createdAt: Date(timeIntervalSince1970: 4), kind: .annotation
        )
        model.highlights = [annotation, secondAnnotation]
        let annotations = try #require(model.mergeHighlights(ids: [annotation.id, secondAnnotation.id]))
        #expect(annotations.markKind == .annotation)
        #expect(ObsidianNoteBuilder.highlightBlock(annotations).contains("[!success]"))
    }

    @Test func mergedObsidianTextEscapesMarkupWithoutDroppingItsMiddle() {
        let record = HighlightRecord(
            text: "• 前段 <hidden> 中段\n• [链接文字](https://example.com) 后段 *重点*",
            pageIndex: 0,
            bounds: PDFRect(CGRect(x: 0, y: 0, width: 80, height: 12)),
            tint: .blue
        )
        let block = ObsidianNoteBuilder.highlightBlock(record)
        #expect(block.contains("前段 &lt;hidden&gt; 中段"))
        #expect(block.contains("\\[链接文字\\](https://example.com) 后段 \\*重点\\*"))
        #expect(!block.contains("<hidden>"))
    }

    @Test func OCRAndMarkdownSearchIgnoresSpacingWidthCaseAndPunctuation() {
        #expect(ReaderModel.searchSnippet(query: "电影研究", in: "这是电 影 研 究的核心问题。") != nil)
        #expect(ReaderModel.searchSnippet(query: "Representation Study", in: "REPRESENTATION—study appears here.") != nil)
        #expect(ReaderModel.searchSnippet(query: "不存在", in: "这是另一段文字。") == nil)
    }

    @Test func searchSnippetStartsAtSentenceBeginningAndKeepsPunctuation() {
        let source = "前一句已经结束。这里讨论电 影 研 究的核心问题，并给出理由。后一句继续展开。"
        #expect(ReaderModel.searchSnippet(query: "电影研究", in: source) == "这里讨论电影研究的核心问题，并给出理由。")
    }

    @Test func searchHighlightRangesCoverEveryVisibleMatch() {
        let text = "电影研究不同于电影史，电影研究关注方法。"
        let matches = ReaderModel.searchMatchRanges(query: "电影研究", in: text)
        #expect(matches.map { String(text[$0]) } == ["电影研究", "电影研究"])
    }

    @Test func obsidianServiceSkipsMatchingLegacyRecordWithoutMarker() async throws {
        let noteURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("ReadingCompanionLegacyDedup-\(UUID().uuidString).md")
        defer { try? FileManager.default.removeItem(at: noteURL) }
        let record = HighlightRecord(
            text: "旧版已有内容",
            pageIndex: 0,
            bounds: PDFRect(CGRect(x: 0, y: 0, width: 10, height: 10)),
            tint: .blue
        )
        let block = ObsidianNoteBuilder.highlightBlock(record)
        try (ObsidianNoteBuilder.skeleton(title: "测试", sourcePath: nil, outline: []) + "\n" + block)
            .write(to: noteURL, atomically: true, encoding: .utf8)

        try await ObsidianService().append(block: block, afterPage: nil, to: noteURL)

        let markdown = try String(contentsOf: noteURL, encoding: .utf8)
        #expect(markdown.components(separatedBy: block).count - 1 == 1)
        #expect(!markdown.contains("<!--"))
    }

    @Test func oldSavedRecordsDecodeBeforeNoteExportTracking() throws {
        let record = HighlightRecord(
            text: "旧记录",
            pageIndex: 0,
            bounds: PDFRect(CGRect(x: 0, y: 0, width: 10, height: 10)),
            tint: .yellow
        )
        let encoded = try JSONEncoder().encode(record)
        var object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        object.removeValue(forKey: "noteExportedAt")
        let legacy = try JSONSerialization.data(withJSONObject: object)
        let decoded = try JSONDecoder().decode(HighlightRecord.self, from: legacy)
        #expect(!decoded.isInNotes)
        #expect(decoded.markKind == .highlight)
    }

    @Test func obsidianInsertionUsesTheRequestedChapterHeading() {
        let outline = [
            OutlineEntry(title: "第一章", pageIndex: 0, level: 0, generated: false),
            OutlineEntry(title: "第二章", pageIndex: 9, level: 0, generated: false)
        ]
        let original = ObsidianNoteBuilder.skeleton(title: "测试书", sourcePath: nil, outline: outline)
        let merged = ObsidianNoteBuilder.insert(
            block: "中间页划线",
            into: original,
            afterPage: 5,
            chapterTitle: "第一章"
        )
        let block = merged.range(of: "中间页划线")!
        let first = merged.range(of: "## 第一章")!
        let second = merged.range(of: "## 第二章")!
        #expect(block.lowerBound > first.upperBound)
        #expect(block.upperBound < second.lowerBound)
    }

    @Test func obsidianMigrationRemovesInternalCommentsAndRestoresNativeColors() {
        let legacy = """
        <!-- reading-companion:generated:start -->
        <!-- reading-companion:chapter-note page=30 kind=overview -->
        > [!quote-yellow] 划线
        > [!annotation] 批注
        > [!ai]- AI 讨论
        """
        let migrated = ObsidianNoteBuilder.migrateLegacyMarkdown(legacy)
        #expect(!migrated.contains("<!--"))
        #expect(migrated.contains("[!warning]"))
        #expect(migrated.contains("[!success]"))
        #expect(migrated.contains("[!example]-"))
    }

    @Test func rejectsOneBookmarkPerPageOutline() {
        let entries = (0..<80).map {
            OutlineEntry(title: "\($0 + 1)", pageIndex: $0, level: 0, generated: false)
        }
        #expect(!OutlineBuilder.isPlausible(entries, pageCount: 80))
    }

    @Test func acceptsRealChapterOutline() {
        let entries = [
            OutlineEntry(title: "导言", pageIndex: 3, level: 0, generated: false),
            OutlineEntry(title: "第一章 现代性的困境", pageIndex: 18, level: 0, generated: false),
            OutlineEntry(title: "第二章 制度与行动", pageIndex: 57, level: 0, generated: false),
            OutlineEntry(title: "结语", pageIndex: 112, level: 0, generated: false)
        ]
        #expect(OutlineBuilder.isPlausible(entries, pageCount: 120))
    }

    @Test func locatesOnlyContentsPagesAndTheirContinuation() {
        let pages = [
            PageText(pageIndex: 0, text: "封面", cameFromOCR: false),
            PageText(pageIndex: 1, text: "正文里出现标题两个字，但这里不是目录。\n第一章 一个句子", cameFromOCR: false),
            PageText(pageIndex: 2, text: "目 录\n序言 ........ i\n第一章 真正的问题 ........ 1\n第二章 制度与行动 ........ 15", cameFromOCR: false),
            PageText(pageIndex: 3, text: "第三章 技术系统 ........ 31\n第四章 结论 ........ 48\n附录 ........ 60", cameFromOCR: false),
            PageText(pageIndex: 4, text: "第一章 一个句子\n这里开始是正文。", cameFromOCR: false)
        ]
        #expect(TOCPageDetector.locate(in: pages) == [2, 3])
    }

    @Test func neverBuildsOutlineFromBodyHeadingsWithoutContentsPage() {
        let pages = (0..<20).map {
            PageText(pageIndex: $0, text: "第\($0 + 1)章 标题字样\n这是正文，不含目录列出的印刷页码。", cameFromOCR: false)
        }
        #expect(TOCPageDetector.locate(in: pages).isEmpty)
    }

    @Test func locatesContentsWhenPDFExtractionSeparatesPageNumberColumn() {
        let pages = [
            PageText(pageIndex: 0, text: "封面", cameFromOCR: false),
            PageText(
                pageIndex: 1,
                text: "目录\n第一章 真正的问题\n第二章 制度与行动\n第三章 技术系统\n第四章 结论\n1\n15\n31\n48",
                cameFromOCR: false
            ),
            PageText(pageIndex: 2, text: "第一章 真正的问题\n正文", cameFromOCR: false)
        ]
        #expect(TOCPageDetector.locate(in: pages) == [1])
    }

    @Test func manualContentsInfersDirectoryPagesWithoutAUserEnteredRange() {
        let entries = [
            TOCSourceEntry(title: "非物", printedPage: 1, level: 0),
            TOCSourceEntry(title: "从物到非物", printedPage: 9, level: 0),
            TOCSourceEntry(title: "智能手机", printedPage: 18, level: 0)
        ]
        let pages = [
            PageText(pageIndex: 0, text: "封面", cameFromOCR: false),
            PageText(pageIndex: 1, text: "版权信息", cameFromOCR: false),
            PageText(pageIndex: 2, text: "非物\n从物到非物\n智能手机\n1\n9\n18", cameFromOCR: true),
            PageText(pageIndex: 3, text: "非物\n这里开始是正文。", cameFromOCR: true),
            PageText(pageIndex: 4, text: "从物到非物\n正文继续。", cameFromOCR: true)
        ]

        #expect(TOCPageDetector.locate(in: pages).isEmpty)
        #expect(TOCPageDetector.inferManualPages(for: entries, in: pages) == [2])
    }

    @Test func acceptsExplicitContentsHeadingEvenWhenOCRLosesPageNumbers() {
        let pages = [
            PageText(pageIndex: 0, text: "封面", cameFromOCR: false),
            PageText(pageIndex: 1, text: "目次\n序言\n真正的问题\n制度与行动", cameFromOCR: true),
            PageText(pageIndex: 2, text: "第一章正文是一段很长的连续文字。", cameFromOCR: true)
        ]
        #expect(TOCPageDetector.locate(in: pages) == [1])
    }

    @Test func manualContentsStartAlwaysUsesSelectedPage() {
        let pages = [
            PageText(pageIndex: 0, text: "封面", cameFromOCR: false),
            PageText(pageIndex: 1, text: "OCR 没有识别出目录标题，但用户确认这是目录首页", cameFromOCR: true),
            PageText(pageIndex: 2, text: "第一章 真正的问题 ........ 1\n第二章 制度与行动 ........ 15", cameFromOCR: true)
        ]
        #expect(TOCPageDetector.locate(startingAt: 1, in: pages) == [1, 2])
    }

    @Test func sendsCompleteContentsPageTextOnly() {
        let pages = [
            PageText(pageIndex: 0, text: "正文中的标题", cameFromOCR: false),
            PageText(pageIndex: 1, text: "目录\n第一章 完整标题 ........ 1\n第二章 另一个标题 ........ 9", cameFromOCR: false)
        ]
        let input = TOCPageTextBuilder.build(pages: pages, pageIndices: [1])
        #expect(input.contains("第一章 完整标题"))
        #expect(input.contains("第二章 另一个标题"))
        #expect(!input.contains("正文中的标题"))
    }

    @Test func pastedContentsParserKeepsFirstEntryAndRomanPageStyle() {
        let source = """
        目录
        前言 ........ ix
        第一章 电影是什么 ........ 1
        1.1 电影作为文本 ........ 5
        """
        let entries = TOCTextParser.parse(source)
        #expect(entries.map(\.title) == ["前言", "第一章 电影是什么", "1.1 电影作为文本"])
        #expect(entries.first?.printedPage == 9)
        #expect(entries.first?.pageStyle == .roman)
        #expect(entries[1].pageStyle == .arabic)
    }

    @Test func pastedContentsParserSeparatesHeadingFromFirstEntry() {
        let entries = TOCTextParser.parse("目录第一章 电影是什么 1\n第二章 电影语言 18")
        #expect(entries.map(\.title) == ["第一章 电影是什么", "第二章 电影语言"])
        #expect(entries.map(\.printedPage) == [1, 18])
    }

    @Test func manualPastedContentsUsesLeadingSpacesAsExactLevels() {
        let entries = ManualTOCTextParser.parse("""
        第一章 起点 1
         第一节 问题 3
          1.1.1 更深一层 5
        """)
        #expect(entries.map(\.level) == [0, 1, 2])
        #expect(entries.map(\.printedPage) == [1, 3, 5])
    }

    @Test func manualPastedContentsReordersInterleavedColumnsBySequence() {
        let entries = ManualTOCTextParser.parse("""
        1 起点 1
        3 转折 25
        2 推进 12
        4 结论 39
        """)
        #expect(entries.map(\.title) == ["1 起点", "2 推进", "3 转折", "4 结论"])
        #expect(entries.map(\.printedPage) == [1, 12, 25, 39])
    }

    @Test func manualPastedContentsAcceptsPageBeforeTitleAndSequenceAfterTitle() {
        let entries = ManualTOCTextParser.parse("""
        1 起点 1
        25 转折 3
        12 推进 2
        39 结论 4
        """)
        #expect(entries.map(\.title) == ["1 起点", "2 推进", "3 转折", "4 结论"])
        #expect(entries.map(\.printedPage) == [1, 12, 25, 39])
    }

    @Test func manualPastedContentsAcceptsSlashesBulletsAndPageOnEitherSide() {
        let entries = ManualTOCTextParser.parse("""
        • 第一章 起点 / 1
        / 12 第二章 推进
        ※ 第三章 转折 ／ P.25
        """)
        #expect(entries.map(\.title) == ["第一章 起点", "第二章 推进", "第三章 转折"])
        #expect(entries.map(\.printedPage) == [1, 12, 25])
    }

    @Test func manualPastedContentsInfersHierarchyFromWholeNumberingScheme() {
        let entries = ManualTOCTextParser.parse("""
        第一部分 方法 1
        第1章 电影研究 3
        1.1 引言 5
        1.1.1 研究对象 7
        第2章 电影工业 18
        2.1 制作 20
        """)
        #expect(entries.map(\.level) == [0, 1, 2, 3, 1, 2])
        #expect(entries.map(\.printedPage) == [1, 3, 5, 7, 18, 20])
    }

    @Test func manualPastedContentsAcceptsAttachedFieldsAndPageLabels() {
        let entries = ManualTOCTextParser.parse("""
        第1章电影研究001
        1.1引言第3页
        第二章电影工业12
        """)
        #expect(entries.map(\.title) == ["第1章 电影研究", "1.1 引言", "第二章 电影工业"])
        #expect(entries.map(\.printedPage) == [1, 3, 12])
        #expect(entries.map(\.level) == [0, 1, 0])
    }

    @Test func manualPageBoxSegmentsOneFlattenedDigitRunGlobally() {
        let match = ManualTOCPageNumberParser.match(
            "5192122242932353845454960",
            expectedCount: 12,
            restart: .never,
            maximumPage: 160
        )
        #expect(match.values.compactMap { $0 } == [19, 21, 22, 24, 29, 32, 35, 38, 45, 45, 49, 60])
        #expect(match.discardedDigitCount == 1)
        #expect(match.restartAfter == nil)
    }

    @Test func manualPageBoxTreatsEachLineAsOneNumberAndIgnoresNonDigitsInsideIt() {
        let match = ManualTOCPageNumberParser.match(
            """
            ……5  1
            P. 6 / 3
            第 7 7 页
            """,
            expectedCount: 3,
            restart: .never,
            maximumPage: 200
        )
        #expect(match.values == [51, 63, 77])
        #expect(match.discardedDigitCount == 0)
    }

    @Test func manualPageBoxDetectsRestartInOnePagePerLineFormat() {
        let match = ManualTOCPageNumberParser.match(
            "1\n3\n19\n22\n1\n2\n10",
            expectedCount: 7,
            restart: .automatic,
            maximumPage: 600
        )
        #expect(match.values.compactMap { $0 } == [1, 3, 19, 22, 1, 2, 10])
        #expect(match.restartAfter == 4)
    }

    @Test func manualPageBoxDetectsFrontMatterPaginationRestart() {
        let match = ManualTOCPageNumberParser.match(
            "1319221210",
            expectedCount: 7,
            restart: .automatic,
            maximumPage: 600
        )
        #expect(match.values.compactMap { $0 } == [1, 3, 19, 22, 1, 2, 10])
        #expect(match.restartAfter == 4)
    }

    @Test func separatedManualTOCKeepsAnUnpagedPartHeading() {
        let parsed = ManualTOCSeparatedParser.parse(
            titles: """
            第一部分 关于电影研究
            第1章 电影研究再发现
            1.1 引言
            1.2 非线性电影历史
            """,
            pages: "128",
            restart: .never,
            maximumPage: 200
        )
        #expect(parsed.entries.map(\.title) == [
            "第一部分 关于电影研究", "第1章 电影研究再发现", "1.1 引言", "1.2 非线性电影历史"
        ])
        #expect(parsed.entries.map(\.printedPage) == [1, 1, 2, 8])
        #expect(parsed.missingEntryIndices == [0])
    }

    @Test func filmHistoryTOCRecoversPagesEmittedBeforeAndAfterTitles() {
        let source = """
        目录
        Contents
        电影史：理论与实践
        作者序
        第一部分 阅读、研究和撰写电影史
        第一章 作为历史的电影史
        3
        1.1 作为电影研究一个分支的电影史 4
        1.2 历史研究的本质
        6
        1.3 历史知识和科学知识 11
        1.4 约定论对经验论的批评 14
        1.5 实在论的反应
        17
        1.6 作为电影史理论的实在论 20
        第二章 研究电影史
        27
        2.1 电影学术的历史
        27
        2.2 影片证据 31
        2.3 电影史研究的对象 42
        2.4 影片之外的证据
        45
        第三章 阅读电影史 51
        3.1 叙事的电影史 51
        3.2 阅读电影史 56
        3.3 阅读即质疑 57
        3.4 个案研究：第一批美国电影史学家 62
        63
        3.5 总看法
        3.6 电影史和关于技术的流行话语 66
        3.7 技术和成功
        69
        3.8 电影史著作和征订出版 72
        3.9 结论
        74
        第二部分 传统的电影史研究方法
        第四章 美学电影史
        79
        4.1 美学电影史中的唯杰作传统
        80
        4.2 电影史和电影理论
        82
        4.20 结论
        127
        """
        let entries = TOCReliableParser.parse(source)
        let byTitle = Dictionary(uniqueKeysWithValues: entries.map { ($0.title, $0.printedPage) })
        #expect(byTitle["第一章 作为历史的电影史"] == 3)
        #expect(byTitle["1.2 历史研究的本质"] == 6)
        #expect(byTitle["3.5 总看法"] == 63)
        #expect(byTitle["第四章 美学电影史"] == 79)
        #expect(byTitle["4.1 美学电影史中的唯杰作传统"] == 80)
        #expect(byTitle["4.20 结论"] == 127)
    }

    @Test func storyTOCKeepsUnpagedPartsAndRejoinedChapterLabels() {
        let source = """
        C ontents
        目录
        PART I 作家和故事艺术
        CHAPTER 01 故事问题 003
        PARTⅡ 故事诸要素
        CHAPTER 02 结构图谱 027
        CHAPTER 03 结构与背景 069
        CHAPTER 04 结构与类型 085
        CHAPTER 05 结构与人物 109
        CHAPTER 06 结构与意义 123
        PART Ⅲ故事设计原理
        CHAPTER 07 故事材质 151
        CHAPTER 08 激励事件 205
        CHAPTER 09 幕设计 237
        CHAPTER 10 场景设计 265
        CHAPTER 11 场景分析 289
        PART Ⅳ 作家在工作
        CHAPTER 14 反面人物塑造原理 369
        CHAPTER 19 作家的创造方法 477
        淡出
        487
        附录1：译注
        489
        附录2：文中涉及影片列表 503
        """
        let entries = TOCReliableParser.parse(source)
        let byTitle = Dictionary(uniqueKeysWithValues: entries.map { ($0.title, $0) })
        #expect(byTitle["PART I 作家和故事艺术"]?.printedPage == 3)
        #expect(byTitle["PART II 故事诸要素"]?.printedPage == 27)
        #expect(byTitle["PART III 故事设计原理"]?.printedPage == 151)
        #expect(byTitle["PART IV 作家在工作"]?.printedPage == 369)
        #expect(byTitle["CHAPTER 01 故事问题"]?.printedPage == 3)
        #expect(byTitle["CHAPTER 09 幕设计"]?.printedPage == 237)
        #expect(byTitle["CHAPTER 19 作家的创造方法"]?.printedPage == 477)
        #expect(byTitle["附录2:文中涉及影片列表"]?.printedPage == 503)
        #expect(byTitle["PART I 作家和故事艺术"]?.level == 0)
        #expect(byTitle["CHAPTER 01 故事问题"]?.level == 1)
    }

    @Test func pastedOCRSeparatesSpacedChineseTitlesAndSpacedPageDigits() {
        let source = """
        第 四 版 说 明 1
        推 荐 序 ⽐ 尔 • 尼 科 尔 斯 3
        撰 稿 ⼈ 简 介 1 9
        第 四 版 导 读 2 2
        """
        let entries = ManualTOCTextParser.parse(source)
        #expect(entries.map(\.title) == ["第四版说明", "推荐序比尔•尼科尔斯", "撰稿人简介", "第四版导读"])
        #expect(entries.map(\.printedPage) == [1, 3, 19, 22])
        let automatic = TOCTextParser.parse(source)
        #expect(automatic.map(\.title) == entries.map(\.title))
        #expect(automatic.map(\.printedPage) == entries.map(\.printedPage))
    }

    @Test func pastedOCRDropsVerticalContentsHeadingFragmentsAndKeepsEveryEntry() {
        let source = """
        目 从物到非物/001
        录 从占有到体验/019
        智能手机/029
        自拍/049
        人工智能/063
        对物的看法/077
        物中潜伏着的危险/080
        物的脊背/084
        鬼魂/092
        物的魔力/096
        艺术对物的遗忘.104
        海德格尔的手/112
        心物/121
        安静/125
        关于点唱机的附论/139
        """
        let entries = ManualTOCTextParser.parse(source)
        #expect(entries.count == 15)
        #expect(entries.map(\.title).prefix(3) == ["从物到非物", "从占有到体验", "智能手机"])
        #expect(entries.map(\.printedPage) == [1, 19, 29, 49, 63, 77, 80, 84, 92, 96, 104, 112, 121, 125, 139])
        let automatic = TOCTextParser.parse(source)
        #expect(automatic.map(\.title) == entries.map(\.title))
        #expect(automatic.map(\.printedPage) == entries.map(\.printedPage))
    }

    @Test func flattenedSearchableTOCKeepsFirstEntryAndDropsVerticalHeadingGlyphs() {
        let source = "目 从物到非物/001 录 从占有到体验/019 智能手机/029 自拍/049"
        let entries = TOCReliableParser.parse(source)
        #expect(entries.map(\.title) == ["从物到非物", "从占有到体验", "智能手机", "自拍"])
        #expect(entries.compactMap(\.printedPage) == [1, 19, 29, 49])
    }

    @Test func pastedOCRPrintedPagesCalibrateToPhysicalPDFPagesAsOneSequence() {
        let source = """
        目 从物到非物/001
        录 从占有到体验/019
        智能手机/029
        自拍/049
        人工智能/063
        对物的看法/077
        物中潜伏着的危险/080
        物的脊背/084
        鬼魂/092
        物的魔力/096
        艺术对物的遗忘.104
        海德格尔的手/112
        心物/121
        安静/125
        关于点唱机的附论/139
        """
        let entries = ManualTOCTextParser.parse(source)
        let offset = 8
        let pageCount = 155
        var pages = (0..<pageCount).map {
            PageText(pageIndex: $0, text: "正文内容", cameFromOCR: true)
        }
        for entry in entries {
            guard let printed = entry.printedPage else { continue }
            let pageIndex = printed + offset - 1
            pages[pageIndex].text = "\(entry.title)\n本章正文"
        }
        let outline = TOCPageResolver.resolve(
            entries,
            tocPageIndices: [3],
            pages: pages,
            preserveUnmatched: true
        )
        #expect(outline.count == entries.count)
        #expect(outline.map(\.pageIndex) == entries.compactMap(\.printedPage).map { $0 + offset - 1 })
    }

    @Test func flexibleContentsParserTreatsSlashBeforePageAsSeparator() {
        let entries = TOCTextParser.parse("第一章 电影是什么 / 1\n第二章 电影语言／18")
        #expect(entries.map(\.title) == ["第一章 电影是什么", "第二章 电影语言"])
        #expect(entries.map(\.printedPage) == [1, 18])
    }

    @Test func flexibleContentsParserSplitsTwoEntriesFlattenedIntoOneOCRLine() {
        let entries = TOCTextParser.parse("第一章 起点 1 第二章 推进 12\n第三章 转折 25")
        #expect(entries.map(\.title) == ["第一章 起点", "第二章 推进", "第三章 转折"])
        #expect(entries.map(\.printedPage) == [1, 12, 25])
    }

    @Test func flexibleContentsParserSplitsGenericTwoColumnEntriesWithLeaders() {
        let entries = TOCTextParser.parse("电影作为文本 .... 1 叙事与类型 .... 18")
        #expect(entries.map(\.title) == ["电影作为文本", "叙事与类型"])
        #expect(entries.map(\.printedPage) == [1, 18])
    }

    @Test func flexibleContentsParserPairsSplitTitleAndPageColumnsAfterUnmixing() {
        let entries = TOCTextParser.parse("第一章 起点 第二章 推进\n1\n12")
        #expect(entries.map(\.title) == ["第一章 起点", "第二章 推进"])
        #expect(entries.map(\.printedPage) == [1, 12])
    }

    @Test func flexibleContentsParserDoesNotSplitChapterWordsInsideOneTitle() {
        let entries = TOCTextParser.parse("第一章 从第一章到第二章的转折 1")
        #expect(entries.count == 1)
        #expect(entries.first?.title == "第一章 从第一章到第二章的转折")
    }

    @Test func flexibleContentsParserPairsDetachedTitleAndPageColumnsOneToOne() {
        let entries = TOCTextParser.parse("""
        电影作为文本
        叙事与类型
        作者研究
        （1）
        【18】
        (35)
        """)
        #expect(entries.map(\.title) == ["电影作为文本", "叙事与类型", "作者研究"])
        #expect(entries.map(\.printedPage) == [1, 18, 35])
    }

    @Test func contentsParserCleansLeadersBracketsAndSequenceSpacing() {
        let source = """
        第一章电影是什么........（1）
        1.1叙事结构······【18】
        第二章 作者研究 .... (35)
        """
        let automatic = TOCTextParser.parse(source)
        let manual = ManualTOCTextParser.parse(source)
        let expectedTitles = ["第一章 电影是什么", "1.1 叙事结构", "第二章 作者研究"]
        #expect(automatic.map(\.title) == expectedTitles)
        #expect(automatic.map(\.printedPage) == [1, 18, 35])
        #expect(manual.map(\.title) == expectedTitles)
        #expect(manual.map(\.printedPage) == [1, 18, 35])
    }

    @Test func automaticContentsKeepsUnpagedDivisionsAndInheritsNextPage() {
        let entries = TOCTextParser.parse("""
        上篇 理论
        第一章电影是什么
        第二章叙事结构
        下篇 实践
        第三章作者研究
        （1）
        【18】
        (35)
        """)
        #expect(entries.map(\.title) == [
            "上篇 理论", "第一章 电影是什么", "第二章 叙事结构", "下篇 实践", "第三章 作者研究"
        ])
        #expect(entries.map(\.printedPage) == [1, 1, 18, 35, 35])
        #expect(entries.map(\.level) == [0, 1, 1, 0, 1])
    }

    @Test func automaticContentsKeepsNumberedPartWithoutPrintedPage() {
        let entries = TOCTextParser.parse("""
        第一部分 基础
        第一章 概念 ........ 3
        第二部分 应用
        第二章 方法 ........ 27
        """)
        #expect(entries.map(\.title) == ["第一部分 基础", "第一章 概念", "第二部分 应用", "第二章 方法"])
        #expect(entries.map(\.printedPage) == [3, 3, 27, 27])
        #expect(entries.map(\.level) == [0, 1, 0, 1])
    }

    @Test func preservesProviderErrorDetailFromNestedOrTopLevelJSON() {
        let nested = Data(#"{"error":{"message":"Model access denied","type":"forbidden","code":"403"}}"#.utf8)
        let topLevel = Data(#"{"message":"Region blocked"}"#.utf8)
        #expect(OpenAIService.errorMessage(from: nested) == "Model access denied")
        #expect(OpenAIService.errorMessage(from: topLevel) == "Region blocked")
    }

    @Test func questionOverviewNamesSelectedTextInsteadOfRepeatingQuickPrompt() {
        let content = """
        原文（第 18 页）：
        电影影像并不是现实本身，而是一套组织观看的符号关系。

        问题：
        请解释这个词或这段话的含义，并说明关键术语。
        """
        let preview = QuestionOverview.preview(content)
        #expect(preview.contains("P18"))
        #expect(preview.contains("电影影像并不是现实本身"))
        #expect(preview.contains("含义与关键术语"))
        #expect(!preview.hasPrefix("请解释"))
    }

    @Test func questionOverviewUsesAnswerToCondenseSelectedPassage() {
        let content = """
        原文（第 23 页）：
        类型与作者不是符号学的下位分支，而是宏观层面辨认影片的范畴。

        问题：
        请联系上下文说明。
        """
        let answer = "类型、作者与再现研究处于不同分析层级。后续说明。"
        let preview = QuestionOverview.preview(content, answer: answer)
        #expect(preview == "P23 · 类型、作者、再现研究 · 不同分析层级")
        #expect(preview.count <= 48)
    }

    @Test func questionOverviewDropsBoilerplateAndHardLimitsKeywordDigest() {
        let content = """
        原文（第 9 页）：
        电影史理论必须明确自己描述的对象。

        问题：
        请联系上下文说明。
        """
        let answer = "这段话的核心意思是理论的表述对象属于经验性电影史判断，因此需要作品证据，不能用历史哲学的预言性掩护。"
        let preview = QuestionOverview.preview(content, answer: answer)
        #expect(preview.hasPrefix("P9 · "))
        #expect(!preview.contains("这段话的核心意思是"))
        #expect(preview.count <= 48)
    }

    @Test func normalizesEscapedAndInlineMarkdownBreaksForReadableChat() {
        let source = "直接回答。\\n\\n### 区分 一句话。 - 第一项 - 第二项"
        let result = AIResponseFormatter.normalized(source)
        #expect(result.contains("\n\n### 区分"))
        #expect(result.contains("\n- 第一项"))
        #expect(result.contains("\n- 第二项"))
    }

    @Test func splitsVeryLongAssistantParagraphAfterTwoSentences() {
        let sentence = String(repeating: "这是承载关键论证的一句话", count: 8) + "。"
        let result = AIResponseFormatter.normalized(sentence + sentence + sentence)
        #expect(result.contains("。\n\n这是"))
    }

    @Test func readingDepthKeepsRepliesBounded() {
        #expect(AIReadingDepth.economical.outputLimit == 1_500)
        #expect(AIReadingDepth.balanced.outputLimit == 3_000)
        #expect(AIReadingDepth.deep.outputLimit == 5_000)
        let budget = OpenAIService.responseBudgetInstructions(for: .balanced)
        #expect(budget.contains("max_output_tokens=\"3000\""))
        #expect(OpenAIService.responseBudgetInstructions(for: .economical).contains("448–640 个汉字"))
        #expect(budget.contains("768–1,152 个汉字"))
        #expect(OpenAIService.responseBudgetInstructions(for: .deep).contains("1,280–1,920 个汉字"))
        #expect(budget.contains("API 安全上限"))
        #expect(budget.contains("不是生成后的裁剪"))
        #expect(budget.contains("必须在上限到来前自然收束"))
    }

    @Test func documentStoreRegistersCachedProjectsForBookshelf() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ReadingCompanionBookshelfTest-\(UUID().uuidString)", isDirectory: true)
        let pdf = directory.appendingPathComponent("test.pdf")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("%PDF-test".utf8).write(to: pdf)
        let store = DocumentStore(directoryURL: directory.appendingPathComponent("state", isDirectory: true))
        await store.registerProject(url: pdf, title: "测试项目")
        let projects = await store.cachedProjects()
        #expect(projects.count == 1)
        #expect(projects.first?.title == "测试项目")
        #expect(projects.first?.sourcePath == pdf.path)
        try? FileManager.default.removeItem(at: directory)
    }

    @Test func bookshelfReusesAnEmptyWindowAndOnlyCreatesAWindowForASecondProject() {
        let project = CachedProject(
            sourcePath: "/tmp/reading-companion-book-a.pdf",
            title: "书 A",
            lastOpenedAt: Date()
        )
        #expect(BookshelfOpenPolicy.destination(currentDocumentURL: nil, project: project) == .currentWindow)
        #expect(
            BookshelfOpenPolicy.destination(
                currentDocumentURL: URL(fileURLWithPath: "/tmp/reading-companion-book-b.pdf"),
                project: project
            ) == .newWindow
        )
        #expect(
            BookshelfOpenPolicy.destination(
                currentDocumentURL: URL(fileURLWithPath: project.sourcePath),
                project: project
            ) == .alreadyOpen
        )
    }

    @Test func deletingBookshelfProjectRemovesAllCachesButKeepsSourcePDF() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ReadingCompanionBookshelfDeleteTest-\(UUID().uuidString)", isDirectory: true)
        let stateDirectory = directory.appendingPathComponent("state", isDirectory: true)
        let pdf = directory.appendingPathComponent("test.pdf")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("%PDF-delete-cache-test".utf8).write(to: pdf)
        let store = DocumentStore(directoryURL: stateDirectory)
        let outline = [OutlineEntry(title: "第一章", pageIndex: 0, level: 0, generated: true)]
        let state = DocumentState(
            lastPageIndex: 4,
            bookmarks: [BookmarkRecord(title: "旧书签", pageIndex: 4)]
        )
        await store.registerProject(url: pdf, title: "待重置项目")
        try await store.save(state, for: pdf)
        try await store.saveMarkdown(
            pages: [PageText(pageIndex: 0, text: "旧 OCR 内容", cameFromOCR: true)],
            outline: outline,
            title: "待重置项目",
            for: pdf
        )

        try await store.deleteProject(for: pdf)

        #expect(await store.cachedProjects().isEmpty)
        #expect(await store.load(for: pdf).bookmarks.isEmpty)
        #expect(await store.loadMarkdown(for: pdf) == nil)
        #expect(await store.loadIndex(for: pdf, outline: outline) == nil)
        #expect(FileManager.default.fileExists(atPath: pdf.path))
        let identifier = await store.identifier(for: pdf)
        #expect(!FileManager.default.fileExists(atPath: stateDirectory.appendingPathComponent(identifier + ".md").path))

        // A still-open window must not recreate deleted data. Explicitly
        // reopening/registering the PDF is what begins a clean project.
        try await store.save(state, for: pdf)
        #expect(await store.load(for: pdf).bookmarks.isEmpty)
        await store.registerProject(url: pdf, title: "重新导入")
        try await store.save(state, for: pdf)
        #expect(await store.load(for: pdf).bookmarks.count == 1)
        try? FileManager.default.removeItem(at: directory)
    }

    @Test func documentStorePersistsOCRPagesAndOutlineBoundIndex() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ReadingCompanionPersistentIndexTest-\(UUID().uuidString)", isDirectory: true)
        let pdf = directory.appendingPathComponent("test.pdf")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("%PDF-persistent-cache".utf8).write(to: pdf)
        let store = DocumentStore(directoryURL: directory.appendingPathComponent("state", isDirectory: true))
        let pages = [
            PageText(pageIndex: 0, text: "第一章的 OCR 正文", cameFromOCR: true),
            PageText(pageIndex: 1, text: "第二页继续论证", cameFromOCR: true)
        ]
        let firstOutline = [OutlineEntry(title: "第一章", pageIndex: 0, level: 0, generated: true)]

        try await store.saveMarkdown(pages: pages, outline: firstOutline, title: "缓存测试", for: pdf)

        let cachedPages = await store.loadMarkdown(for: pdf)
        let cachedIndex = await store.loadIndex(for: pdf, outline: firstOutline)
        #expect(cachedPages?.count == 2)
        #expect(cachedPages?.allSatisfy(\.cameFromOCR) == true)
        #expect(cachedIndex?.first?.chapterTitle == "第一章")

        let changedOutline = [OutlineEntry(title: "修订后的第一章", pageIndex: 0, level: 0, generated: true)]
        #expect(await store.loadIndex(for: pdf, outline: changedOutline) == nil)
        #expect(await store.loadMarkdown(for: pdf) != nil)

        try Data("%PDF-source-was-replaced-with-different-content".utf8).write(to: pdf)
        #expect(await store.loadMarkdown(for: pdf) == nil)
        #expect(await store.loadIndex(for: pdf, outline: firstOutline) == nil)
        try? FileManager.default.removeItem(at: directory)
    }

    @Test func staleAutomaticOutlineIsInvalidatedWithoutDeletingReadingData() {
        let bookmark = BookmarkRecord(title: "关键页", pageIndex: 7)
        var state = DocumentState(
            lastPageIndex: 12,
            bookmarks: [bookmark],
            highlights: [],
            chats: [],
            outline: [OutlineEntry(title: "错误合并目录", pageIndex: 30, level: 0, generated: true)],
            outlineRefinedByAI: false,
            outlineWasManuallyEdited: false,
            outlineAlgorithmVersion: nil
        )

        let invalidated = state.invalidateAutomaticOutline(olderThan: 10)
        #expect(invalidated)
        #expect(state.outline == nil)
        #expect(state.outlineAlgorithmVersion == 10)
        #expect(state.lastPageIndex == 12)
        #expect(state.bookmarks == [bookmark])
    }

    @Test func manualOutlineSurvivesAlgorithmUpgrade() {
        let manual = [OutlineEntry(title: "用户目录", pageIndex: 5, level: 0, generated: true)]
        var state = DocumentState(
            outline: manual,
            outlineRefinedByAI: false,
            outlineWasManuallyEdited: true,
            outlineAlgorithmVersion: nil
        )

        let invalidated = state.invalidateAutomaticOutline(olderThan: 10)
        #expect(!invalidated)
        #expect(state.outline == manual)
    }

    @Test func existingObsidianNoteReceivesNewOutlineHeadingsBeforeNotes() {
        let original = """
        # 测试

        ## 阅读地图

        ## 我的笔记

        手写内容
        """
        let outline = [
            OutlineEntry(title: "第一章", pageIndex: 4, level: 0, generated: true),
            OutlineEntry(title: "第一节", pageIndex: 5, level: 1, generated: true)
        ]
        let synchronized = ObsidianNoteBuilder.ensureOutlineHeadings(in: original, outline: outline)
        let chapter = synchronized.range(of: "## 第一章")
        let section = synchronized.range(of: "### 第一节")
        let notes = synchronized.range(of: "## 我的笔记")
        #expect(chapter != nil && section != nil && notes != nil)
        if let chapter, let section, let notes {
            #expect(chapter.lowerBound < section.lowerBound)
            #expect(section.lowerBound < notes.lowerBound)
        }
        #expect(synchronized.contains("手写内容"))
    }

    @Test func reconstructsTwoColumnContentsInColumnOrder() {
        let observations = [
            OCRLineObservation(text: "目录", boundingBox: CGRect(x: 0.40, y: 0.91, width: 0.20, height: 0.05)),
            OCRLineObservation(text: "第一章 起点 1", boundingBox: CGRect(x: 0.08, y: 0.78, width: 0.34, height: 0.04)),
            OCRLineObservation(text: "第二章 推进 12", boundingBox: CGRect(x: 0.08, y: 0.67, width: 0.34, height: 0.04)),
            OCRLineObservation(text: "第三章 转折 25", boundingBox: CGRect(x: 0.58, y: 0.78, width: 0.34, height: 0.04)),
            OCRLineObservation(text: "第四章 结论 39", boundingBox: CGRect(x: 0.58, y: 0.67, width: 0.34, height: 0.04))
        ]
        #expect(OCRLayoutReconstructor.text(from: observations).components(separatedBy: .newlines) == [
            "目录", "第一章 起点 1", "第二章 推进 12", "第三章 转折 25", "第四章 结论 39"
        ])
    }

    @Test func pairsDetachedPageBoxesInsideEachColumnWithoutCrossColumnMerging() {
        let observations = [
            OCRLineObservation(text: "目录", boundingBox: CGRect(x: 0.40, y: 0.91, width: 0.20, height: 0.05)),
            OCRLineObservation(text: "第一章 起点", boundingBox: CGRect(x: 0.06, y: 0.78, width: 0.27, height: 0.04)),
            OCRLineObservation(text: "1", boundingBox: CGRect(x: 0.42, y: 0.78, width: 0.03, height: 0.04)),
            OCRLineObservation(text: "第二章 推进", boundingBox: CGRect(x: 0.06, y: 0.67, width: 0.27, height: 0.04)),
            OCRLineObservation(text: "12", boundingBox: CGRect(x: 0.41, y: 0.67, width: 0.04, height: 0.04)),
            OCRLineObservation(text: "第三章 转折", boundingBox: CGRect(x: 0.55, y: 0.78, width: 0.27, height: 0.04)),
            OCRLineObservation(text: "25", boundingBox: CGRect(x: 0.91, y: 0.78, width: 0.04, height: 0.04)),
            OCRLineObservation(text: "第四章 结论", boundingBox: CGRect(x: 0.55, y: 0.67, width: 0.27, height: 0.04)),
            OCRLineObservation(text: "39", boundingBox: CGRect(x: 0.91, y: 0.67, width: 0.04, height: 0.04))
        ]
        #expect(OCRLayoutReconstructor.text(from: observations).components(separatedBy: .newlines) == [
            "目录", "第一章 起点 1", "第二章 推进 12", "第三章 转折 25", "第四章 结论 39"
        ])
    }

    @Test func reconstructsVerticalContentsRightToLeft() {
        let observations = [
            OCRLineObservation(text: "第一章", boundingBox: CGRect(x: 0.76, y: 0.30, width: 0.05, height: 0.52)),
            OCRLineObservation(text: "第二章", boundingBox: CGRect(x: 0.62, y: 0.30, width: 0.05, height: 0.52)),
            OCRLineObservation(text: "第三章", boundingBox: CGRect(x: 0.48, y: 0.30, width: 0.05, height: 0.52))
        ]
        #expect(OCRLayoutReconstructor.text(from: observations).components(separatedBy: .newlines) == [
            "第一章", "第二章", "第三章"
        ])
    }

    @Test func localContentsCandidatesPreventAIFromDroppingFirstEntry() {
        let local = [
            TOCSourceEntry(title: "前言", printedPage: 9, level: 0, pageStyle: .roman),
            TOCSourceEntry(title: "第一章", printedPage: 1, level: 0, pageStyle: .arabic)
        ]
        let ai = [TOCSourceEntry(title: "第一章", printedPage: 1, level: 0, pageStyle: .arabic)]
        let merged = TOCSourceMerger.merge(primary: local, secondary: ai)
        #expect(merged.map(\.title) == ["前言", "第一章"])
    }

    @Test func mapsPrintedPageNumbersToPhysicalPDFPages() {
        var pages = (0..<45).map {
            PageText(pageIndex: $0, text: "普通正文 \($0)", cameFromOCR: false)
        }
        pages[2].text = "目录\n第一章 真正的问题 ........ 1\n第二章 制度与行动 ........ 15\n第三章 技术系统 ........ 30"
        pages[10].text = "第一章 真正的问题\n本章正文"
        pages[24].text = "第二章 制度与行动\n本章正文"
        let source = [
            TOCSourceEntry(title: "第一章 真正的问题", printedPage: 1, level: 0),
            TOCSourceEntry(title: "第二章 制度与行动", printedPage: 15, level: 0),
            TOCSourceEntry(title: "第三章 技术系统", printedPage: 30, level: 0)
        ]
        let outline = TOCPageResolver.resolve(source, tocPageIndices: [2], pages: pages)
        #expect(outline.map(\.pageIndex) == [10, 24, 39])
    }

    @Test func repeatedChapterTitleInLaterBodyDoesNotDistortSharedPageOffset() {
        var pages = (0..<55).map { PageText(pageIndex: $0, text: "普通正文 \($0)", cameFromOCR: false) }
        pages[2].text = "目录"
        pages[10].text = "第一章 真正的问题\n本章正文"
        pages[24].text = "第二章 制度与行动\n本章正文"
        pages[40].text = "回顾第一章 真正的问题，但这里不是章首"
        let source = [
            TOCSourceEntry(title: "第一章 真正的问题", printedPage: 1, level: 0, pageStyle: .arabic),
            TOCSourceEntry(title: "第二章 制度与行动", printedPage: 15, level: 0, pageStyle: .arabic),
            TOCSourceEntry(title: "第三章 结论", printedPage: 30, level: 0, pageStyle: .arabic)
        ]
        let outline = TOCPageResolver.resolve(source, tocPageIndices: [2], pages: pages)
        #expect(outline.map(\.pageIndex) == [10, 24, 39])
    }

    @Test func declaredPDFPageLabelsOverrideAmbiguousTitleMatches() {
        var pages = (0..<25).map {
            PageText(pageIndex: $0, text: "普通正文 \($0)", cameFromOCR: false, pageLabel: String($0 + 1))
        }
        pages[0].pageLabel = "i"
        pages[7].pageLabel = "1"
        pages[8].pageLabel = "2"
        pages[9].pageLabel = "3"
        pages[12].text = "第一章 起点在正文中被再次引用"
        let source = [TOCSourceEntry(title: "第一章 起点", printedPage: 1, level: 0, pageStyle: .arabic)]
        let outline = TOCPageResolver.resolve(source, tocPageIndices: [5], pages: pages)
        #expect(outline.first?.pageIndex == 7)
    }

    @Test func mapsPrintedPagesFromSelectedContentsRangeWithoutTitleAnchors() {
        let pages = (0..<30).map {
            PageText(pageIndex: $0, text: "正文 \($0)", cameFromOCR: false)
        }
        let source = [
            TOCSourceEntry(title: "第一章 缺失的标题锚点", printedPage: 1, level: 0),
            TOCSourceEntry(title: "第二章 另一个标题", printedPage: 8, level: 0)
        ]
        let outline = TOCPageResolver.resolve(source, tocPageIndices: [2, 3], pages: pages)
        #expect(outline.map(\.pageIndex) == [4, 11])
    }

    @Test func calibratesRomanFrontMatterSeparatelyFromArabicBodyPages() {
        var pages = (0..<20).map { PageText(pageIndex: $0, text: "普通正文 \($0)", cameFromOCR: false) }
        pages[1].text = "前言\n说明"
        pages[4].text = "目录"
        pages[8].text = "第一章 电影是什么\n正文"
        let source = [
            TOCSourceEntry(title: "前言", printedPage: 9, level: 0, pageStyle: .roman),
            TOCSourceEntry(title: "第一章 电影是什么", printedPage: 1, level: 0, pageStyle: .arabic),
            TOCSourceEntry(title: "第二章 电影语言", printedPage: 5, level: 0, pageStyle: .arabic)
        ]
        let outline = TOCPageResolver.resolve(source, tocPageIndices: [4], pages: pages)
        #expect(outline.map(\.pageIndex) == [1, 8, 12])
    }

    @Test func calibratesRestartedArabicFrontMatterSeparatelyFromBody() {
        var pages = (0..<70).map { PageText(pageIndex: $0, text: "普通正文 \($0)", cameFromOCR: false) }
        pages[0].text = "第四版说明"
        pages[2].text = "推荐序 比尔 尼科尔斯"
        pages[18].text = "撰稿人简介"
        pages[21].text = "第四版导读"
        pages[22].text = "目录"
        pages[29].text = "第一部分 关于电影研究"
        pages[30].text = "第1章 电影研究再发现"
        let source = [
            TOCSourceEntry(title: "第四版说明", printedPage: 1, level: 0, pageStyle: .arabic),
            TOCSourceEntry(title: "推荐序 比尔·尼科尔斯", printedPage: 3, level: 0, pageStyle: .arabic),
            TOCSourceEntry(title: "撰稿人简介", printedPage: 19, level: 0, pageStyle: .arabic),
            TOCSourceEntry(title: "第四版导读", printedPage: 22, level: 0, pageStyle: .arabic),
            TOCSourceEntry(title: "第一部分 关于电影研究", printedPage: 1, level: 0, pageStyle: .arabic),
            TOCSourceEntry(title: "第1章 电影研究再发现", printedPage: 2, level: 1, pageStyle: .arabic)
        ]
        let outline = TOCPageResolver.resolve(source, tocPageIndices: [22, 23], pages: pages, preserveUnmatched: true)
        #expect(outline.map(\.pageIndex) == [0, 2, 18, 21, 29, 30])
        #expect(outline.map(\.level) == [0, 0, 0, 0, 0, 1])
    }

    @Test func titleAnchorsCorrectIrregularPrintedToPhysicalPageOffsets() {
        var pages = (0..<150).map { PageText(pageIndex: $0, text: "普通正文 \($0)", cameFromOCR: false) }
        pages[2].text = "目录"
        pages[3].text = "从物到非物"
        pages[20].text = "从占有到体验"
        pages[29].text = "智能手机"
        pages[48].text = "自拍"
        let source = [
            TOCSourceEntry(title: "从物到非物", printedPage: 1, level: 0, pageStyle: .arabic),
            TOCSourceEntry(title: "从占有到体验", printedPage: 19, level: 0, pageStyle: .arabic),
            TOCSourceEntry(title: "智能手机", printedPage: 29, level: 0, pageStyle: .arabic),
            TOCSourceEntry(title: "自拍", printedPage: 49, level: 0, pageStyle: .arabic)
        ]
        let outline = TOCPageResolver.resolve(source, tocPageIndices: [2], pages: pages, preserveUnmatched: true)
        #expect(outline.map(\.pageIndex) == [3, 20, 29, 48])
    }

    @Test func titleOffsetConsensusRejectsAHighScoringLaterRepeat() {
        var pages = (0..<100).map { PageText(pageIndex: $0, text: "普通正文 \($0)", cameFromOCR: false) }
        pages[2].text = "目录"
        pages[3].text = "第一章 起点"
        pages[12].text = "导语 第二章 推进"
        pages[22].text = "第三章 结论"
        pages[80].text = "第二章 推进\n回顾与总结"
        let source = [
            TOCSourceEntry(title: "第一章 起点", printedPage: 1, level: 0, pageStyle: .arabic),
            TOCSourceEntry(title: "第二章 推进", printedPage: 10, level: 0, pageStyle: .arabic),
            TOCSourceEntry(title: "第三章 结论", printedPage: 20, level: 0, pageStyle: .arabic)
        ]
        let outline = TOCPageResolver.resolve(source, tocPageIndices: [2], pages: pages, preserveUnmatched: true)
        #expect(outline.map(\.pageIndex) == [3, 12, 22])
    }

    @Test func doclingLayoutBlocksRemainSeparateTOCEntries() throws {
        let json = """
        {
          "texts": [
            {"label":"text","text":"目","prov":[{"page_no":1}]},
            {"label":"text","text":"录","prov":[{"page_no":1}]},
            {"label":"text","text":"从物到非物/001","prov":[{"page_no":1}]},
            {"label":"text","text":"从占有到体验 /019","prov":[{"page_no":1}]},
            {"label":"text","text":"智能手机 /029","prov":[{"page_no":1}]},
            {"label":"text","text":"自拍；049","prov":[{"page_no":1}]},
            {"label":"text","text":"物的脊背 1084","prov":[{"page_no":1}]},
            {"label":"text","text":"鬼魂1092","prov":[{"page_no":1}]}
          ]
        }
        """
        let pages = try DoclingTOCJSONParser.parse(Data(json.utf8), sourcePageIndices: [2])
        #expect(pages.count == 1)
        #expect(pages[0].pageIndex == 2)
        let entries = TOCReliableParser.parse(pages[0].text)
        #expect(entries.map(\.title) == ["从物到非物", "从占有到体验", "智能手机", "自拍", "物的脊背", "鬼魂"])
        #expect(entries.compactMap(\.printedPage) == [1, 19, 29, 49, 1_084, 1_092])
    }

    @Test func doclingPageNumbersMapBackToOriginalPDFPages() throws {
        let json = """
        {
          "texts": [
            {"label":"section_header","text":"第一章 起点 1","prov":[{"page_no":1}]},
            {"label":"list_item","text":"1.1 问题 3","prov":[{"page_no":1}]},
            {"label":"section_header","text":"第二章 推进 18","prov":[{"page_no":2}]},
            {"label":"page_footer","text":"22","prov":[{"page_no":2}]}
          ]
        }
        """
        let pages = try DoclingTOCJSONParser.parse(Data(json.utf8), sourcePageIndices: [21, 22])
        #expect(pages.map(\.pageIndex) == [21, 22])
        #expect(pages[0].text.contains("第一章 起点 1"))
        #expect(pages[1].text == "第二章 推进 18")
    }

    @Test func resolverRepairsSlashReadAsLeadingOneInPrintedPage() {
        var pages = (0..<160).map { PageText(pageIndex: $0, text: "正文 \($0)", cameFromOCR: true) }
        pages[90].pageLabel = "84"
        pages[98].pageLabel = "92"
        pages[127].pageLabel = "121"
        let source = [
            TOCSourceEntry(title: "物的脊背", printedPage: 1_084, level: 0),
            TOCSourceEntry(title: "鬼魂", printedPage: 1_092, level: 0),
            TOCSourceEntry(title: "心物", printedPage: 1_121, level: 0)
        ]
        let outline = TOCPageResolver.resolve(source, tocPageIndices: [2], pages: pages, preserveUnmatched: true)
        #expect(outline.map(\.pageIndex) == [90, 98, 127])
    }

    @Test func staleChapterSummaryCacheIsInvalidatedIndependentlyOfManualOutline() {
        let outline = [OutlineEntry(title: "用户修正章节", pageIndex: 8, level: 0, generated: true)]
        var state = DocumentState(
            outline: outline,
            outlineWasManuallyEdited: true,
            chapterSummaries: ["0|8|用户修正章节": "旧错误概要"]
        )
        let invalidated = state.invalidateChapterSummaries(olderThan: 2)
        #expect(invalidated)
        #expect(state.outline == outline)
        #expect(state.chapterSummaries == nil)
        #expect(state.chapterSummaryAlgorithmVersion == 2)
        let invalidatedAgain = state.invalidateChapterSummaries(olderThan: 2)
        #expect(!invalidatedAgain)
    }

    @Test func compactPageAnchorSupportsNewAndLegacyQuestionFormats() {
        #expect(ReaderModel.explicitPageReference(in: "P18\n原文") == 17)
        #expect(ReaderModel.explicitPageReference(in: "/ljg-read\n\nP31\n原文") == 30)
        #expect(ReaderModel.explicitPageReference(in: "原文（第 9 页）：内容") == 8)
    }

    @Test func removedConversationSourceFieldIsIgnoredWhenDecoding() throws {
        let encoded = try JSONEncoder().encode(ChatTurn(role: .user, content: "旧问题"))
        var object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        object["assistantMode"] = "Claude"
        let legacy = try JSONSerialization.data(withJSONObject: object)
        let oldTurn = try JSONDecoder().decode(ChatTurn.self, from: legacy)
        #expect(oldTurn.content == "旧问题")
    }

    @Test func obsidianKeepsImportedMarkdownEmphasis() {
        let turn = ChatTurn(role: .assistant, content: "这是 **重点** 与普通文字")
        let block = ObsidianNoteBuilder.aiBlock(turns: [turn], pages: [3], collapsed: true)
        #expect(block.contains("**重点**"))
    }

    @Test func localReadingScopeStaysInChapterUnlessWholeBookIsRequested() {
        let chunks = [
            TextChunk(pageIndex: 10, chapterTitle: "第一章", text: "符号学与再现研究"),
            TextChunk(pageIndex: 11, chapterTitle: "第一章", text: "当前论证继续"),
            TextChunk(pageIndex: 80, chapterTitle: "第六章", text: "符号学的另一处讨论")
        ]
        let local = LocalIndex.retrieveForReading("符号学", focusPageIndex: 10, from: chunks, wholeBook: false)
        let wholeBook = LocalIndex.retrieveForReading("符号学", focusPageIndex: 10, from: chunks, wholeBook: true)
        #expect(!local.contains(where: { $0.pageIndex == 80 }))
        #expect(wholeBook.contains(where: { $0.pageIndex == 80 }))
    }

    @Test func siblingConceptSectionsShareTheirNearestLogicalContainerWithoutMoreChunks() {
        let outline = [
            OutlineEntry(title: "CHAPTER 02 结构图谱", pageIndex: 0, level: 0, generated: true),
            OutlineEntry(title: "故事设计术语", pageIndex: 0, level: 1, generated: true),
            OutlineEntry(title: "场景", pageIndex: 0, level: 2, generated: true),
            OutlineEntry(title: "节拍", pageIndex: 1, level: 2, generated: true),
            OutlineEntry(title: "序列", pageIndex: 2, level: 2, generated: true),
            OutlineEntry(title: "幕", pageIndex: 3, level: 2, generated: true),
            OutlineEntry(title: "人物设计", pageIndex: 4, level: 1, generated: true)
        ]
        let pages = [
            PageText(pageIndex: 0, text: "CHAPTER 02 结构图谱\n故事设计术语\n术语构成层级。\n场景\n场景是连续时空中的行动。", cameFromOCR: false),
            PageText(pageIndex: 1, text: "节拍\n节拍是场景内部最小的行为变化。", cameFromOCR: false),
            PageText(pageIndex: 2, text: "序列\n序列由多个场景构成。", cameFromOCR: false),
            PageText(pageIndex: 3, text: "幕\n幕由多个序列形成更大的运动。", cameFromOCR: false),
            PageText(pageIndex: 4, text: "人物设计\n人物塑造属于另一组问题。", cameFromOCR: false)
        ]
        let chunks = LocalIndex.makeChunks(pages: pages, outline: outline, targetLength: 10_000, overlap: 0)
        let result = LocalIndex.retrieveForReading(
            "场景、节拍、序列、幕这些概念是什么关系？",
            focusPageIndex: 0,
            from: chunks,
            limit: 6,
            scope: .standard
        )

        #expect(Set(result.map(\.pageIndex)).isSuperset(of: [0, 1, 2, 3]))
        #expect(!result.contains(where: { $0.pageIndex == 4 }))
        #expect(result.count <= 6)
    }

    @Test func samePageHeadingBoundaryKeepsUnlabelledIntroductionInParent() {
        let outline = [
            OutlineEntry(title: "第二章", pageIndex: 0, level: 0, generated: true),
            OutlineEntry(title: "第一节", pageIndex: 1, level: 1, generated: true)
        ]
        let pages = [
            PageText(pageIndex: 0, text: "第二章\n章节开头。", cameFromOCR: false),
            PageText(pageIndex: 1, text: "这部分仍是本章无标题导入。\n第一节\n这里才进入第一节。", cameFromOCR: false)
        ]
        let chunks = LocalIndex.makeChunks(pages: pages, outline: outline, targetLength: 10_000, overlap: 0)
        let pageChunks = chunks.filter { $0.pageIndex == 1 }

        #expect(pageChunks.count == 2)
        #expect(pageChunks[0].chapterPath == ["第二章"])
        #expect(pageChunks[1].chapterPath == ["第二章", "第一节"])
    }

    @Test func directQuestionsUseCurrentPageWhileReferentialFollowUpsReuseRecentAnchor() {
        let prior = ChatTurn(role: .user, content: "P18\n一段原文\n\n解释一下", noteAnchorPageIndex: 17)

        #expect(ReaderModel.inferredFocusPage(
            for: "场景、节拍和幕是什么关系？",
            explicitPage: nil,
            currentPageIndex: 42,
            priorTurns: [prior]
        ) == 42)
        #expect(ReaderModel.inferredFocusPage(
            for: "这里为什么这样划分？",
            explicitPage: nil,
            currentPageIndex: 42,
            priorTurns: [prior]
        ) == 17)
        #expect(ReaderModel.inferredFocusPage(
            for: "P9\n指定原文",
            explicitPage: 8,
            currentPageIndex: 42,
            priorTurns: [prior]
        ) == 8)
    }

    @Test func localReadingNeighborsNeverLeakAcrossChapterBoundary() {
        let chunks = [
            TextChunk(pageIndex: 9, chapterTitle: "第一章", text: "上一段"),
            TextChunk(pageIndex: 10, chapterTitle: "第一章", text: "当前定义"),
            TextChunk(pageIndex: 11, chapterTitle: "第二章", text: "下一章同名概念")
        ]
        let result = LocalIndex.retrieveForReading(
            "当前定义",
            focusPageIndex: 10,
            from: chunks,
            limit: 20,
            scope: .context
        )
        #expect(result.allSatisfy { $0.chapterTitle == "第一章" })
    }

    @Test func legacyObsidianTemplateIsCleanedWithoutRemovingNotes() {
        let legacy = """
        ---
        type: reading-companion
        title: "测试书"
        created: 2026-08-13T00:00:00Z
        ---

        # 测试书

        > [!info] 原文
        > `/Users/example/book.pdf`

        ## 阅读地图

        *可在这里补充全书问题、结构和阅读进度。*

        ## 测试书

        ## 我的笔记

        用户内容
        """
        let migrated = ObsidianNoteBuilder.migrateLegacyMarkdown(legacy)
        #expect(!migrated.contains("type: reading-companion"))
        #expect(!migrated.contains("[!info] 原文"))
        #expect(!migrated.contains("阅读地图"))
        #expect(migrated.components(separatedBy: "测试书").count - 1 == 1)
        #expect(migrated.contains("用户内容"))
    }

    @Test func selectionOCRCorrectionUsesSimilarVisualTextOnly() {
        #expect(OCRSelectionTextCorrector.preferred(
            original: "再 现 研 究 是 一 种 方 法",
            recognized: "再现研究是一种方法"
        ) == "再现研究是一种方法")
        #expect(OCRSelectionTextCorrector.preferred(
            original: "再现研究是一种方法",
            recognized: "完全无关的另一页文字"
        ) == nil)
    }

    @Test func conversationHistoryResetsForNewPassageAndContinuesForFollowUp() {
        let first = ChatTurn(role: .user, content: "P12\n第一段原文\n\n解释一下")
        let answer = ChatTurn(role: .assistant, content: "第一段回答")
        let second = ChatTurn(role: .user, content: "P40\n另一段原文\n\n联系上下文")
        let reset = ReaderModel.contextualHistory(from: [first, answer, second], currentQuestion: second.content)
        #expect(reset.map(\.id) == [second.id])

        let repeatedSelection = ChatTurn(role: .user, content: second.content)
        let repeatedReset = ReaderModel.contextualHistory(
            from: [second, ChatTurn(role: .assistant, content: "旧回答"), repeatedSelection],
            currentQuestion: repeatedSelection.content
        )
        #expect(repeatedReset.map(\.id) == [repeatedSelection.id])

        let secondAnswer = ChatTurn(role: .assistant, content: "第二段回答")
        let followUp = ChatTurn(role: .user, content: "这里的判断对象为何变化？")
        let continued = ReaderModel.contextualHistory(
            from: [first, answer, second, secondAnswer, followUp],
            currentQuestion: followUp.content
        )
        #expect(continued.map(\.id) == [second.id, secondAnswer.id, followUp.id])

        let unrelated = ChatTurn(role: .user, content: "请介绍法国新浪潮的历史")
        let isolated = ReaderModel.contextualHistory(
            from: [second, secondAnswer, unrelated],
            currentQuestion: unrelated.content
        )
        #expect(isolated.map(\.id) == [unrelated.id])
    }

    @Test func explanationRetrievalUsesLessContextThanContextQuestion() {
        let chunks = (0..<9).map { index in
            TextChunk(pageIndex: index, chapterTitle: "第一章", text: index == 4 ? "再现研究的核心定义" : "相邻论证 \(index)")
        }
        let explanation = LocalIndex.retrieveForReading("再现研究", focusPageIndex: 4, from: chunks, limit: 20, scope: .explanation)
        let context = LocalIndex.retrieveForReading("再现研究", focusPageIndex: 4, from: chunks, limit: 20, scope: .context)
        #expect(explanation.count < context.count)
        #expect(explanation.allSatisfy { $0.pageIndex == 4 })
    }

    @Test func markdownCompactionRemovesRepeatedHeadersAndJoinsWrappedText() {
        let pages = (0..<6).map { index in
            PageText(pageIndex: index, text: "电影研究导论 \(index + 1)\n符号学用于再现研-\n究。\n正文 \(index)", cameFromOCR: true)
        }
        let compact = PDFMarkdownDocument.compactPages(pages)
        #expect(compact.allSatisfy { !$0.text.contains("电影研究导论") })
        #expect(compact[0].text.contains("再现研究"))
        let markdown = PDFMarkdownDocument.render(title: "测试", pages: compact, outline: [])
        #expect(markdown.contains("# 测试"))
        #expect(markdown.contains("<!-- P1 -->"))
    }

    @Test func answerCacheKeyChangesWithModelContextAndHistory() {
        let chunk = TextChunk(pageIndex: 2, chapterTitle: "一", text: "核心原文")
        let base = ReaderModel.answerCacheKey(question: "解释", context: [chunk], model: "m1", provider: .openAI, depth: .balanced, usesWebSearch: false, usesWholeBook: false, history: [])
        let otherModel = ReaderModel.answerCacheKey(question: "解释", context: [chunk], model: "m2", provider: .openAI, depth: .balanced, usesWebSearch: false, usesWholeBook: false, history: [])
        let otherContext = ReaderModel.answerCacheKey(question: "解释", context: [TextChunk(pageIndex: 3, text: "另一段")], model: "m1", provider: .openAI, depth: .balanced, usesWebSearch: false, usesWholeBook: false, history: [])
        #expect(base != otherModel)
        #expect(base != otherContext)
    }

    @Test func oneLinePerEntryManualParsingDoesNotAppendTrailingDuplicates() {
        let text = """
        第一章 起点 1
        第二章 方法 18
        第三章 结论 36
        """
        let entries = ManualTOCTextParser.parse(text)
        #expect(entries.map(\.title) == ["第一章 起点", "第二章 方法", "第三章 结论"])
        #expect(Set(entries.map { "\($0.title)|\($0.printedPage ?? -1)" }).count == entries.count)
    }

    @Test func selectedQuestionParserSendsFocusedPassageOnlyOnce() {
        let parsed = ReadingQuestionParser.parse("P12\n场景、节拍、序列和幕构成结构层级。\n\n解释一下")
        #expect(parsed.pageNumber == 12)
        #expect(parsed.focusedPassage == "场景、节拍、序列和幕构成结构层级。")
        #expect(parsed.request == "解释一下")
        #expect(ReadingQuestionParser.parse("普通问题").focusedPassage == nil)
    }

    @Test func promptPreparationRemovesOverlapWithinTokenBudget() {
        let overlap = "这是两个索引片段共同保留的边界文字，用来维持跨片段语义连续性。"
        let chunks = [
            TextChunk(pageIndex: 2, chapterTitle: "故事设计术语", text: "前文论证。\(overlap)", chapterPath: ["结构图谱", "故事设计术语"]),
            TextChunk(pageIndex: 2, chapterTitle: "故事设计术语", text: "\(overlap)后文继续讨论幕与序列。", chapterPath: ["结构图谱", "故事设计术语"])
        ]
        let prepared = LocalIndex.prepareForPrompt(chunks, tokenBudget: 180)
        let joined = prepared.map(\.text).joined()
        #expect(prepared.count == 2)
        #expect(joined.components(separatedBy: overlap).count - 1 == 1)
        #expect(prepared.reduce(0) { $0 + LocalIndex.estimatedTokenCount($1.text) } <= 180)
    }

    @Test func BM25RetrievalPrefersRareConceptCombination() {
        let chunks = [
            TextChunk(pageIndex: 1, text: "cinema theory montage montage image narrative"),
            TextChunk(pageIndex: 2, text: "diegetic ellipsis connects sequence and act in story design"),
            TextChunk(pageIndex: 3, text: "cinema narrative image author genre")
        ]
        #expect(LocalIndex.retrieve("diegetic ellipsis sequence act", from: chunks, limit: 2).first?.pageIndex == 2)
    }

    @Test func decodesProviderUsageAndCacheHits() throws {
        let openAI = Data(#"{"usage":{"input_tokens":1200,"output_tokens":180,"total_tokens":1380,"input_tokens_details":{"cached_tokens":900},"output_tokens_details":{"reasoning_tokens":40}}}"#.utf8)
        let anthropic = Data(#"{"usage":{"input_tokens":700,"output_tokens":90,"cache_read_input_tokens":500,"cache_creation_input_tokens":120}}"#.utf8)
        let first = OpenAIService.decodedUsage(from: openAI)
        let second = OpenAIService.decodedUsage(from: anthropic)
        #expect(first?.cachedInputTokens == 900)
        #expect(first?.reasoningTokens == 40)
        #expect(second?.cacheWriteTokens == 120)
        #expect(second?.totalTokens == 790)
    }

    @Test func decodesNestedAndStringValuedRelayUsage() throws {
        let relay = Data(#"{"data":{"usage":{"promptTokens":"840","completionTokens":"210","totalTokens":"1050"}}}"#.utf8)
        let usage = OpenAIService.decodedUsage(from: relay)
        #expect(usage?.inputTokens == 840)
        #expect(usage?.outputTokens == 210)
        #expect(usage?.totalTokens == 1_050)
    }

    @Test func missingOrZeroUsageUsesLabelledLocalEstimate() throws {
        let missing = Data(#"{"id":"response-without-usage"}"#.utf8)
        let zero = Data(#"{"usage":{"input_tokens":0,"output_tokens":0,"total_tokens":8}}"#.utf8)
        let first = OpenAIService.resolvedUsage(from: missing, system: "系统规则", input: "输入原文", output: "完整回答")
        let second = OpenAIService.resolvedUsage(from: zero, system: "系统规则", input: "输入原文", output: "完整回答")
        #expect(first.inputTokens > 0 && first.outputTokens > 0)
        #expect(first.isEstimated == true)
        #expect(second.inputTokens > 0 && second.outputTokens > 0)
        #expect(second.isEstimated == true)
        #expect(second.compactDescription.contains("约"))
    }

    @Test func responsesAPIKeepsEveryOutputTextBlock() throws {
        let data = Data(#"{"output":[{"type":"reasoning"},{"type":"message","content":[{"type":"output_text","text":"第一部分"},{"type":"output_text","text":"第二部分"}]}]}"#.utf8)
        let envelope = try JSONDecoder().decode(OpenAIService.ResponseEnvelope.self, from: data)
        #expect(OpenAIService.outputText(from: envelope) == "第一部分\n\n第二部分")
    }

    @Test func responsesAPIDecodesOutputLimitTruncation() throws {
        let data = Data(#"{"status":"incomplete","incomplete_details":{"reason":"max_output_tokens"},"output":[]}"#.utf8)
        let envelope = try JSONDecoder().decode(OpenAIService.ResponseEnvelope.self, from: data)
        #expect(envelope.status == "incomplete")
        #expect(envelope.incompleteDetails?.reason == "max_output_tokens")
    }

    @Test func promptCacheIdentityIsStableAndDoesNotExposePath() {
        let url = URL(fileURLWithPath: "/Users/example/Private Book.pdf")
        let first = ReaderModel.promptCacheIdentity(for: url)
        #expect(first == ReaderModel.promptCacheIdentity(for: url))
        #expect(!first.contains("Private Book"))
    }

    @Test func roundUsageMetricsPersistWithAnswer() throws {
        let usage = APIUsage(inputTokens: 1_200, outputTokens: 180, totalTokens: 1_380, cachedInputTokens: 900, cacheWriteTokens: 0, reasoningTokens: 40)
        let turn = ChatTurn(role: .assistant, content: "回答", apiUsage: usage, requestModel: "gpt-test", requestProvider: .openAI, requestDepth: .balanced, contextChunkCount: 5, estimatedContextTokens: 2_100, usedWholeBook: false, usedWebSearch: false)
        let restored = try JSONDecoder().decode(ChatTurn.self, from: JSONEncoder().encode(turn))
        #expect(restored.apiUsage?.uncachedInputTokens == 300)
        #expect(restored.apiUsage?.cacheHitRate == 0.75)
        #expect(restored.requestDepth == .balanced)
        #expect(restored.contextChunkCount == 5)
        #expect(restored.estimatedContextTokens == 2_100)
    }
}
