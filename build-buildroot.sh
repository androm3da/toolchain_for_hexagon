#!/bin/bash

#  Copyright (c) 2024, Qualcomm Innovation Center, Inc. All rights reserved.
#  SPDX-License-Identifier: BSD-3-Clause

set -euo pipefail

BASE=$(readlink -f ${PWD})
# Must match build-toolchain.sh's NATIVE_TRIPLE exactly.
NATIVE_TRIPLE="$(uname -p)-$(lsb_release -is | tr '[:upper:]' '[:lower:]')-$(lsb_release -rs)"

set -x
TOOLCHAIN_INSTALL_REL=${TOOLCHAIN_INSTALL}
TOOLCHAIN_INSTALL=$(readlink -f ${TOOLCHAIN_INSTALL})
TOOLCHAIN_BIN=${TOOLCHAIN_INSTALL}/${NATIVE_TRIPLE}/bin
export PATH=${TOOLCHAIN_BIN}:${PATH}

# TODO: change build to use unprivileged user
export FORCE_UNSAFE_CONFIGURE=1
export BR2_DL_DIR=$PWD/br_download/

make -C buildroot/ O=${PWD}/obj_buildroot/ qcom_dsp_qemu_defconfig
make -C obj_buildroot -j
make -C obj_buildroot legal-info
install -D ./obj_buildroot/images/* ${ARTIFACT_BASE}/${ARTIFACT_TAG}/
