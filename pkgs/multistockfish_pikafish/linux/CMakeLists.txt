# Linux desktop build of the Pikafish flavour.
#
# This mirrors android/CMakeLists.txt, with the differences the platform
# forces:
#
#   - the Android-only 16k-page-size link option is gone, and with it the
#     `if(ANDROID_ABI ...)` wrapper: Linux desktop is x86_64 only, so there is
#     one flag set rather than two;
#   - nothing newer than the x86_64 baseline is enabled. Pikafish's own Makefile
#     would add -march=native (AVX2, BMI2, ...) on an x86-64 host, and this
#     library ships inside a package that is installed on other people's
#     machines, where a Haswell-era instruction is a SIGILL on startup. Same
#     choice as the other three flavours; a v3 build can be a separate package;
#   - the library is handed to the Flutter tooling at the end, which is how a
#     Linux FFI plugin is wired: the app's linux/flutter/generated_plugins.cmake
#     adds this directory through add_subdirectory() and reads the
#     `<package>_bundled_libraries` variable, then installs the file it names
#     into the bundle's lib/ next to the executable.
#
# The net is not built in and not downloaded here. Pikafish has no embedding
# mechanism at all: it loads `pikafish.nnue` from the binary directory or from
# whatever `setoption name EvalFile value <path>` says, and the app bundles the
# file and passes the path (see the app's assets/pikafish/).
#
# The Flutter tooling requires that developers have CMake 3.10 or later
# installed. You should not increase this version, as doing so will cause
# the plugin to fail to compile for some customers of the plugin.
cmake_minimum_required(VERSION 3.10)

project(multistockfish_pikafish_library VERSION 0.1.0 LANGUAGES CXX)

file(GLOB_RECURSE cppPaths "../ios/multistockfish_pikafish/Sources/multistockfish_pikafish/Pikafish-532c3ff216/src/*.cpp")

# src/main.cpp defines the process's `main`. The plugin has its own entry points
# and an app that links this library already has a `main` of its own, so this
# file must not be compiled. Everything else under src/ is wanted, including
# src/external/ (zstd): Pikafish's network file is zstd-compressed and this is
# the decompressor it arrives with.
list(FILTER cppPaths EXCLUDE REGEX "/src/main\\.cpp$")

add_library(
  multistockfish_pikafish
  SHARED
  ../ios/multistockfish_pikafish/Sources/multistockfish_pikafish/stockfish_pikafish.cpp
  ../ios/multistockfish_pikafish/Sources/multistockfish_pikafish/sfio.cpp
  ${cppPaths}
)

set_target_properties(multistockfish_pikafish PROPERTIES
  PUBLIC_HEADER multistockfish_pikafish.h
  OUTPUT_NAME "multistockfish_pikafish"
)

target_compile_definitions(multistockfish_pikafish PUBLIC DART_SHARED_LIB)

# Not an optimisation -- a clang build does not finish without it. Pikafish
# builds its NNUE feature-set lookup tables in constexpr lambdas, and clang's
# default constexpr step budget (1,048,576) is not enough for the 90x90x2 table
# in nnue/features/half_ka_v2_hm.h: clang reports "constexpr evaluation hit
# maximum step limit" and fails the file. GCC needs no equivalent flag -- its
# floor for the same work is far higher -- and would reject this one, since it
# has no such option, so it is gated on the compiler rather than on the
# platform. It is a ceiling rather than a cost, so it is set well clear of the
# ~2M steps this tree needs instead of just above it.
if (CMAKE_CXX_COMPILER_ID MATCHES "Clang")
  target_compile_options(multistockfish_pikafish PRIVATE -fconstexpr-steps=10000000)
endif()

# zstd's BMI2 decompression loops live in external/decompress/huf_decompress_amd64.S,
# which upstream's Makefile assembles and this file deliberately does not compile.
# This platform is the one where that matters most: a Linux desktop build is
# x86-64 ELF, so huf_decompress.cpp references those loops and the link fails
# without them. Assembling the file instead would mean teaching four build
# systems the ASM language (CMake silently drops `.S` sources unless ASM is
# enabled for the project) and would still not work on Mach-O, where the file is
# empty under its own `#if defined(__ELF__)` guard while the reference is live.
# ZSTD_DISABLE_ASM turns both sides off. The cost is that the network file is
# decompressed by zstd's C loop rather than the assembly one, which is what every
# arm64 build already does; it happens once, when the net is loaded, so the
# difference is not measurable next to the search that follows it.
target_compile_options(multistockfish_pikafish PRIVATE -DZSTD_DISABLE_ASM)

# lives in a separate libpthread. Asking for Threads::Threads costs nothing on
# a newer glibc and keeps the library linkable on an older one.
find_package(Threads REQUIRED)
target_link_libraries(multistockfish_pikafish PRIVATE Threads::Threads)

# See android/CMakeLists.txt for why -DNNUE_EMBEDDING_OFF and -DUSE_PTHREADS are
# absent: Pikafish has neither feature, so neither macro means anything here.
if (CMAKE_BUILD_TYPE STREQUAL "Debug")
  target_compile_options(multistockfish_pikafish PRIVATE -std=c++17 -DIS_64BIT -DUSE_POPCNT)
else()
  target_compile_options(multistockfish_pikafish PRIVATE -std=c++17 -fno-exceptions -DNDEBUG -funroll-loops -O3 -DIS_64BIT -DUSE_POPCNT)
endif()

# Hand the shared library to the Flutter tooling. The variable name is the
# package name with `_bundled_libraries` appended, which is what
# linux/flutter/generated_plugins.cmake reads for every entry of
# FLUTTER_FFI_PLUGIN_LIST.
set(multistockfish_pikafish_bundled_libraries
  $<TARGET_FILE:multistockfish_pikafish>
  PARENT_SCOPE
)
