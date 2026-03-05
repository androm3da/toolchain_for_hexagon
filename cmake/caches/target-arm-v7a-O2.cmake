set(CMAKE_C_FLAGS_RELEASE "-march=armv7-a -mfpu=vfpv3-d16 -mfloat-abi=hard -O2" CACHE STRING "")
set(CMAKE_CXX_FLAGS_RELEASE "-march=armv7-a -mfpu=vfpv3-d16 -mfloat-abi=hard -O2" CACHE STRING "")
set(CMAKE_EXE_LINKER_FLAGS "-static" CACHE STRING "")
set(CMAKE_BUILD_TYPE "Release" CACHE STRING "")
