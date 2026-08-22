import Foundation

/// Local-build credential storage. The application is currently ad-hoc signed,
/// so macOS changes its Keychain code requirement after every rebuilt binary.
/// A private Application Support file avoids authorization loops until the app
/// can be shipped with a stable Developer ID signature.
actor APIKeyStore {
    nonisolated static let fileName = "credentials.binary-plist"

    private struct Payload: Codable {
        var keys: [String: String] = [:]
    }

    private let directoryURL: URL
    private let fileURL: URL

    init(directoryURL: URL? = nil) {
        let directory = directoryURL
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("Reading Companion Open", isDirectory: true)
        self.directoryURL = directory
        self.fileURL = directory.appendingPathComponent(Self.fileName)
    }

    func load(for provider: AIProvider) throws -> String? {
        let key = try readPayload().keys[provider.storageAccount]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return key?.isEmpty == false ? key : nil
    }

    func save(_ apiKey: String, for provider: AIProvider) throws {
        let trimmed = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw StoreError.invalidStoredValue }
        var payload = try readPayload()
        payload.keys[provider.storageAccount] = trimmed
        try write(payload)
    }

    func delete(for provider: AIProvider) throws {
        var payload = try readPayload()
        payload.keys.removeValue(forKey: provider.storageAccount)
        if payload.keys.isEmpty {
            if FileManager.default.fileExists(atPath: fileURL.path) {
                try FileManager.default.removeItem(at: fileURL)
            }
        } else {
            try write(payload)
        }
    }

    private func readPayload() throws -> Payload {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return Payload() }
        do {
            let data = try Data(contentsOf: fileURL)
            return try PropertyListDecoder().decode(Payload.self, from: data)
        } catch {
            throw StoreError.readFailed(error.localizedDescription)
        }
    }

    private func write(_ payload: Payload) throws {
        do {
            try FileManager.default.createDirectory(
                at: directoryURL,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directoryURL.path)
            let encoder = PropertyListEncoder()
            encoder.outputFormat = .binary
            let data = try encoder.encode(payload)
            try data.write(to: fileURL, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
        } catch {
            throw StoreError.writeFailed(error.localizedDescription)
        }
    }

    enum StoreError: LocalizedError {
        case invalidStoredValue
        case readFailed(String)
        case writeFailed(String)

        var errorDescription: String? {
            switch self {
            case .invalidStoredValue:
                "保存的 API Key 内容为空。"
            case .readFailed(let detail):
                "无法读取本机凭据文件：\(detail)"
            case .writeFailed(let detail):
                "无法写入本机凭据文件：\(detail)"
            }
        }
    }
}
