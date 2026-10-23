# Local Laya runtime

The native helper's canonical SwiftPM project is bundled for explicit preparation
at `Core/ModelManager/Resources/DecisionPreparation/LayaHelper/`.
Normal app inference starts the verified, preinstalled `localflow-laya` binary
with JSON pipes; it runs full-precision ONNX locally and needs no Python or server.
See `DECISIONS.md` for preparation, calibration and measured limitations.


The System-2 helper is a separate native Swift/MLX text-only resident child under
`Core/ModelManager/Resources/PlannerRuntime/QwenHelper/`. It uses local pipes,
fixed model/runtime hashes and no inference server. `Scripts/prepare-planner.sh`
is explicit local setup; `localflow-planner-setup --install-candidate /absolute/path`
imports the one benchmark-selected candidate through PlannerModelManager. It is
never invoked by tests or automatic startup. See `SYSTEM2_PLANNER.md` and the
qualification report; automatic voice use remains disabled.
