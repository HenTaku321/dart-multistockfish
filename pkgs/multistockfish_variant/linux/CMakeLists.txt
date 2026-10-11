# Linux desktop build of the Fairy-Stockfish flavour.
#
# This mirrors android/CMakeLists.txt, with the differences the platform
# forces:
#
#   - the Android-only 16k-page-size link option is gone (it is a linker flag
#     for Android 15's page size, meaningless on the desktop), and with it the
#     `if (ANDROID)` wrapper;
#   - the compile flags are the non-arm64 ones, plus the x86_64 baseline the
#     Android file also sets: -DIS_64BIT and -DUSE_POPCNT. Nothing newer. A
#     -DUSE_AVX2 build would run several percent faster and SIGILL on any CPU
#     older than Haswell (2013), and this library ships inside a package that
#     is installed on other people's machines, so the baseline wins. The
#     Android x86_64 branch makes the same choice. A v3 microarchitecture
#     build can be a separate package for whoever wants one;
#   - the library is handed to the Flutter tooling at the end, which is how a
#     Linux FFI plugin is wired: the app's linux/flutter/generated_plugins.cmake
#     adds this directory through add_subdirectory() and reads the
#     `<package>_bundled_libraries` variable, then installs the file it names
#     into the bundle's lib/ next to the executable.
#
# The Flutter tooling requires that developers have CMake 3.10 or later
# installed. You should not increase this version, as doing so will cause
# the plugin to fail to compile for some customers of the plugin.
cmake_minimum_required(VERSION 3.10)

project(multistockfish_variant_library VERSION 0.1.0 LANGUAGES CXX)

file(GLOB_RECURSE cppPaths "../ios/multistockfish_variant/Sources/multistockfish_variant/Fairy-Stockfish-2b5d9512/src/*.cpp")

list(FILTER cppPaths EXCLUDE REGEX "(pyffish|ffishjs).cpp")

add_library(
  multistockfish_variant
  SHARED
  ../ios/multistockfish_variant/Sources/multistockfish_variant/stockfish_variant.cpp
  ../ios/multistockfish_variant/Sources/multistockfish_variant/sfio.cpp
  ${cppPaths}
)

set_target_properties(multistockfish_variant PROPERTIES
  PUBLIC_HEADER multistockfish_variant.h
  OUTPUT_NAME "multistockfish_variant"
)

target_compile_definitions(multistockfish_variant PUBLIC DART_SHARED_LIB)

# The engine starts its threads with std::thread, which on glibc before 2.34
# lives in a separate libpthread. Asking for Threads::Threads costs nothing on
# a newer glibc and keeps the library linkable on an older one.
find_package(Threads REQUIRED)
target_link_libraries(multistockfish_variant PRIVATE Threads::Threads)

if (CMAKE_BUILD_TYPE STREQUAL "Debug")
  target_compile_options(multistockfish_variant PRIVATE -std=c++17 -DNNUE_EMBEDDING_OFF -DUSE_PTHREADS -DIS_64BIT -DUSE_POPCNT)
else()
  target_compile_options(multistockfish_variant PRIVATE -std=c++17 -fno-exceptions -DNNUE_EMBEDDING_OFF -DUSE_PTHREADS -DNDEBUG -O3 -DIS_64BIT -DUSE_POPCNT)
endif()

# Hand the shared library to the Flutter tooling. The variable name is the
# package name with `_bundled_libraries` appended, which is what
# linux/flutter/generated_plugins.cmake reads for every entry of
# FLUTTER_FFI_PLUGIN_LIST.
set(multistockfish_variant_bundled_libraries
  $<TARGET_FILE:multistockfish_variant>
  PARENT_SCOPE
)
