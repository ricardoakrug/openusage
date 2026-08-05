import Foundation

struct KimiAuth: Hashable, Sendable {
    var apiKey: String
}

enum KimiAuthError: Error, LocalizedError, Equatable {
    case missingKey
    case invalidKey
    case saveFailed
    case deleteFailed

    init(_ failure: UserAPIKeyStore.Failure) {
        switch failure {
        case .missingKey: self = .missingKey
        case .saveFailed: self = .saveFailed
        case .deleteFailed: self = .deleteFailed
        }
    }

    var errorDescription: String? {
        switch self {
        case .missingKey:
            return "No Kimi Code API key. Set KIMI_CODE_API_KEY or add it to ~/.config/openusage/kimi.json."
        case .invalidKey:
            return "Kimi Code API key invalid. Check your key at kimi.com/code."
        case .saveFailed:
            return "Couldn't save the Kimi Code API key."
        case .deleteFailed:
            return "Couldn't remove the saved Kimi Code API key."
        }
    }
}

/// Reads the [Kimi Code](https://www.kimi.com/code) API key the user placed on this machine — an
/// environment variable or a small config file, through the shared `UserAPIKeyStore`.
///
/// The Kimi Code CLI does stash a credential (`~/.kimi-code/credentials/kimi-code.json`), but that
/// file holds a 15-minute OAuth access token whose refresh call rotates the refresh token. Refreshing
/// it from here would race the CLI writing the same file and could invalidate the CLI's own login, so
/// the file is only probed for first-run detection (`hasCLICredential`) and never used as a
/// credential. The API key is the only credential this provider sends.
struct KimiAuthStore: Sendable {
    /// Config files checked in order; first readable key wins. JSON (`apiKey` / `api_key` / `key`) or a
    /// plain-text file containing only the key.
    static let configPaths = [
        "~/.config/openusage/kimi.json",
        "~/.config/kimi/key.json"
    ]
    /// Environment variables checked in order. `KIMI_CODE_API_KEY` is the Kimi Code name;
    /// `KIMI_API_KEY` is accepted as the shorter form users commonly export.
    static let environmentNames = ["KIMI_CODE_API_KEY", "KIMI_API_KEY"]
    /// The Kimi Code CLI's OAuth credential file — read for detection only, never for authentication.
    static let cliCredentialPath = "~/.kimi-code/credentials/kimi-code.json"

    private let store: UserAPIKeyStore
    private let files: TextFileAccessing

    init(
        files: TextFileAccessing = LocalTextFileAccessor(),
        environment: EnvironmentReading = ProcessEnvironmentReader()
    ) {
        self.files = files
        store = UserAPIKeyStore(
            configPaths: Self.configPaths,
            environmentNames: Self.environmentNames,
            files: files,
            environment: environment,
            makeError: { KimiAuthError($0) }
        )
    }

    func loadAPIKey() -> KimiAuth? { store.loadKey().map(KimiAuth.init(apiKey:)) }
    func currentAPIKey() -> String? { store.loadKey() }
    func keyStatus() -> APIKeyStatus { store.keyStatus() }
    func saveAPIKey(_ key: String) throws { try store.saveKey(key) }
    func deleteAPIKey() throws { try store.deleteKey() }

    /// True when the Kimi Code CLI holds a non-empty `access_token` on this machine. First-run
    /// detection only: it proves the user runs Kimi Code, so the card is worth enabling even before a
    /// key is pasted. The token itself is deliberately never sent (see the type comment).
    func hasCLICredential() -> Bool {
        guard let text = try? files.readTextIfPresent(Self.cliCredentialPath),
              let data = text.data(using: .utf8),
              let object = ProviderParse.jsonObject(data),
              let token = (object["access_token"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        else {
            return false
        }
        return !token.isEmpty
    }
}
