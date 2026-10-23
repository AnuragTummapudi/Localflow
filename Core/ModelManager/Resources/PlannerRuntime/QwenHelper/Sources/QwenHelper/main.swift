import Darwin
import Foundation
import MLX
import MLXLLM
import MLXLMCommon
import Tokenizers
import PlannerReplyProtocol

struct LocalTokenizer: MLXLMCommon.Tokenizer {
    let base: any Tokenizers.Tokenizer
    func encode(text: String, addSpecialTokens: Bool) -> [Int] { base.encode(text: text, addSpecialTokens: addSpecialTokens) }
    func decode(tokenIds: [Int], skipSpecialTokens: Bool) -> String { base.decode(tokens: tokenIds, skipSpecialTokens: skipSpecialTokens) }
    func convertTokenToId(_ token: String) -> Int? { base.convertTokenToId(token) }
    func convertIdToToken(_ id: Int) -> String? { base.convertIdToToken(id) }
    var bosToken: String? { base.bosToken }
    var eosToken: String? { base.eosToken }
    var unknownToken: String? { base.unknownToken }
    func applyChatTemplate(messages: [[String: any Sendable]], tools: [[String: any Sendable]]?, additionalContext: [String: any Sendable]?) throws -> [Int] {
        try base.applyChatTemplate(messages: messages, tools: tools, additionalContext: additionalContext)
    }
}
struct LocalTokenizerLoader: TokenizerLoader {
    func load(from directory: URL) async throws -> any MLXLMCommon.Tokenizer {
        LocalTokenizer(base: try await AutoTokenizer.from(modelFolder: directory))
    }
}
/// Retains ONLY the trusted system/tool prefix in RAM. Every goal/receipt suffix uses an independent cache copy.
/// Never trims a Qwen recurrent cache or retains user conversation tokens between requests.
final class RegistryPrefixCache: @unchecked Sendable {
    // Access exclusively inside the serial ModelContainer.perform closure.
    private var prefix: [Int] = []
    private var state: [any KVCache] = []
    func input(prompt: [Int], chat: [[String: any Sendable]], tools: [[String: any Sendable]], context: ModelContext) throws -> (LMInput, [any KVCache], Int) {
        guard (2...34).contains(chat.count), chat[0]["role"] as? String == "system", chat[1]["role"] as? String == "user" else { throw CocoaError(.coderInvalidValue) }
        // Locate the first template-owned user boundary. Everything before it comes from
        // host system text and registry schemas; no goal, saved data or receipt is cached.
        let marker = context.tokenizer.encode(text: "<|im_start|>user\n", addSpecialTokens: false)
        guard !marker.isEmpty, let boundary = (0...max(0, prompt.count - marker.count)).first(where: { Array(prompt[$0..<$0 + marker.count]) == marker }), boundary > 0 else {
            return (LMInput(tokens: MLXArray(prompt)), try context.model.newCache(parameters: nil), 0)
        }
        let trusted = Array(prompt.prefix(boundary))
        if prefix != trusted {
            state = []; prefix = []
            let cache = try context.model.newCache(parameters: nil)
            for start in stride(from: 0, to: trusted.count, by: 512) {
                let part = Array(trusted[start..<min(start + 512, trusted.count)])
                _ = context.model(MLXArray(part)[.newAxis], cache: cache)
                eval(cache.map { $0.state })
            }
            state = cache; prefix = trusted
        }
        return (LMInput(tokens: MLXArray(Array(prompt.dropFirst(prefix.count)))), state.map { $0.copy() }, prefix.count)
    }
}
func send(_ value: [String: Any]) {
    guard let bytes = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]) else { return }
    FileHandle.standardOutput.write(bytes + Data([10]))
}
func sendable(_ value: Any) -> any Sendable {
    if let d = value as? [String: Any] { return d.mapValues(sendable) }
    if let a = value as? [Any] { return a.map(sendable) }
    if let n = value as? NSNumber { return CFGetTypeID(n) == CFBooleanGetTypeID() ? n.boolValue as any Sendable : n.intValue as any Sendable }
    return (value as? String) ?? ""
}
func milliseconds(_ start: TimeInterval) -> Double { (ProcessInfo.processInfo.systemUptime - start) * 1000 }
func rss() -> UInt64 {
    var info = mach_task_basic_info(); var count = mach_msg_type_number_t(MemoryLayout.size(ofValue: info) / MemoryLayout<integer_t>.size)
    let status = withUnsafeMutablePointer(to: &info) { p in p.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count) } }
    return status == KERN_SUCCESS ? info.resident_size : 0
}
let started = ProcessInfo.processInfo.systemUptime
// Parent pipe EOF and process termination own lifetime. No HTTP/download client or auto logging.
do {
    guard CommandLine.arguments.count == 2 else { throw CocoaError(.fileReadInvalidFileName) }
    Memory.cacheLimit = 128 * 1024 * 1024
    let model = try await LLMModelFactory.shared.loadContainer(from: URL(fileURLWithPath: CommandLine.arguments[1]), using: LocalTokenizerLoader())
    send(["ready": true, "coldLoadMS": milliseconds(started), "rssBytes": rss(), "mlxActiveBytes": Memory.activeMemory, "mlxPeakBytes": Memory.peakMemory])
    let prefixCache = RegistryPrefixCache()
    while let line = readLine() {
        let start = ProcessInfo.processInfo.systemUptime
        guard line.utf8.count <= 131_072 else { send(["error": "Request too large"]); continue }
        do {
            guard let data = line.data(using: .utf8), let request = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let messages = request["messages"] as? [[String: Any]], let rawTools = request["tools"] as? [[String: Any]],
                  messages.count <= 34, rawTools.count <= 12 else { throw CocoaError(.coderInvalidValue) }
            let thinking = request["thinking"] as? Bool ?? false
            let firstOnly = request["firstOnly"] as? Bool ?? true
            let warmOnly = request["warmOnly"] as? Bool ?? false
            let limit = min(thinking ? 2048 : 512, max(1, request["maxTokens"] as? Int ?? (thinking ? 2048 : 512)))
            let chat: [[String: any Sendable]] = messages.map { $0.mapValues(sendable) }
            let tools: [[String: any Sendable]] = rawTools.map { $0.mapValues(sendable) }
            let reply = try await model.perform { context -> [String: String] in
                let prompt = try context.tokenizer.applyChatTemplate(messages: chat, tools: tools, additionalContext: ["enable_thinking": thinking])
                guard prompt.count <= 8192 else { throw CocoaError(.coderInvalidValue) }
                let (input, cache, prefixTokens) = try prefixCache.input(prompt: prompt, chat: chat, tools: tools, context: context)
                if warmOnly {
                    return ["kind": "assistant_stop", "output": "", "ttftMS": "0", "firstToolCallMS": "-1", "planMS": String(milliseconds(start)), "tokens": "0", "tokensPerSecond": "0", "promptTokens": String(prompt.count), "cachedPrefixTokens": String(prefixTokens)]
                }
                guard let thinkStart = context.tokenizer.convertTokenToId("<think>"), let thinkEnd = context.tokenizer.convertTokenToId("</think>") else { throw CocoaError(.coderInvalidValue) }
                var filter = PlannerTokenReplyFilter(startToken: thinkStart, endToken: thinkEnd, thinking: thinking)
                var tokenCount = 0; var firstToken: Double?; var firstCall: Double?
                var detokenizer = NaiveStreamingDetokenizer(tokenizer: context.tokenizer)
                let iterator = try TokenIterator(input: input, model: context.model, cache: cache, parameters: GenerateParameters(maxTokens: limit, temperature: 0))
                let info = generate(input: input, context: context, iterator: iterator) { (token: Int) in
                    if firstToken == nil { firstToken = milliseconds(start) }
                    tokenCount += 1; detokenizer.append(token: token)
                    filter.consume(token: token, fragment: detokenizer.next() ?? "")
                    if filter.hasCompleteToolCall, Qwen35ToolCallParser(startTag: "<tool_call>", endTag: "</tool_call>").parse(content: filter.output.trimmingCharacters(in: .whitespacesAndNewlines), tools: tools) != nil {
                        if firstCall == nil { firstCall = milliseconds(start) }
                        if firstOnly { return .stop }
                    }
                    return .more
                }
                // Reasoning fragments were discarded before collecting the reply, using actual token IDs.
                // A normal EOS answer ends the advisory turn; its prose is discarded.
                // Envelopes still go through the host's whole-output structural parser.
                // Truncation or attempted JSON is never relabelled as completion.
                let accepted = filter.output.trimmingCharacters(in: .whitespacesAndNewlines)
                // Pinned native Qwen3.5 parser supports XML and framed Hermes JSON only.
                // Reject any prefix/suffix prose before invoking it; do not use recovery APIs.
                let call = accepted.hasPrefix("<tool_call>") && accepted.hasSuffix("</tool_call>")
                    ? Qwen35ToolCallParser(startTag: "<tool_call>", endTag: "</tool_call>").parse(content: accepted, tools: tools) : nil
                let controls = ["FINISH": "finish", "ASK_USER": "ask_user", "ABSTAIN": "abstain"]
                let kind = call != nil ? "tool_calls" : controls[accepted] ?? "invalid"
                let canonical = try call.map { "<tool_call>" + String(decoding: try JSONEncoder().encode($0.function), as: UTF8.self) + "</tool_call>" } ?? ""
                return ["kind": kind, "output": canonical, "ttftMS": String(firstToken ?? -1), "firstToolCallMS": String(firstCall ?? -1),
                    "planMS": String(milliseconds(start)), "promptTokens": String(prompt.count), "cachedPrefixTokens": String(prefixTokens), "tokens": String(tokenCount), "tokensPerSecond": String(info.tokensPerSecond)]
            }
            send(reply.merging(["rssBytes": String(rss()), "mlxActiveBytes": String(Memory.activeMemory), "mlxPeakBytes": String(Memory.peakMemory)]) { a, _ in a })
            Memory.clearCache()
        } catch { send(["error": "Local generation failed: \(type(of: error))"]) }
    }
} catch { send(["error": "Local model load failed: \(error)"]); exit(1) }
