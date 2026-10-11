# Linux desktop build of the small-net Stockfish flavour.
#
# This mirrors android/CMakeLists.txt, with the differences the platform
# forces:
#
#   - the Android-only 16k-page-size link option is gone, and with it the
#     `if (ANDROID)` wrapper;
#   - the compile flags are the non-arm64 ones, plus the x86_64 baseline the
#     Android file also sets: -DIS_64BIT and -DUSE_POPCNT. Nothing newer; see
#     the same note in multistockfish_variant/linux/CMakeLists.txt;
#   - the embedded net is taken from the copy committed in this package rather
#     than downloaded, which is what the file(DOWNLOAD) at the bottom of the
#     Android file is for; see the note above it;
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

project(multistockfish_light_library VERSION 0.1.0 LANGUAGES CXX)

file(GLOB_RECURSE sfPaths "../ios/multistockfish_light/Sources/multistockfish_light/StockfishLight/src/*.cpp")

# src/universal/ holds the entry points and the NNUE embedding used by upstream's
# macOS universal-binary build. They are not part of a normal build: the entry_*
# files call into per-arch `StockfishLight_<arch>::main` namespaces that only
# exist in that build, and nnue_embed.cpp defines a second `gEmbeddedNNUEData`.
# Compiling either here fails to link.
list(FILTER sfPaths EXCLUDE REGEX "/StockfishLight/src/universal/")

add_library(
  multistockfish_light
  SHARED
  ../ios/multistockfish_light/Sources/multistockfish_light/stockfish_light.cpp
  ../ios/multistockfish_light/Sources/multistockfish_light/sfio.cpp
  ${sfPaths}
)

set_target_properties(multistockfish_light PROPERTIES
  PUBLIC_HEADER multistockfish_light.h
  OUTPUT_NAME "multistockfish_light"
)

target_compile_definitions(multistockfish_light PUBLIC DART_SHARED_LIB)

# The engine starts its threads with std::thread, which on glibc before 2.34
# lives in a separate libpthread. Asking for Threads::Threads costs nothing on
# a newer glibc and keeps the library linkable on an older one.
find_package(Threads REQUIRED)
target_link_libraries(multistockfish_light PRIVATE Threads::Threads)

# Unlike multistockfish_chess, this package does NOT define NNUE_EMBEDDING_OFF:
# its ~1.1MB net is compiled into the library by `INCBIN(EmbeddedNNUE, ...)` in
# nnue/network.cpp.
if (CMAKE_BUILD_TYPE STREQUAL "Debug")
  target_compile_options(multistockfish_light PRIVATE -std=c++17 -DUSE_PTHREADS -DIS_64BIT -DUSE_POPCNT)
else()
  target_compile_options(multistockfish_light PRIVATE -std=c++17 -DUSE_PTHREADS -fno-exceptions -DNDEBUG -funroll-loops -O3 -DIS_64BIT -DUSE_POPCNT)
endif()

# Where the embedded net comes from.
#
# `INCBIN(EmbeddedNNUE, EvalFileDefaultName)` in nnue/network.cpp expands to a
# `.incbin "nn-61e7af4bb97d.nnue"` inline assembly directive. The file is
# committed in this package, under
# Sources/multistockfish_light/nnue/ -- but `.incbin` names it with no
# directory, and where that lands depends on the compiler:
#
#   - clang resolves it through -I exactly like a #include, which is how the
#     iOS build does it (see the note at the end of
#     ios/multistockfish_light/Package.swift);
#   - the Android build instead relies on the assembler's working directory
#     being CMAKE_BINARY_DIR, which is why its file(DOWNLOAD) writes the net
#     there -- a network fetch at configure time for a file the repository
#     already holds.
#
# Both routes are set up below: the include directory for the first, a copy
# into this directory's build tree for the second. Whichever clang uses, the
# bytes are the committed ones, verified by hash here so that a build cannot
# quietly embed something else. The hash is the one the Android download
# verifies against, so the two paths cannot drift apart unnoticed.
set(light_nnue_source
  "${CMAKE_CURRENT_SOURCE_DIR}/../ios/multistockfish_light/Sources/multistockfish_light/nnue/nn-61e7af4bb97d.nnue")

file(SHA256 "${light_nnue_source}" light_nnue_hash)
if (NOT light_nnue_hash STREQUAL "61e7af4bb97d51eeeb25d322916f86513b5cd3a827ce189c98c6e31946f99e5b")
  message(FATAL_ERROR
    "The committed NNUE net is not the expected one.\n"
    "  ${light_nnue_source}\n"
    "  expected sha256 61e7af4bb97d51eeeb25d322916f86513b5cd3a827ce189c98c6e31946f99e5b\n"
    "  found             ${light_nnue_hash}")
endif()

target_include_directories(multistockfish_light PRIVATE
  ../ios/multistockfish_light/Sources/multistockfish_light/nnue)

file(COPY "${light_nnue_source}" DESTINATION "${CMAKE_CURRENT_BINARY_DIR}")

# Hand the shared library to the Flutter tooling. The variable name is the
# package name with `_bundled_libraries` appended, which is what
# linux/flutter/generated_plugins.cmake reads for every entry of
# FLUTTER_FFI_PLUGIN_LIST.
set(multistockfish_light_bundled_libraries
  $<TARGET_FILE:multistockfish_light>
  PARENT_SCOPE
)
