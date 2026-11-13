#!/usr/bin/env bash
#
# mayhem/test.sh — RUN wasmer's own `wasmer` crate tests (cranelift + singlepass backends), already built by
# mayhem/build.sh. They compile wat modules, instantiate them and assert the values the guest computes,
# the memory contents and the traps, so a program that exits 0 without doing the work fails them.
# exit 0 = pass. Reports CTRF (results.summary) via emit_ctrf; does not compile.
set -uo pipefail
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH
: "${MAYHEM_JOBS:=$(nproc)}"   # build parallelism; env-overridable, falls back to nproc (use -j"$MAYHEM_JOBS")
cd "$SRC"

# emit_ctrf <tool> <passed> <failed> [skipped] [pending] [other]
# Writes a CTRF report (file + stdout `CTRF {...}` marker) and returns non-zero iff failed>0.
emit_ctrf() {
  local tool="$1" passed="$2" failed="$3" skipped="${4:-0}" pending="${5:-0}" other="${6:-0}"
  local tests=$(( passed + failed + skipped + pending + other ))
  cat > "${CTRF_REPORT:-$SRC/ctrf-report.json}" <<JSON
{
  "results": {
    "tool": { "name": "$tool" },
    "summary": {
      "tests": $tests,
      "passed": $passed,
      "failed": $failed,
      "pending": $pending,
      "skipped": $skipped,
      "other": $other
    }
  }
}
JSON
  printf 'CTRF {"results":{"tool":{"name":"%s"},"summary":{"tests":%d,"passed":%d,"failed":%d,"pending":%d,"skipped":%d,"other":%d}}}\n' \
    "$tool" "$tests" "$passed" "$failed" "$pending" "$skipped" "$other"
  [ "$failed" -eq 0 ]
}

# Fail loudly rather than rebuild: build.sh already produced the test binaries with these exact flags.
export CARGO_NET_OFFLINE=true
export CARGO_PROFILE_DEV_DEBUG=0 CARGO_INCREMENTAL=0   # same env as build.sh, or cargo rebuilds
if [ -z "${RUSTUP_TOOLCHAIN:-}" ]; then
  RUSTUP_TOOLCHAIN="$(cd / && rustup show active-toolchain | awk '{print $1; exit}')"
  export RUSTUP_TOOLCHAIN
fi

log="$(mktemp)"
trap 'rm -f "$log"' EXIT
cargo test -p wasmer --features "cranelift,singlepass,wat" --tests --no-fail-fast 2>&1 | tee "$log"

passed=0 failed=0 skipped=0
while read -r p f i; do
  passed=$(( passed + p )); failed=$(( failed + f )); skipped=$(( skipped + i ))
done < <(sed -nE 's/^test result: [a-zA-Z]+\. ([0-9]+) passed; ([0-9]+) failed; ([0-9]+) ignored.*/\1 \2 \3/p' "$log")

# No `test result:` lines (cargo missing, or the binaries never ran) is a failure, not an empty pass.
if [ "$passed" -eq 0 ]; then failed=$(( failed + 1 )); fi
emit_ctrf "cargo-test" "$passed" "$failed" "$skipped"
