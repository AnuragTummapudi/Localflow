"""Download pinned experiment assets only; never touch the installed LocalFlow models.

Uses curl's system TLS trust rather than disabling certificate validation. Existing
files must match the pinned Hugging Face LFS hash; interrupted files are replaced.
"""
import argparse
import hashlib
import json
import subprocess
from pathlib import Path

REVISIONS = {
    "laya": "55cf4c4ebb4ebe31b2550e8bdf3bd21b99753851",
    "laya-multilingual": "e4e9ddf21a7b1903b7acffd8814ad4307bf63a67",
    "laya-typed-decisions": "1a793eb568e6718f15941d08f85432581df534e3",
}
FILES = ["encoder/config.json", "tokenizer/tokenizer.json", "tokenizer/tokenizer_config.json",
         "rl_agent_config.json", "model.safetensors"]

def digest(path):
    h = hashlib.sha256()
    with open(path, "rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            h.update(chunk)
    return h.hexdigest()

def fetch(name, root):
    revision = REVISIONS[name]
    root.mkdir(parents=True, exist_ok=True)
    metadata = root / "remote-metadata.json"
    subprocess.run(["/usr/bin/curl", "-fSLsS", "--retry", "2", "--max-time", "60",
                    f"https://huggingface.co/api/models/convaiinnovations/{name}/revision/{revision}?blobs=true",
                    "-o", str(metadata)], check=True)
    info = json.loads(metadata.read_text())
    assert info["sha"] == revision
    siblings = {x["rfilename"]: x for x in info["siblings"]}
    hashes = {}
    for name_in_repo in FILES:
        path = root / name_in_repo
        path.parent.mkdir(parents=True, exist_ok=True)
        expected = siblings[name_in_repo].get("lfs", {}).get("sha256")
        if not path.exists() or expected and digest(path) != expected:
            temporary = path.with_suffix(path.suffix + ".download")
            print(f"Downloading {name}/{name_in_repo}", flush=True)
            subprocess.run(["/usr/bin/curl", "-fSLsS", "--retry", "2", "--max-time", "600",
                            f"https://huggingface.co/convaiinnovations/{name}/resolve/{revision}/{name_in_repo}",
                            "-o", str(temporary)], check=True)
            if expected and digest(temporary) != expected:
                raise RuntimeError("Pinned model hash mismatch")
            temporary.replace(path)
        hashes[name_in_repo] = digest(path)
    (root / "provenance.json").write_text(json.dumps({"model": "convaiinnovations/" + name,
        "revision": revision, "hashes": hashes}, indent=2) + "\n")

if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("name", choices=REVISIONS)
    parser.add_argument("destination", type=Path)
    args = parser.parse_args()
    fetch(args.name, args.destination)
