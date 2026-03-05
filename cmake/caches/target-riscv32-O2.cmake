set(CMAKE_C_FLAGS_RELEASE "-march=rv32imafdc -mabi=ilp32d -O2" CACHE STRING "")
set(CMAKE_CXX_FLAGS_RELEASE "-march=rv32imafdc -mabi=ilp32d -O2" CACHE STRING "")
set(CMAKE_EXE_LINKER_FLAGS "-static" CACHE STRING "")
set(CMAKE_BUILD_TYPE "Release" CACHE STRING "")
