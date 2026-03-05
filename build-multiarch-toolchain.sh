#!/bin/bash

#  Copyright (c) Qualcomm Technologies, Inc. and/or its subsidiaries.
#  SPDX-License-Identifier: BSD-3-Clause-Clear

# Build a multi-architecture LLVM cross-compilation toolchain targeting Linux
# with musl libc, plus optional baremetal targets with picolibc.
# Supports Hexagon, ARM (v7 hard-float), AArch64, RISC-V 32, and RISC-V 64.
#
# This script is self-contained (no LSF dependency).  For cluster submission,
# use bsub-multiarch-build.sh which wraps this script.
#
# Build phases (sequential due to dependency chains):
#   1. Host tools — either copied from a prebuilt toolchain (--host-toolchain)
#      or built from source (fallback, requires --llvm-src)
#   2. Per-target kernel headers + musl headers
#   3. Per-target compiler-rt builtins
#   4. Per-target musl libc
#   5. Per-target runtimes (libc++, libc++abi, libunwind, compiler-rt)
#   6. Driver config files + symlinks
#   7. Smoke tests (simple C/C++ programs via QEMU)
#   8. llvm-test-suite (per cmake cache file)
#   9. Baremetal targets: builtins + picolibc + config files (if --picolibc-src)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# ─── Default Configuration ────────────────────────────────────────────────

ALL_TARGETS="hexagon-unknown-linux-musl,arm-unknown-linux-musleabihf,aarch64-unknown-linux-musl,riscv32-unknown-linux-musl,riscv64-unknown-linux-musl"

LLVM_SRC=""
INSTALL_DIR=""
HOST_TOOLCHAIN=""
ELD_SRC=""
MUSL_SRC=""
MUSL_HEXAGON_SRC=""
LINUX_SRC=""
TEST_SUITE_SRC=""
PICOLIBC_SRC=""
TARGETS="${ALL_TARGETS}"
BUILD_DIR=""
SKIP_RUNTIMES=0
SKIP_TESTS=0
PARALLEL_LINK_JOBS=8
USE_CCACHE=0
CACHE_FILES=()

# QEMU paths (auto-detected if not specified)
QEMU_HEXAGON=""
QEMU_ARM=""
QEMU_AARCH64=""
QEMU_RISCV32=""
QEMU_RISCV64=""

# ─── Usage ────────────────────────────────────────────────────────────────

usage() {
    cat <<EOF
Usage: $(basename "$0") [OPTIONS]

Build a multi-architecture LLVM cross-compilation toolchain with musl libc.

Required:
  --install-dir DIR          Toolchain install prefix

Host tools (one of):
  --host-toolchain DIR       Prebuilt toolchain to copy (preferred; skips stage 0)
  --llvm-src DIR             Path to llvm-project source tree (builds stage 0)

Optional source paths:
  --llvm-src DIR             Also needed for compiler-rt/runtimes source
  --eld-src DIR              Path to ELD source (only for stage 0 from-source build)
  --musl-src DIR             Path to upstream musl source
  --musl-hexagon-src DIR     Path to Hexagon musl fork source
  --linux-src DIR            Path to Linux kernel source (for headers)
  --test-suite-src DIR       Path to llvm-test-suite source
  --picolibc-src DIR         Path to picolibc source (enables baremetal targets)

Build control:
  --targets LIST             Comma-separated triples (default: all 5)
  --build-dir DIR            Build directory (default: ./build-multiarch)
  --skip-runtimes            Skip phases 2-5 (builtins, headers, musl, runtimes)
  --skip-tests               Skip phases 7-8 (smoke tests, test-suite)
  --parallel-link-jobs N     Limit parallel link jobs (default: 8)
  --ccache                   Enable ccache
  --llvm-ref REF             Record LLVM ref in BUILD_MANIFEST (auto-detected from git if omitted)

Testing:
  --cache FILE               CMake cache for test-suite (repeatable)
  --qemu-hexagon PATH        Path to qemu-hexagon
  --qemu-arm PATH            Path to qemu-arm
  --qemu-aarch64 PATH        Path to qemu-aarch64
  --qemu-riscv32 PATH        Path to qemu-riscv32
  --qemu-riscv64 PATH        Path to qemu-riscv64

  -h, --help                 Show this help

Supported targets:
  hexagon-unknown-linux-musl
  arm-unknown-linux-musleabihf
  aarch64-unknown-linux-musl
  riscv32-unknown-linux-musl
  riscv64-unknown-linux-musl
EOF
    exit 0
}

# ─── Argument Parsing ─────────────────────────────────────────────────────

while [ $# -gt 0 ]; do
    case "$1" in
        --llvm-src)           LLVM_SRC="$2"; shift 2 ;;
        --install-dir)        INSTALL_DIR="$2"; shift 2 ;;
        --host-toolchain)     HOST_TOOLCHAIN="$2"; shift 2 ;;
        --eld-src)            ELD_SRC="$2"; shift 2 ;;
        --musl-src)           MUSL_SRC="$2"; shift 2 ;;
        --musl-hexagon-src)   MUSL_HEXAGON_SRC="$2"; shift 2 ;;
        --linux-src)          LINUX_SRC="$2"; shift 2 ;;
        --test-suite-src)     TEST_SUITE_SRC="$2"; shift 2 ;;
        --picolibc-src)       PICOLIBC_SRC="$2"; shift 2 ;;
        --targets)            TARGETS="$2"; shift 2 ;;
        --build-dir)          BUILD_DIR="$2"; shift 2 ;;
        --skip-runtimes)      SKIP_RUNTIMES=1; shift ;;
        --skip-tests)         SKIP_TESTS=1; shift ;;
        --parallel-link-jobs) PARALLEL_LINK_JOBS="$2"; shift 2 ;;
        --ccache)             USE_CCACHE=1; shift ;;
        --cache)              CACHE_FILES+=("$2"); shift 2 ;;
        --qemu-hexagon)       QEMU_HEXAGON="$2"; shift 2 ;;
        --qemu-arm)           QEMU_ARM="$2"; shift 2 ;;
        --qemu-aarch64)       QEMU_AARCH64="$2"; shift 2 ;;
        --qemu-riscv32)       QEMU_RISCV32="$2"; shift 2 ;;
        --qemu-riscv64)       QEMU_RISCV64="$2"; shift 2 ;;
        --llvm-ref)           LLVM_REF="$2"; shift 2 ;;
        -h|--help)            usage ;;
        *)                    echo "Unknown option: $1"; usage ;;
    esac
done

# ─── Validation ───────────────────────────────────────────────────────────

if [ -z "$INSTALL_DIR" ]; then
    echo "Error: --install-dir is required."
    exit 1
fi
if [ -z "$HOST_TOOLCHAIN" ] && [ -z "$LLVM_SRC" ]; then
    echo "Error: either --host-toolchain or --llvm-src is required."
    exit 1
fi
if [ -n "$HOST_TOOLCHAIN" ] && [ ! -d "$HOST_TOOLCHAIN" ]; then
    echo "Error: --host-toolchain directory does not exist: $HOST_TOOLCHAIN"
    exit 1
fi

[ -n "$LLVM_SRC" ] && LLVM_SRC="$(readlink -f "$LLVM_SRC")"
[ -n "$HOST_TOOLCHAIN" ] && HOST_TOOLCHAIN="$(readlink -f "$HOST_TOOLCHAIN")"
mkdir -p "$INSTALL_DIR"
INSTALL_DIR="$(readlink -f "$INSTALL_DIR")"

if [ -z "$BUILD_DIR" ]; then
    BUILD_DIR="$(pwd)/build-multiarch"
fi
mkdir -p "$BUILD_DIR"
BUILD_DIR="$(readlink -f "$BUILD_DIR")"

# Resolve optional source paths
[ -n "$ELD_SRC" ] && ELD_SRC="$(readlink -f "$ELD_SRC")"
[ -n "$MUSL_SRC" ] && MUSL_SRC="$(readlink -f "$MUSL_SRC")"
[ -n "$MUSL_HEXAGON_SRC" ] && MUSL_HEXAGON_SRC="$(readlink -f "$MUSL_HEXAGON_SRC")"
[ -n "$LINUX_SRC" ] && LINUX_SRC="$(readlink -f "$LINUX_SRC")"
[ -n "$TEST_SUITE_SRC" ] && TEST_SUITE_SRC="$(readlink -f "$TEST_SUITE_SRC")"
[ -n "$PICOLIBC_SRC" ] && PICOLIBC_SRC="$(readlink -f "$PICOLIBC_SRC")"

# Parse comma-separated targets into an array
IFS=',' read -ra TARGET_ARRAY <<< "$TARGETS"

# CCACHE flag for cmake
CCACHE_FLAG=""
if [ "$USE_CCACHE" -eq 1 ]; then
    CCACHE_FLAG="-DLLVM_CCACHE_BUILD:BOOL=ON"
fi

echo "=== Multi-Architecture Toolchain Build ==="
echo "Host toolchain: ${HOST_TOOLCHAIN:-<building from source>}"
echo "LLVM source:    ${LLVM_SRC:-<not set>}"
echo "Install dir:    ${INSTALL_DIR}"
echo "Build dir:      ${BUILD_DIR}"
echo "Targets:        ${TARGET_ARRAY[*]}"
echo "ELD source:     ${ELD_SRC:-<not set>}"
echo "musl source:    ${MUSL_SRC:-<not set>}"
echo "musl hexagon:   ${MUSL_HEXAGON_SRC:-<not set>}"
echo "Linux source:   ${LINUX_SRC:-<not set>}"
echo "picolibc src:   ${PICOLIBC_SRC:-<not set>}"
echo "Skip runtimes:  ${SKIP_RUNTIMES}"
echo "Skip tests:     ${SKIP_TESTS}"
echo "Link jobs:      ${PARALLEL_LINK_JOBS}"
echo "ccache:         ${USE_CCACHE}"
echo ""

# ─── Utility Functions ────────────────────────────────────────────────────

log_phase() {
    echo ""
    echo "=========================================="
    echo "=== Phase $1: $2"
    echo "=========================================="
    echo ""
}

# Map a target triple to the corresponding QEMU binary name
qemu_bin_for_target() {
    local target="$1"
    case "${target}" in
        hexagon*)  echo "${QEMU_HEXAGON:-qemu-hexagon}" ;;
        arm*)      echo "${QEMU_ARM:-qemu-arm}" ;;
        aarch64*)  echo "${QEMU_AARCH64:-qemu-aarch64}" ;;
        riscv32*)  echo "${QEMU_RISCV32:-qemu-riscv32}" ;;
        riscv64*)  echo "${QEMU_RISCV64:-qemu-riscv64}" ;;
        *)         echo "qemu-unknown"; return 1 ;;
    esac
}

# Check if a test-suite cache file is relevant for a given target
cache_matches_target() {
    local target="$1"
    local cache="$2"
    local cache_base
    cache_base="$(basename "${cache}" .cmake)"
    case "${target}" in
        hexagon*)  [[ "${cache_base}" == *hexagon* ]] ;;
        arm*)      [[ "${cache_base}" == *arm* ]] ;;
        aarch64*)  [[ "${cache_base}" == *aarch64* ]] ;;
        riscv32*)  [[ "${cache_base}" == *riscv32* ]] ;;
        riscv64*)  [[ "${cache_base}" == *riscv64* ]] ;;
        *)         return 1 ;;
    esac
}

# Map a target triple to the Linux kernel ARCH value
linux_arch_for_target() {
    local target="$1"
    case "${target}" in
        hexagon*)  echo "hexagon" ;;
        arm*)      echo "arm" ;;
        aarch64*)  echo "arm64" ;;
        riscv32*)  echo "riscv" ;;
        riscv64*)  echo "riscv" ;;
        *)         echo "unknown"; return 1 ;;
    esac
}

# Map a target triple to the musl configure --target value
musl_target_for_triple() {
    local target="$1"
    case "${target}" in
        hexagon*)  echo "hexagon" ;;
        arm*)      echo "arm" ;;
        aarch64*)  echo "aarch64" ;;
        riscv32*)  echo "riscv32" ;;
        riscv64*)  echo "riscv64" ;;
        *)         echo "unknown"; return 1 ;;
    esac
}

# ─── Phase 1: Host Tools ─────────────────────────────────────────────────

# Copy a prebuilt toolchain into INSTALL_DIR.  This is the preferred path:
# avoids rebuilding LLVM+Clang from source every time.
install_prebuilt_host_tools() {
    log_phase 1 "Install prebuilt host tools"

    echo "Copying prebuilt toolchain from ${HOST_TOOLCHAIN} to ${INSTALL_DIR}..."
    rsync -a "${HOST_TOOLCHAIN}/" "${INSTALL_DIR}/"

    echo "Prebuilt host tools installed to ${INSTALL_DIR}"
}

# Build host tools from LLVM source (fallback when --host-toolchain is not given).
build_host_tools() {
    log_phase 1 "Build Host Tools from source (LLVM + Clang)"

    if [ -z "${LLVM_SRC}" ]; then
        echo "Error: --llvm-src is required when building host tools from source."
        exit 1
    fi

    local eld_flags=()
    if [ -n "$ELD_SRC" ]; then
        eld_flags=(-DLLVM_EXTERNAL_PROJECTS=eld "-DLLVM_EXTERNAL_ELD_SOURCE_DIR=${ELD_SRC}")
        echo "ELD enabled: ${ELD_SRC}"
    fi

    local ccache_flags=()
    if [ -n "${CCACHE_FLAG}" ]; then
        ccache_flags=("${CCACHE_FLAG}")
    fi

    cmake -G Ninja \
        -C "${SCRIPT_DIR}/cmake/caches/multiarch-stage0.cmake" \
        -DCMAKE_INSTALL_PREFIX="${INSTALL_DIR}" \
        -DCMAKE_C_COMPILER="${CC:-clang}" \
        -DCMAKE_CXX_COMPILER="${CXX:-clang++}" \
        -DLLVM_PARALLEL_LINK_JOBS="${PARALLEL_LINK_JOBS}" \
        "${eld_flags[@]}" \
        "${ccache_flags[@]}" \
        -B "${BUILD_DIR}/host" \
        -S "${LLVM_SRC}/llvm"

    cmake --build "${BUILD_DIR}/host" --target install-distribution

    echo "Host tools installed to ${INSTALL_DIR}"
}

# ─── Phase 2: Per-target compiler-rt builtins ─────────────────────────────

build_builtins() {
    local target="$1"
    echo "--- Building builtins for ${target} ---"

    local sysroot="${INSTALL_DIR}/sysroot/${target}"
    local cmake_args=(
        -G Ninja
        -C "${SCRIPT_DIR}/cmake/caches/multiarch-builtins.cmake"
        -DCMAKE_INSTALL_PREFIX="${INSTALL_DIR}"
        -DCOMPILER_RT_INSTALL_PATH="${CLANG_RESOURCE_DIR}"
        -DCMAKE_C_COMPILER="${INSTALL_DIR}/bin/clang"
        -DCMAKE_CXX_COMPILER="${INSTALL_DIR}/bin/clang++"
        -DCMAKE_ASM_COMPILER="${INSTALL_DIR}/bin/clang"
        -DCMAKE_C_COMPILER_TARGET="${target}"
        -DCMAKE_CXX_COMPILER_TARGET="${target}"
        -DCMAKE_ASM_COMPILER_TARGET="${target}"
        -DCMAKE_SYSROOT="${sysroot}"
        -DLLVM_CMAKE_DIR="${LLVM_SRC}/llvm/cmake/modules"
        -B "${BUILD_DIR}/builtins-${target}"
        -S "${LLVM_SRC}/compiler-rt"
    )

    if [[ "${target}" == hexagon* ]]; then
        cmake_args+=(
            "-DCMAKE_C_FLAGS=-G0 -mlong-calls -fno-pic"
            "-DCMAKE_ASM_FLAGS=-G0 -mlong-calls -fno-pic"
            -DCOMPILER_RT_BUILTINS_ENABLE_PIC=OFF
        )
    fi

    cmake "${cmake_args[@]}"
    cmake --build "${BUILD_DIR}/builtins-${target}" --target install-builtins install-crt

    echo "Builtins for ${target} installed."
}

# ─── Phase 3: Per-target Linux kernel headers ─────────────────────────────

install_kernel_headers() {
    local target="$1"
    echo "--- Installing kernel headers for ${target} ---"

    if [ -z "$LINUX_SRC" ]; then
        echo "WARNING: --linux-src not set, skipping kernel headers for ${target}"
        return 0
    fi

    local linux_arch
    linux_arch="$(linux_arch_for_target "${target}")"
    local sysroot="${INSTALL_DIR}/sysroot/${target}"

    mkdir -p "${sysroot}/usr"

    make -C "${LINUX_SRC}" headers_install \
        ARCH="${linux_arch}" \
        INSTALL_HDR_PATH="${sysroot}/usr" \
        LLVM=1

    echo "Kernel headers for ${target} installed to ${sysroot}/usr/include"
}

# ─── Phase 3b: Per-target musl headers (needed before builtins) ──────────

install_musl_headers() {
    local target="$1"
    echo "--- Installing musl headers for ${target} ---"

    local sysroot="${INSTALL_DIR}/sysroot/${target}"
    mkdir -p "${sysroot}"

    # Select musl source
    local musl_dir
    if [[ "${target}" == hexagon* ]]; then
        if [ -z "$MUSL_HEXAGON_SRC" ]; then
            echo "WARNING: --musl-hexagon-src not set, skipping musl headers for ${target}"
            return 0
        fi
        musl_dir="${MUSL_HEXAGON_SRC}"
    else
        if [ -z "$MUSL_SRC" ]; then
            echo "WARNING: --musl-src not set, skipping musl headers for ${target}"
            return 0
        fi
        musl_dir="${MUSL_SRC}"
    fi

    local musl_target
    musl_target="$(musl_target_for_triple "${target}")"

    local musl_hdr_build="${BUILD_DIR}/musl-headers-${target}"
    mkdir -p "${musl_hdr_build}"
    cp -a "${musl_dir}/." "${musl_hdr_build}/src/"

    local extra_cflags=""
    if [[ "${target}" == hexagon* ]]; then
        extra_cflags="-G0 -O0 -mv68 -fno-builtin -mlong-calls"
        extra_cflags="${extra_cflags} -Wno-switch-bool -Wno-unsupported-floating-point-opt"
    fi

    (
        cd "${musl_hdr_build}/src"

        CC="${INSTALL_DIR}/bin/clang --target=${target} ${extra_cflags}" \
        AR="${INSTALL_DIR}/bin/llvm-ar" \
        RANLIB="${INSTALL_DIR}/bin/llvm-ranlib" \
        LIBCC="-lclang_rt.builtins" \
        ./configure \
            --prefix=/usr \
            --target="${musl_target}"

        make install-headers DESTDIR="${sysroot}"
    )

    echo "musl headers for ${target} installed to ${sysroot}/usr/include"
}

# ─── Phase 4: Per-target musl libc ───────────────────────────────────────

build_musl() {
    local target="$1"
    echo "--- Building musl for ${target} ---"

    local sysroot="${INSTALL_DIR}/sysroot/${target}"
    mkdir -p "${sysroot}"

    # Select musl source
    local musl_dir
    if [[ "${target}" == hexagon* ]]; then
        if [ -z "$MUSL_HEXAGON_SRC" ]; then
            echo "WARNING: --musl-hexagon-src not set, skipping musl for ${target}"
            return 0
        fi
        musl_dir="${MUSL_HEXAGON_SRC}"
    else
        if [ -z "$MUSL_SRC" ]; then
            echo "WARNING: --musl-src not set, skipping musl for ${target}"
            return 0
        fi
        musl_dir="${MUSL_SRC}"
    fi

    local musl_target
    musl_target="$(musl_target_for_triple "${target}")"

    # Build in a separate directory to avoid polluting the source
    local musl_build="${BUILD_DIR}/musl-${target}"
    mkdir -p "${musl_build}"

    # Copy musl source to build dir (musl configure doesn't support out-of-tree
    # builds well for all targets)
    cp -a "${musl_dir}/." "${musl_build}/src/"

    local extra_cflags=""
    if [[ "${target}" == hexagon* ]]; then
        extra_cflags="-G0 -O0 -mv68 -fno-builtin -mlong-calls"
        extra_cflags="${extra_cflags} -Wno-switch-bool -Wno-unsupported-floating-point-opt"
    fi

    (
        cd "${musl_build}/src"
        make clean 2>/dev/null || true

        CC="${INSTALL_DIR}/bin/clang --target=${target} ${extra_cflags}" \
        AR="${INSTALL_DIR}/bin/llvm-ar" \
        RANLIB="${INSTALL_DIR}/bin/llvm-ranlib" \
        LIBCC="-lclang_rt.builtins" \
        ./configure \
            --prefix=/usr \
            --target="${musl_target}" \
            --disable-shared \
            --enable-static

        make -j"$(nproc)"
        DESTDIR="${sysroot}" make install
    )

    echo "musl for ${target} installed to ${sysroot}/usr"
}

# ─── Phase 5: Per-target runtimes ─────────────────────────────────────────

build_runtimes() {
    local target="$1"
    echo "--- Building runtimes for ${target} ---"

    local sysroot="${INSTALL_DIR}/sysroot/${target}"

    cmake -G Ninja \
        -C "${SCRIPT_DIR}/cmake/caches/multiarch-runtimes.cmake" \
        -DCMAKE_INSTALL_PREFIX="${sysroot}/usr" \
        -DCMAKE_C_COMPILER="${INSTALL_DIR}/bin/clang" \
        -DCMAKE_CXX_COMPILER="${INSTALL_DIR}/bin/clang++" \
        -DCMAKE_ASM_COMPILER="${INSTALL_DIR}/bin/clang" \
        -DCMAKE_C_COMPILER_TARGET="${target}" \
        -DCMAKE_CXX_COMPILER_TARGET="${target}" \
        -DCMAKE_ASM_COMPILER_TARGET="${target}" \
        -DCMAKE_SYSROOT="${sysroot}" \
        -DLLVM_CMAKE_DIR="${LLVM_SRC}/llvm/cmake/modules" \
        -B "${BUILD_DIR}/runtimes-${target}" \
        -S "${LLVM_SRC}/runtimes"

    cmake --build "${BUILD_DIR}/runtimes-${target}" --target install

    echo "Runtimes for ${target} installed to ${sysroot}/usr"
}

# ─── Phase 6: Driver config files + symlinks ─────────────────────────────

create_config_files() {
    local target="$1"
    echo "--- Creating config for ${target} ---"

    # ELD only supports Hexagon; other targets use LLD
    local linker
    if [[ "${target}" == hexagon* ]]; then
        linker="eld"
    else
        linker="lld"
    fi

    local cfg="${INSTALL_DIR}/bin/${target}.cfg"
    cat > "${cfg}" <<EOF
--sysroot=<CFGDIR>/../sysroot/${target}
-fuse-ld=${linker}
EOF

    echo "Created ${cfg}"
}

create_symlinks() {
    local target="$1"
    local bindir="${INSTALL_DIR}/bin"

    echo "--- Creating symlinks for ${target} ---"

    # Hexagon driver uses -lclang_rt.builtins-hexagon (old-style naming),
    # so create a relative symlink in the sysroot where the linker searches.
    if [[ "${target}" == hexagon* ]]; then
        local hex_syslib="${INSTALL_DIR}/sysroot/${target}/usr/lib"
        local hex_builtins="${CLANG_RESOURCE_DIR}/lib/${target}/libclang_rt.builtins.a"
        if [ -f "${hex_builtins}" ]; then
            ln -sfr "${hex_builtins}" "${hex_syslib}/libclang_rt.builtins-hexagon.a"
            echo "  Created builtins symlink for Hexagon driver"
        fi
    fi

    # Clang driver symlinks
    ln -sf clang   "${bindir}/${target}-clang"
    ln -sf clang++ "${bindir}/${target}-clang++"

    # LLVM tools
    local tools=(llvm-ar llvm-ranlib llvm-objdump llvm-strip llvm-size llvm-nm llvm-readelf llvm-objcopy)
    local short=(ar ranlib objdump strip size nm readelf objcopy)

    for i in "${!tools[@]}"; do
        ln -sf "${tools[$i]}" "${bindir}/${target}-${short[$i]}"
    done

    echo "Symlinks created for ${target}"
}

# ─── Phase 9: Baremetal targets (picolibc) ───────────────────────────────

# Map a Linux target triple to its corresponding baremetal triple
baremetal_triple_for() {
    local target="$1"
    case "${target}" in
        hexagon*)  echo "hexagon-unknown-none-elf" ;;
        arm*)      echo "arm-none-eabi" ;;
        aarch64*)  echo "aarch64-none-elf" ;;
        riscv32*)  echo "riscv32-unknown-elf" ;;
        riscv64*)  echo "riscv64-unknown-elf" ;;
        *)         echo "unknown-none-elf"; return 1 ;;
    esac
}

# Map a baremetal triple to meson cpu_family
meson_cpu_family_for() {
    local bm="$1"
    case "${bm}" in
        hexagon*)  echo "hexagon" ;;
        arm*)      echo "arm" ;;
        aarch64*)  echo "aarch64" ;;
        riscv32*)  echo "riscv32" ;;
        riscv64*)  echo "riscv64" ;;
        *)         echo "unknown" ;;
    esac
}

# Extra C flags for each baremetal target (appended to --target and -nostdlib)
baremetal_c_flags_for() {
    local bm="$1"
    case "${bm}" in
        hexagon*)  echo "'-mv68', '-G0', '-fno-pic', '-fuse-init-array'" ;;
        arm*)      echo "'-march=armv7-a', '-mfloat-abi=hard', '-mfpu=vfpv3-d16'" ;;
        aarch64*)  echo "" ;;
        riscv32*)  echo "'-march=rv32imafdc', '-mabi=ilp32d'" ;;
        riscv64*)  echo "'-march=rv64imafdc', '-mabi=lp64d', '-mcmodel=medany'" ;;
        *)         echo "" ;;
    esac
}

build_baremetal_builtins() {
    local bm_target="$1"
    echo "--- Building builtins for ${bm_target} ---"

    local cmake_args=(
        -G Ninja
        -DCMAKE_SYSTEM_NAME=Generic
        -C "${SCRIPT_DIR}/cmake/caches/multiarch-builtins.cmake"
        -DCMAKE_INSTALL_PREFIX="${INSTALL_DIR}"
        -DCOMPILER_RT_INSTALL_PATH="${CLANG_RESOURCE_DIR}"
        -DCMAKE_C_COMPILER="${INSTALL_DIR}/bin/clang"
        -DCMAKE_CXX_COMPILER="${INSTALL_DIR}/bin/clang++"
        -DCMAKE_ASM_COMPILER="${INSTALL_DIR}/bin/clang"
        -DCMAKE_C_COMPILER_TARGET="${bm_target}"
        -DCMAKE_CXX_COMPILER_TARGET="${bm_target}"
        -DCMAKE_ASM_COMPILER_TARGET="${bm_target}"
        -DCOMPILER_RT_BAREMETAL_BUILD=ON
        -DLLVM_CMAKE_DIR="${LLVM_SRC}/llvm/cmake/modules"
        -B "${BUILD_DIR}/builtins-${bm_target}"
        -S "${LLVM_SRC}/compiler-rt"
    )

    case "${bm_target}" in
        hexagon*)
            cmake_args+=(
                "-DCMAKE_C_FLAGS=-G0 -mlong-calls -fno-pic"
                "-DCMAKE_ASM_FLAGS=-G0 -mlong-calls -fno-pic"
                -DCOMPILER_RT_BUILTINS_ENABLE_PIC=OFF
            ) ;;
        arm*)
            cmake_args+=(
                "-DCMAKE_C_FLAGS=-march=armv7-a -mfloat-abi=hard -mfpu=vfpv3-d16"
                "-DCMAKE_ASM_FLAGS=-march=armv7-a -mfloat-abi=hard -mfpu=vfpv3-d16"
            ) ;;
        riscv32*)
            cmake_args+=(
                "-DCMAKE_C_FLAGS=-march=rv32imafdc -mabi=ilp32d"
                "-DCMAKE_ASM_FLAGS=-march=rv32imafdc -mabi=ilp32d"
            ) ;;
        riscv64*)
            cmake_args+=(
                "-DCMAKE_C_FLAGS=-march=rv64imafdc -mabi=lp64d -mcmodel=medany"
                "-DCMAKE_ASM_FLAGS=-march=rv64imafdc -mabi=lp64d -mcmodel=medany"
            ) ;;
    esac

    cmake "${cmake_args[@]}"
    cmake --build "${BUILD_DIR}/builtins-${bm_target}" --target install

    echo "Builtins for ${bm_target} installed."
}

build_picolibc() {
    local bm_target="$1"
    local cpu_family
    cpu_family="$(meson_cpu_family_for "${bm_target}")"

    echo "--- Building picolibc for ${bm_target} ---"

    local sysroot="${INSTALL_DIR}/sysroot/${bm_target}"
    mkdir -p "${sysroot}"

    # Build the c_args list for the meson cross-file
    local extra_flags
    extra_flags="$(baremetal_c_flags_for "${bm_target}")"

    local c_args="'--target=${bm_target}', '-nostdlib'"
    if [ -n "${extra_flags}" ]; then
        c_args="${c_args}, ${extra_flags}"
    fi

    local c_link_args="'-nostdlib'"
    # picolibc's meson.build only accepts bfd/gold/lld — always use lld here.
    # The final driver config file will select the correct linker for users.
    local c_ld="'lld'"

    # Generate meson cross-file
    local crossfile="${BUILD_DIR}/picolibc-cross-${bm_target}.txt"
    cat > "${crossfile}" <<CROSSEOF
[binaries]
c = ['${INSTALL_DIR}/bin/clang', ${c_args}]
ar = '${INSTALL_DIR}/bin/llvm-ar'
as = ['${INSTALL_DIR}/bin/clang', ${c_args}]
nm = '${INSTALL_DIR}/bin/llvm-nm'
strip = '${INSTALL_DIR}/bin/llvm-strip'
c_ld = ${c_ld}

[host_machine]
system = 'none'
cpu_family = '${cpu_family}'
cpu = '${cpu_family}'
endian = 'little'

[properties]
skip_sanity_check = true
librt = '-lclang_rt.builtins'
CROSSEOF

    # Configure picolibc with meson
    local picolibc_build="${BUILD_DIR}/picolibc-${bm_target}"
    meson setup "${picolibc_build}" "${PICOLIBC_SRC}" \
        --cross-file "${crossfile}" \
        --prefix=/usr \
        -Dmultilib=false \
        -Dpicocrt=true \
        -Dsemihost=false \
        -Dspecsdir=none \
        -Dtests=false \
        -Dsystem-libc=true \
        -Dincludedir=include \
        -Dlibdir=lib

    ninja -C "${picolibc_build}"

    DESTDIR="${sysroot}" ninja -C "${picolibc_build}" install

    echo "picolibc for ${bm_target} installed to ${sysroot}"
}

create_baremetal_config() {
    local bm_target="$1"
    echo "--- Creating baremetal config for ${bm_target} ---"

    # ELD only supports Hexagon; other targets use LLD
    local linker
    if [[ "${bm_target}" == hexagon* ]]; then
        linker="eld"
    else
        linker="lld"
    fi

    local cfg="${INSTALL_DIR}/bin/${bm_target}.cfg"
    {
        echo "--sysroot=<CFGDIR>/../sysroot/${bm_target}"
        echo "-fuse-ld=${linker}"
        # Hexagon: -G0 avoids global .CONST_* constant pool symbols
        if [[ "${bm_target}" == hexagon* ]]; then
            echo "-G0"
        fi
    } > "${cfg}"

    echo "Created ${cfg}"

    # Symlinks
    local bindir="${INSTALL_DIR}/bin"
    ln -sf clang   "${bindir}/${bm_target}-clang"
    ln -sf clang++ "${bindir}/${bm_target}-clang++"

    local tools=(llvm-ar llvm-ranlib llvm-objdump llvm-strip llvm-size llvm-nm llvm-readelf llvm-objcopy)
    local short=(ar ranlib objdump strip size nm readelf objcopy)
    for i in "${!tools[@]}"; do
        ln -sf "${tools[$i]}" "${bindir}/${bm_target}-${short[$i]}"
    done

    echo "Symlinks created for ${bm_target}"
}

# ─── Phase 7: Smoke tests ────────────────────────────────────────────────

smoke_test() {
    local target="$1"
    echo "--- Smoke test for ${target} ---"

    local qemu_bin
    qemu_bin="$(qemu_bin_for_target "${target}")"
    if ! command -v "${qemu_bin}" >/dev/null 2>&1; then
        echo "WARNING: ${qemu_bin} not found, skipping smoke test for ${target}"
        return 0
    fi

    local sysroot="${INSTALL_DIR}/sysroot/${target}"
    local tmpdir="${BUILD_DIR}/smoke-${target}"
    mkdir -p "${tmpdir}"

    # C test
    cat > "${tmpdir}/hello.c" <<'CEOF'
#include <stdio.h>
int main(void) {
    printf("Hello from %s (C)\n", __FILE__);
    return 0;
}
CEOF

    local qemu_extra_args=""
    if [[ "${target}" == hexagon* ]]; then
        qemu_extra_args="-cpu v68"
    fi

    echo "  Compiling hello.c for ${target}..."
    if ! "${INSTALL_DIR}/bin/clang" --target="${target}" -static \
        -o "${tmpdir}/hello" "${tmpdir}/hello.c" 2>&1; then
        echo "  FAILED: compile hello.c for ${target}"
        return 1
    fi

    echo "  Running hello via ${qemu_bin}..."
    if ! "${qemu_bin}" ${qemu_extra_args} -L "${sysroot}" "${tmpdir}/hello"; then
        echo "  FAILED: run hello for ${target}"
        return 1
    fi

    # C++ test
    cat > "${tmpdir}/hello.cpp" <<'CPPEOF'
#include <iostream>
#include <string>
int main() {
    std::string arch = __FILE__;
    std::cout << "Hello from " << arch << " (C++)" << std::endl;
    return 0;
}
CPPEOF

    echo "  Compiling hello.cpp for ${target}..."
    if ! "${INSTALL_DIR}/bin/clang++" --target="${target}" -static \
        -o "${tmpdir}/hello_cpp" "${tmpdir}/hello.cpp" 2>&1; then
        echo "  FAILED: compile hello.cpp for ${target}"
        return 1
    fi

    echo "  Running hello_cpp via ${qemu_bin}..."
    if ! "${qemu_bin}" ${qemu_extra_args} -L "${sysroot}" "${tmpdir}/hello_cpp"; then
        echo "  FAILED: run hello_cpp for ${target}"
        return 1
    fi

    echo "  Smoke test PASSED for ${target}"
}

# ─── Phase 8: llvm-test-suite ─────────────────────────────────────────────

run_test_suite() {
    local target="$1"
    local cache_file="$2"

    local flavor
    flavor="$(basename "${cache_file}" .cmake)"

    echo "--- Test suite: ${target} / ${flavor} ---"

    if [ -z "$TEST_SUITE_SRC" ]; then
        echo "WARNING: --test-suite-src not set, skipping test-suite"
        return 0
    fi

    local qemu_bin
    qemu_bin="$(qemu_bin_for_target "${target}")"
    if ! command -v "${qemu_bin}" >/dev/null 2>&1; then
        echo "WARNING: ${qemu_bin} not found, skipping test-suite for ${target}"
        return 0
    fi

    local sysroot="${INSTALL_DIR}/sysroot/${target}"
    local suite_build="${BUILD_DIR}/test-suite-${target}-${flavor}"
    local results_dir="${BUILD_DIR}/results"
    mkdir -p "${results_dir}"

    # Create QEMU wrapper script
    local wrapper="${BUILD_DIR}/qemu-wrapper-${target}.sh"
    local qemu_extra_args=""
    # System qemu-hexagon (Debian 6.2) can't auto-detect CPU from ELF flags;
    # pass -cpu v68 explicitly to match the v68 target we build for.
    if [[ "${target}" == hexagon* ]]; then
        qemu_extra_args="-cpu v68"
    fi
    cat > "${wrapper}" <<WRAPPER
#!/bin/bash
exec ${qemu_bin} ${qemu_extra_args} -L ${sysroot} "\$@"
WRAPPER
    chmod +x "${wrapper}"

    cmake -G Ninja \
        -DCMAKE_C_COMPILER="${INSTALL_DIR}/bin/clang" \
        -DCMAKE_CXX_COMPILER="${INSTALL_DIR}/bin/clang++" \
        -DCMAKE_C_COMPILER_TARGET="${target}" \
        -DCMAKE_CXX_COMPILER_TARGET="${target}" \
        -DCMAKE_SYSROOT="${sysroot}" \
        -DTEST_SUITE_USER_MODE_EMULATION=ON \
        -DTEST_SUITE_RUN_UNDER="${wrapper}" \
        -DTEST_SUITE_SUBDIRS="SingleSource;MultiSource" \
        -C "${cache_file}" \
        -B "${suite_build}" \
        -S "${TEST_SUITE_SRC}"

    cmake --build "${suite_build}" -- -k 0

    # Run tests with lit
    local lit_bin="${BUILD_DIR}/host/bin/llvm-lit"
    if [ ! -f "${lit_bin}" ]; then
        lit_bin="$(command -v llvm-lit 2>/dev/null || true)"
    fi

    if [ -n "${lit_bin}" ] && [ -f "${lit_bin}" ]; then
        python3 "${lit_bin}" \
            -v --timeout=600 \
            -o "${results_dir}/test-${target}-${flavor}.json" \
            "${suite_build}"
    else
        echo "WARNING: llvm-lit not found, skipping lit execution"
    fi

    echo "Test suite results: ${results_dir}/test-${target}-${flavor}.json"
}

# ─── Main Build Flow ─────────────────────────────────────────────────────

# Phase 1: Host tools (prebuilt or from-source)
if [ -n "${HOST_TOOLCHAIN}" ]; then
    install_prebuilt_host_tools
else
    build_host_tools
fi

# Ensure the just-built clang can find its shared libraries (libLLVM, libclang-cpp)
export LD_LIBRARY_PATH="${INSTALL_DIR}/lib${LD_LIBRARY_PATH:+:${LD_LIBRARY_PATH}}"

# Detect the clang resource directory (e.g., lib/clang/23) for compiler-rt install
CLANG_RESOURCE_DIR="$("${INSTALL_DIR}/bin/clang" --print-resource-dir)"
echo "Clang resource dir: ${CLANG_RESOURCE_DIR}"

if [ "$SKIP_RUNTIMES" -eq 0 ]; then
    # Phase 2: Kernel headers + musl headers (needed before builtins)
    log_phase 2 "Per-target kernel headers + musl headers"
    for target in "${TARGET_ARRAY[@]}"; do
        install_kernel_headers "${target}"
        install_musl_headers "${target}"
    done

    # Phase 3: Builtins (requires headers from Phase 2)
    log_phase 3 "Per-target compiler-rt builtins"
    for target in "${TARGET_ARRAY[@]}"; do
        build_builtins "${target}"
    done

    # Phase 4: Full musl libc (requires builtins from Phase 3)
    log_phase 4 "Per-target musl libc"
    for target in "${TARGET_ARRAY[@]}"; do
        build_musl "${target}"
    done

    # Phase 5: Runtimes (requires musl from Phase 4)
    log_phase 5 "Per-target runtimes (libc++, libc++abi, libunwind, compiler-rt)"
    for target in "${TARGET_ARRAY[@]}"; do
        build_runtimes "${target}"
    done
fi

# Phase 6: Config files and symlinks
log_phase 6 "Driver config files + symlinks"
for target in "${TARGET_ARRAY[@]}"; do
    create_config_files "${target}"
    create_symlinks "${target}"
done

if [ "$SKIP_TESTS" -eq 0 ]; then
    # Phase 7: Smoke tests
    log_phase 7 "Smoke tests"
    smoke_failed=0
    for target in "${TARGET_ARRAY[@]}"; do
        if ! smoke_test "${target}"; then
            ((smoke_failed++)) || true
        fi
    done
    echo ""
    echo "Smoke test summary: ${#TARGET_ARRAY[@]} targets, ${smoke_failed} failed"

    # Phase 8: Test suite (all targets run concurrently)
    if [ "${#CACHE_FILES[@]}" -gt 0 ] && [ -n "$TEST_SUITE_SRC" ]; then
        log_phase 8 "llvm-test-suite"
        ts_results="${BUILD_DIR}/results"
        mkdir -p "${ts_results}"
        ts_pids=()
        ts_labels=()
        ts_logs=()
        set +e
        for target in "${TARGET_ARRAY[@]}"; do
            for cache in "${CACHE_FILES[@]}"; do
                if cache_matches_target "${target}" "${cache}"; then
                    flavor="$(basename "${cache}" .cmake)"
                    logfile="${ts_results}/${target}-${flavor}.log"
                    echo "Starting test suite: ${target} / ${flavor}"
                    run_test_suite "${target}" "${cache}" > "${logfile}" 2>&1 &
                    ts_pids+=($!)
                    ts_labels+=("${target} / ${flavor}")
                    ts_logs+=("${logfile}")
                fi
            done
        done
        echo "Launched ${#ts_pids[@]} test-suite runs in parallel, waiting..."
        ts_failed=0
        for i in "${!ts_pids[@]}"; do
            if wait "${ts_pids[$i]}"; then
                echo "  DONE: ${ts_labels[$i]}"
            else
                echo "  FAIL: ${ts_labels[$i]} (exit $?)"
                ((ts_failed++)) || true
            fi
        done
        echo ""
        echo "Test suite summary: ${#ts_pids[@]} runs, ${ts_failed} failed"
        for i in "${!ts_logs[@]}"; do
            echo "--- ${ts_labels[$i]} ---"
            grep -E "^(Testing Time|Total Discovered|  Passed|  Failed|  Executable Missing)" "${ts_logs[$i]}" 2>/dev/null || echo "  (no summary found)"
        done
        set -e
    fi
fi

# Phase 9: Baremetal targets with picolibc
if [ -n "${PICOLIBC_SRC}" ]; then
    log_phase 9 "Baremetal targets (picolibc)"
    for target in "${TARGET_ARRAY[@]}"; do
        bm_target="$(baremetal_triple_for "${target}")"
        build_baremetal_builtins "${bm_target}"
        build_picolibc "${bm_target}"
        create_baremetal_config "${bm_target}"
    done
fi

# ─── Write build manifest ─────────────────────────────────────────────────

# Auto-detect LLVM ref from git if not provided via --llvm-ref
if [ -z "${LLVM_REF:-}" ]; then
    if [ -n "${LLVM_SRC}" ] && git -C "${LLVM_SRC}" rev-parse HEAD >/dev/null 2>&1; then
        LLVM_REF="$(git -C "${LLVM_SRC}" rev-parse HEAD)"
    else
        LLVM_REF="unknown"
    fi
fi

cat > "${INSTALL_DIR}/BUILD_MANIFEST" <<MANIFEST
llvm_project_ref=${LLVM_REF}
targets=${TARGETS}
build_date=$(date -u +%Y-%m-%dT%H:%M:%SZ)
build_host=$(hostname)
MANIFEST
echo "Build manifest written to ${INSTALL_DIR}/BUILD_MANIFEST"

echo ""
echo "=== Build Complete ==="
echo "Toolchain installed to: ${INSTALL_DIR}"
echo ""
echo "Installed targets:"
for target in "${TARGET_ARRAY[@]}"; do
    echo "  ${target}"
    if [ -d "${INSTALL_DIR}/sysroot/${target}" ]; then
        echo "    sysroot: ${INSTALL_DIR}/sysroot/${target}"
    fi
    if [ -f "${INSTALL_DIR}/bin/${target}.cfg" ]; then
        echo "    config:  ${INSTALL_DIR}/bin/${target}.cfg"
    fi
done
if [ -n "${PICOLIBC_SRC}" ]; then
    echo ""
    echo "Baremetal targets (picolibc):"
    for target in "${TARGET_ARRAY[@]}"; do
        bm_target="$(baremetal_triple_for "${target}")"
        echo "  ${bm_target}"
        if [ -d "${INSTALL_DIR}/sysroot/${bm_target}" ]; then
            echo "    sysroot: ${INSTALL_DIR}/sysroot/${bm_target}"
        fi
        if [ -f "${INSTALL_DIR}/bin/${bm_target}.cfg" ]; then
            echo "    config:  ${INSTALL_DIR}/bin/${bm_target}.cfg"
        fi
    done
fi
echo ""
echo "Usage:  ${INSTALL_DIR}/bin/clang --target=<triple> -static -o hello hello.c"
echo "Date:   $(date)"
