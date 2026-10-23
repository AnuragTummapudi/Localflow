# Local operational memory and daily-use validation

Settings → **Agent / Mac Control** owns the local model controls, real-time agent
toggle, preferred applications, confirmation policy, aliases/workflows, explicit
command approval, metadata activity, reset, and live spoken benchmark.

## Storage and boundaries

One `AgentMemoryStore` is created by `AppServices` and shared by Settings and the
coordinator. Files live in `~/Library/Application Support/LocalFlow/Agent/`:

- `memory.json`: versioned, pretty-printed, sorted-key operational configuration.
- `activity.json`: at most 200 tool IDs, outcomes, timestamps, and durations.
- `benchmark.json`: explicitly exported measurements from live benchmark runs.

Writes replace JSON atomically, use owner-only file permissions, and reject a save
if memory has changed on disk since loading. Reload imports manual changes. Invalid
memory is preserved for repair and blocks agent execution until repaired or explicitly
reset. Reset touches only memory/activity; existing dictation history, vocabulary,
models, and exported benchmark reports are preserved. Existing dictation history
retains its original behavior; this feature does not add conversation storage.

There is no background preference learning. Application names/bundle IDs, absolute
folder paths, HTTP(S) URLs, and workflow commands are supplied explicitly. **Approve
& Save Last Command** accepts only a verified successful single non-consequential
command. No quit, overwrite, lock, or sleep command can become an approved mapping.
User-created workflows may contain consequential commands; the native tool's
single-use confirmation still applies. Aliases never grant partial-speech speculation.

Example `memory.json` (replace the path and app names with your choices):

```json
{
  "version": 1,
  "realTimeEnabled": true,
  "confirmAllActions": false,
  "preferredApps": {
    "browser": "com.apple.Safari",
    "editor": "com.microsoft.VSCode",
    "terminal": "com.apple.Terminal"
  },
  "applicationAliases": { "code": "com.microsoft.VSCode" },
  "folders": { "LocalFlow project": "/absolute/path/to/LocalFlow" },
  "websites": { "placement portal": "https://example.com/placements" },
  "workflows": {
    "start LocalFlow": [
      "open LocalFlow project",
      "open my editor",
      "open my terminal",
      "open http://localhost:3000"
    ]
  },
  "approvedCommands": {}
}
```

Say “open my editor”, “open placement portal”, “start LocalFlow”, or “run start
LocalFlow”. A named folder is revealed in Finder. Preferred browser controls URL
delivery as well as “open browser”. Missing preferred browsers produce an error;
they do not silently open a different browser. Workflow steps execute in order
after final ASR, with dependencies and the existing verification/confirmation rules.
The agent validates exact slots against Apple's authoritative finalized ranges. No second STT model refines the recording. Ordinary dictation retains final-only vocabulary, formatting, history and insertion. Cancellation cannot publish stale finalized speech.

Nested workflows are limited to eight levels/40 expanded actions, with cycle checks.
Text-bearing commands consume their remaining clause, so note text cannot smuggle
an extra command. Put independent commands on separate workflow lines.

The example opens an already-running local website. It does not start a server or
type shell commands into Terminal. This implementation deliberately retains the
existing native tool boundary, which does not support arbitrary shell execution.

## Benchmark

The ten fixtures cover Notes open, new note, dictated note text, browser open,
person/topic search, explicit website, Photo Booth open, a safe website action,
reminder creation, and a multi-command sentence. The camera fixture opens the app;
it does not take a photo. Set the preferred browser before running fixtures.

Three layers are available:

1. `AgentOperationalTests`: five repetitions of all ten scenarios with duplicate
   partial events, deterministic decisions, and mocked native effects. This measures
   control-flow overhead, not ASR speed or real Mac completion.
2. `AppleSpeechTests`: opt-in real local Apple inference on test-owned paced audio, with no native action effects. This measures STT independently.
3. Settings Debug acceptance workflow: explicit microphone capture and real native tools. Creates test notes/reminders only on deliberate runs; native permission prompts and confirmation remain active.

Reports contain no transcript, note text, reminder titles, audio, or URLs. Metrics:

- Partial STT: detected speech onset to first delivered nonempty partial; unavailable
  for batch fallback. Synthetic inference uses the first speech-bearing audio chunk.
- Decision: mean duration of a segment decision, including deterministic parsing and
  optional local inference/cache lookup. Speech and decision provenance are exported;
  missing samples remain unavailable.
- First action: speech onset to actual native `perform`, excluding confirmation
  preparation. Waiting for user confirmation is included in session elapsed time.
- Total: speech onset until final decisions and the action ledger reach a terminal
  state. A pending confirmation is not completion.
- Duplicate rate: excess invocations of expected actions / all performed invocations.
- Incorrect rate: unexpected slots/tools or actions performed out of expected order
  / all performed invocations. Application confidence is not an execution slot.
- Missing, failed, unverified, out-of-order, and cancelled counts remain separate;
  a sent URL is not proof of a loaded browser page.

Scripted report:

```sh
LOCALFLOW_BENCHMARK_OUTPUT=/tmp/localflow-scripted-benchmark.json \
  swift test --filter AgentOperationalTests
```

For real Apple inference, use the fixture contract in STREAMING.md. Historical benchmark JSON remains evidence of prior speech implementations.

The ordinary suite skips opt-in model checks when their fixture environment is absent.
Tests never install/remove production assets or execute real Notes/Reminders/camera
commands. Actual TCC, camera state, foreground focus, browser page loading, and
third-party app behavior require the live benchmark/manual smoke check.

## Regression coverage

Memory round trips, invalid/manual edits, conflicting saves, bounded metadata,
explicit reset, exact aliases, workflow cycles/unsupported commands, confirmation
policy snapshots, no automatic learning, final-only macros, duplicate suppression,
payload integrity, rapid cancel/new session, ownership release, and benchmark rate
accounting have focused tests. Runtime fixtures verify unloading in-flight IPC
before reloading and repeated removal in temporary model directories.

Audio teardown no longer touches input hardware on idle reset; old tap callbacks
and waveform UI deliveries are generation-gated. Cancelled agent work is drained
before a new decision queue acquires the shared executor. Model removal owns a
lifecycle gate until old loads and helper IPC drain. The existing island remains
nonactivating, never key/main, and uses the existing overlay focus/layout tests.


## System-2 phase

System-2 adds optional explicit project records: aliases, canonical folder, configured editor, loopback service, approved direct executable workflows and important-file hints. Old v1 files remain valid; bounds, atomic JSON and stale-write guards remain. Projects and workflows are edited explicitly in the existing JSON editor. No automatic project scan or path learning is enabled. See [SYSTEM2_PLANNER.md](SYSTEM2_PLANNER.md).
