"""Freeze the assistant-authored corpus, with family isolation and exclusion checks."""
import hashlib
import json
import re
from pathlib import Path

ROOT = Path(__file__).resolve().parent
INTENTS = ["dictation", "open_application", "focus_application", "quit_application", "web_navigation",
           "search", "note_action", "reminder_action", "media_action", "system_action", "text_action",
           "file_action", "workflow", "unknown"]

def normalized(text):
    return " ".join(re.findall(r"\w+", text.casefold()))

def build():
    excluded = json.loads((ROOT.parent.parent / "Core/ModelManager/Resources/DecisionPreparation/Laya/utterances.json").read_text())
    old = {normalized(row["text"]) for row in excluded}
    source = ROOT / "corpus.tsv"
    rows, omissions, families = [], [], {}
    for line in source.read_text().splitlines():
        if not line or line.startswith("#"):
            continue
        split, family, intent, risk, more, command, ambiguous, final, text = line.split("|", 8)
        assert intent in INTENTS and risk in ("safe", "reversible", "consequential")
        assert split in ("train", "calibration", "test")
        assert families.setdefault(family, split) == split, "Paraphrase family leakage"
        if split != "test" and normalized(text) in old:
            omissions.append({"family": family, "reason": "existing Laya fixture overlap"})
            continue
        variants = [(text, "authored")]
        if split == "train" and final == "1":
            # No template synthesis across splits. Each noise sibling retains its family.
            variants += [(text.lower(), "casing-loss"),
                         (re.sub(r"[,;:?.!]", "", text), "punctuation-loss"),
                         ("um " + text, "hesitation-prefix")]
        seen = set()
        for speech, variant in variants:
            if speech in seen:
                continue
            seen.add(speech)
            rows.append({"id": f"{family}:{variant}:{len(rows)}", "split": split, "family": family,
                "state": {"utterance": speech, "is_final": final == "1"},
                "labels": {"intent": intent, "risk": risk, "more_speech": more == "1",
                           "command": command == "1", "ambiguous": ambiguous == "1"},
                "provenance": {"source": "assistant-authored-localflow-corpus-v1", "variant": variant,
                               "review": "assistant label review; no independent human review"}})
    manifest = {"version": 1, "seed": 421322, "sourceSHA256": hashlib.sha256(source.read_bytes()).hexdigest(),
        "reviewBoundary": "Assistant-authored and assistant-reviewed; independent human sign-off is pending.",
        "heldOutConstruction": "Separate explicit adversarial entries, not generated training templates.",
        "limitations": "Shared intent vocabulary and operator words are unavoidable. Family IDs cannot prove all semantic independence.",
        "exclusions": omissions, "splits": {}}
    for split in ("train", "calibration", "test"):
        selected = [r for r in rows if r["split"] == split]
        data = "".join(json.dumps(r, ensure_ascii=False, sort_keys=True) + "\n" for r in selected).encode()
        (ROOT / f"{split}.jsonl").write_bytes(data)
        manifest["splits"][split] = {"count": len(selected), "families": sorted({r["family"] for r in selected}),
            "sha256": hashlib.sha256(data).hexdigest(), "ids": [r["id"] for r in selected]}
    (ROOT / "split-manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
    print({s: x["count"] for s, x in manifest["splits"].items()}, "exclusions:", len(omissions))

if __name__ == "__main__":
    build()
