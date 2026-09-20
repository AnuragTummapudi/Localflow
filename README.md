# LocalFlow

LocalFlow is a native macOS voice-to-text utility that keeps transcription, formatting, history, and app controls on your Mac.

## What it does

- Dictates into the app you are using with **Fn** or **Right Option**.
- Supports hands-free dictation by double-pressing the selected trigger.
- Inserts text through macOS Accessibility and clipboard paste.
- Provides local history, a custom dictionary, app-aware formatting, and Option + 1 polishing with Apple Intelligence when available.
- Opens apps, searches the web, and controls the installed Spotify app through voice commands.

## Requirements

- macOS 14 or later.
- Microphone and Accessibility permission for dictation and text insertion.
- Apple Intelligence support and macOS 26 or later for Option + 1 semantic polish.

Speech models are downloaded on demand and are never committed to this repository or bundled in a release artifact.

## Build

Open `LocalFlow.xcodeproj` in Xcode, select the **LocalFlow** scheme, and run it. The project resolves its Swift package dependencies automatically.

For a command-line build:

```sh
xcodebuild -project LocalFlow.xcodeproj -scheme LocalFlow -configuration Debug CODE_SIGNING_ALLOWED=NO build
```

## Test

```sh
swift test --package-path . --filter FeaturesTests
```

## Privacy

LocalFlow does not send dictation, history, or formatting requests to a LocalFlow service. Apple Intelligence polishing is performed by Apple’s system on-device model when enabled. Spotify playback uses the installed desktop app’s Accessibility interface; no Spotify credentials are requested.

## Project layout

- `App/` — macOS application UI and session coordination.
- `Core/` — audio capture, global hotkeys, model lifecycle, and text insertion.
- `Engines/` — Apple Speech, Parakeet, and Whisper transcription engines.
- `Features/` — commands, formatting, privacy dashboard, and speech cleanup.
- `Shared/` — user settings, stores, and shared types.
- `Tests/` — focused unit tests.
