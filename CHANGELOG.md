# Changelog

All notable changes to LocalFlow are listed here.

## 0.1.2 — 2026-11-24

### Added
- Sarvam as a cloud provider: Sarvam Dictate for dictation (English + 22 Indian languages, up to 30 s per clip) and `sarvam-105b` for Smart Polish.

### Fixed
- macOS 27: dictation no longer stops right after it starts or when a call app (Meet, Zoom, FaceTime) reconfigures the mic; capture restarts in place and keeps what was recorded.
- macOS 27: holding Fn to dictate no longer opens the Emoji & Symbols picker, and Fn is detected even when macOS omits its modifier flag.

## 0.1.1 — 2026-11-21

### Fixed
- When Fn is the shortcut and macOS also uses it for Emoji & Symbols, Settings offers to set “Press 🌐 key to” to Do Nothing.

## 0.1.0 — 2026-11-21

### Added
- Learn from corrections: fixing a word right after dictating adds it to the Dictionary ("New word learned"), with a setting to turn it off.
- "Start Dictation" in the menu bar menu, for keyboards without Fn or Right Option.
- "Clear all" for dictation history.
- Bring your own API key: cloud dictation (Groq, OpenAI, Gemini) and Smart Polish (Groq, OpenAI, Claude, Gemini). Keys stay in the macOS Keychain.
- Editable provider model IDs.
- One setup screen shared by onboarding and Settings, with download progress and Cancel.
- CI, a tag-triggered release workflow, and optional Developer ID signing and notarization in `Scripts/build-dmg.sh`.

### Changed
- Hands-free Undo now restores and inserts the cancelled recording instead of starting a new one.
- Recordings auto-stop and transcribe at 10 minutes (memory is capped; was 30 minutes).
- A microphone change mid-recording now transcribes what was captured instead of silently recording nothing.
- Hands-free auto-stop measures silence in seconds, so the 45-second limit is accurate on every audio device.
- ⌘V/⌘C/⌘A follow the active keyboard layout (Dvorak, Colemak, AZERTY…).
- Dictated text is never pasted into password fields or into nothing: a floating card with Copy appears instead.
- An unreadable history file is kept as a backup instead of being overwritten.
- Smart phonetic matching uses a generic rule (spelled-out letters) instead of built-in personal words.
- Activity heatmap fits the window and always shows the current week; history is grouped into day cards.
- The Accessibility status in Settings updates without relaunching.
- Cloud audio is converted to 16 kHz before upload (about 6 minutes per recording).
- Whisper downloads are pinned to a fixed model revision, streamed through SHA-256, checked for free disk space, and only count as installed once complete.
- Switching engines keeps the current engine running until the new one is ready; a failed or cancelled switch restores your previous settings.
- Text pasted by LocalFlow is marked transient so clipboard managers skip it, and the full previous clipboard is restored.

### Fixed
- Groq Smart Polish defaults to `openai/gpt-oss-120b`; Groq retired `llama-3.3-70b-versatile`.
- Cancelling during transcription and immediately dictating again no longer kills the new recording.

### Removed
- Personal entries from the default dictionary.
- Unused debug-logging shim and placeholder update feed.
