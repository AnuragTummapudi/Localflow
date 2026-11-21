import XCTest
@testable import Shared

final class CloudProviderTests: XCTestCase {
    private var defaults: UserDefaults!
    private var settings: LocalFlowSettings!
    private var keys: ProviderKeyStore!
    private var suite: String!

    override func setUpWithError() throws {
        suite = "LocalFlow.BYOK.Tests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)!
        settings = LocalFlowSettings(defaults: defaults)
        keys = ProviderKeyStore(service: suite)
    }
    override func tearDownWithError() throws {
        for provider in CloudProvider.allCases { try keys.delete(provider) }
        defaults.removePersistentDomain(forName: suite)
    }
    private func client() -> CloudAPIClient {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [CloudTestProtocol.self]
        return CloudAPIClient(settings: settings, session: URLSession(configuration: config), keys: keys)
    }
    func testSettingsPreserveLegacyLocalChoiceAndNeverStoreKeys() throws {
        XCTAssertEqual(settings.dictationSource, .apple)
        XCTAssertNil(settings.polishProvider)
        settings.modelOverride = .whisperLargeV3Turbo
        XCTAssertEqual(settings.dictationSource, .local)
        settings.dictationSource = .cloud
        settings.transcriptionProvider = .gemini
        settings.polishProvider = .claude
        let reloaded = LocalFlowSettings(defaults: defaults)
        XCTAssertEqual(reloaded.dictationSource, .cloud)
        XCTAssertEqual(reloaded.transcriptionProvider, .gemini)
        XCTAssertEqual(reloaded.polishProvider, .claude)
        try keys.save("test-secret", for: .groq)
        XCTAssertFalse(String(describing: defaults.dictionaryRepresentation()).contains("test-secret"))
    }
    func testKeychainReplaceDeleteAndInvalidKeys() throws {
        XCTAssertNil(try keys.read(.groq))
        try keys.save("first", for: .groq)
        try keys.save("second", for: .groq)
        XCTAssertEqual(try keys.read(.groq), "second")
        XCTAssertThrowsError(try keys.save("bad\nkey", for: .groq))
        XCTAssertEqual(try keys.read(.groq), "second")
        try keys.delete(.groq)
        XCTAssertNil(try keys.read(.groq))
    }
    func testWAVHeaderClippingAndInvalidAudio() throws {
        let data = try CloudAPIClient.wavData(CapturedAudio(buffer: nil, samples: [-2, 0, 2], sampleRate: 16_000))
        XCTAssertEqual(String(data: data.prefix(4), encoding: .utf8), "RIFF")
        XCTAssertEqual(data.count, 50)
        XCTAssertEqual(Array(data.suffix(6)), [1, 128, 0, 0, 255, 127])
        for audio in [CapturedAudio(buffer: nil, samples: [], sampleRate: 16_000),
                      CapturedAudio(buffer: nil, samples: [.nan], sampleRate: 16_000),
                      CapturedAudio(buffer: nil, samples: [1], sampleRate: .infinity)] {
            XCTAssertThrowsError(try CloudAPIClient.wavData(audio))
        }
    }
    func testCloudAudioIsDownsampledTo16kHz() throws {
        let samples = (0..<4_800).map { Float($0 % 3) / 2 } // 0, 0.5, 1 repeating at 48 kHz
        let data = try CloudAPIClient.wavData(CapturedAudio(buffer: nil, samples: samples, sampleRate: 48_000))
        XCTAssertEqual(data.subdata(in: 24..<28).withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }.littleEndian, 16_000)
        XCTAssertEqual(data.count, 44 + 1_600 * 2)
        let first = data.subdata(in: 44..<46).withUnsafeBytes { $0.loadUnaligned(as: Int16.self) }.littleEndian
        XCTAssertEqual(first, 16_384) // average of 0, 0.5, 1
        // 7 minutes at 16 kHz exceeds the ~6 minute cloud limit.
        XCTAssertThrowsError(try CloudAPIClient.wavData(CapturedAudio(buffer: nil, samples: [Float](repeating: 0, count: 16_000 * 420), sampleRate: 16_000)))
    }
    func testModelIDOverridesAreUsedAndValidated() async throws {
        settings.setPolishModel("  custom-model-1  ", for: .groq)
        XCTAssertEqual(settings.polishModel(for: .groq), "custom-model-1")
        settings.setSpeechModel("../evil", for: .gemini)
        XCTAssertEqual(settings.speechModel(for: .gemini), CloudProvider.gemini.speechModel)
        settings.setPolishModel("", for: .groq)
        XCTAssertEqual(settings.polishModel(for: .groq), CloudProvider.groq.polishModel)
        settings.setSpeechModel("whisper-large-v3", for: .groq)
        try keys.save("test-secret", for: .groq)
        CloudTestProtocol.handler = { request in
            XCTAssertTrue(String(decoding: Self.body(request), as: UTF8.self).contains("whisper-large-v3\r\n"))
            return (200, ["text": "ok"])
        }
        _ = try await client().transcribe(CapturedAudio(buffer: nil, samples: [0.5], sampleRate: 16_000), provider: .groq)
    }
    func testNetworkBlockAndMissingKeyNeverSendRequest() async throws {
        CloudTestProtocol.handler = { _ in XCTFail("Must not contact a provider"); return (200, [:]) }
        settings.hardBlockNetworkAfterModelsDownloaded = true
        do { try await client().validateKey(.groq); XCTFail("Should block") }
        catch { XCTAssertEqual(error as? LocalFlowError, .networkBlocked) }
        settings.hardBlockNetworkAfterModelsDownloaded = false
        do { try await client().validateKey(.groq); XCTFail("Should require key") }
        catch { XCTAssertTrue(error.localizedDescription.contains("API key")) }
    }
    func testGroqAndOpenAITranscriptionRequests() async throws {
        for provider in [CloudProvider.groq, .openAI] {
            try keys.save("test-secret", for: provider)
            CloudTestProtocol.handler = { request in
                XCTAssertTrue(request.url!.path.hasSuffix("/audio/transcriptions"))
                XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test-secret")
                XCTAssertTrue(request.value(forHTTPHeaderField: "Content-Type")!.contains("multipart/form-data"))
                let body = Self.body(request)
                XCTAssertTrue(String(decoding: body, as: UTF8.self).contains(provider.speechModel))
                XCTAssertNotNil(body.range(of: Data("RIFF".utf8)))
                return (200, ["text": "Hello there."])
            }
            let text = try await client().transcribe(CapturedAudio(buffer: nil, samples: [0.5], sampleRate: 16_000), provider: provider)
            XCTAssertEqual(text, "Hello there.")
        }
    }
    func testPolishProviderRequestsAndResponses() async throws {
        for provider in CloudProvider.allCases {
            try keys.save("test-secret", for: provider)
            CloudTestProtocol.handler = { request in
                let json = try! JSONSerialization.jsonObject(with: Self.body(request)) as! [String: Any]
                XCTAssertFalse(request.url!.absoluteString.contains("test-secret"))
                switch provider {
                case .claude:
                    XCTAssertEqual(request.value(forHTTPHeaderField: "x-api-key"), "test-secret")
                    XCTAssertEqual(json["model"] as? String, provider.polishModel)
                    return (200, ["stop_reason": "end_turn", "content": [["type": "text", "text": "Edited."]]])
                case .gemini:
                    XCTAssertEqual(request.value(forHTTPHeaderField: "x-goog-api-key"), "test-secret")
                    XCTAssertNotNil(json["systemInstruction"])
                    return (200, ["candidates": [["finishReason": "STOP", "content": ["parts": [["text": "Edited."]]]]]])
                default:
                    XCTAssertEqual(json["model"] as? String, provider.polishModel)
                    return (200, ["choices": [["finish_reason": "stop", "message": ["content": "Edited."]]]])
                }
            }
            let text = try await client().polish("Source.", instructions: "Edit only.", provider: provider)
            XCTAssertEqual(text, "Edited.")
        }
    }
    func testGeminiAudioAndClaudeNotOfferedForTranscription() async throws {
        XCTAssertFalse(CloudProvider.transcriptionProviders.contains(.claude))
        try keys.save("test-secret", for: .gemini)
        CloudTestProtocol.handler = { request in
            let json = try! JSONSerialization.jsonObject(with: Self.body(request)) as! [String: Any]
            let contents = json["contents"] as! [[String: Any]]
            let parts = contents[0]["parts"] as! [[String: Any]]
            let audio = parts[0]["inlineData"] as! [String: String]
            XCTAssertEqual(audio["mimeType"], "audio/wav")
            XCTAssertEqual(Data(base64Encoded: audio["data"]!)?.prefix(4), Data("RIFF".utf8))
            return (200, ["candidates": [["finishReason": "STOP", "content": ["parts": [["text": "Spoken words."]]]]]])
        }
        let text = try await client().transcribe(CapturedAudio(buffer: nil, samples: [0.5], sampleRate: 16_000), provider: .gemini)
        XCTAssertEqual(text, "Spoken words.")
    }
    func testTruncationAndPrivateErrorBodiesAreRejected() async throws {
        XCTAssertThrowsError(try CloudAPIClient.generatedText(["choices": [["finish_reason": "length", "message": ["content": "partial"]]]], provider: .groq))
        XCTAssertThrowsError(try CloudAPIClient.generatedText(["stop_reason": "max_tokens", "content": [["type": "text", "text": "partial"]]], provider: .claude))
        XCTAssertThrowsError(try CloudAPIClient.generatedText(["candidates": [["finishReason": "SAFETY"]]], provider: .gemini))
        try keys.save("test-secret", for: .groq)
        for status in [401, 429, 500] {
            CloudTestProtocol.handler = { _ in (status, ["error": ["message": "PRIVATE INPUT test-secret"]]) }
            do { try await client().validateKey(.groq); XCTFail("Expected rejection") }
            catch {
                XCTAssertTrue(error.localizedDescription.contains("HTTP \(status)"))
                XCTAssertFalse(error.localizedDescription.contains("PRIVATE INPUT"))
                XCTAssertFalse(error.localizedDescription.contains("test-secret"))
            }
        }
    }
    private static func body(_ request: URLRequest) -> Data {
        if let data = request.httpBody { return data }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open(); defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count <= 0 { break }
            data.append(contentsOf: buffer.prefix(count))
        }
        return data
    }
}

private final class CloudTestProtocol: URLProtocol {
    static var handler: ((URLRequest) -> (Int, [String: Any]))!
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let (status, json) = Self.handler(request)
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: try! JSONSerialization.data(withJSONObject: json))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
