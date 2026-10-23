import Foundation
import Darwin
import OnnxRuntimeBindings
import Tokenizers

struct Question: Decodable { let id: String; let type: String?; let instructions: String; let options: [String: String] }
struct RuntimeSpec: Decodable {
    let protocolVersion: Int; let maxLength: Int; let headMaxLength: Int
    let clsToken: String; let sepToken: String; let maskToken: String; let padToken: String
}
struct Policy: Decodable { let temperature: Double; let threshold: Double?; let enabled: Bool }
struct Request: Decodable {
    let id: String
    let state: State
    let questions: [String]
    struct State: Decodable { let text: String; let isFinal: Bool; let languageCode: String }
}

func emit(_ value: [String: Any]) throws {
    let data = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
    FileHandle.standardOutput.write(data + Data([10]))
}
func milliseconds(_ start: UInt64) -> Double { Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000 }
func memoryBytes() -> UInt64 {
    var info = mach_task_basic_info()
    var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
    let status = withUnsafeMutablePointer(to: &info) { ptr in
        ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
        }
    }
    return status == KERN_SUCCESS ? info.resident_size : 0
}

/// Only local files are opened. No Hub load, provider auto-download or HTTP runtime.
@main struct LocalLaya {
    static func main() async {
        do {
            guard CommandLine.arguments.count == 2 else { throw NSError(domain: "usage", code: 1) }
            let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
            let cold = DispatchTime.now().uptimeNanoseconds
            let tokenizer = try await AutoTokenizer.from(modelFolder: root.appendingPathComponent("tokenizer"))
            let questionsData = try Data(contentsOf: root.appendingPathComponent("questions.json"))
            // Preserve JSON option order exactly as official Python's dict iteration does.
            
            let questions = try JSONDecoder().decode([Question].self, from: questionsData)
            let labelsData = try Data(contentsOf: root.appendingPathComponent("option-order.json"))
            let labelOrder = try JSONDecoder().decode([String: [String]].self, from: labelsData)
            let policyURL = root.appendingPathComponent("calibration.json")
            let policies = (try? JSONDecoder().decode([String: Policy].self, from: Data(contentsOf: policyURL))) ?? [:]
            let env = try ORTEnv(loggingLevel: .error)
            let options = try ORTSessionOptions()
            try options.setIntraOpNumThreads(Int32(min(4, ProcessInfo.processInfo.activeProcessorCount)))
            try options.setGraphOptimizationLevel(.all)
            let session = try ORTSession(env: env, modelPath: root.appendingPathComponent("laya.onnx").path, sessionOptions: options)
            let specURL = root.appendingPathComponent("runtime-spec.json")
            let spec = FileManager.default.fileExists(atPath: specURL.path) ? try JSONDecoder().decode(RuntimeSpec.self, from: Data(contentsOf: specURL)) : nil
            let maxLength = spec?.maxLength ?? 512, headLength = spec?.headMaxLength ?? 192
            guard (1...1024).contains(maxLength), (16...256).contains(headLength), spec == nil || spec?.protocolVersion == 2 else { throw NSError(domain: "spec", code: 1) }
            let cls = tokenizer.encode(text: spec?.clsToken ?? "[CLS]", addSpecialTokens: false).first!
            let sep = tokenizer.encode(text: spec?.sepToken ?? "[SEP]", addSpecialTokens: false).first!
            let mask = tokenizer.encode(text: spec?.maskToken ?? "[MASK]", addSpecialTokens: false).first!
            let pad = tokenizer.encode(text: spec?.padToken ?? "[PAD]", addSpecialTokens: false).first!
            try emit(["ready": true, "coldLoadMilliseconds": milliseconds(cold), "residentBytes": memoryBytes(), "protocolVersion": spec?.protocolVersion ?? 1])
            while let line = readLine(strippingNewline: true) {
                guard line.utf8.count <= 65536, let bytes = line.data(using: .utf8) else { break }
                let request = try JSONDecoder().decode(Request.self, from: bytes)
                guard request.state.text.utf8.count <= 16384, request.state.languageCode == "en",
                      !request.questions.isEmpty, Set(request.questions).count == request.questions.count,
                      request.questions.allSatisfy({ id in questions.contains { $0.id == id } }) else { throw NSError(domain: "request", code: 2) }
                let start = DispatchTime.now().uptimeNanoseconds
                let selected = questions.filter { request.questions.contains($0.id) }
                var sequences = [[Int64]](), markers = [[Int64]]()
                let stateText: String
                if spec != nil {
                    let literal = try JSONSerialization.data(withJSONObject: request.state.text, options: [.fragmentsAllowed, .withoutEscapingSlashes])
                    // Dataset JSON uses this exact key order. Token parity includes
                    // serialization as well as vocabulary and question prompts.
                    stateText = "{\"is_final\": " + (request.state.isFinal ? "true" : "false") + ", \"utterance\": " + String(decoding: literal, as: UTF8.self) + "}"
                } else { stateText = request.state.text }
                let stateTokens = tokenizer.encode(text: stateText.replacingOccurrences(of: spec?.maskToken ?? "[MASK]", with: " "), addSpecialTokens: false)
                for question in selected {
                    var head = tokenizer.encode(text: (question.type ?? "choice") + " question: " + question.instructions.replacingOccurrences(of: spec?.maskToken ?? "[MASK]", with: " "), addSpecialTokens: false)
                    let labels = labelOrder[question.id]!
                    var spans = labels.map { label in
                        [mask] + Array(tokenizer.encode(text: " " + label + ": " + question.options[label]!, addSpecialTokens: false).prefix(48))
                    }
                    var budget = headLength - spans.reduce(0) { $0 + $1.count }
                    if budget < 16 {
                        let per = max(4, (headLength - 16) / spans.count)
                        spans = spans.map { Array($0.prefix(per)) }
                        budget = headLength - spans.reduce(0) { $0 + $1.count }
                    }
                    head = Array(head.prefix(max(8, budget)))
                    var ids = [cls] + head + [sep], positions = [Int64]()
                    for span in spans { positions.append(Int64(ids.count)); ids += span }
                    ids += [sep]
                    let room = max(0, maxLength - ids.count - 1)
                    guard stateTokens.count <= room else { throw NSError(domain: "stateBudget", code: 5) }
                    ids += stateTokens + [sep]
                    sequences.append(Array(ids.prefix(maxLength)).map(Int64.init)); markers.append(positions)
                }
                let batch = selected.count, length = sequences.map(\.count).max()!, markerCount = markers.map(\.count).max()!
                var input = [Int64](), attention = [Int64](), positions = [Int64](), markerMask = [Int64]()
                for index in 0..<batch {
                    input += sequences[index] + Array(repeating: Int64(pad), count: length - sequences[index].count)
                    attention += Array(repeating: 1, count: sequences[index].count) + Array(repeating: 0, count: length - sequences[index].count)
                    positions += markers[index] + Array(repeating: 0, count: markerCount - markers[index].count)
                    markerMask += Array(repeating: 1, count: markers[index].count) + Array(repeating: 0, count: markerCount - markers[index].count)
                }
                func tensor<T>(_ array: [T], _ type: ORTTensorElementDataType, _ shape: [NSNumber]) throws -> ORTValue {
                    let bytes = array.withUnsafeBytes { NSMutableData(bytes: $0.baseAddress!, length: $0.count) }
                    return try ORTValue(tensorData: bytes, elementType: type, shape: shape)
                }
                let output = try session.run(withInputs: [
                    "input_ids": tensor(input, .int64, [NSNumber(value: batch), NSNumber(value: length)]),
                    "attention_mask": tensor(attention, .int64, [NSNumber(value: batch), NSNumber(value: length)]),
                    "marker_pos": tensor(positions, .int64, [NSNumber(value: batch), NSNumber(value: markerCount)]),
                    "marker_mask": tensor(markerMask, .int64, [NSNumber(value: batch), NSNumber(value: markerCount)]),
                    "qtype": tensor(selected.map { $0.type == "noul" ? Int64(2) : Int64(0) }, .int64, [NSNumber(value: batch)])
                ], outputNames: ["logits"], runOptions: nil)
                let logitsData = try output["logits"]!.tensorData() as Data
                let logits: [Float] = logitsData.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
                var decisions: [String: Any] = ["inferenceMilliseconds": milliseconds(start)]
                var debugLogits = [String: [Double]]()
                for (index, question) in selected.enumerated() {
                    let labels = labelOrder[question.id]!
                    let values = (0..<labels.count).map { Double(logits[index * markerCount + $0]) }
                    guard values.allSatisfy(\.isFinite) else { throw NSError(domain: "logits", code: 3) }
                    debugLogits[question.id] = values
                    let policy = policies[question.id]
                    let temperature = policy?.temperature ?? 1
                    guard temperature.isFinite, temperature > 0 else { throw NSError(domain: "calibration", code: 4) }
                    let maxLogit = values.max()!
                    let expValues = values.map { exp(($0 - maxLogit) / temperature) }
                    let total = expValues.reduce(0, +)
                    let probabilities = expValues.map { $0 / total }
                    let best = probabilities.indices.max { probabilities[$0] < probabilities[$1] }!
                    let confidence = probabilities[best]
                    let accepted = policy?.enabled == true && policy?.threshold.map { confidence >= $0 } == true
                    let value: Any
                    if question.type == "noul" { value = labels[best] == "true" }
                    else if question.id == "requires_more_speech" { value = labels[best] == "B" }
                    else { value = labels[best] }
                    let wireKeys = ["requires_more_speech": "requiresMoreSpeech", "actionable_command": "actionableCommand", "needs_more_speech": "needsMoreSpeech", "coarse_family": "coarseFamily", "correction_or_replacement": "correctionOrReplacement"]
                    decisions[wireKeys[question.id] ?? question.id] = ["value": value, "confidence": confidence, "accepted": accepted]
                }
                try emit(["id": request.id, "decisions": decisions, "logits": debugLogits, "residentBytes": memoryBytes()])
            }
        } catch {
            // No transcripts or inference contents are logged, including malformed requests.
            FileHandle.standardError.write(Data("LocalFlow Laya helper failed.\n".utf8))
            exit(1)
        }
    }
}
