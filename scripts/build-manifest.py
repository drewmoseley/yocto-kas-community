#!/usr/bin/env python3
# Write a build-manifest.json from a resolved kas dump (JSON on stdin).
# Usage: build-manifest.py <release> <machine> <output-file>
# Same schema as the yocto-build-manifest script: layers maps each checkout path to
# its exact revision and upstream (the tracked branch, or the revision if none).
import datetime
import json
import socket
import sys

release, machine, output = sys.argv[1:4]
dump = json.load(sys.stdin)

layers = {}
for name, repo in dump["repos"].items():
    rev = repo.get("commit")
    if not rev:
        continue
    layers[repo.get("path", name)] = {
        "revision": rev,
        "upstream": repo.get("branch", rev),
    }

manifest = {
    "project": "community-kas",
    "branch": release,
    "machine": machine,
    "image": dump["target"],
    "build_host": socket.gethostname(),
    "build_time": datetime.datetime.now().isoformat(timespec="seconds"),
    "layers": layers,
}

with open(output, "w") as f:
    json.dump(manifest, f, indent=2)
    f.write("\n")
print(f"Wrote {len(layers)} layers -> {output}")
