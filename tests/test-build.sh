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
echo "stub kas output for $KAS_MACHINE"
case " ${STUB_FAIL:-} " in *" $KAS_MACHINE "*) echo "stub failure" >&2; exit 1;; esac
STUB
    chmod +x "$T/bin/kas"
    export STUB_CALLS="$T/kas.calls"; : > "$STUB_CALLS"
    unset STUB_FAIL
    export PATH="$T/bin:$ORIG_PATH"
}
ORIG_PATH="$PATH"

run() { OUT=$("$T/build.sh" "$@" 2>&1); RC=$?; }

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

test_default_builds_all_targets
test_named_targets_only
test_failure_continues_and_exits_nonzero
test_one_log_per_target
test_summary
test_missing_local_env
test_missing_variable
test_bad_arguments

echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
