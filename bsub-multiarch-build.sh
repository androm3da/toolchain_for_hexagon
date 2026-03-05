#!/bin/bash

#  Copyright (c) Qualcomm Technologies, Inc. and/or its subsidiaries.
#  SPDX-License-Identifier: BSD-3-Clause-Clear

# Build the multi-architecture toolchain on an LSF node.
#
# Two modes:
#   Outer (default): Parse arguments, submit job to LSF via bsub.
#   Inner (--_run-payload): Execute the actual build on the LSF node.
#
# The outer mode re-invokes this script with --_run-payload on the LSF node.

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# ─── Configuration ────────────────────────────────────────────────────────

LSF_RESOURCES="select[ubuntu22_llvm] rusage[mem=204800]"
LSF_QUEUE="${LSF_QUEUE:-normal}"

# Pre-installed host clang toolchain available on LSF ubuntu22_llvm nodes
HOST_CLANG=/pkg/qct/software/llvm/build_tools/clang+llvm-14.0.0-x86_64-linux-gnu-ubuntu-18.04

# Default source refs
DEFAULT_LLVM_REF="main"
DEFAULT_ELD_REF=""
DEFAULT_MUSL_REF="v1.2.5"
DEFAULT_MUSL_HEXAGON_REF="hexagon-v1.2.4-mar-2026"
DEFAULT_LINUX_REF="v6.13.5"
DEFAULT_PICOLIBC_REF="1.8.11"

ALL_TARGETS="hexagon-unknown-linux-musl,arm-unknown-linux-musleabihf,aarch64-unknown-linux-musl,riscv32-unknown-linux-musl,riscv64-unknown-linux-musl"

# ─── Usage ────────────────────────────────────────────────────────────────

usage() {
    cat <<EOF
Usage: $(basename "$0") [OPTIONS]

Build a multi-architecture LLVM toolchain on an LSF node.

Submits a job via bsub that:
  1. Downloads LLVM, musl, Linux kernel, test-suite sources
  2. Installs host tools (prebuilt --host-toolchain, or builds from source)
  3. Builds per-target builtins, kernel headers, musl, runtimes
  4. Runs smoke tests and optionally llvm-test-suite

Options:
  --results-dir DIR          Where to copy final artifacts (default: ./results-<datestamp>)
  --host-toolchain DIR       Prebuilt toolchain to copy (skips stage 0 build)
  --llvm-ref REF             LLVM source ref (default: ${DEFAULT_LLVM_REF})
  --eld-ref REF              ELD source ref (default: none, ELD not built)
  --musl-ref REF             Upstream musl ref (default: ${DEFAULT_MUSL_REF})
  --musl-hexagon-ref REF     Hexagon musl fork ref (default: ${DEFAULT_MUSL_HEXAGON_REF})
  --linux-ref REF            Linux kernel ref (default: ${DEFAULT_LINUX_REF})
  --picolibc-ref REF         Picolibc ref (default: ${DEFAULT_PICOLIBC_REF}; empty to skip)
  --targets LIST             Comma-separated targets (default: all 5)
  --skip-tests               Skip test phases
  --cache FILE               Test-suite cache file (repeatable)
  --qemu-dir DIR             Directory containing qemu-{hexagon,arm,aarch64,riscv32,riscv64}
  --queue QUEUE              LSF queue (default: ${LSF_QUEUE})
  --dry-run                  Print bsub command without submitting
  --probe-only               Just probe the node environment and exit
  -h, --help                 Show this help

Environment:
  DRM_PROJECT                Required. LSF job accounting project.

Examples:
  # Probe LSF node environment:
  DRM_PROJECT=myproj $0 --probe-only

  # Full build + test:
  DRM_PROJECT=myproj $0 --results-dir /path/to/results

  # Build only (no tests):
  DRM_PROJECT=myproj $0 --results-dir /path/to/results --skip-tests

  # Build specific targets:
  DRM_PROJECT=myproj $0 --results-dir /path/to/results \\
      --targets aarch64-unknown-linux-musl,riscv64-unknown-linux-musl

  # Dry run:
  DRM_PROJECT=myproj $0 --results-dir /path/to/results --dry-run
EOF
    exit 0
}

# ─── Probe ────────────────────────────────────────────────────────────────

run_probe() {
    echo "=== LSF Node Environment Probe ==="
    echo "Hostname: $(hostname)"
    echo "Date:     $(date)"
    echo "User:     $(id)"
    echo "Kernel:   $(uname -r)"
    echo ""

    echo "--- OS ---"
    head -3 /etc/os-release 2>/dev/null || echo "(unknown)"
    echo ""

    echo "--- Host Clang Toolchain ---"
    if [ -d "$HOST_CLANG" ]; then
        echo "Found: $HOST_CLANG"
        "$HOST_CLANG/bin/clang" --version 2>&1 | head -2 || echo "  clang binary not working"
    else
        echo "NOT FOUND: $HOST_CLANG"
    fi
    echo ""

    echo "--- Required Tools ---"
    for tool in cmake ninja python3 ccache zstd git gcc make wget patch; do
        if command -v "$tool" >/dev/null 2>&1; then
            ver=$("$tool" --version 2>&1 | head -1)
            printf "  %-12s OK  (%s)\n" "$tool" "$ver"
        else
            printf "  %-12s MISSING\n" "$tool"
        fi
    done
    echo ""

    echo "--- QEMU Binaries ---"
    for qemu in qemu-hexagon qemu-arm qemu-aarch64 qemu-riscv32 qemu-riscv64; do
        if command -v "$qemu" >/dev/null 2>&1; then
            ver=$("$qemu" --version 2>&1 | head -1)
            printf "  %-18s OK  (%s)\n" "$qemu" "$ver"
        else
            printf "  %-18s MISSING\n" "$qemu"
        fi
    done
    echo ""

    echo "--- Disk Space ---"
    df -h /local/mnt/workspace/ 2>/dev/null || echo "/local/mnt/workspace not available"
    echo ""

    echo "--- Memory ---"
    free -h 2>/dev/null || echo "(unknown)"
    echo ""

    echo "--- CPU ---"
    echo "$(nproc 2>/dev/null || echo '?') cores available"
    echo ""

    echo "=== Probe Complete ==="
}

# ─── Download Helper ──────────────────────────────────────────────────────

download_archive() {
    local url="$1"
    local dest="$2"

    echo "Downloading: ${url}"
    echo "  -> ${dest}"
    mkdir -p "${dest}"

    case "${url}" in
        *.tar.xz)
            wget --quiet "${url}" -O "${dest}.tar.xz"
            tar xf "${dest}.tar.xz" -C "${dest}" --strip-components=1
            rm "${dest}.tar.xz"
            ;;
        *.tar.gz|*.tgz)
            wget --quiet "${url}" -O "${dest}.tar.gz"
            tar xf "${dest}.tar.gz" -C "${dest}" --strip-components=1
            rm "${dest}.tar.gz"
            ;;
        *)
            echo "ERROR: Unknown archive format: ${url}"
            return 1
            ;;
    esac
}

# ─── Payload ──────────────────────────────────────────────────────────────

run_payload() {
    local results_dir="$1"
    local llvm_ref="$2"
    local eld_ref="$3"
    local musl_ref="$4"
    local musl_hexagon_ref="$5"
    local linux_ref="$6"
    local targets="$7"
    local skip_tests="$8"
    local host_toolchain="$9"
    local qemu_dir="${10}"
    local picolibc_ref="${11}"
    shift 11
    local cache_files=("$@")

    echo "=== Multi-Architecture Toolchain Build (LSF) ==="
    echo "Hostname:           $(hostname)"
    echo "Date:               $(date)"
    echo "Host toolchain:     ${host_toolchain:-<building from source>}"
    echo "LLVM ref:           ${llvm_ref}"
    echo "ELD ref:            ${eld_ref:-<not building ELD>}"
    echo "musl ref:           ${musl_ref}"
    echo "musl hexagon ref:   ${musl_hexagon_ref}"
    echo "Linux ref:          ${linux_ref}"
    echo "picolibc ref:       ${picolibc_ref:-<not building picolibc>}"
    echo "Targets:            ${targets}"
    echo "Results Dir:        ${results_dir}"
    echo "Skip Tests:         ${skip_tests}"
    echo ""

    # ── Workspace setup ──────────────────────────────────────────────
    WORKSPACE="/local/mnt/workspace/${LOGNAME}-multiarch-$(date +%s)"

    echo "Creating workspace: ${WORKSPACE}"
    mkdir -p "${WORKSPACE}"

    cleanup() {
        local rc=$?
        echo ""
        echo "=== Cleanup (exit code: ${rc}) ==="
        if [ -d "${WORKSPACE}" ]; then
            echo "Removing workspace: ${WORKSPACE}"
            rm -rf "${WORKSPACE}"
        fi
        echo "Done."
    }
    trap cleanup EXIT

    # ── Environment setup ────────────────────────────────────────────
    export CC="${HOST_CLANG}/bin/clang"
    export CXX="${HOST_CLANG}/bin/clang++"
    export PATH="${HOST_CLANG}/bin:${PATH}"
    export LD_LIBRARY_PATH="${HOST_CLANG}/lib${LD_LIBRARY_PATH:+:${LD_LIBRARY_PATH}}"

    echo "--- Host Clang ---"
    clang --version
    echo ""

    # ── Step 1: Download sources ─────────────────────────────────────
    echo "=========================================="
    echo "=== Step 1: Downloading Sources"
    echo "=========================================="

    local src_dir="${WORKSPACE}/src"
    mkdir -p "${src_dir}"

    # LLVM
    download_archive \
        "https://github.com/llvm/llvm-project/archive/${llvm_ref}.tar.gz" \
        "${src_dir}/llvm-project"

    # ELD (optional)
    if [ -n "${eld_ref}" ]; then
        download_archive \
            "https://github.com/qualcomm/eld/archive/${eld_ref}.tar.gz" \
            "${src_dir}/eld"

        # Patch ELD cmake: LLVM's AddLLVM.cmake uses keyword-form
        # target_link_libraries (PRIVATE/PUBLIC), but ELD uses plain form.
        # CMake forbids mixing.  Add PRIVATE to ELD's plain calls.
        # Handles both single-line: target_link_libraries(ELDFoo lib1)
        # and multi-line:          target_link_libraries(\n  ELDFoo\n  lib1)
        echo "Patching ELD CMakeLists for cmake CMP0023 compatibility..."
        find "${src_dir}/eld" -name CMakeLists.txt -exec \
            perl -i -0777 -pe \
            's/target_link_libraries\(\n(\s*)(ELD\w+)/target_link_libraries(\n$1$2 PRIVATE/g;
             s/target_link_libraries\((ELD\w+)\s/target_link_libraries($1 PRIVATE /g' {} +
    fi

    # musl upstream
    download_archive \
        "https://git.musl-libc.org/cgit/musl/snapshot/${musl_ref}.tar.gz" \
        "${src_dir}/musl"

    # musl hexagon fork
    download_archive \
        "https://github.com/quic/musl/archive/${musl_hexagon_ref}.tar.gz" \
        "${src_dir}/musl-hexagon"

    # Linux kernel — extract version number for URL construction
    local linux_ver="${linux_ref#v}"
    local linux_major="${linux_ver%%.*}"
    download_archive \
        "https://cdn.kernel.org/pub/linux/kernel/v${linux_major}.x/linux-${linux_ver}.tar.xz" \
        "${src_dir}/linux"

    # Test suite (same ref as LLVM)
    if [ "${skip_tests}" -eq 0 ]; then
        download_archive \
            "https://github.com/llvm/llvm-test-suite/archive/${llvm_ref}.tar.gz" \
            "${src_dir}/llvm-test-suite"
    fi

    # Picolibc (for baremetal targets)
    if [ -n "${picolibc_ref}" ]; then
        download_archive \
            "https://github.com/picolibc/picolibc/archive/${picolibc_ref}.tar.gz" \
            "${src_dir}/picolibc"
    fi

    echo ""
    echo "Sources downloaded to ${src_dir}"
    ls -1d "${src_dir}"/*
    echo ""

    # Ensure meson is available (needed for picolibc)
    if [ -n "${picolibc_ref}" ]; then
        if ! command -v meson >/dev/null 2>&1; then
            echo "Installing meson via pip3..."
            pip3 install --user meson
            export PATH="${HOME}/.local/bin:${PATH}"
        fi
        echo "meson: $(meson --version)"
    fi

    # ── Step 2: Build toolchain ──────────────────────────────────────
    echo "=========================================="
    echo "=== Step 2: Building Multi-Arch Toolchain"
    echo "=========================================="

    local install_dir="${WORKSPACE}/toolchain"
    local build_flags=(
        --install-dir "${install_dir}"
        --llvm-src "${src_dir}/llvm-project"
        --musl-src "${src_dir}/musl"
        --musl-hexagon-src "${src_dir}/musl-hexagon"
        --linux-src "${src_dir}/linux"
        --build-dir "${WORKSPACE}/build"
        --targets "${targets}"
        --parallel-link-jobs 8
        --ccache
        --llvm-ref "${llvm_ref}"
    )

    if [ -n "${host_toolchain}" ]; then
        build_flags+=(--host-toolchain "${host_toolchain}")
    fi

    if [ -n "${qemu_dir}" ]; then
        [ -x "${qemu_dir}/qemu-hexagon" ] && build_flags+=(--qemu-hexagon "${qemu_dir}/qemu-hexagon")
        [ -x "${qemu_dir}/qemu-arm" ]     && build_flags+=(--qemu-arm "${qemu_dir}/qemu-arm")
        [ -x "${qemu_dir}/qemu-aarch64" ] && build_flags+=(--qemu-aarch64 "${qemu_dir}/qemu-aarch64")
        [ -x "${qemu_dir}/qemu-riscv32" ] && build_flags+=(--qemu-riscv32 "${qemu_dir}/qemu-riscv32")
        [ -x "${qemu_dir}/qemu-riscv64" ] && build_flags+=(--qemu-riscv64 "${qemu_dir}/qemu-riscv64")
    fi

    if [ -n "${eld_ref}" ] && [ -d "${src_dir}/eld" ]; then
        build_flags+=(--eld-src "${src_dir}/eld")
    fi

    if [ -n "${picolibc_ref}" ] && [ -d "${src_dir}/picolibc" ]; then
        build_flags+=(--picolibc-src "${src_dir}/picolibc")
    fi

    if [ "${skip_tests}" -eq 1 ]; then
        build_flags+=(--skip-tests)
    else
        if [ -d "${src_dir}/llvm-test-suite" ]; then
            build_flags+=(--test-suite-src "${src_dir}/llvm-test-suite")
        fi
    fi

    for cache in "${cache_files[@]}"; do
        build_flags+=(--cache "${cache}")
    done

    "${SCRIPT_DIR}/build-multiarch-toolchain.sh" "${build_flags[@]}"

    # ── Step 3: Package results ──────────────────────────────────────
    echo ""
    echo "=========================================="
    echo "=== Step 3: Packaging Results"
    echo "=========================================="

    mkdir -p "${results_dir}"

    # Write build manifest into the toolchain directory (included in tarball)
    cat > "${install_dir}/BUILD_MANIFEST" <<MANIFEST
llvm_project_ref=${llvm_ref}
eld_ref=${eld_ref:-none}
musl_ref=${musl_ref}
musl_hexagon_ref=${musl_hexagon_ref}
linux_ref=${linux_ref}
picolibc_ref=${picolibc_ref:-none}
targets=${targets}
build_date=$(date -u +%Y-%m-%dT%H:%M:%SZ)
build_host=$(hostname)
MANIFEST
    echo "Build manifest written to ${install_dir}/BUILD_MANIFEST"

    # Create a compressed tarball of the toolchain
    # Prefer zstd, fall back to gzip if zstd is not available
    if command -v zstd >/dev/null 2>&1; then
        local tarball="${results_dir}/multiarch-toolchain.tar.zst"
        echo "Creating ${tarball}..."
        tar c -C "$(dirname "${install_dir}")" "$(basename "${install_dir}")" \
            | zstd --fast -T0 > "${tarball}"
    else
        local tarball="${results_dir}/multiarch-toolchain.tar.gz"
        echo "Creating ${tarball} (zstd not available, using gzip)..."
        tar czf "${tarball}" -C "$(dirname "${install_dir}")" "$(basename "${install_dir}")"
    fi

    # Copy test results if they exist
    if [ -d "${WORKSPACE}/build/results" ]; then
        cp -a "${WORKSPACE}/build/results"/* "${results_dir}/" 2>/dev/null || true
    fi

    # Generate checksums
    (cd "${results_dir}" && sha256sum ./*.tar.* 2>/dev/null | tee SHA256SUMS)

    echo ""
    echo "Artifacts:"
    ls -lh "${results_dir}/"

    echo ""
    echo "=== Build Complete ==="
    echo "Results: ${results_dir}"
    echo "Date:    $(date)"
}

# ─── Argument Parsing ─────────────────────────────────────────────────────

RESULTS_DIR=""
HOST_TOOLCHAIN=""
QEMU_DIR=""
LLVM_REF="${DEFAULT_LLVM_REF}"
ELD_REF="${DEFAULT_ELD_REF}"
MUSL_REF="${DEFAULT_MUSL_REF}"
MUSL_HEXAGON_REF="${DEFAULT_MUSL_HEXAGON_REF}"
LINUX_REF="${DEFAULT_LINUX_REF}"
PICOLIBC_REF="${DEFAULT_PICOLIBC_REF}"
TARGETS="${ALL_TARGETS}"
SKIP_TESTS=0
DRY_RUN=0
PROBE_ONLY=0
_RUN_PAYLOAD=0
CACHE_FILES=()

while [ $# -gt 0 ]; do
    case "$1" in
        --_run-payload)       _RUN_PAYLOAD=1; shift ;;
        --results-dir)        RESULTS_DIR="$2"; shift 2 ;;
        --host-toolchain)     HOST_TOOLCHAIN="$2"; shift 2 ;;
        --qemu-dir)           QEMU_DIR="$2"; shift 2 ;;
        --llvm-ref)           LLVM_REF="$2"; shift 2 ;;
        --eld-ref)            ELD_REF="$2"; shift 2 ;;
        --musl-ref)           MUSL_REF="$2"; shift 2 ;;
        --musl-hexagon-ref)   MUSL_HEXAGON_REF="$2"; shift 2 ;;
        --linux-ref)          LINUX_REF="$2"; shift 2 ;;
        --picolibc-ref)       PICOLIBC_REF="$2"; shift 2 ;;
        --targets)            TARGETS="$2"; shift 2 ;;
        --skip-tests)         SKIP_TESTS=1; shift ;;
        --cache)              CACHE_FILES+=("$2"); shift 2 ;;
        --queue)              LSF_QUEUE="$2"; shift 2 ;;
        --dry-run)            DRY_RUN=1; shift ;;
        --probe-only)         PROBE_ONLY=1; shift ;;
        -h|--help)            usage ;;
        *)                    echo "Unknown option: $1"; usage ;;
    esac
done

# ─── Payload Mode (runs on the LSF node) ──────────────────────────────────

if [ "$_RUN_PAYLOAD" -eq 1 ]; then
    if [ "$PROBE_ONLY" -eq 1 ]; then
        run_probe
    else
        run_payload "$RESULTS_DIR" "$LLVM_REF" "$ELD_REF" "$MUSL_REF" \
            "$MUSL_HEXAGON_REF" "$LINUX_REF" "$TARGETS" "$SKIP_TESTS" \
            "$HOST_TOOLCHAIN" "$QEMU_DIR" "$PICOLIBC_REF" "${CACHE_FILES[@]}"
    fi
    exit $?
fi

# ─── Submission Mode (runs on the user's machine) ────────────────────────

# DRM_PROJECT is required for LSF job accounting
if test -z "${DRM_PROJECT:-}"; then
    echo "Error: DRM_PROJECT environment variable must be set for LSF job accounting."
    exit 1
fi

if [ "$PROBE_ONLY" -eq 0 ]; then
    if [ -z "$RESULTS_DIR" ]; then
        RESULTS_DIR="$(pwd)/results-$(date +"%Y_%d%b_%H%M")"
        echo "No --results-dir specified, using: ${RESULTS_DIR}"
    fi
    # Resolve to absolute path for the LSF node
    mkdir -p "$RESULTS_DIR"
    RESULTS_DIR="$(readlink -f "$RESULTS_DIR")"
fi

# Job naming
if [ "$PROBE_ONLY" -eq 1 ]; then
    JOB_NAME="multiarch-probe"
else
    JOB_NAME="multiarch-build"
fi

# Build the payload command: re-invoke this script with --_run-payload
PAYLOAD_CMD=("${SCRIPT_DIR}/bsub-multiarch-build.sh" --_run-payload)
if [ "$PROBE_ONLY" -eq 1 ]; then
    PAYLOAD_CMD+=(--probe-only)
else
    PAYLOAD_CMD+=(--results-dir "$RESULTS_DIR")
    [ -n "$HOST_TOOLCHAIN" ] && PAYLOAD_CMD+=(--host-toolchain "$HOST_TOOLCHAIN")
    [ -n "$QEMU_DIR" ] && PAYLOAD_CMD+=(--qemu-dir "$QEMU_DIR")
    PAYLOAD_CMD+=(--llvm-ref "$LLVM_REF")
    [ -n "$ELD_REF" ] && PAYLOAD_CMD+=(--eld-ref "$ELD_REF")
    PAYLOAD_CMD+=(--musl-ref "$MUSL_REF")
    PAYLOAD_CMD+=(--musl-hexagon-ref "$MUSL_HEXAGON_REF")
    PAYLOAD_CMD+=(--linux-ref "$LINUX_REF")
    [ -n "$PICOLIBC_REF" ] && PAYLOAD_CMD+=(--picolibc-ref "$PICOLIBC_REF")
    PAYLOAD_CMD+=(--targets "$TARGETS")
    [ "$SKIP_TESTS" -eq 1 ] && PAYLOAD_CMD+=(--skip-tests)
    for cache in "${CACHE_FILES[@]}"; do
        PAYLOAD_CMD+=(--cache "$cache")
    done
fi

# Construct the bsub command
BSUB_CMD=(
    bsub
    -P "$DRM_PROJECT"
    -q "$LSF_QUEUE"
    -J "$JOB_NAME"
    -R "$LSF_RESOURCES"
    -o "${JOB_NAME}-%J.log"
    -e "${JOB_NAME}-%J.err"
    "${PAYLOAD_CMD[@]}"
)

if [ "$DRY_RUN" -eq 1 ]; then
    echo "=== Dry Run ==="
    echo "Would submit to LSF:"
    echo "  ${BSUB_CMD[*]}"
    exit 0
fi

echo "Submitting '${JOB_NAME}' job to LSF..."
echo "  Queue:          ${LSF_QUEUE}"
echo "  Resources:      ${LSF_RESOURCES}"
echo "  Project:        ${DRM_PROJECT}"
if [ "$PROBE_ONLY" -eq 0 ]; then
    [ -n "$HOST_TOOLCHAIN" ] && echo "  Host toolchain: ${HOST_TOOLCHAIN}"
    [ -n "$QEMU_DIR" ] && echo "  QEMU dir:       ${QEMU_DIR}"
    echo "  LLVM ref:       ${LLVM_REF}"
    echo "  Targets:        ${TARGETS}"
    echo "  Results:        ${RESULTS_DIR}"
fi
echo ""

"${BSUB_CMD[@]}"
