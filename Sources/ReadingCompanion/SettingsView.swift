import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var model: ReaderModel
    @Environment(\.dismiss) private var dismiss
    @State private var modelName = ""
    @State private var apiKey = ""
    @State private var rememberKey = true
    @State private var useCustomRelay = false
    @State private var customBaseURL = ""
    @State private var relayConnectionInfo = ""
    @State private var relayImportStatus = ""
    @State private var customProtocol: CustomAPIProtocol = .automatic
    @State private var customAuthentication: CustomAPIAuthentication = .automatic
    @State private var customModelHint = ""
    @State private var showAdvancedConnection = false
    @State private var showAPICompatibility = false
    @State private var vaultPath = ""
    @State private var folder = "Reading Companion"

    var body: some View {
        TabView {
            Form {
                Picker("连接方式", selection: $useCustomRelay) {
                    Text("自动连接").tag(false)
                    Text("自定义 API").tag(true)
                }
                .pickerStyle(.segmented)
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 16) {
                        connectionHelpText
                        Spacer(minLength: 12)
                        compatibilityButton
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        connectionHelpText
                        compatibilityButton
                    }
                }
                if useCustomRelay {
                    SecureField("粘贴连接信息（JSON）", text: $relayConnectionInfo)
                        .textContentType(.password)
                        .onChange(of: relayConnectionInfo) { _, value in
                            importRelayConnectionInfoIfComplete(value)
                        }
                    if !relayImportStatus.isEmpty {
                        Text(relayImportStatus)
                            .font(.caption)
                            .foregroundStyle(relayImportStatus.hasPrefix("已填入") ? Color.green : Color.red)
                    }
                    TextField("Base URL，例如 https://api.example.com/v1", text: $customBaseURL)
                        .textContentType(.URL)
                    DisclosureGroup("高级兼容", isExpanded: $showAdvancedConnection) {
                        Picker("协议", selection: $customProtocol) {
                            ForEach(CustomAPIProtocol.allCases) { Text($0.rawValue).tag($0) }
                        }
                        Picker("认证", selection: $customAuthentication) {
                            ForEach(CustomAPIAuthentication.allCases) { Text($0.rawValue).tag($0) }
                        }
                        TextField("模型 ID / Azure Deployment（仅无模型列表时）", text: $customModelHint)
                    }
                    Text("可粘贴连接信息或完整端点。自动兼容 OpenAI、Responses、Anthropic、Azure 和本机 Ollama/vLLM。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                SecureField("API Key", text: $apiKey)
                Toggle("记住 API Key", isOn: $rememberKey)

                HStack {
                    Circle()
                        .fill(model.hasActiveAPIKey ? Color.green : Color.secondary)
                        .frame(width: 8, height: 8)
                    Text(connectionStatus)
                    Spacer()
                }
                .font(.caption)

                HStack {
                    Button("验证并保存") {
                        if useCustomRelay {
                            model.saveCustomRelaySettings(
                                apiKey: apiKey,
                                baseURL: customBaseURL,
                                protocol: customProtocol,
                                authentication: customAuthentication,
                                modelHint: customModelHint,
                                remember: rememberKey
                            )
                        } else {
                            model.saveAISettings(apiKey: apiKey, model: modelName, remember: rememberKey)
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(
                        (apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                            && !customConnectionAllowsEmptyKey)
                        || (useCustomRelay && (
                            customBaseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        ))
                    )

                    Spacer()
                    if model.hasActiveAPIKey {
                        Button("清除 Key", role: .destructive) {
                            model.clearAPIKey()
                            apiKey = ""
                        }
                    }
                }

            }
            .formStyle(.grouped)
            .padding(16)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .tabItem { Label("AI", systemImage: "gearshape") }

            Form {
                HStack {
                    TextField("Vault", text: $vaultPath)
                        .disabled(true)
                    Button("选择…") {
                        model.chooseObsidianVault()
                        vaultPath = model.obsidianVaultPath
                    }
                }
                TextField("笔记目录", text: $folder)
                    .onChange(of: folder) { _, value in model.obsidianFolder = value }
                Text("其余写入操作已集中到工具栏“笔记”。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .formStyle(.grouped)
            .padding(16)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .tabItem { Label("Obsidian", systemImage: "note.text") }
        }
        .onAppear {
            modelName = model.aiModel
            if !modelOptions.contains(modelName) { modelName = modelOptions.first ?? "" }
            rememberKey = model.rememberAPIKey
            useCustomRelay = model.aiProvider == .customRelay
            customBaseURL = model.customRelayBaseURL
            customProtocol = model.aiProvider == .customRelay ? CustomRelayConfiguration.savedProtocol : .automatic
            customAuthentication = model.aiProvider == .customRelay ? CustomRelayConfiguration.savedAuthentication : .automatic
            customModelHint = model.customRelayModel
            vaultPath = model.obsidianVaultPath
            folder = model.obsidianFolder
        }
        .onChange(of: model.closeSettingsAfterValidation) { _, shouldClose in
            guard shouldClose else { return }
            model.closeSettingsAfterValidation = false
            dismiss()
        }
        .sheet(isPresented: $showAPICompatibility) {
            APICompatibilityView()
        }
    }

    private var modelOptions: [String] {
        model.cachedAIModels(for: model.aiProvider).sorted()
    }

    private var connectionHelpText: some View {
        Text(useCustomRelay ? "填写平台提供的连接信息" : "自动识别已内置平台")
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var compatibilityButton: some View {
        Button("查看兼容平台") { showAPICompatibility = true }
            .buttonStyle(.link)
            .fixedSize()
    }

    private var connectionStatus: String {
        if model.apiKeyStatus.contains("正在") { return "正在验证…" }
        return model.hasActiveAPIKey ? "连接成功" : "未连接"
    }

    private var customConnectionAllowsEmptyKey: Bool {
        guard useCustomRelay else { return false }
        return CustomRelayConfiguration.resolvedAuthentication(
            for: customBaseURL,
            protocol: CustomRelayConfiguration.resolvedProtocol(for: customBaseURL, requested: customProtocol),
            requested: customAuthentication
        ) == .none
    }

    private func importRelayConnectionInfoIfComplete(_ value: String) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.contains("{"), trimmed.hasSuffix("}") else { return }
        do {
            let info = try CustomRelayConnectionInfo.parse(trimmed)
            apiKey = info.apiKey
            customBaseURL = info.baseURL.absoluteString
            customProtocol = .automatic
            customAuthentication = .automatic
            relayImportStatus = "已填入 API Key 和 Base URL，请验证"
            relayConnectionInfo = ""
        } catch {
            relayImportStatus = error.localizedDescription
        }
    }

}

private struct APICompatibilityView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Label("API 兼容平台", systemImage: "network")
                    .font(.title2.weight(.semibold))
                Spacer()
                Button("完成") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(20)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    compatibilitySection(
                        title: "直接支持",
                        symbol: "checkmark.seal.fill",
                        color: .green,
                        text: "OpenAI、Anthropic Claude、Google Gemini、DeepSeek、AIHUBMix、OpenRouter。",
                        note: "选择“自动连接”，只需输入完整 API Key。"
                    )

                    compatibilitySection(
                        title: "自定义 API",
                        symbol: "slider.horizontal.3",
                        color: .blue,
                        text: "Azure OpenAI / Foundry、AWS Bedrock API Key、xAI、Mistral、Moonshot / Kimi、阿里云百炼 / 通义千问、火山方舟 / 豆包、腾讯混元 / LKEAP、智谱 GLM、MiniMax、硅基流动，以及 NewAPI、OneAPI、LiteLLM、Ollama、vLLM、LM Studio 等兼容服务。",
                        note: "填写 Key 与 Base URL，或粘贴完整端点；无 /models 时展开“高级兼容”填写模型 ID / Azure Deployment。"
                    )

                    VStack(alignment: .leading, spacing: 10) {
                        Label("支持的接口", systemImage: "arrow.left.arrow.right")
                            .font(.headline)
                        Text("OpenAI Chat Completions · OpenAI Responses · Anthropic Messages")
                        Text("Bearer Key · Azure api-key · Anthropic x-api-key · 本机无 Key")
                            .foregroundStyle(.secondary)
                        Text("远程接口必须使用 HTTPS；本机 Ollama/vLLM 可使用 http://localhost 或 127.0.0.1。")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }

                    compatibilitySection(
                        title: "不能保证",
                        symbol: "exclamationmark.triangle.fill",
                        color: .orange,
                        text: "AWS IAM / SigV4、Google Vertex AI ADC/OAuth、Azure Entra ID、临时令牌自动刷新、客户端证书、自定义动态签名，以及只提供厂商私有协议的接口。",
                        note: "这些需要云账户凭据代理或官方 SDK，不能由一个 API Key 输入框安全地通用处理。"
                    )

                    Text("“协议兼容”不代表所有 Key 或模型必然可用。余额、地区、模型授权、IP 白名单及服务商实现差异仍可能导致连接失败。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .padding(12)
                        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
                }
                .padding(22)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(minWidth: 560, idealWidth: 640, minHeight: 540, idealHeight: 600)
    }

    private func compatibilitySection(
        title: String,
        symbol: String,
        color: Color,
        text: String,
        note: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            Label(title, systemImage: symbol)
                .font(.headline)
                .foregroundStyle(color)
            Text(text)
                .fixedSize(horizontal: false, vertical: true)
            Text(note)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
