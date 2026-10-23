# Apple Speech streaming · macOS 26+

LocalFlow has one production speech implementation: `AppleSpeechEngine` implements the small streaming and captured-audio interfaces. Both use SpeechAnalyzer + SpeechTranscriber. There is no secondary recognizer, downloadable LocalFlow speech model, or model selector. Unsupported devices/locales are unavailable; asset/inference/overflow failures fail closed.

## Configuration and assets

SpeechTranscriber uses general conversational transcription: no transcription replacements, reporting `[.volatileResults, .alternativeTranscriptions]`, attributes `[.audioTimeRange, .transcriptionConfidence]`. `.fastResults` is disabled. Quality is preferred. The analyzer requests `.processLifetime` retention and is warmed during explicit setup before recording.

`AppleSpeechAssets` resolves only the selected locale using Apple's supported-locale equivalence. Unsupported selection is explicit. Setup checks AssetInventory.status, reserves the selected locale, requests installation only when missing, observes the actual installation Progress, awaits installation and verifies installed status. Apple owns, retains, updates and shares the assets. LocalFlow stores no speech binaries in Application Support. Locale changes release only this actor's previous selected locale; other reservations are never evicted to make space. Recording/cold-start uses installed assets only.

## Streaming and finalization

The existing microphone tap copies immutable mono PCM into a bounded stream. A per-invocation converter preserves its resampling state and drains at EOF. The input sequence converts lazily; it does not make an unbounded PCM queue. Voice Agent does not retain a second full audio recording.

The results consumer starts before analyzer input. `SpeechPhraseLedger` uses normalized Apple CMTime range endpoints and finalization times. Overlapping ranges replace prior hypotheses, including changed range lengths. Final ranges cannot become volatile again. Every real result revision retains text, alternatives, final state and available confidence; confidence is never manufactured as 1.0.

SpeechTranscriber publishes its own finalized ranges during continuous capture. A controlled real Apple PCM test found that forced `finalize(through: nil)` at acoustic pauses lost later commands on this system; removing that custom endpoint preserved all four commands. LocalFlow therefore does not force pause finalization. Only Apple’s actual finalized ranges authorize payloads. At stop, `finalizeAndFinishThroughEndOfInput` authoritatively flushes all trailing speech. A 15-second stop deadline cancels the actual analyzer. Partial text is never substituted for an absent final.

Session IDs, revision IDs, typed word ranges, consumed cursor, deterministic segmentation, per-segment/tool/argument deduplication, contextual dependencies and confirmation ownership remain in VoiceAgentCoordinator. A finalized phrase can execute while microphone capture continues; full-session final reconciliation cannot duplicate an already delivered action. Safe exact bounded commands may still use the existing calibrated stable volatile prefix gate. Writes and consequential commands require authoritative ranges and the native tool's confirmation policy.

Cancellation closes the event relay immediately, cancels input/result/endpoint tasks and calls `cancelAndFinishNow`. Every invocation owns its own analyzer and converter. Late old results cannot enter a later session. Ordinary dictation continues to format/store/inject only after the recording final.

## Alternatives and diagnostics

Explicit agent mode may select an Apple alternative only for a bounded open/launch application entity matching one exact unique installed app name, bundle-declared name or explicit configured app alias. Competing exact apps abstain. Already recognized non-app operations, exact primary apps, URLs/domains, searches, text and correction/conjunction grammar cannot be rewritten by this rescue. Original and selected interpretations are shown only in opt-in transient Debug evidence. They are never persisted in activity/memory or logged by AgentDebugLog.

## Validation

`AppleSpeechTests` covers range revisions, finalization identity, quality configuration and unsupported locales. Real Apple inference is opt-in with test-owned audio: `LOCALFLOW_APPLE_SPEECH_FIXTURES=/absolute/fixtures LOCALFLOW_APPLE_SPEECH_LOCALE=en-IN swift test --filter testRealAppleStreamingWithPacedTestOwnedAudioAndRestart`. A fixtures.json list contains file and utterance fields. Asset installation additionally requires explicit `LOCALFLOW_APPLE_INSTALL=1`. This is real STT on paced synthetic audio; it does not establish microphone or native-action completion.

The current measured results and limitations are in CORE_ARCHITECTURE_REPORT.md. Historical STT bake-off reports remain evidence of earlier architectures, not fallback options.
