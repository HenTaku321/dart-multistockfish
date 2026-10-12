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

# Support Android 15 16k page size
target_link_options(multistockfish_pikafish PRIVATE "-Wl,-z,max-page-size=16384")

# Not an optimisation -- the build does not finish without it. Pikafish builds
# its NNUE feature-set lookup tables in constexpr lambdas, and clang's default
# constexpr step budget (1,048,576) is not enough for the 90x90x2 table in
# nnue/features/half_ka_v2_hm.h: clang reports "constexpr evaluation hit maximum
# step limit" and fails the file. Android always compiles with clang, so the
# flag is unconditional here. It is a ceiling rather than a cost, so it is set
# well clear of the ~2M steps this tree needs instead of just above it.
target_compile_options(multistockfish_pikafish PRIVATE -fconstexpr-steps=10000000)

# zstd's BMI2 decompression loops live in external/decompress/huf_decompress_amd64.S,
# which upstream's Makefile assembles and this file deliberately does not compile.
# On an x86-64 ELF build -- and the Android x86_64 ABI is one --
# huf_decompress.cpp references those loops and the link fails without them; but
# assembling the file means every build system has to learn the ASM language
# (CMake silently drops `.S` sources unless ASM is enabled for the project), and
# on Mach-O the file is empty under its own `#if defined(__ELF__)` guard while
# the reference is still live, so an x86-64 macOS build could not satisfy it
# either way. ZSTD_DISABLE_ASM turns both sides off. The cost is that the network
# file is decompressed by zstd's C loop rather than the assembly one, which is
# what every arm64 build already does; it happens once, when the net is loaded,
# so the difference is not measurable next to the search that follows it.
target_compile_options(multistockfish_pikafish PRIVATE -DZSTD_DISABLE_ASM)

# The compile flags are Pikafish's own, taken from its src/Makefile, and they
# are NOT the ones the other three flavours use. Two of those are missing here
# on purpose:
#
#   -DNNUE_EMBEDDING_OFF and -DUSE_PTHREADS name features Pikafish does not
#   have. It never embeds a net (the app injects one with `setoption name
#   EvalFile`), and its Makefile has no NNUE_EMBEDDING or USE_PTHREADS switch
#   at all, so defining either would be a flag that means nothing to this code.
#
# The ISA flags are the x86_64 baseline plus POPCNT, and NEON on 64-bit ARM
# with the value 8. That value is not decoration: Pikafish's nnue/simd.h tests
# `USE_NEON >= 8` to decide whether NEON is usable, so a bare `-DUSE_NEON`
# compiles and silently selects the portable path. Upstream's Makefile passes
# `-DUSE_NEON=$(arm_version)` for exactly this reason.
if(ANDROID_ABI STREQUAL arm64-v8a)
  if (CMAKE_BUILD_TYPE STREQUAL "Debug")
    target_compile_options(multistockfish_pikafish PRIVATE -std=c++17 -DIS_64BIT -DUSE_POPCNT -DUSE_NEON=8)
  else()
    target_compile_options(multistockfish_pikafish PRIVATE -std=c++17 -fno-exceptions -DNDEBUG -funroll-loops -O3 -DIS_64BIT -DUSE_POPCNT -DUSE_NEON=8)
  endif()

else()

  if (CMAKE_BUILD_TYPE STREQUAL "Debug")
    target_compile_options(multistockfish_pikafish PRIVATE -std=c++17 -DIS_64BIT -DUSE_POPCNT)
  else()
    target_compile_options(multistockfish_pikafish PRIVATE -std=c++17 -fno-exceptions -DNDEBUG -funroll-loops -O3 -DIS_64BIT -DUSE_POPCNT)
  endif()
endif()
