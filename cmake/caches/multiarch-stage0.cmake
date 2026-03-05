# Host tools: LLVM + Clang for multi-arch cross-compilation targets
#
# Used by build-multiarch-toolchain.sh Phase 1 (only when building from source,
# i.e. when --host-toolchain is not given).
# Builds a host-native LLVM+Clang with support for Hexagon, ARM, AArch64,
# and RISC-V backends.  Linker is provided by ELD (external project).

set(LLVM_TARGETS_TO_BUILD "Hexagon;ARM;AArch64;RISCV" CACHE STRING "")
set(LLVM_ENABLE_PROJECTS "clang" CACHE STRING "")
set(CMAKE_BUILD_TYPE Release CACHE STRING "")
set(LLVM_ENABLE_PIC ON CACHE BOOL "")

# Static linking: ELD's libLW.so contains statically-linked LLVM backend code
# that conflicts with libLLVM.so (duplicate CommandLine option registration).
# Until ELD supports LLVM_LINK_LLVM_DYLIB, we must link everything statically.
set(LLVM_BUILD_LLVM_DYLIB OFF CACHE BOOL "")
set(LLVM_LINK_LLVM_DYLIB OFF CACHE BOOL "")
set(LLVM_VERSION_SUFFIX "" CACHE STRING "")

# ld.eld still needs libLW.so at runtime (ELD forces shared libLW)
set(CMAKE_INSTALL_RPATH "\$ORIGIN/../lib" CACHE STRING "")

# Distribution: toolchain-only install
set(LLVM_INSTALL_TOOLCHAIN_ONLY ON CACHE BOOL "")

# Clang defaults for musl Linux targets
set(CLANG_DEFAULT_CXX_STDLIB "libc++" CACHE STRING "")
set(CLANG_DEFAULT_RTLIB "compiler-rt" CACHE STRING "")
set(CLANG_DEFAULT_UNWINDLIB "libunwind" CACHE STRING "")
set(CLANG_DEFAULT_LINKER "eld" CACHE STRING "")
set(CLANG_DEFAULT_OBJCOPY "llvm-objcopy" CACHE STRING "")

# Trim the install
set(LLVM_INCLUDE_TESTS OFF CACHE BOOL "")
set(LLVM_INCLUDE_DOCS OFF CACHE BOOL "")
set(LLVM_ENABLE_ZLIB ON CACHE BOOL "")
set(LLVM_ENABLE_ZSTD ON CACHE BOOL "")

# Memory control (overridable from command line)
set(LLVM_PARALLEL_LINK_JOBS 8 CACHE STRING "")

# Distribution components
set(LLVM_TOOLCHAIN_TOOLS
  llvm-ar
  llvm-cov
  llvm-cxxfilt
  llvm-dwarfdump
  llvm-nm
  llvm-objcopy
  llvm-objdump
  llvm-profdata
  llvm-ranlib
  llvm-readelf
  llvm-readobj
  llvm-size
  llvm-strip
  llvm-symbolizer
  CACHE STRING "")

set(LLVM_DISTRIBUTION_COMPONENTS
  clang
  clang-resource-headers
  ld.eld
  LTO
  ${LLVM_TOOLCHAIN_TOOLS}
  CACHE STRING "")
