# Host tools: LLVM + Clang for Hexagon cross-compilation
#
# Usage:
#   cmake -G Ninja -C hexagon-stage0.cmake -C hexagon-stage0-cross.cmake ...
#   cmake --build . --target install-distribution
#
# For zig cross-builds, add -C hexagon-stage0-dylib.cmake

set(LLVM_TARGETS_TO_BUILD "Hexagon" CACHE STRING "")
set(LLVM_ENABLE_PROJECTS "clang;lld" CACHE STRING "")
set(CMAKE_BUILD_TYPE Release CACHE STRING "")
set(LLVM_ENABLE_PIC ON CACHE BOOL "")

# ELD constraint: libLW.so conflicts with libLLVM.so
set(LLVM_BUILD_LLVM_DYLIB OFF CACHE BOOL "")
set(LLVM_LINK_LLVM_DYLIB OFF CACHE BOOL "")
set(LLVM_VERSION_SUFFIX "" CACHE STRING "")

# ld.eld needs libLW.so at runtime
set(CMAKE_INSTALL_RPATH "$ORIGIN/../lib" CACHE STRING "")

# Clang defaults for Hexagon
set(LLVM_DEFAULT_TARGET_TRIPLE "hexagon-unknown-linux-musl" CACHE STRING "")
set(CLANG_DEFAULT_CXX_STDLIB "libc++" CACHE STRING "")
set(CLANG_DEFAULT_RTLIB "compiler-rt" CACHE STRING "")
set(CLANG_DEFAULT_UNWINDLIB "libunwind" CACHE STRING "")
set(CLANG_DEFAULT_LINKER "lld" CACHE STRING "")
set(CLANG_DEFAULT_OBJCOPY "llvm-objcopy" CACHE STRING "")

# Trim
set(LLVM_INSTALL_TOOLCHAIN_ONLY ON CACHE BOOL "")
set(LLVM_INCLUDE_TESTS OFF CACHE BOOL "")
set(LLVM_INCLUDE_DOCS OFF CACHE BOOL "")
set(LLVM_ENABLE_ZLIB ON CACHE BOOL "")
set(LLVM_ENABLE_ZSTD ON CACHE BOOL "")

# Distribution components — installed via `--target install-distribution`
set(LLVM_TOOLCHAIN_TOOLS
  llvm-ar
  llvm-config
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
  lld
  LTO
  ${LLVM_TOOLCHAIN_TOOLS}
  CACHE STRING "")
