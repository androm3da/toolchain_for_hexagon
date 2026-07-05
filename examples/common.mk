# common.mk — Shared toolchain path variables for Hexagon examples
#
# Override TOOLCHAIN_ROOT on the command line or via environment, e.g.:
#   make TOOLCHAIN_ROOT=/path/to/clang+llvm-22.1.0-cross-hexagon-unknown-linux-musl

TOOLCHAIN_ROOT ?= /opt/clang+llvm-22.1.0-cross-hexagon-unknown-linux-musl

# Native host dir name varies with the build host's OS/version
# (e.g. x86_64-ubuntu-22.04) to avoid colliding with cross-triple
# packages named x86_64-linux-gnu / aarch64-linux-gnu.
HOST_DIR      := $(firstword $(wildcard $(TOOLCHAIN_ROOT)/x86_64-*))
BIN_DIR       := $(HOST_DIR)/bin

# Linux cross-compiler (hexagon-unknown-linux-musl)
CC_LINUX      := $(BIN_DIR)/hexagon-unknown-linux-musl-clang
CXX_LINUX     := $(BIN_DIR)/hexagon-unknown-linux-musl-clang++
SYSROOT_LINUX := $(HOST_DIR)/target/hexagon-unknown-linux-musl/usr

# Baremetal cross-compiler (hexagon-unknown-none-elf)
# The cfg file (hexagon-unknown-none-elf.cfg) is auto-discovered from BIN_DIR.
CC_BAREMETAL  := $(BIN_DIR)/hexagon-clang

# QEMU emulators
QEMU_HEXAGON  := $(BIN_DIR)/qemu-hexagon
QEMU_SYSTEM   := $(BIN_DIR)/qemu-system-hexagon

# Common flags for sanitizer demos (Linux target).
# Most sanitizer demos use -static for simplicity.  ASan and LSan require
# dynamic linking because the runtime references _DYNAMIC for interception.
LINUX_STATIC_FLAGS := -static -g -O0
LINUX_DYNAMIC_FLAGS := -g -O0
