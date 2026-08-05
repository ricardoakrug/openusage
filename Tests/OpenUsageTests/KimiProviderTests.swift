import XCTest
@testable import OpenUsage

final class KimiAuthStoreTests: XCTestCase {
    func testPrefersConfigFileOverEnvironment() {
        let store = KimiAuthStore(
            files: FakeFiles([KimiAuthStore.configPaths[0]: #"{"apiKey":"kimi-file"}"#]),
            environment: FakeEnvironment(["KIMI_CODE_API_KEY": "kimi-env"])
        )

        XCTAssertEqual(store.loadAPIKey()?.apiKey, "kimi-file")
    }

    func testFallsBackToEitherEnvironmentName() {
        let primary = KimiAuthStore(
            files: FakeFiles(),
            environment: FakeEnvironment(["KIMI_CODE_API_KEY": "kimi-env"])
        )
        let secondary = KimiAuthStore(
            files: FakeFiles(),
            environment: FakeEnvironment(["KIMI_API_KEY": "kimi-short"])
        )

        XCTAssertEqual(primary.loadAPIKey()?.apiKey, "kimi-env")
        XCTAssertEqual(secondary.loadAPIKey()?.apiKey, "kimi-short")
    }

    func testReturnsNilWhenNoKeyAnywhere() {
        let store = KimiAuthStore(files: FakeFiles(), environment: FakeEnvironment())
        XCTAssertNil(store.loadAPIKey())
    }

    func testSaveAPIKeyWritesTrimmedJSONConfigFile() throws {
        let files = FakeFiles()
        let store = KimiAuthStore(files: files, environment: FakeEnvironment())

        try store.saveAPIKey("  kimi-new  ")

        XCTAssertEqual(files.files[KimiAuthStore.configPaths[0]], #"{"apiKey":"kimi-new"}"#)
        XCTAssertEqual(store.loadAPIKey()?.apiKey, "kimi-new")
    }

    func testSaveAPIKeyRejectsEmptyKey() {
        let store = KimiAuthStore(files: FakeFiles(), environment: FakeEnvironment())
        XCTAssertThrowsError(try store.saveAPIKey("   ")) { error in
            XCTAssertEqual(error as? KimiAuthError, .missingKey)
        }
    }

    func testDeleteAPIKeyClearsAllConfigPaths() throws {
        let files = FakeFiles([
            KimiAuthStore.configPaths[0]: #"{"apiKey":"kimi-a"}"#,
            KimiAuthStore.configPaths[1]: "kimi-b"
        ])
        let store = KimiAuthStore(files: files, environment: FakeEnvironment())

        try store.deleteAPIKey()

        XCTAssertNil(files.files[KimiAuthStore.configPaths[0]])
        XCTAssertNil(files.files[KimiAuthStore.configPaths[1]])
        XCTAssertNil(store.loadAPIKey())
    }

    func testKeyStatusReportsAllFourStates() {
        let notSet = KimiAuthStore(files: FakeFiles(), environment: FakeEnvironment())
        let fromEnvironment = KimiAuthStore(
            files: FakeFiles(),
            environment: FakeEnvironment(["KIMI_CODE_API_KEY": "kimi-env"])
        )
        let saved = KimiAuthStore(
            files: FakeFiles([KimiAuthStore.configPaths[0]: #"{"apiKey":"kimi-file"}"#]),
            environment: FakeEnvironment()
        )
        let overrideActive = KimiAuthStore(
            files: FakeFiles([KimiAuthStore.configPaths[0]: #"{"apiKey":"kimi-file"}"#]),
            environment: FakeEnvironment(["KIMI_CODE_API_KEY": "kimi-env"])
        )

        XCTAssertEqual(notSet.keyStatus(), .notSet)
        XCTAssertEqual(fromEnvironment.keyStatus(), .fromEnvironment)
        XCTAssertEqual(saved.keyStatus(), .saved)
        XCTAssertEqual(overrideActive.keyStatus(), .overrideActive)
    }

    // MARK: - CLI credential probe (detection only)

    func testHasCLICredentialTrueWithToken() {
        let store = KimiAuthStore(
            files: FakeFiles([KimiAuthStore.cliCredentialPath: #"{"access_token":"tok","expires_in":900}"#]),
            environment: FakeEnvironment()
        )

        XCTAssertTrue(store.hasCLICredential())
    }

    func testHasCLICredentialFalseWhenMissingBlankOrUnparsable() {
        let missing = KimiAuthStore(files: FakeFiles(), environment: FakeEnvironment())
        let blank = KimiAuthStore(
            files: FakeFiles([KimiAuthStore.cliCredentialPath: #"{"access_token":"   "}"#]),
            environment: FakeEnvironment()
        )
        let garbage = KimiAuthStore(
            files: FakeFiles([KimiAuthStore.cliCredentialPath: "not json"]),
            environment: FakeEnvironment()
        )

        XCTAssertFalse(missing.hasCLICredential())
        XCTAssertFalse(blank.hasCLICredential())
        XCTAssertFalse(garbage.hasCLICredential())
    }
}

final class KimiUsageMapperTests: XCTestCase {
    func testMapsSessionAndWeeklyMetersWithPlan() throws {
        let mapped = try KimiUsageMapper.map(kimiPayload())

        XCTAssertEqual(mapped.plan, "Intermediate")
        guard case .progress(let label, let used, let limit, let format, let resetsAt, let periodMs, _) =
                mapped.lines.first else {
            return XCTFail("expected a session progress line")
        }
        XCTAssertEqual(label, "Session")
        XCTAssertEqual(used, 139)
        XCTAssertEqual(limit, 200)
        XCTAssertEqual(format, .count(suffix: "requests"))
        XCTAssertEqual(periodMs, 5 * 60 * 60 * 1000)
        XCTAssertNotNil(resetsAt)

        guard case .progress(let weeklyLabel, let weeklyUsed, let weeklyLimit, _, _, _, _) =
                mapped.lines.last else {
            return XCTFail("expected a weekly progress line")
        }
        XCTAssertEqual(weeklyLabel, "Weekly")
        XCTAssertEqual(weeklyUsed, 214)
        XCTAssertEqual(weeklyLimit, 2048)
    }

    func testDerivesUsedFromRemainingWhenAbsent() throws {
        let body = Data(#"{"usage":{"limit":"2048","remaining":"1834"}}"#.utf8)

        let mapped = try KimiUsageMapper.map(body)

        guard case .progress(_, let used, let limit, _, _, _, _) = mapped.lines.first else {
            return XCTFail("expected a progress line")
        }
        XCTAssertEqual(used, 214)
        XCTAssertEqual(limit, 2048)
    }

    func testMapsWeeklyOnlyWhenNoWindowsReported() throws {
        let body = Data(#"{"usage":{"limit":"2048","used":"214"}}"#.utf8)

        let mapped = try KimiUsageMapper.map(body)

        XCTAssertEqual(mapped.lines.count, 1)
        XCTAssertEqual(mapped.lines.first?.label, "Weekly")
    }

    func testPicksShortestWindowAsSession() throws {
        let body = Data("""
        {"limits":[
          {"window":{"duration":7,"timeUnit":"TIME_UNIT_DAY"},
           "detail":{"limit":"2048","used":"214"}},
          {"window":{"duration":300,"timeUnit":"TIME_UNIT_MINUTE"},
           "detail":{"limit":"200","used":"139"}}
        ]}
        """.utf8)

        let mapped = try KimiUsageMapper.map(body)

        guard case .progress(let label, let used, _, _, _, let periodMs, _) = mapped.lines.first else {
            return XCTFail("expected a session progress line")
        }
        XCTAssertEqual(label, "Session")
        XCTAssertEqual(used, 139)
        XCTAssertEqual(periodMs, 5 * 60 * 60 * 1000)
    }

    func testValidBodyWithoutUsableMetersReportsNoUsageData() throws {
        let mapped = try KimiUsageMapper.map(Data(#"{"user":{"membership":{"level":"LEVEL_BASIC"}}}"#.utf8))

        XCTAssertEqual(mapped.plan, "Basic")
        XCTAssertEqual(mapped.lines, [.noUsageData])
    }

    func testUnparsableBodyThrowsInvalidResponse() {
        XCTAssertThrowsError(try KimiUsageMapper.map(Data("not json".utf8))) { error in
            XCTAssertEqual(error as? KimiUsageError, .invalidResponse)
        }
    }
}

@MainActor
final class KimiProviderTests: XCTestCase {
    func testRefreshMapsBothMeters() async {
        let provider = KimiProvider(
            authStore: makeKimiAuthStore(key: "kimi-test"),
            usageClient: KimiUsageClient(http: RoutingHTTPClient { request in
                XCTAssertEqual(request.headers["Authorization"], "Bearer kimi-test")
                return HTTPResponse(statusCode: 200, headers: [:], body: kimiPayload())
            }),
            now: { Date(timeIntervalSince1970: 1_800_000_000) }
        )

        let snapshot = await provider.refresh()

        XCTAssertNil(snapshot.errorCategory)
        XCTAssertEqual(snapshot.plan, "Intermediate")
        XCTAssertNotNil(snapshot.line(label: "Session"))
        XCTAssertNotNil(snapshot.line(label: "Weekly"))
    }

    func testRefreshWithoutKeyReportsNotLoggedIn() async {
        let provider = KimiProvider(
            authStore: KimiAuthStore(files: FakeFiles(), environment: FakeEnvironment()),
            usageClient: KimiUsageClient(http: RoutingHTTPClient { _ in
                XCTFail("must not call the API without a key")
                return HTTPResponse(statusCode: 200, headers: [:], body: Data())
            })
        )

        let snapshot = await provider.refresh()

        XCTAssertEqual(snapshot.errorCategory, .notLoggedIn)
    }

    func testRefreshOnAuthFailureReportsInvalidKey() async {
        let provider = KimiProvider(
            authStore: makeKimiAuthStore(key: "kimi-bad"),
            usageClient: KimiUsageClient(http: RoutingHTTPClient { _ in
                HTTPResponse(statusCode: 401, headers: [:], body: Data("{}".utf8))
            })
        )

        let snapshot = await provider.refresh()

        XCTAssertEqual(snapshot.errorCategory, .authInvalid)
    }

    func testRefreshOnServerErrorReportsRequestFailed() async {
        let provider = KimiProvider(
            authStore: makeKimiAuthStore(key: "kimi-test"),
            usageClient: KimiUsageClient(http: RoutingHTTPClient { _ in
                HTTPResponse(statusCode: 500, headers: [:], body: Data())
            })
        )

        let snapshot = await provider.refresh()

        XCTAssertEqual(snapshot.errorCategory, ErrorCategory.http(500))
    }

    func testHasLocalCredentialsAcceptsCLICredentialWithoutKey() async {
        let provider = KimiProvider(
            authStore: KimiAuthStore(
                files: FakeFiles([KimiAuthStore.cliCredentialPath: #"{"access_token":"tok"}"#]),
                environment: FakeEnvironment()
            ),
            usageClient: KimiUsageClient(http: RoutingHTTPClient { _ in
                XCTFail("detection must stay local")
                return HTTPResponse(statusCode: 200, headers: [:], body: Data())
            })
        )

        let detected = await provider.hasLocalCredentials()

        XCTAssertTrue(detected)
    }

    /// The layout lists are plain string IDs filtered against the registry, so a typo would silently
    /// drop the metric instead of failing to compile.
    func testShippedLayoutDefaults() {
        let ids = KimiProvider().widgetDescriptors.map(\.id)

        XCTAssertEqual(ids, ["kimi.session", "kimi.weekly"])
        XCTAssertTrue(ids.allSatisfy(DefaultLayout.metricIDs.contains))
        XCTAssertTrue(DefaultLayout.pinnedMetricIDs.contains("kimi.weekly"))
        XCTAssertFalse(DefaultLayout.pinnedMetricIDs.contains("kimi.session"))
        // Both meters stay above the fold.
        XCTAssertFalse(ids.contains(where: DefaultLayout.expandedMetricIDs.contains))
    }

    func testProviderAPIKeyManagingDelegatesToAuthStore() throws {
        let files = FakeFiles()
        let provider = KimiProvider(
            authStore: KimiAuthStore(files: files, environment: FakeEnvironment())
        )

        XCTAssertEqual(provider.apiKeyStatus, .notSet)
        try provider.saveAPIKey("kimi-saved")
        XCTAssertEqual(provider.currentAPIKey(), "kimi-saved")
        XCTAssertEqual(provider.apiKeyStatus, .saved)
        try provider.deleteAPIKey()
        XCTAssertNil(provider.currentAPIKey())
    }
}

private func makeKimiAuthStore(key: String) -> KimiAuthStore {
    KimiAuthStore(
        files: FakeFiles([KimiAuthStore.configPaths[0]: #"{"apiKey":"\#(key)"}"#]),
        environment: FakeEnvironment()
    )
}

private func kimiPayload() -> Data {
    Data("""
    {
      "usage": {"limit":"2048","used":"214","remaining":"1834",
                "resetTime":"2026-01-09T15:23:13.716839300Z"},
      "limits": [{"window":{"duration":300,"timeUnit":"TIME_UNIT_MINUTE"},
                  "detail":{"limit":"200","used":"139","remaining":"61",
                            "resetTime":"2026-01-06T13:33:02.717479433Z"}}],
      "user": {"membership":{"level":"LEVEL_INTERMEDIATE"}}
    }
    """.utf8)
}
