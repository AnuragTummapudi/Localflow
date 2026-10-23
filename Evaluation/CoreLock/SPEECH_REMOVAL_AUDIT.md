# Speech dependency removal proof

4 October 2026. Before deletion, repository-wide Swift imports and references were inspected. FluidAudio imports existed only in ParakeetEngine and ParakeetStreamingEngine; WhisperKit import only in WhisperEngine. ModelManager constructed those engines and CascadingSTTEngine; onboarding and Settings exposed their downloads/selection. No unrelated audio, writing, native tools or Laya helper depends on either package. The Apple engine now implements both retained STTEngine and StreamingSTTEngine boundaries. CascadingSTTEngine has no remaining production role.

These implementations are removed, not retained as wrappers or commented code:

- Engines/ParakeetEngine/ParakeetEngine.swift
- Engines/ParakeetEngine/ParakeetStreamingEngine.swift
- Engines/WhisperEngine/WhisperEngine.swift
- Engines/CascadingSTTEngine.swift

Engine-specific cascading, Parakeet and STT bake-off tests were removed because their implementations are gone. Historical evaluation JSON/Markdown remains evidence. AgentFinalSpeechPolicy and its tests were removed because Apple range finals replace the second-model refinement policy.
- Tests/SharedTests/CascadingSTTEngineTests.swift
- Tests/SharedTests/ParakeetStreamingIntegrationTests.swift
- Tests/SharedTests/STTBakeoffTests.swift
