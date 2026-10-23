# Apple API decisions checked against macOS 26.5 SDK and Apple documentation

- SpeechAnalyzer consumes AnalyzerInput PCM buffers with monotonically advancing sample timestamps. A single invocation owns one converter and analyzer.
- SpeechTranscriber uses conversational transcription, volatile and alternative results, audio-time-range and confidence attributes. No fastResults accuracy tradeoff is enabled.
- Result range, resultsFinalizationTime and isFinal feed range replacement and authoritative final-prefix handling. Confidence is optional, never fabricated.
- SpeechAnalyzer.finalize(through:nil) finalizes audio already consumed without ending the sequence. The API was audited, but the real controlled continuation test lost later speech when forcing it at pauses; production does not call it during capture. Only naturally published final results authorize payload execution. Stop uses finalizeAndFinishThroughEndOfInput. Cancellation uses cancelAndFinishNow.
- AssetInventory status, supported locale equivalence, app locale reservations and real installation-request Progress control setup. Apple stores, updates and shares the assets; LocalFlow never copies them.

Primary references:

- https://developer.apple.com/documentation/speech/speechanalyzer
- https://developer.apple.com/documentation/speech/speechtranscriber
- https://developer.apple.com/documentation/speech/speechtranscriber/result
- https://developer.apple.com/documentation/speech/speechtranscriber/reportingoption/fastresults
- https://developer.apple.com/documentation/speech/assetinventory
- https://developer.apple.com/documentation/speech/speechanalyzer/finalize(through:)
- https://developer.apple.com/documentation/speech/bringing-advanced-speech-to-text-capabilities-to-your-app

Live measurements are separate evidence, not inferred from these APIs.
