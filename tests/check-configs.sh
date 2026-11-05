#!/bin/bash
# Validate that every release kas file resolves, without building anything.
#
# kas dump needs the layer repos checked out to resolve includes, so it runs in
# a persistent cache directory outside this repo (first run clones, later runs
# only fetch). Override the location with CHECK_WORK_DIR.
set -u
cd "$(dirname "$0")/.."

export KAS_WORK_DIR="${CHECK_WORK_DIR:-${XDG_CACHE_HOME:-$HOME/.cache}/community-kas-check}"
mkdir -p "$KAS_WORK_DIR"

releases=(kas/wrynose.yml)
rc=0
for f in "${releases[@]}"; do
    if out=$(kas dump "$f" 2>&1); then
        echo "ok    $f"
    else
        echo "FAIL  $f"
        echo "$out" | tail -5
        rc=1
    fi
done
exit $rc
