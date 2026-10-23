> Current architecture: macOS 26+, one Apple Speech stack and 26 native tools.
> Earlier validation figures below are historical; current results are in
> Evaluation/CoreLock and CORE_ARCHITECTURE_REPORT.md.

# Native tools

CommandMode retains its existing deterministic application/URL/search/Spotify
parsers. Its former side-effect switch now maps `CommandIntent` to `AgentAction`
and calls one `ActionExecutor`. There is no new agent, HTTP service, cloud inference
or second command executor. Speech, rewriting, history and normal dictation insertion
continue through their established paths. Dependencies were not upgraded.

```text
Authoritative final transcript -> existing CommandMode + conservative native parser
 -> existing deterministic/Laya decision policy (may only increase confirmation)
 -> CommandIntent.agentAction -> ActionExecutor -> ToolRegistry -> NativeToolSystem
 -> native operation + readback -> typed ToolResult -> existing nonactivating island
```

## Contracts and ownership

- `NativeTools.swift`: stable IDs, descriptions, argument-kind metadata, typed slots,
  risk, confirmation, results, verification and the executor. `AgentTool` exposes
  prepare/execute; callers must enter through the executor's risk policy.
- `NativeCommandParser.swift`: new anchored grammar, legacy intent mapping and summaries.
- `MacNativeToolSystem.swift`: real NSWorkspace, TextInjection, EventKit,
  NSAppleScript/Apple Events, ScreenCaptureKit, ImageIO and native shortcut effects.
  Native APIs are preferred to GUI interaction. AppKit/EventKit are main-actor owned;
  blocking Apple Events and image encoding/file work run off the UI actor.
- `NativeUndoGuards.swift`: created-file identity/revision/content guards and coordinated deletion.
- `SpotifyTransportPolicy.swift`: pure readback/Undo policy over existing Spotify snapshots.
- `DictationCoordinator.swift`: uses the same TextInjection service, owns the executor,
  pending confirmation/task and presentation generation; shows actual result feedback.
- `ActionVerifier`: injectable receipt verification policy. Production tools perform
  native readback before returning their receipt; `NativeActionVerifier` retains
  verified/unverified/failed evidence, never upgrades “sent” to “verified”.

`ToolArguments` is an exhaustive sum of application identity/PID, URL, provider
query, exact text, captured selection, bounded integer volume, reminder/date,
note/body, captured note ID/body, Spotify action, screenshot destination/display,
file URL and no-argument operations. Argument types/limits are checked before
preparation or any native effect. Web tools accept HTTP(S), never arbitrary URI
schemes, credentials, terminal strings or scripts. File tools use explicit file URLs.

## Tools and risk

| Tool IDs | Risk | Native effect / verification | Reliable Undo |
| --- | --- | --- | --- |
| `application.open`, `application.focus` | Reversible | NSWorkspace open/activate; frontmost PID readback. Switch retains legacy launch-if-absent behavior. | Restore previous focus only while the opened target still owns focus. Never quit the opened app as Undo. |
| `application.quit` | Consequential | Freeze running PID; revalidate bundle/path identity; ordinary terminate; bounded termination polling. Save dialogs remain unverified. | None; never force-terminate. |
| `web.open_url`, `web.search`, `web.search_provider`, `web.open_website` | Safe | Existing provider/URL extraction and NSWorkspace. Browser request accepted, page load unverified. | None. |
| `text.type` | Reversible | Freeze foreground PID; reject a known nonempty selection in favor of explicit Replace Selected Text; reuse TextInjection. Opaque-editor paste remains unverified. | None; never blind Cmd-Z. |
| `text.replace_selection` | Consequential | Capture selection before confirmation; existing TextInjection revalidates target/selection and returns verified or sent-unverified. | None. |
| `text.copy` | Reversible | NSPasteboard write/readback. | Restore all captured types only if snapshot was complete and changeCount still belongs to this write. Read back restoration. |
| `system.volume_up`, `system.volume_down`, `system.volume_set`, `system.mute`, `system.unmute` | Reversible | Native system volume scripting; bounded 0–100 values and state readback. Only requested volume/mute property is written. | Restore owned property while observed volume/mute state remains unchanged; verify restored state. |
| `system.sleep_display` | Consequential | Existing fixed `pmset displaysleepnow`, no shell/user arguments, five-second wait bound. Request unverified. | None. |
| `system.lock` | Consequential | Existing native Ctrl-Cmd-Q shortcut through CGEvent, requires posting permission. Request unverified. | None; no private macOS APIs. |
| `reminder.create` | Reversible | EventKit full Reminders permission, native default writable list, exact title/notes/optional typed due date, saved-item readback. | Refresh EventKit; remove only the created, unchanged, uncompleted reminder in its original list, with matching creation/modification metadata and no added priority/location/URL/alarms/recurrence. Missing metadata means no Undo. |
| `note.create` | Reversible | Notes Apple Events, escaped HTML, native default account/folder; compare returned plaintext with exact supplied title/body. | Delete only the newly created ID with unchanged canonical body, no sharing/password/attachments; verify removal. |
| `note.append_current`, `note.write_current` | Consequential | Freeze one selected note ID/body; explicit confirmation; foreground Notes and exact selection/body checks. Reject shared/locked/attached notes and unsafe rich bodies. | None. |
| `spotify.transport` | Reversible | Existing transport and native snapshots. Pause/resume verify state; next/previous require observed track change. Automation errors no longer count as accepted commands. | Pause/resume only on unchanged track/observed state, with restored state verification. Track skipping has no reliable Undo. |
| `spotify.search` | Safe | Existing Spotify provider query URL, browser/app request acceptance. | None; normal spoken song commands still open results rather than invoking autoplay. |
| `utility.screenshot` | Reversible | Public ScreenCaptureKit screenshot of selected/main display; exclude LocalFlow island; PNG readback. Unique default filename in Application Support/LocalFlow/Screenshots. Never overwrite existing files/symlinks. | Remove only exact created file identity, revision and bytes through NSFileCoordinator. |
| `utility.reveal` | Safe | Existing explicit path + NSWorkspace Finder reveal. Selection not read back, request unverified. | None. |

SAFE executes immediately. REVERSIBLE exposes Undo only for a verified receipt
with a guarded restoration. CONSEQUENTIAL always needs explicit confirmation.
Low-confidence/model policy can also request confirmation for a lower-risk action;
it cannot relax tool risk. Confirmation tokens are single-use, bound to frozen
arguments and expire after 120 seconds. Cancel/new recording invalidates the
pending token. Cancellation before an effect prevents execution; already-delivered
native requests cannot be retracted and may produce an unverified receipt.
Concurrent requests are rejected rather than interleaved. UI completion must still own both coordinator and overlay presentation generations, so newer rewrite/dictation feedback wins. Action Undo uses the same cancellable task ownership; duplicate Undo callbacks cannot start hands-free recording. Expiry tasks release stored snapshots even if no next command arrives. Undo tokens expire after
60 seconds; the existing island offers action Undo for eight seconds. Hands-free
cancellation Undo retains its separate 3.5-second behavior.

Notes comparison explicitly considers case/diacritics/punctuation/whitespace;
see Apple's [AppleScript comparison controls](https://developer.apple.com/library/archive/documentation/AppleScript/Conceptual/AppleScriptLangGuide/reference/ASLR_control_statements.html).
User text is sent in typed Apple Event descriptors, never compiled as AppleScript.
No transcript/selection/body content is logged. Permission failures are visible.

## Voice entry points

Existing open/switch/quit application, mute/unmute, sleep display, lock it,
URL/search/provider and Spotify utterances retain their existing parsers/routes.
The application catalog now includes system applications and Utilities.
Known provider names such as “open GitHub” resolve to their deterministic domain.

Additional exact grammar:

```text
volume up / volume down                 (10 percentage points)
set volume to 40 percent                (integer 0–100, or 40%)
type at cursor Hello!
replace selected text with Revised text.
copy to clipboard Exact text.
create reminder Buy milk                (exact title; no inferred date)
create note Meeting: Call Sam.           (title: body; title-only also supported)
append to current note More text.
write current note Replacement text.
take a screenshot
reveal in finder /absolute/path
reveal in finder ~/explicit/path
```

More specific values (reminder notes/date, screenshot destination/display,
explicit captured targets and provider searches) are available in typed arguments.
No filename/app/date guessing, arbitrary shell expansion, generated URLs or model
extraction is introduced. Ambiguous/unrecognized new grammar falls back to the
existing dictation path. Existing Smart Polish and Prompt Engineer remain separate,
explicit selection workflows with their proven validation.

## Validation

Pre-change baseline: 137 Swift tests, four existing optional skips, zero failures.
Final suite: 167 tests, four optional skips, zero failures (30 added tests).
New tests cover all 25 tool routes and metadata, invalid/cross-tool arguments,
confirmation binding/reuse/cancel/expiry, frozen selection, preparation cancellation,
concurrency, result verification, Undo ownership/reuse/expiry, preserved legacy
routes, exact parsing/escaping, real production audio/Notes logic through mocked
Apple Events, Spotify state policy, and test-owned file preservation.
Trusted Notes/audio scripts compile against the installed macOS dictionary.
A pure AppleScript echo verifies actual typed descriptor round trips without any
external application action. The existing overlay state tests now cover supported
success Undo as well as hands-free cancellation Undo.

Commands run from the workspace parent:

```sh
swift test --package-path LocalFlow
swift test --package-path LocalFlow --filter 'NativeToolTests|NativeAutomationTests|NativeFileUndoTests|OverlayStateTests'
xcodebuild -project LocalFlow/LocalFlow.xcodeproj -scheme LocalFlow -configuration Debug CODE_SIGNING_ALLOWED=NO build
git -C LocalFlow diff --check
```

From `LocalFlow/`:

```sh
python3 -m unittest discover -s Evaluation/Laya -p 'test_*.py'
```

Unsigned Xcode Debug build succeeded; all five calibration-policy tests passed.
The existing optional model integration tests remain opt-in. Existing harmless
Historical dependency warnings are superseded by the Apple-only build.

## Limits and manual checks

Unit tests do not grant or modify real permissions or perform Mac command effects.
Live Notes/Reminders, clipboard, application activation/termination, browser,
Spotify, screen recording, display sleep and lock have not been exercised against
the user's real data/apps in this iteration. Runtime permissions and editor/app
behavior still need deliberate user smoke checks using the built Xcode application.
Notes/Reminders use the user's native default account/list; macOS may sync those
accounts according to existing system settings. LocalFlow adds no cloud API or
changes to account/sync configuration. No automatic model preparation is added.

Clipboard promises that cannot be fully captured have no Undo. Opaque editors,
web page load, Finder selection, lock/display state and quit save dialogs remain
truthfully unverified. A repeated or last Spotify track may provide no observable
identifier change; that result remains unverified. Selected-note rich/attached,
locked/shared content is rejected; this tool is not a general Notes editor. Voice
reminder creation does not infer dates; typed callers can supply an exact date.
No Undo is offered where it cannot restore an exact owned state safely.

## Files changed in this iteration

Seven new files:

- `Features/CommandMode/NativeTools.swift`
- `Features/CommandMode/NativeCommandParser.swift`
- `Features/CommandMode/MacNativeToolSystem.swift`
- `Features/CommandMode/NativeUndoGuards.swift`
- `Features/CommandMode/SpotifyTransportPolicy.swift`
- `Tests/FeaturesTests/NativeToolTests.swift`
- `NATIVE_TOOLS.md`

Thirteen existing files edited, including files already uncommitted before this task:

- `Features/CommandMode/CommandMode.swift`
- `Features/CommandMode/SpotifyPlaybackController.swift`
- `Features/CommandMode/DecisionEngine.swift`
- `App/DictationCoordinator.swift`
- `App/OverlayWindowController.swift`
- `App/WaveformOverlayView.swift`
- `App/CommandConfirmationView.swift`
- `App/Info.plist`
- `App/LocalFlow.entitlements`
- `Shared/OverlayState.swift`
- `Package.swift`
- `Tests/SharedTests/OverlayStateTests.swift`
- `AGENTS.md`

`Package.swift` only adds the existing TextInjection target dependency to
CommandMode for this iteration. Both package resolution files remain unchanged.
No Settings/website, speech engines, model assets or remote Git state were changed.
At final review the entire checkout has 17 modified tracked files
(`git diff --stat`: +828/−656) and 41 untracked files. This cumulative diff includes
prior baseline/streaming/overlay/Laya work; it is not this task's standalone diff.
This iteration adds seven files and edits thirteen; all prior work is retained.
No staging, commit, push, PR, reset, clean or deployment was performed.

## Current note title support

`note.rename_current` is consequential. “Call it <exact title>” prepares a frozen
current-note identity/body and confirmation. A fixed AppleScript handler checks
identity, body revision, foreground application, lock/share/attachment guards,
uses Notes’ writable name property, and verifies the exact plaintext title plus unchanged body. Notes may normalize HTML; append/write verification compares exact plaintext, removing only the single terminal line feed added by Notes. Rich objects remain refused. No model
supplies the title. “Write <exact body>” uses the existing guarded append tool.
Creating a note shows the created note for later current-note commands.

Created-note Undo checks the frozen default folder, ID and exact body before deletion, then verifies absence from that folder. Recently Deleted retaining an ID does not imply Undo failed. Automation readiness probes run off the UI thread with a three-second display deadline; a stalled OS probe reports ACTION REQUIRED, never READY, and is not repeatedly spawned. Native tool receipts remain authoritative about actual permission failures.


## System-2 phase

System-2 adds 16 narrow semantic IDs through the same registry and executor. Planner visibility/schema metadata is attached to registered IDs; screenshot/internal tools remain hidden. See [SYSTEM2_PLANNER.md](SYSTEM2_PLANNER.md) and its measured report. Workflow run/stop remain consequential and require existing confirmation. Editor/Finder launch acceptance remains unverified and supplies no fabricated Undo.

## Semantic Accessibility substrate

`SemanticAccessibilityService` is owned by `MacNativeToolSystem`. Its seven `ui.*` IDs use strict registry schemas, ephemeral observation IDs and native readback. The host freezes contextual risk during preparation: structural navigation may execute safely; unknown UI mutations require the existing single-use confirmation. UI text never expands `GoalEnvelope`. Secured fields are excluded; no screenshots, coordinates, keyboard fallback or persistent UI contents are added. See `SEMANTIC_AX_REPORT.md` for qualification results and current limitations.
