#!/bin/bash
# Build targets for a release with kas.  Usage: build.sh <release> [target...]
set -u
here="$(cd "$(dirname "$0")" && pwd)"
cd "$here"

die() { echo "build.sh: $*" >&2; exit 2; }

[ $# -ge 1 ] || die "usage: build.sh <release> [target...]"
release="$1"; shift
[ -f "kas/$release.yml" ] || die "unknown release '$release' (no kas/$release.yml)"

[ -f ./local.env ] || die "local.env not found; copy local.env.example to local.env and edit it"
. ./local.env
for v in DL_DIR SSTATE_DIR WORK_ROOT; do
    [ -n "${!v:-}" ] || die "$v is not set in local.env"
done
for t in "$@"; do
    grep -qE "^$t([[:space:]]|\$)" all-targets.txt || die "unknown target '$t' (not in all-targets.txt)"
done

export DL_DIR SSTATE_DIR
export KAS_WORK_DIR="$WORK_ROOT/$release"
logdir="$KAS_WORK_DIR/logs/$(date +%Y%m%d-%H%M%S)"
mkdir -p "$logdir"
failed=0
summary=""

while read -r machine overlay _; do
    case "$machine" in ''|'#'*) continue;; esac
    if [ $# -gt 0 ]; then
        case " $* " in *" $machine "*) ;; *) continue;; esac
    fi
    cfg="kas/$release.yml"
    [ "$overlay" != "-" ] && cfg="$cfg:kas/overlays/$overlay.yml"
    KAS_MACHINE="$machine" kas build "$cfg" 2>&1 | tee "$logdir/$machine.log"
    if [ "${PIPESTATUS[0]}" -eq 0 ]; then
        summary+="PASS  $machine"$'\n'
    else
        failed=1
        summary+="FAIL  $machine  $logdir/$machine.log"$'\n'
    fi
done < all-targets.txt
echo; echo "== Summary =="; printf "%s" "$summary"
exit "$failed"
