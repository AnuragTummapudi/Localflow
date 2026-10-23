# Continuous Voice Agent evidence — 4 October 2026

All transcripts in these files are synthetic developer/test fixtures. No user microphone
content was exported. Runtime trace collection in the app is opt-in, Debug-only and in memory.

- `before-debug-trace.json`: instrumented pre-fix source, four raw partial sequences.
- `after-debug-trace.json`: same four raw sequences, plus two acoustic-pause companion sequences.
- `real-asr.json`: real Parakeet streaming + batch refinement on existing synthetic audio;
  native tools mocked. Five of twelve exact payloads remain wrong, zero executed duplicates.

The raw sequences are: incremental bare headers; longer cumulative hypotheses; two independent
hypotheses without a pause signal; and a controlled closed first clause followed by replacement
hypotheses. The pre-fix fourth sequence executes Notes at revision 2 and then stops advancing.
After fixing, the first two sequences execute Notes and Safari before final speech; the trailing
Chrome remains pending until an acoustic boundary or final. Replacements of open/unconsumed
hypotheses without boundary evidence remain revisions, preserving correction safety.

The two appended post-fix traces supply observed pause information using an injected clock:

1. `open notes` → `open notes open safari` → … Chrome → … github.com.
2. `open notes` → `open safari` → `open chrome` → `open github.com`.

Both execute all four typed invocations, with consumed cursor eight, while the session remains
live. Timings here are synthetic control-flow evidence, never microphone/native latency metrics.

Reproduce from `/Users/anuragtummapudi/Localflow-project`:

```sh
LOCALFLOW_CONTINUATION_TRACE_OUTPUT=/tmp/localflow-continuation-after.json \
  swift test --package-path LocalFlow --filter VoiceContinuationTests
```

The historical pre-fix source copies and source deltas are in `.build/continuation/before/`
and `.build/continuation/diff-*.patch`; test/build logs are in `.build/continuation/logs/`.
Do not replace current source with the historical copies: the working tree contains earlier work.
