/// Reserved compatibility shim for builds created before the diagnostic cleanup.
/// LocalFlow deliberately keeps no transcript, filesystem-path, or session debug logs.
@available(*, deprecated, message: "LocalFlow does not persist diagnostic logs.")
public enum AgentDebugLog {
    public static func write(
        hypothesisId: String,
        location: String,
        message: String,
        data: [String: Any] = [:],
        runId: String = ""
    ) {}
}
