# Changelog

All notable changes to LocalFlow are listed here.

## Unreleased

### Added
- Bring your own API key: cloud dictation (Groq, OpenAI, Gemini) and Smart Polish (Groq, OpenAI, Claude, Gemini). Keys stay in the macOS Keychain.
- Editable provider model IDs.
- One setup screen shared by onboarding and Settings, with download progress and Cancel.
- CI, a tag-triggered release workflow, and optional Developer ID signing and notarization in `Scripts/build-dmg.sh`.

### Changed
- Cloud audio is converted to 16 kHz before upload (about 6 minutes per recording).
- Whisper downloads are pinned to a fixed model revision, streamed through SHA-256, checked for free disk space, and only count as installed once complete.
- Switching engines keeps the current engine running until the new one is ready; a failed or cancelled switch restores your previous settings.
- Text pasted by LocalFlow is marked transient so clipboard managers skip it, and the full previous clipboard is restored.

### Removed
- Personal entries from the default dictionary.
- Unused debug-logging shim and placeholder update feed.
