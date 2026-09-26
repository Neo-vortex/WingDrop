cmake_minimum_required(VERSION 3.22.1)
project(wingdrop LANGUAGES C CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

add_library(vortexengine SHARED
        jni.cpp
        engine.cpp
        vortex.cpp
        aegis.cpp
        perf.cpp
        wdlog.cpp
        bench.cpp
        media.cpp
        third_party/lz4.c
        third_party/monocypher.c
        third_party/zstd/zstd.c)

target_include_directories(vortexengine PRIVATE
        ${CMAKE_CURRENT_SOURCE_DIR}
        ${CMAKE_CURRENT_SOURCE_DIR}/third_party/ffmpeg/include)

# Prebuilt LGPL FFmpeg 8 (libavcodec 62), packaged from src/main/jniLibs.
add_library(ffmpeg SHARED IMPORTED)
set_target_properties(ffmpeg PROPERTIES
        IMPORTED_LOCATION ${CMAKE_CURRENT_SOURCE_DIR}/../jniLibs/${CMAKE_ANDROID_ARCH_ABI}/libffmpeg.so)

# Always optimise the hot path, even in debug builds: -O0 crypto/LZ4 would make
# debug transfers an order of magnitude slower than release ones.
target_compile_options(vortexengine PRIVATE -O3 -fno-exceptions -fvisibility=hidden -Wall)
if (CMAKE_ANDROID_ARCH_ABI STREQUAL "arm64-v8a")
    target_compile_options(vortexengine PRIVATE -march=armv8-a+crc+crypto)
endif ()
# ThinLTO for release builds. Not INTERPROCEDURAL_OPTIMIZATION: CMake's
# Android toolchain maps that to -fuse-ld=gold, which NDK r28+ no longer ships.
if (NOT CMAKE_BUILD_TYPE STREQUAL "Debug")
    target_compile_options(vortexengine PRIVATE -flto=thin)
    target_link_options(vortexengine PRIVATE -flto=thin -fuse-ld=lld)
endif ()

target_link_options(vortexengine PRIVATE -Wl,--gc-sections -Wl,-z,max-page-size=16384)
target_link_libraries(vortexengine ffmpeg mediandk android log)
