import Foundation

@MainActor
final class KimiProvider: ProviderRuntime {
    let provider = Provider(
        id: "kimi",
        displayName: "Kimi Code",
        icon: .providerMark("kimi"),
        links: [
            ProviderLink(label: "Dashboard", url: "https://www.kimi.com/code")
        ]
    )

    let authStore: KimiAuthStore
    let usageClient: KimiUsageClient
    let now: @Sendable () -> Date

    init(
        authStore: KimiAuthStore = KimiAuthStore(),
        usageClient: KimiUsageClient = KimiUsageClient(),
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.authStore = authStore
        self.usageClient = usageClient
        self.now = now
    }

    var widgetDescriptors: [WidgetDescriptor] {
        [
            .boundedCount(id: "kimi.session", provider: provider, title: "Session",
                          metricLabel: "Session", limit: 200, suffix: "requests",
                          periodDurationMs: 5 * 60 * 60 * 1000)
                .exportingLimit("session", unit: "requests"),
            .boundedCount(id: "kimi.weekly", provider: provider, title: "Weekly",
                          metricLabel: "Weekly", limit: 2048, suffix: "requests",
                          periodDurationMs: 7 * 24 * 60 * 60 * 1000)
                .exportingLimit("weekly", unit: "requests")
        ]
    }

    func hasLocalCredentials() async -> Bool {
        // The API key is what `refresh()` uses. The Kimi Code CLI's credential file also counts here —
        // it proves the user runs Kimi Code, so the card is worth enabling on first run; the card then
        // asks for a key. That token is never sent (see `KimiAuthStore`).
        await loadOffMainActor { [authStore] in
            authStore.loadAPIKey() != nil || authStore.hasCLICredential()
        }
    }

    func refresh() async -> ProviderSnapshot {
        guard let auth = await loadOffMainActor({ [authStore] in authStore.loadAPIKey() }) else {
            return ProviderSnapshot.error(provider: provider, error: KimiAuthError.missingKey)
        }

        do {
            let response = try await usageClient.fetchUsages(apiKey: auth.apiKey)
            if response.statusCode == 401 || response.statusCode == 403 {
                return ProviderSnapshot.error(provider: provider, error: KimiAuthError.invalidKey)
            }
            guard (200..<300).contains(response.statusCode) else {
                return ProviderSnapshot.error(
                    provider: provider,
                    error: KimiUsageError.requestFailed(response.statusCode)
                )
            }
            let mapped = try KimiUsageMapper.map(response.body)
            return ProviderSnapshot.make(
                provider: provider,
                plan: mapped.plan,
                lines: mapped.lines,
                refreshedAt: now()
            )
        } catch let error as KimiUsageError {
            return ProviderSnapshot.error(provider: provider, error: error)
        } catch {
            return ProviderSnapshot.error(provider: provider, error: KimiUsageError.connectionFailed)
        }
    }
}

extension KimiProvider: APIKeyManaging {
    var apiKeyStatus: APIKeyStatus { authStore.keyStatus() }
    func currentAPIKey() -> String? { authStore.currentAPIKey() }
    func saveAPIKey(_ key: String) throws { try authStore.saveAPIKey(key) }
    func deleteAPIKey() throws { try authStore.deleteAPIKey() }
}
