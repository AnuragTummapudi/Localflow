/// Reasoning boundaries are special token IDs, never strings from untrusted quoted text.
/// This value retains only post-reasoning reply fragments for one generation.
public struct PlannerTokenReplyFilter {
    private let startToken: Int
    private let endToken: Int
    public private(set) var insideReasoning: Bool
    public private(set) var output = ""
    public init(startToken: Int, endToken: Int, thinking: Bool) {
        self.startToken = startToken; self.endToken = endToken; insideReasoning = thinking
    }
    public mutating func consume(token: Int, fragment: String) {
        if token == startToken { insideReasoning = true; output = ""; return }
        if token == endToken { insideReasoning = false; output = ""; return }
        if !insideReasoning { output += fragment }
    }
    public var hasCompleteToolCall: Bool { !insideReasoning && output.contains("</tool_call>") }
}
