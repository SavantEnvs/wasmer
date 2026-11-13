#!/usr/bin/env bash
#
# mayhem/build.sh — build wasmer's cargo-fuzz targets as sanitized libFuzzer binaries (ASan via RUSTFLAGS)
# and pre-build the functional suite that mayhem/test.sh runs.
#
# Runs inside the commit image (mayhem/Dockerfile) as `mayhem` in /mayhem. The Rust toolchain and the cargo
# registry live at $CARGO_HOME=/opt/toolchains/rust/cargo (pinned by the Dockerfile ENV).
#
# Air-gapped contract (SPEC §6.5): the first build (online) fills the cargo registry; the PATCH re-run is
# offline (CARGO_NET_OFFLINE=true) and resolves from it, so no `--offline` here. Re-runnable: cargo reuses
# fuzz/target and target/ on an already-built tree.
set -euo pipefail

[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH

: "${MAYHEM_JOBS:=$(nproc)}"
export CARGO_BUILD_JOBS="$MAYHEM_JOBS"
# DWARF < 4 (SPEC §6.2 item 10), via rustc's own -Zdwarf-version. line-tables-only (not debuginfo=2) keeps
# file:line in ASan/panic backtraces while each fuzz binary stays ~350 MB instead of ~800 MB: the image holds
# four of them plus both cargo target dirs, and has to fit a CI runner.
: "${RUST_DEBUG_FLAGS:=-C debuginfo=line-tables-only -C force-frame-pointers=yes -Zdwarf-version=3}"

cd "$SRC"

# Upstream pins stable in rust-toolchain.toml; the fuzz build needs the image's nightly (-Zsanitizer). The
# Dockerfile sets RUSTUP_TOOLCHAIN; fall back to the image default if it is unset (e.g. a different identity).
if [ -z "${RUSTUP_TOOLCHAIN:-}" ]; then
  RUSTUP_TOOLCHAIN="$(cd / && rustup show active-toolchain | awk '{print $1; exit}')"
  export RUSTUP_TOOLCHAIN
fi

FUZZ_DIR="fuzz"
TRIPLE="x86_64-unknown-linux-gnu"
FUZZ_TARGET_DIR="$SRC/$FUZZ_DIR/target"

# Upstream's fuzz crate. `llvm` and `deterministic` need the LLVM backend (LLVM 23 via llvm-sys), which the
# image does not have, so they are not built; the other four use only cranelift and singlepass.
FUZZ_TARGETS=(cranelift singlepass metering equivalence)
FUZZ_FEATURES="cranelift,singlepass,sanitizer"

# $SANITIZER_FLAGS (the base image's clang flags) is only consulted for its sanitizer names: rustc cannot take
# the flags themselves, and has no UBSan. ASan is the default (the base sets address+undefined); an operator
# who clears it gets an unsanitized build.
RUST_SANITIZER=""
case "${SANITIZER_FLAGS-address}" in *address*) RUST_SANITIZER="-Zsanitizer=address" ;; esac

# Fleet policy: LeakSanitizer off, ASan on. rustc has no source hook for it, so link a one-function object.
mkdir -p "$FUZZ_TARGET_DIR"
LSAN_OFF_OBJ="$FUZZ_TARGET_DIR/lsan_off.o"
cc -c -O1 "$SRC/mayhem/lsan_off.c" -o "$LSAN_OFF_OBJ"

export RUSTFLAGS="${RUSTFLAGS:-} --cfg fuzzing $RUST_SANITIZER $RUST_DEBUG_FLAGS -C link-arg=$LSAN_OFF_OBJ"

echo "=== cargo fuzz build (toolchain $RUSTUP_TOOLCHAIN, ASan via RUSTFLAGS) ==="
echo "RUSTFLAGS=$RUSTFLAGS"
for t in "${FUZZ_TARGETS[@]}"; do
  echo "--- building fuzz target: $t ---"
  cargo fuzz build --fuzz-dir "$FUZZ_DIR" --target-dir "$FUZZ_TARGET_DIR" -O --debug-assertions \
    --features "$FUZZ_FEATURES" "$t"
  bin="$FUZZ_TARGET_DIR/$TRIPLE/release/$t"
  [ -x "$bin" ] || { echo "ERROR: expected fuzz binary not found at $bin" >&2; exit 1; }
  ln -f "$bin" "/mayhem/$t"   # hard link: no second copy of a ~350 MB binary in the image
  echo "built /mayhem/$t"
done

# The functional suite, with the project's NORMAL flags (no sanitizer, no fuzz cfg), so test.sh only runs it.
# Same env as mayhem/test.sh (it is part of cargo's fingerprint). No debuginfo or incremental cache: they
# are most of the 8 GB the test target dir otherwise takes in the image.
unset RUSTFLAGS
export CARGO_PROFILE_DEV_DEBUG=0 CARGO_INCREMENTAL=0
echo "=== building the test suite (normal flags) ==="
cargo test --no-run -p wasmer --features "cranelift,singlepass,wat" --tests

echo "build.sh complete"
