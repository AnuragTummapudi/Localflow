# Contributing to LocalFlow

Thanks for helping. LocalFlow is a macOS menu-bar dictation app; privacy is a feature, so changes that send data off the Mac need extra care.

## Setup

- macOS 14+ to run, Xcode 26+ to build (the macOS 26 SDK is needed for Apple Speech and Apple Intelligence).
- `swift build` and `swift test` from the repo root. Open `LocalFlow.xcodeproj` to run the app.
- New Swift files under `App/` must also be added to `LocalFlow.xcodeproj` (SwiftPM picks them up automatically, Xcode does not).

## Pull requests

- Keep each PR to one change, with a test for any new logic (`Tests/SharedTests` or `Tests/FeaturesTests`).
- CI must pass: build, tests, and an unsigned Xcode build.
- Never log or display transcripts, selected text, API keys, or provider response bodies.
- Any new network request must respect the Privacy network block and increment `NetworkActivityCounter`.
- Don't add personal data (names, emails, vocabulary) to defaults, fixtures, or tests — use placeholders like `Ada Lovelace` / `example.com`.

## Reporting bugs

Use the issue templates. Include your macOS version, Mac model (Apple Silicon / Intel), and dictation mode (Apple Speech, local model, or cloud provider). Don't paste API keys or private transcripts.
