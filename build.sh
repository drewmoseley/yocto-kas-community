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

# Optional caps in local.env (e.g. on a host with flaky RAM); default to the CPU count.
BB_NUMBER_THREADS="${BB_NUMBER_THREADS:-$(nproc)}"
PARALLEL_MAKE="${PARALLEL_MAKE:--j$(nproc)}"

export DL_DIR SSTATE_DIR BB_NUMBER_THREADS PARALLEL_MAKE
export KAS_WORK_DIR="$WORK_ROOT/$release"
logdir="$KAS_WORK_DIR/logs/$(date +%Y%m%d-%H%M%S)"
mkdir -p "$logdir"
failed=0
summary=""

while read -r machine overlay _ <&3; do
    case "$machine" in ''|'#'*) continue;; esac
    if [ $# -gt 0 ]; then
        case " $* " in *" $machine "*) ;; *) continue;; esac
    fi
    cfg="kas/$release.yml"
    [ "$overlay" != "-" ] && cfg="$cfg:kas/overlays/$overlay.yml"
    log="$logdir/$machine.log"
    # The image under test must be built with the testimage overlay (login features).
    case "$machine" in qemu*) cfg="$cfg:kas/testimage.yml";; esac
    KAS_MACHINE="$machine" kas build "$cfg" 2>&1 | tee "$log"
    if [ "${PIPESTATUS[0]}" -ne 0 ]; then
        failed=1
        summary+="FAIL  $machine  build  $log"$'\n'
        continue
    fi
    # Boot-test QEMU targets only; hardware targets cannot be booted here.
    case "$machine" in
    qemu*)
        KAS_MACHINE="$machine" kas build --task testimage "$cfg" 2>&1 | tee -a "$log"
        if [ "${PIPESTATUS[0]}" -ne 0 ]; then
            failed=1
            summary+="FAIL  $machine  boot-test  $log"$'\n'
            continue
        fi
        ;;
    esac
    summary+="PASS  $machine"$'\n'
done 3< all-targets.txt
echo; echo "== Summary =="; printf "%s" "$summary"
exit "$failed"
