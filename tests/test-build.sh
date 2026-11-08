#!/bin/bash
# Tests for build.sh at its command-line seam, with a stubbed kas.
# Each test builds a throwaway copy of the repo layout so nothing real is touched.
set -u
REPO="$(cd "$(dirname "$0")/.." && pwd)"
pass=0; fail=0

setup() {
    T=$(mktemp -d)
    mkdir -p "$T/kas/overlays" "$T/bin" "$T/work"
    cp "$REPO/build.sh" "$T/build.sh" 2>/dev/null
    : > "$T/kas/fake.yml"; : > "$T/kas/overlays/ov.yml"
    printf 'DL_DIR=%s/dl\nSSTATE_DIR=%s/ss\nWORK_ROOT=%s/work\n' "$T" "$T" "$T" > "$T/local.env"
    printf '# machine overlay\n\nm1 ov\nm2 -\nm3 -\n' > "$T/all-targets.txt"
    cat > "$T/bin/kas" <<'STUB'
#!/bin/bash
echo "$KAS_MACHINE $*" >> "$STUB_CALLS"
echo "$KAS_MACHINE threads=${BB_NUMBER_THREADS:-} make=${PARALLEL_MAKE:-}" >> "$STUB_ENV"
[ -n "${STUB_READ_STDIN:-}" ] && cat > /dev/null
echo "stub kas output for $KAS_MACHINE"
case "$*" in *"--task testimage"*)
    case " ${STUB_FAIL_TEST:-} " in *" $KAS_MACHINE "*) echo "stub boot failure" >&2; exit 1;; esac
    exit 0;;
esac
case " ${STUB_FAIL:-} " in *" $KAS_MACHINE "*) echo "stub failure" >&2; exit 1;; esac
STUB
    chmod +x "$T/bin/kas"
    export STUB_CALLS="$T/kas.calls" STUB_ENV="$T/kas.env"; : > "$STUB_CALLS"; : > "$STUB_ENV"
    unset STUB_FAIL STUB_FAIL_TEST
    export PATH="$T/bin:$ORIG_PATH"
}
ORIG_PATH="$PATH"

run() { OUT=$("$T/build.sh" "$@" 2>&1 </dev/null); RC=$?; }

expect() {  # expect <description> <condition...>
    local desc="$1"; shift
    if "$@"; then pass=$((pass+1)); echo "ok    $desc"; else fail=$((fail+1)); echo "FAIL  $desc"; echo "$OUT" | sed 's/^/        /' | head -15; fi
}
calls_equal() { [ "$(cat "$STUB_CALLS")" = "$1" ]; }

test_default_builds_all_targets() {
    setup; run fake
    expect "default: builds every target with its machine and overlay" calls_equal \
"m1 build kas/fake.yml:kas/overlays/ov.yml
m2 build kas/fake.yml
m3 build kas/fake.yml"
}

test_named_targets_only() {
    setup; run fake m3 m1
    expect "named: builds only the requested targets" calls_equal \
"m1 build kas/fake.yml:kas/overlays/ov.yml
m3 build kas/fake.yml"
}

test_failure_continues_and_exits_nonzero() {
    setup; STUB_FAIL="m1" run fake
    expect "failure: remaining targets still built" calls_equal \
"m1 build kas/fake.yml:kas/overlays/ov.yml
m2 build kas/fake.yml
m3 build kas/fake.yml"
    expect "failure: exit status is 1" [ "$RC" -eq 1 ]
}

test_one_log_per_target() {
    setup; STUB_FAIL="m2" run fake
    local d; d=$(ls -d "$T"/work/fake/logs/*/ 2>/dev/null | head -1)
    expect "logs: one file per target" [ "$(ls "$d" 2>/dev/null | sort | tr '\n' ' ')" = "m1.log m2.log m3.log " ]
    expect "logs: contain that target's kas output" grep -q "stub kas output for m1" "${d}m1.log"
    expect "logs: contain stderr of a failed target" grep -q "stub failure" "${d}m2.log"
}

test_summary() {
    setup; STUB_FAIL="m2" run fake
    expect "summary: passing target listed" grep -qE '^PASS +m1' <<<"$OUT"
    expect "summary: failing target listed with its log" grep -qE '^FAIL +m2 .*/m2\.log' <<<"$OUT"
}

test_missing_local_env() {
    setup; rm "$T/local.env"; run fake
    expect "config: missing local.env exits 2" [ "$RC" -eq 2 ]
    expect "config: missing local.env names the file" grep -q 'local.env' <<<"$OUT"
    expect "config: missing local.env runs no kas" calls_equal ""
}

test_missing_variable() {
    setup; sed -i '/SSTATE_DIR/d' "$T/local.env"; run fake
    expect "config: missing variable exits 2" [ "$RC" -eq 2 ]
    expect "config: missing variable is named" grep -q 'SSTATE_DIR' <<<"$OUT"
    expect "config: missing variable runs no kas" calls_equal ""
}

test_bad_arguments() {
    setup; run
    expect "args: no release exits 2" [ "$RC" -eq 2 ]
    setup; run nosuch
    expect "args: unknown release exits 2" [ "$RC" -eq 2 ]
    expect "args: unknown release is named" grep -q nosuch <<<"$OUT"
    setup; run fake m1 bogus
    expect "args: unknown target exits 2" [ "$RC" -eq 2 ]
    expect "args: unknown target is named" grep -q bogus <<<"$OUT"
    expect "args: unknown target runs no kas, even for valid ones" calls_equal ""
}

qemu_setup() {
    setup
    : > "$T/kas/testimage.yml"
    printf 'qemua -\nhw ov\nqemub -\n' > "$T/all-targets.txt"
}

test_boot_test_qemu_only() {
    qemu_setup; run fake
    expect "boot: QEMU targets build with the testimage overlay then run testimage; hardware does neither" calls_equal \
"qemua build kas/fake.yml:kas/testimage.yml
qemua build --task testimage kas/fake.yml:kas/testimage.yml
hw build kas/fake.yml:kas/overlays/ov.yml
qemub build kas/fake.yml:kas/testimage.yml
qemub build --task testimage kas/fake.yml:kas/testimage.yml"
    expect "boot: all passing exits 0" [ "$RC" -eq 0 ]
}

test_boot_failure_distinct() {
    qemu_setup; STUB_FAIL_TEST="qemua" run fake
    expect "boot: failure exits 1" [ "$RC" -eq 1 ]
    expect "boot: summary says boot-test failure" grep -qE '^FAIL +qemua +boot-test' <<<"$OUT"
    setup; qemu_setup; STUB_FAIL="qemub" run fake
    expect "boot: build failure labelled build, no testimage run" grep -qE '^FAIL +qemub +build' <<<"$OUT"
    expect "boot: build failure skips testimage" bash -c '! grep -q "qemub build --task" "$STUB_CALLS"'
}

test_kas_reading_stdin_does_not_eat_targets() {
    setup; STUB_READ_STDIN=1 run fake
    expect "stdin: a kas that reads stdin does not swallow the remaining targets" calls_equal \
"m1 build kas/fake.yml:kas/overlays/ov.yml
m2 build kas/fake.yml
m3 build kas/fake.yml"
}

test_parallelism_cap_from_local_env() {
    setup; printf 'BB_NUMBER_THREADS=12\nPARALLEL_MAKE=-j8\n' >> "$T/local.env"; run fake m2
    expect "parallelism: caps from local.env reach kas" [ "$(cat "$STUB_ENV")" = "m2 threads=12 make=-j8" ]
}

test_parallelism_defaults_to_cpu_count() {
    setup; run fake m2
    local n; n=$(nproc)
    expect "parallelism: unset in local.env defaults to the CPU count" [ "$(cat "$STUB_ENV")" = "m2 threads=$n make=-j$n" ]
}

test_default_builds_all_targets
test_named_targets_only
test_failure_continues_and_exits_nonzero
test_one_log_per_target
test_summary
test_missing_local_env
test_missing_variable
test_bad_arguments
test_boot_test_qemu_only
test_boot_failure_distinct
test_kas_reading_stdin_does_not_eat_targets
test_parallelism_cap_from_local_env
test_parallelism_defaults_to_cpu_count

echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
