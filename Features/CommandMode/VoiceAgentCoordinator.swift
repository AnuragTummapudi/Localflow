import AppKit
import Combine
import Foundation
import Shared

public enum AgentActionPhase: String, Equatable, Sendable {
    case proposed, stable, executing, verified, completed, failed, cancelled
}
public struct AgentActionRecord: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let segment: Int
    public let action: AgentAction
    public var sourceStartWord = 0
    public var sourceEndWord = 0
    public var dependencies: [Int] = []
    public var phases: [AgentActionPhase] = [.proposed]
    public var phase: AgentActionPhase { phases.last ?? .proposed }
    public var verification: ToolVerification?
    public var output: ToolOutput?
    public var detail = ""
    public var undo: ToolUndoToken?
    public var requiresConfirmation = false
    public var performed = false
}
public struct AgentTiming: Equatable, Sendable {
    public enum Kind: String, Sendable { case speechToPartial, decision, actionStart, actionCompletion, totalCompletion }
    public let kind: Kind
    public let milliseconds: Double
}
public struct AgentDecisionEvaluation: Sendable {
    public enum Source: String, Sendable { case deterministic, laya, fallback }
    public let decisions: SpeechDecisions
    public let source: Source
    public init(decisions: SpeechDecisions, source: Source) { self.decisions = decisions; self.source = source }
}
/// Transient opt-in developer evidence. Never written to activity or conversational memory.
public struct AgentDecisionTrace: Equatable, Sendable {
    public let segment: Int
    public let text: String
    public let parsed: String
    public let source: String
    public let confidence: Double?
    public let accepted: Bool?
    public let questions: NarrowSpeechDecisions?
}
#if DEBUG
/// Explicitly enabled, bounded developer-only runtime reconstruction; never persisted by the app.
public struct AgentStreamTrace: Equatable, Sendable, Codable {
    public let event: String
    public let sessionID: UUID
    public let revision: Int
    public let transcript: String
    public let previousStablePrefix: String
    public let stablePrefix: String
    public let consumedWordCursor: Int
    public let nextUnconsumedRange: String
    public let candidates: [String]
    public let ledger: [String]
    public let details: String
}
#endif
public struct VoiceAgentSnapshot: Equatable, Sendable {
    #if DEBUG
    public var streamTrace: [AgentStreamTrace] = []
    #endif
    public var consumedWordCursor = 0
    public var seenWordCount = 0
    public var stabilizedWordCount = 0
    public var feedbackRevision = -1
    public var feedbackVisible = false
    public var transcript = ""
    public var streamingTranscript = ""
    public var finalizedTranscript = ""
    public var speechInterpretations: [SpeechInterpretation] = []
    public var appleRevision: UInt64?
    public var finalizedWordCount = 0
    public var decisionTrace: [AgentDecisionTrace] = []
    public var actions: [AgentActionRecord] = []
    public var timings: [AgentTiming] = []
    public var decisionSources: [String] = []
    public var speechSource: String?
    public var isFinal = false
    public var isCancelled = false
    public var confirmation: ToolConfirmation?
    public var plannerNeedsContinuation = false
    public var plannerActive = false
    public var plannerProgress = ""
    public var plannerReceipts: [PlannerResult] = []
    public var notice = ""
    public var isBusy: Bool { plannerActive || actions.contains { $0.phase == .executing || $0.phase == .stable } }
    public init() {}
}

/// Explicit agent sessions only. Capture/STT remain shared with DictationCoordinator;
/// this boundary alone owns incremental decisions, the serial action ledger and dependencies.
@MainActor
public final class VoiceAgentCoordinator: ObservableObject {
    public typealias Evaluate = @MainActor (DecisionState, SpeechDecisions) async -> AgentDecisionEvaluation
    @Published public private(set) var snapshot = VoiceAgentSnapshot()
    public var onChange: ((VoiceAgentSnapshot) -> Void)?
    /// Explicit developer workflow only; bounded and cleared on every new session.
    public var developerTraceEnabled = false
    public func clearDeveloperTrace() {
        developerTraceEnabled = false
        snapshot.streamingTranscript = ""; snapshot.finalizedTranscript = ""; snapshot.speechInterpretations.removeAll(); snapshot.decisionTrace.removeAll()
        #if DEBUG
        snapshot.streamTrace.removeAll()
        #endif
        publish()
    }
    private let memoryStore: AgentMemoryStore?
    private var plannerTask: Task<Void, Never>?
    private weak var plannerProvider: (any PlannerGenerating)?
    private var finalDecisionReady = false
    private var completedTiming = false
    private var sessionMemory = AgentMemory()
    public var operationalMemory: AgentMemory { sessionMemory }
    private let sourceCommands: CommandMode
    private var commands: CommandMode
    private var decisionCache: [String: AgentDecisionEvaluation] = [:]
    private let executor: ActionExecutor
    private let evaluate: Evaluate
    private let clock: () -> TimeInterval
    private let policy: SpeculationPolicy?
    private var prefix = StablePrefixTracker()
    private var previousStablePrefix = ""
    private var utteranceBoundaries: [[String]] = []
    private var incomingText = ""
    private var incomingBase = ""
    private var lastTextChange: TimeInterval = 0
    private var unsupported: [Int: Int] = [:]
    private var consumedSources: [Int: [String]] = [:]
    private var feedbackTask: Task<Void, Never>?
    private var session = UUID()
    private var revision = 0
    private var speechStart: TimeInterval = 0
    private var decisionTask: Task<Void, Never>?
    private var settleTask: Task<Void, Never>?
    private var executionTask: Task<Void, Never>?
    private var cancelledTasks: [Task<Void, Never>] = []
    private var pendingRecord: UUID?
    private var finalConfidence: Float?
    private var firstPartial = false
    private var actionStarts: [UUID: TimeInterval] = [:]

    public init(commands: CommandMode, executor: ActionExecutor, policy: SpeculationPolicy? = try? .calibrated(),
                clock: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }, memoryStore: AgentMemoryStore? = nil, evaluate: @escaping Evaluate) {
        self.memoryStore = memoryStore; self.sourceCommands = commands; self.commands = commands; self.executor = executor; self.policy = policy; self.clock = clock; self.evaluate = evaluate
    }
    deinit { decisionTask?.cancel(); settleTask?.cancel(); executionTask?.cancel(); feedbackTask?.cancel(); plannerTask?.cancel() }
    public func begin() {
        cancel()
        memoryStore?.reload()
        sessionMemory = memoryStore?.memory ?? sourceCommands.operationalMemory
        commands = sourceCommands.forAgentSession(memory: sessionMemory); decisionCache.removeAll()
        completedTiming = false; finalDecisionReady = false
        session = UUID(); revision = 0; prefix = StablePrefixTracker(); snapshot = VoiceAgentSnapshot(); previousStablePrefix = ""
        actionStarts.removeAll()
        utteranceBoundaries.removeAll(); incomingText = ""; incomingBase = ""; unsupported.removeAll(); consumedSources.removeAll()
        lastTextChange = clock(); feedbackTask?.cancel(); feedbackTask = nil
        finalConfidence = nil; firstPartial = false; speechStart = clock(); pendingRecord = nil
        if let error = memoryStore?.error {
            snapshot.isCancelled = true; snapshot.notice = "Reload or repair agent memory in Settings: " + error
        }
        publish()
    }
    /// The capture service supplies a monotonic, locally detected speech-energy onset.
    public func markSpeechOnset(at time: TimeInterval) {
        guard !firstPartial, time >= speechStart, time <= clock() else { return }
        speechStart = time
    }

    public func receive(_ original: PartialTranscript) {
        let interpretations = SpeechAlternativeResolver.selectAll(original.phrases, commands: commands)
        let partial = PartialTranscript(text: interpretations.isEmpty ? original.text : interpretations.map(\.selected).joined(separator: " "),
            isUtteranceBoundary: original.isUtteranceBoundary, revision: original.revision, phrases: original.phrases)
        guard !snapshot.isFinal, !snapshot.isCancelled else { return }
        let changed = incomingText != partial.text
        guard changed || partial.isUtteranceBoundary || original.revision != snapshot.appleRevision else { return }
        snapshot.appleRevision = original.revision
        // Apple's finalized prefix is authority even while capture remains live.
        let finalized = zip(original.phrases, interpretations).prefix(while: { $0.0.isFinal }).map { $0.1.selected }.joined(separator: " ")
        snapshot.finalizedWordCount = StablePrefixTracker.tokens(finalized).count
        if developerTraceEnabled {
            snapshot.finalizedTranscript = original.finalizedText
            snapshot.speechInterpretations = interpretations
        }
        if changed {
            let old = StablePrefixTracker.tokens(snapshot.transcript)
            let next = StablePrefixTracker.tokens(partial.text)
            let previous = StablePrefixTracker.tokens(incomingText)
            if next.starts(with: old) { incomingBase = "" }
            else if !next.starts(with: previous), (snapshot.consumedWordCursor >= old.count || utteranceBoundaries.contains(old)),
                    !old.isEmpty, Self.commandHeader(partial.text) {
                // Some adapters emit independent utterance replacements after a pause.
                // A consumed or acoustically closed utterance can be retired; open hypotheses stay revisions.
                incomingBase = snapshot.transcript + "; "
            } else if !next.starts(with: previous) { incomingBase = "" }
            incomingText = partial.text
            snapshot.transcript = incomingBase + partial.text
            lastTextChange = clock(); snapshot.feedbackVisible = false
            feedbackTask?.cancel(); feedbackTask = nil
        }
        if developerTraceEnabled { snapshot.streamingTranscript = original.text }
        if snapshot.finalizedWordCount > 0 {
            let words = Array(StablePrefixTracker.tokens(snapshot.transcript).prefix(snapshot.finalizedWordCount))
            if !utteranceBoundaries.contains(words) { utteranceBoundaries.append(words) }
        }
        if partial.isUtteranceBoundary { closeCurrentUtterance() }
        snapshot.seenWordCount = StablePrefixTracker.tokens(snapshot.transcript).count
        revision += 1
        invalidateRevisedPendingActions()
        prefix.update(snapshot.transcript, at: clock())
        diagnose("revision")
        if !firstPartial { firstPartial = true; timing(.speechToPartial, elapsed: clock() - speechStart) }
        publish()
        scheduleDecision()
        // A timer can satisfy elapsed time but NEVER adds an ASR observation.
        settleTask?.cancel()
        if let policy {
            let id = session
            settleTask = Task { @MainActor [weak self] in
                do { try await Task.sleep(for: .seconds(policy.settleSeconds)) } catch { return }
                guard let self, self.session == id, !self.snapshot.isFinal, !self.snapshot.isCancelled else { return }
                self.scheduleDecision()
            }
        }
    }
    public func finish(_ transcript: FinalTranscript) async {
        guard !snapshot.isCancelled, !snapshot.isFinal else { return }
        snapshot.isFinal = true; snapshot.feedbackVisible = false
        feedbackTask?.cancel(); feedbackTask = nil
        // A full recording final is authoritative. Utterance-only replacement adapters
        // retain their consumed source prefix, rather than relabeling it as a correction.
        let interpretations = SpeechAlternativeResolver.selectAll(transcript.phrases, commands: commands)
        let selectedFinal = interpretations.isEmpty ? transcript.text : interpretations.map(\.selected).joined(separator: " ")
        if developerTraceEnabled { snapshot.finalizedTranscript = transcript.text; snapshot.speechInterpretations = interpretations }
        let finalWords = StablePrefixTracker.tokens(selectedFinal)
        let fullWords = StablePrefixTracker.tokens(snapshot.transcript)
        let finalText = !incomingBase.isEmpty && !finalWords.starts(with: Array(fullWords.prefix(snapshot.consumedWordCursor)))
            && finalWords.starts(with: StablePrefixTracker.tokens(incomingText)) ? incomingBase + selectedFinal : selectedFinal
        snapshot.transcript = finalText; snapshot.seenWordCount = StablePrefixTracker.tokens(finalText).count;
         snapshot.speechSource = transcript.source.rawValue; finalConfidence = transcript.confidence
        revision += 1; invalidateRevisedPendingActions(); settleTask?.cancel(); settleTask = nil
        // Coalesce final speech behind any in-flight partial inference. Cancelling it
        // here would kill the warm IPC helper; Escape remains the prompt cancellation path.
        publish()
        scheduleDecision()
        let id = session
        await decisionTask?.value
        guard session == id, !snapshot.isCancelled else { return }
        await executionTask?.value
        guard session == id, !snapshot.isCancelled else { return }
        startQueue()
        await executionTask?.value
    }
    public func cancel() {
        if let plannerTask { cancelledTasks.append(plannerTask); plannerTask.cancel() }
        plannerTask = nil; snapshot.plannerActive = false
        session = UUID(); revision += 1
        if let decisionTask { cancelledTasks.append(decisionTask); decisionTask.cancel() }
        decisionTask = nil; settleTask?.cancel(); settleTask = nil
        if let executionTask { cancelledTasks.append(executionTask); executionTask.cancel() }
        executionTask = nil
        executor.cancelConfirmation(); pendingRecord = nil
        feedbackTask?.cancel(); feedbackTask = nil
        snapshot.isCancelled = true; snapshot.confirmation = nil
        for index in snapshot.actions.indices where [.proposed, .stable, .executing].contains(snapshot.actions[index].phase) {
            if snapshot.actions[index].performed, let start = actionStarts.removeValue(forKey: snapshot.actions[index].id) {
                memoryStore?.record(AgentActivity(tool: snapshot.actions[index].action.toolID.rawValue,
                    outcome: "cancelled-unverified", milliseconds: max(0, clock() - start) * 1000))
            }
            transition(index, .cancelled)
            snapshot.actions[index].detail = "Cancelled; an already sent native request may still finish."
        }
        publish()
    }
    /// A new capture waits for exclusive decision/tool ownership to return after cancellation.
    public func cancelAndWait() async {
        cancel()
        let retired = cancelledTasks
        cancelledTasks.removeAll()
        for task in retired { await task.value }
    }

    public func confirm() async {
        guard !snapshot.isCancelled, let challenge = snapshot.confirmation, let record = pendingRecord,
              let index = snapshot.actions.firstIndex(where: { $0.id == record }) else { return }
        let id = session
        snapshot.confirmation = nil; pendingRecord = nil
        if snapshot.notice == "Earlier action may have completed. Confirm the corrected instruction." { snapshot.notice = "" }
        transition(index, .executing); publish()
        let start = clock()
        // Own the confirmation task as well: Escape must cancel native waits, not just the UI.
        executionTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let result = await self.executor.confirm(challenge) { [weak self] in
                self?.markPerformed(record, session: id)
            }
            guard self.session == id, !self.snapshot.isCancelled else { return }
            self.consume(result, record: record, elapsed: self.clock() - start)
            self.executionTask = nil
            self.startQueue()
        }
        await executionTask?.value
        await executionTask?.value
    }
    public func waitForPendingWork() async {
        await decisionTask?.value
        await executionTask?.value
    }
    /// Typed System-2 uses the SAME ledger, executor, grants, receipts and Undo.
    /// This entry point is also the opt-in model-backed benchmark boundary.
    public func runPlanner(_ request: PlannerRequest, provider: any PlannerGenerating, resumeAfterUserApproval: Bool = false) async {
        if resumeAfterUserApproval {
            guard snapshot.plannerNeedsContinuation, !snapshot.isCancelled, plannerTask == nil else { return }
            snapshot.plannerNeedsContinuation = false
        } else {
            await cancelAndWait()
            begin()
        }
        guard !snapshot.isCancelled else { return }
        if !resumeAfterUserApproval, PlannerRouter.route(request.goal, authoritative: true, enabled: true, commands: commands) == .direct {
            // Typed direct requests use the existing deterministic ledger even when the model is unloaded.
            snapshot.isFinal = true; snapshot.transcript = request.goal
            snapshot.seenWordCount = StablePrefixTracker.tokens(request.goal).count; revision += 1
            publish(); scheduleDecision()
            await decisionTask?.value; await executionTask?.value
            guard !snapshot.isCancelled else { return }
            startQueue(); await executionTask?.value
            return
        }
        snapshot.isFinal = true; snapshot.transcript = request.goal
        snapshot.plannerActive = true; snapshot.notice = "Planning…"
        plannerProvider = provider
        let id = session
        let envelope = GoalEnvelope(goal: request.goal, memory: sessionMemory, frontmostApplication: NSWorkspace.shared.frontmostApplication?.bundleIdentifier)
        plannerTask = Task { @MainActor [weak self, weak provider] in
            guard let self, let provider else { return }
            var executed = 0, replans = 0, turns = 0
            defer {
                if self.session == id {
                    self.snapshot.plannerActive = false; self.finalDecisionReady = true
                    self.plannerTask = nil; self.publish()
                }
            }
            while self.session == id, !Task.isCancelled, !self.snapshot.isCancelled {
                guard executed < 16, replans <= 4, turns < 17 else {
                    self.snapshot.plannerNeedsContinuation = true; self.snapshot.notice = "Plan limit reached. Confirm continuation in Settings."; return
                }
                turns += 1; self.snapshot.notice = "Planning…"; self.publish()
                do {
                    let scope = PlannerTurnScope(envelope: envelope, memory: self.sessionMemory, receipts: self.snapshot.plannerReceipts, registry: self.executor.registry)
                    if scope.context.goalSatisfied { self.snapshot.notice = "Planner finished"; return }
                    let generation = try await provider.generate(request, context: scope.context, schemas: scope.schemas)
                    try Task.checkCancellation(); guard self.session == id else { return }
                    guard let proposed = generation.plan else {
                        self.snapshot.notice = "Planner abstained: no framed next action."; return
                    }
                    let (decision, resolvedPlan) = try scope.resolve(proposed)
                    guard decision == .toolCall, let plan = resolvedPlan else {
                        self.snapshot.notice = decision == .finish ? "Planner finished" : decision == .askUser ? (envelope.issue ?? "More information is needed to continue.") : "Planner abstained: unsupported request."
                        return
                    }
                    // Validate the entire batch BEFORE accepting even its first action.
                    let validated = try PlannerValidator(registry: self.executor.registry, commands: self.commands, memory: self.sessionMemory, receipts: self.snapshot.plannerReceipts).validate(plan)
                    guard executed + validated.count <= 16 else {
                        self.snapshot.plannerNeedsContinuation = true; self.snapshot.notice = "Plan limit reached. Confirm continuation in Settings."; return
                    }
                    let base = (self.snapshot.actions.map(\.segment).max() ?? -1) + 1
                    let batchTotal = self.snapshot.actions.count + validated.count
                    var remaining = validated
                    var resolved: [String: Int] = [:]
                    var batchFailed = false
                    while !remaining.isEmpty {
                        guard let next = remaining.firstIndex(where: { $0.0.dependsOn.allSatisfy { resolved[$0.stepID] != nil } }) else { throw ToolError.invalidArguments }
                        let (step, action) = remaining.remove(at: next)
                        let prior = self.snapshot.actions.filter { $0.performed && self.samePlannerInvocation($0.action, action) }
                        if !prior.isEmpty && !(action.toolID.plannerRetryable && prior.allSatisfy({ $0.phase == .failed }) && prior.count < 3) {
                            throw ToolError.unavailable("Planner repeated a delivered action. No retry was sent.")
                        }
                        for dependency in step.dependsOn {
                            guard let segment = resolved[dependency.stepID], let receipt = self.snapshot.actions.last(where: { $0.segment == segment }),
                                  receipt.phase == .completed, (!dependency.requiresVerified || receipt.verification == .verified) else {
                                throw ToolError.unavailable("Required planner context did not verify.")
                            }
                        }
                        // Recheck native context immediately before each send, after prior receipts.
                        _ = try PlannerValidator(registry: self.executor.registry, commands: self.commands, memory: self.sessionMemory, receipts: self.snapshot.plannerReceipts)
                            .validate(PlannerPlan(steps: [PlannerStep(id: step.id, tool: step.tool, arguments: step.arguments)]))
                        let segment = base + resolved.count
                        self.append(action, segment: segment, stable: true, confirm: self.sessionMemory.confirmAllActions)
                        self.snapshot.plannerProgress = validated.count == 1 ? "Action \(self.snapshot.actions.count)" : "\(self.snapshot.actions.count) / \(batchTotal)"
                        self.snapshot.notice = action.summary; self.publish()
                        // Serialized with every deterministic action; native effects live only in startQueue.
                        self.startQueue()
                        let deadline = self.clock() + 125
                        while self.session == id, !Task.isCancelled, let record = self.snapshot.actions.last(where: { $0.segment == segment }),
                              [.proposed, .stable, .executing].contains(record.phase) {
                            await self.executionTask?.value
                            if self.snapshot.confirmation != nil && self.clock() > deadline {
                                self.executor.cancelConfirmation(); self.snapshot.confirmation = nil; self.pendingRecord = nil
                                if let index = self.snapshot.actions.firstIndex(where: { $0.id == action.id }) { self.transition(index, .failed) }
                                break
                            }
                            try await Task.sleep(for: .milliseconds(20))
                        }
                        try Task.checkCancellation(); guard self.session == id else { return }
                        guard let record = self.snapshot.actions.last(where: { $0.segment == segment }) else { throw ToolError.invalidArguments }
                        executed += 1; resolved[step.id] = segment
                        let status: String
                        if record.phase == .completed { status = record.verification == .verified ? "verified" : "unverified" }
                        else { status = record.phase.rawValue }
                        let data: [String: PlannerValue]
                        if case .semantic(let values) = record.output { data = values }
                        else if case .file(let file) = record.output { data = ["path": .string(file.path)] }
                        else { data = [:] }
                        self.snapshot.plannerReceipts.append(PlannerResult(stepID: String(self.snapshot.actions.count), tool: step.tool, status: status, detail: record.detail, data: data, arguments: step.arguments))
                        self.publish()
                        if record.phase != .completed { batchFailed = true; break }
                    }
                    if batchFailed { replans += 1 }
                } catch is CancellationError { return }
                catch { self.snapshot.notice = "Planner stopped: " + error.localizedDescription; return }
            }
        }
        await plannerTask?.value
    }

    private func scheduleDecision() {
        guard !snapshot.isCancelled, decisionTask == nil else { return }
        let id = session
        decisionTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let retired = self.cancelledTasks
            self.cancelledTasks.removeAll()
            for task in retired { await task.value }
            guard self.session == id, !Task.isCancelled else { return }
            var processed = -1
            repeat {
                processed = self.revision
                await self.decide(session: id, revision: processed)
            } while self.session == id && !Task.isCancelled && processed != self.revision
            guard self.session == id else { return }
            self.decisionTask = nil
        }
    }
    private func decide(session id: UUID, revision version: Int) async {
        let sessionFinal = snapshot.isFinal
        let parts: [SpeechCommandSegment]
        do { parts = try currentSegments() }
        catch { snapshot.notice = error.localizedDescription; cancelFollowing(0); finalDecisionReady = sessionFinal; publish(); return }
        let observedStable = policy.map { prefix.stableWordCount(at: clock(), policy: $0) } ?? 0
        let stableCount = max(observedStable, matchingBoundaries().max() ?? 0)
        snapshot.stabilizedWordCount = sessionFinal ? snapshot.seenWordCount : max(stableCount, snapshot.finalizedWordCount)
        snapshot.notice = ""
        // Final ASR is authoritative even if a previous hypothesis contained more clauses.
        for index in snapshot.actions.indices where snapshot.actions[index].segment >= parts.count && snapshot.actions[index].phase == .proposed {
            transition(index, .cancelled)
        }
        segmentLoop: for (ordinal, part) in parts.enumerated() {
            let isFinal = sessionFinal || part.endWord <= snapshot.finalizedWordCount
            guard self.session == id, !Task.isCancelled, version == revision else { return }
            if part.endWord <= snapshot.consumedWordCursor,
               consumedSources[ordinal] == StablePrefixTracker.tokens(part.text) { continue }
            let decisionStart = clock()
            let parsed = SpeechCommandSegmenter.noteAction(part.text).map { CommandResolution.execute(.nativeAction(commands.canonicalizedPayload($0))) }
                ?? commands.resolve(part.text, transcriptionConfidence: isFinal ? finalConfidence : nil)
            diagnose("parser", details: "segment=\(ordinal) parsed=\(parsed)")
            let intent: CommandIntent
            let parserRequiresConfirmation: Bool
            switch parsed {
            case .execute(let command): intent = command; parserRequiresConfirmation = false
            case .needsConfirmation(let command): intent = command; parserRequiresConfirmation = true
            case .notCommand:
                // Unknown speech may be classified, but even accepted scores route
                // back to this parser's unsupported result. No slots are synthesized.
                let key = (isFinal ? "final:" : "partial:") + part.text
                let observation: AgentDecisionEvaluation
                if let cached = decisionCache[key] { observation = cached }
                else {
                    observation = await evaluate(DecisionState(text: part.text, isFinal: isFinal), SpeechDecisions(intent: nil, risk: nil, requiresMoreSpeech: nil))
                    guard self.session == id, !Task.isCancelled, version == revision else { return }
                    if decisionCache.count >= 128 { decisionCache.removeAll() }
                    decisionCache[key] = observation
                }
                timing(.decision, elapsed: clock() - decisionStart)
                if !snapshot.decisionSources.contains(observation.source.rawValue) { snapshot.decisionSources.append(observation.source.rawValue) }
                trace(part, ordinal: ordinal, parsed: parsed, result: observation)
                if isFinal {
                    snapshot.notice = "Unsupported or incomplete instruction. Nothing was typed."
                    unsupported[ordinal] = part.endWord
                    advanceConsumption()
                    // Only true context dependencies are blocked, not unrelated commands.
                    continue segmentLoop
                }
                if part.closed, part.endWord <= stableCount { unsupported[ordinal] = part.endWord; advanceConsumption() }
                continue
            }
            unsupported.removeValue(forKey: ordinal)
            let fallback = (try? DeterministicDecisionEngine.decisions(for: parsed, isFinal: isFinal))
                ?? SpeechDecisions(intent: nil, risk: nil, requiresMoreSpeech: nil)
            let key = (isFinal ? "final:" : "partial:") + part.text
            let result: AgentDecisionEvaluation
            // Exact parser-owned commands do not pay model latency. Laya remains an
            // optional helper for an uncertain parsed target; it cannot invent slots,
            // remove confirmation, or make an unsupported request executable.
            let action = intent.agentAction
            let uncertainOpen = action.toolID == .openApplication
                && !commands.isExactApplicationOpen(part.text, action: action)
                && !commands.isConfiguredApplicationOpen(part.text, action: action)
            let needsSemanticHelp = parserRequiresConfirmation || uncertainOpen
            if !needsSemanticHelp { result = AgentDecisionEvaluation(decisions: fallback, source: .deterministic) }
            else if let cached = decisionCache[key] { result = cached }
            else {
                result = await evaluate(DecisionState(text: part.text, isFinal: isFinal), fallback)
                guard self.session == id, !Task.isCancelled, version == revision else { return }
                if decisionCache.count >= 128 { decisionCache.removeAll() }
                decisionCache[key] = result
            }
            guard self.session == id, !Task.isCancelled, version == revision else { return }
            timing(.decision, elapsed: clock() - decisionStart)
            if !snapshot.decisionSources.contains(result.source.rawValue) { snapshot.decisionSources.append(result.source.rawValue) }
            trace(part, ordinal: ordinal, parsed: parsed, result: result)
            if let narrow = result.decisions.narrow {
                switch NarrowDecisionPolicy.route(parsed, knownExact: !needsSemanticHelp, isFinal: isFinal, decisions: narrow) {
                case .parsed: break
                case .wait: snapshot.notice = "Waiting for more speech."; continue segmentLoop
                case .abstain:
                    if isFinal { snapshot.notice = "Uncertain or unsupported instruction. Nothing was sent."; unsupported[ordinal] = part.endWord; advanceConsumption() }
                    continue segmentLoop
                }
            }
            var confirm = parserRequiresConfirmation || sessionMemory.confirmAllActions || isFinal && uncertainOpen
            var modelAllowsEarly = true
            if result.source == .laya {
                if let value = result.decisions.intent, value.accepted, value.value != intent.decisionIntent { confirm = true; modelAllowsEarly = false }
                if let value = result.decisions.requiresMoreSpeech, value.accepted, value.value { confirm = true; modelAllowsEarly = false }
            }
            // Only exact, unique application opens can speculate. Open-ended tail clauses,
            // fuzzy names, text writes and ALL consequential actions wait for authoritative final.
            let exact = commands.isExactApplicationOpen(part.text, action: action) || commands.isConfiguredApplicationOpen(part.text, action: action)
            let boundaryTarget = boundaryExecutable(part.text, action: action)
            let early = !parserRequiresConfirmation && !sessionMemory.confirmAllActions && policy != nil
                && part.closed && part.endWord <= stableCount && (exact || boundaryTarget) && modelAllowsEarly
            propose(action, segment: ordinal, stable: isFinal || early, confirm: confirm, authoritative: isFinal)
            if let index = snapshot.actions.lastIndex(where: { $0.segment == ordinal && $0.phase != .cancelled }) {
                snapshot.actions[index].sourceStartWord = part.startWord
                snapshot.actions[index].sourceEndWord = part.endWord
                snapshot.actions[index].dependencies = dependencies(for: action, segment: ordinal, independent: part.independent)
            }
        }
        if !Task.isCancelled, session == id, version == revision {
            if sessionFinal { finalDecisionReady = true }
            publish(); startQueue()
        }
    }
    private func trace(_ part: SpeechCommandSegment, ordinal: Int, parsed: CommandResolution, result: AgentDecisionEvaluation?) {
        guard developerTraceEnabled else { return }
        let entry = AgentDecisionTrace(segment: ordinal, text: part.text, parsed: String(describing: parsed),
            source: result?.source.rawValue ?? "deterministic", confidence: result?.source == .laya ? (result?.decisions.narrow?.actionableCommand?.confidence.value ?? result?.decisions.intent?.confidence.value) : nil,
            accepted: result?.source == .laya ? (result?.decisions.narrow?.actionableCommand?.accepted ?? result?.decisions.intent?.accepted) : nil, questions: result?.decisions.narrow)
        if snapshot.decisionTrace.last != entry { snapshot.decisionTrace.append(entry) }
        snapshot.decisionTrace = Array(snapshot.decisionTrace.suffix(48))
    }
    /// Revoke queued grants synchronously, before slower model inference can suspend.
    private func invalidateRevisedPendingActions() {
        let parts = (try? currentSegments()) ?? []
        for index in snapshot.actions.indices where [.proposed, .stable, .executing].contains(snapshot.actions[index].phase) {
            let record = snapshot.actions[index]
            let current: AgentAction?
            if record.segment < parts.count {
                let text = parts[record.segment].text
                if let note = SpeechCommandSegmenter.noteAction(text) { current = note }
                else {
                    switch commands.resolve(text) {
                    case .execute(let intent), .needsConfirmation(let intent): current = intent.agentAction
                    case .notCommand: current = nil
                    }
                }
            } else { current = nil }
            guard current.map({ sameInvocation($0, record.action) }) != true else { continue }
            if pendingRecord == record.id, !record.performed {
                executor.cancelConfirmation()
                snapshot.confirmation = nil; pendingRecord = nil
            }
            if record.phase == .executing {
                executionTask?.cancel() // interrupts native polling/preparation, cannot unsend an effect
                snapshot.notice = "Speech revised after an action started. Waiting for final speech."
            } else { transition(index, .cancelled) }
        }
    }

    /// Canonical saved targets and synonymous semantic IDs cannot bypass delivered-effect deduplication.
    private func samePlannerInvocation(_ lhs: AgentAction, _ rhs: AgentAction) -> Bool {
        func key(_ action: AgentAction) -> String? {
            guard case .semantic(let args) = action.arguments,
                  let project = try? args.project(for: action.toolID, memory: sessionMemory) else { return nil }
            var values = args.values
            values.removeValue(forKey: "name"); values.removeValue(forKey: "scope")
            values["project"] = .string(project.name)
            var family = action.toolID.rawValue
            switch action.toolID {
            case .projectOpen, .editorOpenProject:
                family = NativeToolID.projectOpen.rawValue
                values["preferredEditor"] = .string(args.values["preferredEditor"]?.string ?? project.preferredEditor ?? sessionMemory.preferredApps["editor"] ?? "")
            case .projectOpenFile, .fileOpen, .editorOpenFile:
                family = NativeToolID.projectOpenFile.rawValue
                values["path"] = .string((try? args.file(in: project).path) ?? args.string("path"))
                values["line"] = .integer(args.values["line"]?.integer ?? 1)
            case .projectSearch, .fileSearch, .editorRevealSymbol: family = NativeToolID.projectSearch.rawValue
            case .workflowRun, .workflowStop:
                values["workflowName"] = .string(AgentMemory.key(args.string("workflowName")))
            case .serviceWait: values["timeout"] = .integer(args.values["timeout"]?.integer ?? 30)
            default: break
            }
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
            return family + ":" + String(decoding: (try? encoder.encode(values)) ?? Data(), as: UTF8.self)
        }
        if let left = key(lhs), let right = key(rhs) { return left == right }
        return sameInvocation(lhs, rhs)
    }

    private func sameInvocation(_ lhs: AgentAction, _ rhs: AgentAction) -> Bool {
        guard lhs.toolID == rhs.toolID else { return false }
        if case .application(let left, let leftPID) = lhs.arguments,
           case .application(let right, let rightPID) = rhs.arguments {
            // ASR confidence is evidence, not an execution slot. Its final revision must
            // never re-open an identical target which the ledger already delivered.
            return left.id == right.id && left.url == right.url && leftPID == rightPID
        }
        return lhs.arguments == rhs.arguments
    }

    private func propose(_ action: AgentAction, segment: Int, stable: Bool, confirm: Bool, authoritative: Bool) {
        if let index = snapshot.actions.lastIndex(where: { $0.segment == segment && ($0.phase != .cancelled || $0.performed) }) {
            let previous = snapshot.actions[index]
            if sameInvocation(previous.action, action) {
                if previous.phase == .proposed, stable { transition(index, .stable); snapshot.actions[index].requiresConfirmation = confirm }
                diagnose("deduplicated", details: "segment=\(segment) key=\(invocationKey(action))")
                return
            }
            if previous.performed {
                // Native requests cannot be unsent. Do not quit a prematurely opened app.
                // A revised target gets an explicit confirmation after final ASR instead.
                guard authoritative else {
                    snapshot.notice = "Speech revised after an action started. Waiting for final speech."
                    return
                }
                guard !snapshot.actions.contains(where: { $0.segment == segment && sameInvocation($0.action, action) }) else { return }
                append(action, segment: segment, stable: true, confirm: true)
                snapshot.notice = "Earlier action may have completed. Confirm the corrected instruction."
                return
            }
            if previous.phase == .failed { return } // no automatic retry of a possibly delivered effect
            transition(index, .cancelled)
        }
        append(action, segment: segment, stable: stable, confirm: confirm)
    }
    private func append(_ action: AgentAction, segment: Int, stable: Bool, confirm: Bool) {
        var record = AgentActionRecord(id: action.id, segment: segment, action: action)
        if stable { record.phases.append(.stable) }
        record.requiresConfirmation = confirm
        snapshot.actions.append(record)
        diagnose("proposed", details: "segment=\(segment) action=\(action) key=\(invocationKey(action))")
    }
    private func startQueue() {
        guard !snapshot.isCancelled, snapshot.confirmation == nil, executionTask == nil else { return }
        let id = session
        executionTask = Task { @MainActor [weak self] in
            guard let self else { return }
            while self.session == id, !self.snapshot.isCancelled, !Task.isCancelled {
                let stable = self.snapshot.actions.indices.filter { self.snapshot.actions[$0].phase == .stable }
                let executable = stable.filter { index in
                    let record = self.snapshot.actions[index]
                    // An unresolved fuzzy app is still confirmable, but cannot poison
                    // later independent exact commands. Never bypass consequential grants.
                    if record.action.toolID == .openApplication, record.requiresConfirmation,
                       !self.snapshot.actions.contains(where: { $0.segment == record.segment && $0.performed }),
                       stable.contains(where: { other in
                           self.snapshot.actions[other].segment > record.segment
                           && self.snapshot.actions[other].dependencies.isEmpty
                           && !self.snapshot.actions[other].requiresConfirmation
                       }) { return false }
                    let predecessors = record.dependencies.compactMap { ordinal in
                        self.snapshot.actions.last { $0.segment == ordinal && $0.phase != .cancelled }
                    }
                    let unresolved = predecessors.count != record.dependencies.count || predecessors.contains { [.proposed, .stable, .executing].contains($0.phase) }
                    if unresolved, predecessors.contains(where: { [.proposed, .stable, .executing].contains($0.phase) }) || !self.snapshot.isFinal && !record.dependencies.contains(where: { self.unsupported[$0] != nil }) {
                        self.diagnose("dependency-wait", details: "segment=\(record.segment) dependencies=\(record.dependencies)")
                        return false
                    }
                    return true
                }
                guard let index = executable.min(by: { self.snapshot.actions[$0].segment < self.snapshot.actions[$1].segment }) else { break }
                let record = self.snapshot.actions[index]
                let predecessors = record.dependencies.compactMap { ordinal in
                    self.snapshot.actions.last { $0.segment == ordinal && $0.phase != .cancelled }
                }
                if predecessors.count != record.dependencies.count || predecessors.contains(where: {
                    $0.phase == .failed || ($0.phase == .completed && $0.verification != .verified)
                }) {
                    if self.snapshot.isFinal || record.dependencies.contains(where: { self.unsupported[$0] != nil }) {
                        self.transition(index, .failed); self.snapshot.actions[index].detail = "Required context did not verify readiness."
                        self.advanceConsumption(); self.publish(); continue
                    }
                    break
                }
                if predecessors.contains(where: { $0.phase != .completed }) { break }
                self.transition(index, .executing); self.diagnose("execution-start", details: "segment=\(record.segment)"); self.publish()
                let start = self.clock()
                let result = await self.executor.execute(record.action, requireConfirmation: record.requiresConfirmation) { [weak self] in
                    self?.markPerformed(record.id, session: id)
                }
                guard self.session == id, !self.snapshot.isCancelled else { return }
                self.consume(result, record: record.id, elapsed: self.clock() - start)
                if self.snapshot.confirmation != nil { break }
            }
            guard self.session == id else { return }
            self.executionTask = nil
        }
    }
    private func markPerformed(_ record: UUID, session id: UUID) {
        guard session == id, let index = snapshot.actions.firstIndex(where: { $0.id == record }) else { return }
        snapshot.actions[index].performed = true
        actionStarts[record] = clock()
        timing(.actionStart, elapsed: clock() - speechStart)
    }
    private func consume(_ result: ToolResult, record: UUID, elapsed: Double) {
        guard let index = snapshot.actions.firstIndex(where: { $0.id == record }) else { return }
        switch result {
        case .completed(let message, let output, let verification, let undo):
            snapshot.actions[index].output = output
            snapshot.actions[index].verification = verification
            snapshot.actions[index].detail = message
            snapshot.actions[index].undo = undo
            if verification == .verified { transition(index, .verified) }
            transition(index, .completed)
            timing(.actionCompletion, elapsed: elapsed)
        case .requiresConfirmation(let challenge):
            snapshot.confirmation = challenge; pendingRecord = record
            transition(index, .stable)
            snapshot.actions[index].detail = "Confirm this action?"
        case .failed(let message): transition(index, .failed); snapshot.actions[index].detail = message
        case .cancelled: transition(index, .cancelled)
        }
        if snapshot.actions[index].action.toolID.isAccessibility {
            diagnose("receipt", details: "segment=\(snapshot.actions[index].segment) tool=\(snapshot.actions[index].action.toolID.rawValue) phase=\(snapshot.actions[index].phase.rawValue)")
        } else { diagnose("receipt", details: "segment=\(snapshot.actions[index].segment) result=\(result)") }
        let phase = snapshot.actions[index].phase
        if [.completed, .failed, .cancelled].contains(phase) {
            advanceConsumption()
            snapshot.feedbackRevision = revision; snapshot.feedbackVisible = true
            feedbackTask?.cancel()
            let id = session, feedback = revision
            feedbackTask = Task { @MainActor [weak self] in
                do { try await Task.sleep(for: .seconds(1.2)) } catch { return }
                guard let self, self.session == id, self.revision == feedback, !self.snapshot.isFinal else { return }
                self.snapshot.feedbackVisible = false; self.publish()
            }
            actionStarts.removeValue(forKey: record)
            let outcome = phase == .completed && snapshot.actions[index].verification != .verified ? "unverified" : phase.rawValue
            memoryStore?.record(AgentActivity(tool: snapshot.actions[index].action.toolID.rawValue, outcome: outcome, milliseconds: elapsed * 1000))
        }
        publish()
    }
    /// Save only a verified successful single command after an explicit user approval.
    public func approveSuccessfulCommand(as alias: String) throws {
        guard let memoryStore, snapshot.isFinal, !snapshot.isCancelled,
              snapshot.actions.count == 1, let record = snapshot.actions.first,
              record.phase == .completed, record.verification == .verified,
              record.action.toolID.risk != .consequential else {
            throw AgentMemoryError.invalid("Only a verified, non-consequential single command can be saved.")
        }
        var value = memoryStore.memory
        value.approvedCommands[alias] = snapshot.transcript
        try sourceCommands.validateOperationalMemory(value)
        try memoryStore.save(value)
    }
    private func cancelFollowing(_ segment: Int) {
        for index in snapshot.actions.indices where snapshot.actions[index].segment >= segment && [.proposed, .stable].contains(snapshot.actions[index].phase) {
            transition(index, .cancelled)
        }
    }
    private func transition(_ index: Int, _ phase: AgentActionPhase) {
        if snapshot.actions[index].phase != phase { snapshot.actions[index].phases.append(phase) }
    }
    /// Called only by explicit-agent capture, using existing audio-energy silence state.
    public func observePause(silenceDurationSeconds: Double) {
        guard !snapshot.isFinal, !snapshot.isCancelled, let policy,
              silenceDurationSeconds >= policy.settleSeconds, clock() - lastTextChange >= policy.settleSeconds else { return }
        guard closeCurrentUtterance() else { return }
        diagnose("pause-boundary"); scheduleDecision()
    }
    @discardableResult private func closeCurrentUtterance() -> Bool {
        let words = StablePrefixTracker.tokens(snapshot.transcript)
        guard !words.isEmpty, !utteranceBoundaries.contains(words) else { return false }
        utteranceBoundaries.append(words); return true
    }
    private static func commandHeader(_ text: String) -> Bool {
        text.range(of: "(?i)^(?:open|launch|switch to|quit|go to|browse to|search|create|call it|name it|title it|write|append to|write current|type at|replace selected|copy to|mute|unmute|volume|set volume|take|reveal|pause|resume|run|start)\\b", options: .regularExpression) != nil
    }
    private func matchingBoundaries() -> [Int] {
        let words = StablePrefixTracker.tokens(snapshot.transcript)
        return utteranceBoundaries.filter { words.starts(with: $0) }.map(\.count)
    }
    private func currentSegments() throws -> [SpeechCommandSegment] {
        let text = snapshot.transcript, source = text as NSString
        let words = try NSRegularExpression(pattern: "\\S+").matches(in: text, range: NSRange(location: 0, length: source.length)).filter { !StablePrefixTracker.tokens(source.substring(with: $0.range)).isEmpty }
        let cuts = matchingBoundaries().filter { $0 < words.count && Self.commandHeader(source.substring(from: words[$0].range.location)) }.sorted()
        var result: [SpeechCommandSegment] = [], start = 0, offset = 0
        for end in cuts + [words.count] {
            let location = end == words.count ? source.length : words[end].range.location
            let piece = source.substring(with: NSRange(location: start, length: location - start)).trimmingCharacters(in: .whitespacesAndNewlines)
            let boundary = matchingBoundaries().contains(end)
            let parts = try commands.segments(piece, continuous: true)
            for (index, part) in parts.enumerated() {
                result.append(SpeechCommandSegment(text: part.text,
                    endWord: part.endWord == Int.max ? Int.max : offset + part.endWord,
                    closed: part.closed || boundary && part.endWord != Int.max,
                    startWord: offset + part.startWord, independent: offset > 0 && index == 0 || part.independent))
            }
            start = location; offset = end
        }
        return result
    }

    private func boundaryExecutable(_ text: String, action: AgentAction) -> Bool {
        switch action.toolID {
        case .openURL:
            // Search/query payloads are open-ended. Only a complete anchored navigation
            // target may execute at a stable command boundary.
            guard let header = ["open ", "go to ", "browse to "].first(where: { text.lowercased().hasPrefix($0) }),
                  let url = CommandMode.parseURL(from: String(text.dropFirst(header.count))) else { return false }
            return action.arguments == .url(url)
        case .openWebsite: return true // Existing registry matched a whole known provider.
        default: return false
        }
    }
    private func dependencies(for action: AgentAction, segment: Int, independent: Bool) -> [Int] {
        guard segment > 0 else { return [] }
        let prior = snapshot.actions.filter { $0.segment < segment && $0.phase != .cancelled }
        switch action.toolID {
        case .createNote, .appendNote, .writeNote, .renameNote, .typeText, .replaceSelection:
            let context = prior.last { $0.action.toolID == .openApplication || $0.action.toolID == .focusApplication || $0.action.toolID == .createNote }
            // An unsupported intervening instruction cannot silently reuse older
            // application/note context. Independent opens may pass it; writes may not.
            if let unknown = unsupported.keys.filter({ $0 < segment && $0 > (context?.segment ?? -1) }).max() { return [unknown] }
            return [context?.segment ?? segment - 1]
        default:
            // An explicit compound's consequential predecessor retains its ordered
            // authorization barrier. Independent later utterances don't inherit it.
            if !independent, let previous = prior.last {
                let correctionBarrier = previous.requiresConfirmation && snapshot.actions.contains {
                    $0.segment == previous.segment && $0.performed && !sameInvocation($0.action, previous.action)
                }
                if previous.action.toolID.risk == .consequential || correctionBarrier { return [previous.segment] }
            }
            return []
        }
    }
    private func advanceConsumption() {
        var end = snapshot.consumedWordCursor
        let parts = (try? currentSegments()) ?? []
        for (ordinal, part) in parts.enumerated() {
            if part.endWord <= end { continue }
            let record = snapshot.actions.last { $0.segment == ordinal && ($0.phase != .cancelled || $0.performed) }
            let consumed = unsupported[ordinal] != nil || record.map { $0.phase == .completed || $0.phase == .failed || $0.phase == .cancelled && $0.performed } == true
            guard consumed else { break }
            consumedSources[ordinal] = StablePrefixTracker.tokens(part.text)
            end = min(part.endWord, snapshot.seenWordCount)
        }
        if end > snapshot.consumedWordCursor {
            snapshot.consumedWordCursor = end
            diagnose("segment-consumed")
        }
    }
    private func invocationKey(_ action: AgentAction) -> String {
        if case .application(let app, let pid) = action.arguments {
            return "\(action.toolID.rawValue):\(app.id):\(app.url?.absoluteString ?? ""):\(pid.map(String.init) ?? "")"
        }
        return "\(action.toolID.rawValue):\(action.arguments)"
    }
    private func diagnose(_ event: String, details: String = "") {
        #if DEBUG
        guard developerTraceEnabled else { return }
        let words = StablePrefixTracker.tokens(snapshot.transcript)
        let stable = snapshot.isFinal ? words.count : max(policy.map { prefix.stableWordCount(at: clock(), policy: $0) } ?? 0, matchingBoundaries().max() ?? 0)
        let current = words.prefix(stable).joined(separator: " ")
        let parts = (try? currentSegments()) ?? []
        snapshot.streamTrace.append(AgentStreamTrace(event: event, sessionID: session, revision: revision,
            transcript: snapshot.transcript, previousStablePrefix: previousStablePrefix, stablePrefix: current,
            consumedWordCursor: snapshot.consumedWordCursor,
            nextUnconsumedRange: "\(snapshot.consumedWordCursor)..<\(words.count)",
            candidates: parts.enumerated().map { "segment=\($0.offset) end=\($0.element.endWord) closed=\($0.element.closed) text=\($0.element.text)" },
            ledger: snapshot.actions.map { "segment=\($0.segment) id=\($0.id) key=\(invocationKey($0.action)) range=\($0.sourceStartWord)..<\($0.sourceEndWord) dependencies=\($0.dependencies) phase=\($0.phase.rawValue) sent=\($0.performed)" },
            details: details))
        snapshot.streamTrace = Array(snapshot.streamTrace.suffix(96))
        previousStablePrefix = current
        #endif
    }
    private func timing(_ kind: AgentTiming.Kind, elapsed: Double) {
        snapshot.timings.append(AgentTiming(kind: kind, milliseconds: max(0, elapsed * 1_000)))
        if snapshot.timings.count > 128 { snapshot.timings.removeFirst(snapshot.timings.count - 128) }
    }
    private func publish() {
        if snapshot.isFinal, finalDecisionReady, !snapshot.plannerActive, !snapshot.isCancelled, !completedTiming, snapshot.confirmation == nil,
           !snapshot.actions.contains(where: { [.proposed, .stable, .executing].contains($0.phase) }) {
            completedTiming = true
            timing(.totalCompletion, elapsed: clock() - speechStart)
        }
        onChange?(snapshot)
    }
}
