# Linux desktop build of the full-net Stockfish flavour (latestNoNNUE).
#
# This mirrors android/CMakeLists.txt, with the differences the platform
# forces:
#
#   - the Android-only 16k-page-size link option is gone, and with it the
#     `if (ANDROID)` wrapper;
#   - the compile flags are the non-arm64 ones, plus the x86_64 baseline the
#     Android file also sets: -DIS_64BIT and -DUSE_POPCNT. Nothing newer; see
#     the same note in multistockfish_variant/linux/CMakeLists.txt;
#   - the library is handed to the Flutter tooling at the end, which is how a
#     Linux FFI plugin is wired: the app's linux/flutter/generated_plugins.cmake
#     adds this directory through add_subdirectory() and reads the
#     `<package>_bundled_libraries` variable, then installs the file it names
#     into the bundle's lib/ next to the executable.
#
# Unlike the other two flavours this one has no net of its own -- that is what
# the flavour means -- so the library is only useful to an app that hands it an
# NNUE file at runtime. It is built here for that reason: to keep the three
# flavours parallel and to keep the library honest about what it is, not because
# anything on Linux can currently use it. Nothing on Linux can: a net loaded
# from a file goes through the system-wide shared allocation in Stockfish's
# shm.h, and on Linux that deadlocks. The engine reads `go`, unlinks its own
# .sock under /tmp/stockfish-<uid>/sfshm_<hash>/ and then blocks on a futex that
# is never signalled. shm.h compiles the path in only for
# `(linux && !android) || apple || *bsd`; Android never has it, and on iOS /tmp
# is unwritable so create_shared() gives up and private memory is used. Linux is
# the one platform where it is both compiled in and able to run -- and the one
# platform upstream does not build these packages for.
#
# So: this library builds, loads, exports what the Dart side expects and speaks
# UCI on Linux, and cannot search. test/run_linux_test.sh asks it for a perft at
# depth 0 and says so; the app's capability table marks the slot unavailable.
#
# The Flutter tooling requires that developers have CMake 3.10 or later
# installed. You should not increase this version, as doing so will cause
# the plugin to fail to compile for some customers of the plugin.
cmake_minimum_required(VERSION 3.10)

project(multistockfish_chess_library VERSION 0.2.0 LANGUAGES CXX)

file(GLOB_RECURSE sfPaths "../ios/multistockfish_chess/Sources/multistockfish_chess/Stockfish/src/*.cpp")

# src/universal/ holds the entry points and the NNUE embedding used by upstream's
# macOS universal-binary build. They are not part of a normal build: the entry_*
# files call into per-arch `Stockfish_<arch>::main` namespaces that only exist in
# that build, and nnue_embed.cpp defines a second `gEmbeddedNNUEData`. Compiling
# either here fails to link.
list(FILTER sfPaths EXCLUDE REGEX "/Stockfish/src/universal/")

add_library(
  multistockfish_chess
  SHARED
  ../ios/multistockfish_chess/Sources/multistockfish_chess/stockfish_nnue.cpp
  ../ios/multistockfish_chess/Sources/multistockfish_chess/sfio.cpp
  ${sfPaths}
)

set_target_properties(multistockfish_chess PROPERTIES
  PUBLIC_HEADER multistockfish_chess.h
  OUTPUT_NAME "multistockfish_chess"
)

target_compile_definitions(multistockfish_chess PUBLIC DART_SHARED_LIB)

# The engine starts its threads with std::thread, which on glibc before 2.34
# lives in a separate libpthread. Asking for Threads::Threads costs nothing on
# a newer glibc and keeps the library linkable on an older one.
find_package(Threads REQUIRED)
target_link_libraries(multistockfish_chess PRIVATE Threads::Threads)

if (CMAKE_BUILD_TYPE STREQUAL "Debug")
  target_compile_options(multistockfish_chess PRIVATE -std=c++17 -DNNUE_EMBEDDING_OFF -DUSE_PTHREADS -DIS_64BIT -DUSE_POPCNT)
else()
  target_compile_options(multistockfish_chess PRIVATE -std=c++17 -DNNUE_EMBEDDING_OFF -DUSE_PTHREADS -fno-exceptions -DNDEBUG -O3 -DIS_64BIT -DUSE_POPCNT)
endif()

# Hand the shared library to the Flutter tooling. The variable name is the
# package name with `_bundled_libraries` appended, which is what
# linux/flutter/generated_plugins.cmake reads for every entry of
# FLUTTER_FFI_PLUGIN_LIST.
set(multistockfish_chess_bundled_libraries
  $<TARGET_FILE:multistockfish_chess>
  PARENT_SCOPE
)
