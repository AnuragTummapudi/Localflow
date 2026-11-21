import Shared

public struct CloudSTTEngine: STTEngine {
    private let provider: CloudProvider
    private let client: CloudAPIClient
    public init(provider: CloudProvider, settings: LocalFlowSettings = .shared) {
        self.provider = provider
        self.client = CloudAPIClient(settings: settings)
    }
    public func transcribe(audio: CapturedAudio) async throws -> STTResult {
        STTResult(text: try await client.transcribe(audio, provider: provider))
    }
}
