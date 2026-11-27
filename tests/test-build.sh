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
    mkdir -p "$T/scripts"; cp "$REPO/scripts/build-manifest.py" "$T/scripts/" 2>/dev/null
    : > "$T/kas/fake.yml"; : > "$T/kas/overlays/ov.yml"
    printf 'DL_DIR=%s/dl\nSSTATE_DIR=%s/ss\nWORK_ROOT=%s/work\n' "$T" "$T" "$T" > "$T/local.env"
    printf '# machine overlay\n\nm1 ov\nm2 -\nm3 -\n' > "$T/all-targets.txt"
    cat > "$T/bin/kas" <<'STUB'
#!/bin/bash
if [ "$1" = dump ]; then
    echo "$KAS_MACHINE $*" >> "$STUB_DUMPS"
    case " ${STUB_FAIL_DUMP:-} " in *" $KAS_MACHINE "*) echo "stub dump failure" >&2; exit 1;; esac
    echo '{"target":"stub-image","repos":{"this":{"url":"u","commit":"c0"},"poky":{"url":"p","branch":"br","commit":"c1"},"unpinned":{"url":"q"}}}'
    exit 0
fi
if [ "$1" = shell ]; then
    echo "stub shell noise" >&2
    echo "$KAS_WORK_DIR/build/${STUB_DEPLOY_SUBDIR:-tmp/deploy/images}/$KAS_MACHINE"
    exit 0
fi
[ -n "${STUB_NO_IMAGES:-}" ] || mkdir -p "$KAS_WORK_DIR/build/${STUB_DEPLOY_SUBDIR:-tmp/deploy/images}/$KAS_MACHINE"
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
    export STUB_CALLS="$T/kas.calls" STUB_ENV="$T/kas.env" STUB_DUMPS="$T/kas.dumps"; : > "$STUB_CALLS"; : > "$STUB_ENV"; : > "$STUB_DUMPS"
    unset STUB_FAIL STUB_FAIL_TEST STUB_FAIL_DUMP STUB_NO_IMAGES STUB_DEPLOY_SUBDIR
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

manifest_of() { echo "$T/work/fake/build/tmp/deploy/images/$1/build-manifest.json"; }
manifest_field() { python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print(eval(sys.argv[2]))' "$(manifest_of "$1")" "$2"; }

test_manifest_written_per_machine() {
    setup; run fake
    expect "manifest: one per successful machine, next to its images" \
        bash -c "[ -f '$(manifest_of m1)' ] && [ -f '$(manifest_of m2)' ] && [ -f '$(manifest_of m3)' ]"
    expect "manifest: records release, machine and image" \
        [ "$(manifest_field m1 '" ".join((d["branch"], d["machine"], d["image"]))')" = "fake m1 stub-image" ]
    expect "manifest: each layer has its revision and upstream" \
        [ "$(manifest_field m1 'd["layers"]["poky"]')" = "{'revision': 'c1', 'upstream': 'br'}" ]
    expect "manifest: a repo without a branch uses its revision as upstream" \
        [ "$(manifest_field m1 'd["layers"]["this"]["upstream"]')" = "c0" ]
    expect "manifest: a repo without a resolved revision is left out" \
        [ "$(manifest_field m1 '"unpinned" in d["layers"]')" = "False" ]
    expect "manifest: resolves refs for the same config that was built" \
        grep -qx "m1 dump --resolve-refs --resolve-local --format json kas/fake.yml:kas/overlays/ov.yml" "$STUB_DUMPS"
}

test_manifest_only_after_successful_build() {
    setup; STUB_FAIL="m1" run fake
    expect "manifest: none for a failed build" [ ! -e "$(manifest_of m1)" ]
    expect "manifest: failed build does not resolve refs" bash -c '! grep -q "^m1 " "$STUB_DUMPS"'
    expect "manifest: other machines still get one" [ -f "$(manifest_of m2)" ]
}

test_manifest_failure_reported() {
    setup; STUB_FAIL_DUMP="m1" run fake
    expect "manifest: dump failure exits 1" [ "$RC" -eq 1 ]
    expect "manifest: summary says manifest failure with its log" grep -qE '^FAIL +m1 +manifest .*/m1\.log' <<<"$OUT"
    expect "manifest: no record written for that machine" [ ! -e "$(manifest_of m1)" ]
    expect "manifest: remaining targets still built" [ -f "$(manifest_of m2)" ]
}

test_manifest_written_even_if_boot_test_fails() {
    qemu_setup; STUB_FAIL_TEST="qemua" run fake
    expect "manifest: kept when only the boot test fails" [ -f "$(manifest_of qemua)" ]
}

test_missing_images_reported() {
    setup; STUB_NO_IMAGES=1 run fake m1
    expect "no-images: exits 1" [ "$RC" -eq 1 ]
    expect "no-images: summary names it with the log" grep -qE '^FAIL +m1 +no-images .*/m1\.log' <<<"$OUT"
    expect "no-images: not reported as a manifest failure" bash -c '! grep -q "manifest" <<<"$1"' _ "$OUT"
}

test_manifest_follows_relocated_deploy_dir() {
    setup; STUB_DEPLOY_SUBDIR="deploy-ti/images" run fake m1
    expect "deploy dir: relocated images dir is accepted" [ "$RC" -eq 0 ]
    expect "deploy dir: manifest written beside the relocated images" [ -f "$T/work/fake/build/deploy-ti/images/m1/build-manifest.json" ]
}

test_update_flag() {
    setup; run --update fake m1 m2
    expect "update: --update is passed to kas build for every target" calls_equal \
"m1 build --update kas/fake.yml:kas/overlays/ov.yml
m2 build --update kas/fake.yml"
    expect "update: --update still lets the release and targets be read" [ "$RC" -eq 0 ]
    qemu_setup; run --update fake qemua
    expect "update: the boot-test step does not update again" calls_equal \
"qemua build --update kas/fake.yml:kas/testimage.yml
qemua build --task testimage kas/fake.yml:kas/testimage.yml"
    setup; run --update
    expect "update: --update without a release exits 2" [ "$RC" -eq 2 ]
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
test_manifest_written_per_machine
test_manifest_only_after_successful_build
test_manifest_failure_reported
test_manifest_written_even_if_boot_test_fails
test_update_flag
test_missing_images_reported
test_manifest_follows_relocated_deploy_dir

echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
