#!/usr/bin/env bash
#
# Builds all three flavours' Linux shared libraries and probes them.
#
# This is the Linux counterpart of the two host tests already here, and it
# tests a different thing from both:
#
#   pkgs/multistockfish_variant/test/run_shim_test.sh compiles the engine
#       sources straight into a test binary. It covers the shim's guarantees in
#       depth, but never builds the .so the app actually loads.
#
#   test/run_two_flavours_test.sh links two flavours into one binary, which is
#       how iOS builds them. Nothing on Linux does that -- each flavour is its
#       own .so -- so what it proves does not apply here.
#
# What this one covers is the part the Linux port added: that linux/CMakeLists.txt
# in each package configures and builds with the host compiler, that the shared
# library it produces exports the symbols the Dart side looks up by name, and
# that the library runs. The shim test is then linked against the built .so
# rather than against sources, which is the only way to exercise the dynamic
# linking step; the probes drive each library over UCI and ask for a perft,
# which needs no network and gives a node count that can be checked by hand.
#
# light and variant are asked for one; chess is not, and cannot be -- see the
# note on depth_for below.
#
# Usage: test/run_linux_test.sh
#
# Requires: cmake, a C++17 compiler (clang++, which is what Flutter's Linux
# build uses), and libpthread in libc or as its own library.

set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root="$here/.."
CXX="${CXX:-clang++}"

# The package name is the library name and the directory name. The symbol
# prefix is NOT the package name -- see the note in linux_probe.cpp.
flavours=(chess light variant)
symbols_for() {
  case "$1" in
    chess) echo stockfish ;;
    light) echo stockfish_light ;;
    variant) echo stockfish_variant ;;
  esac
}

# How deep a perft each flavour is asked for. chess gets 0, meaning "stop after
# the UCI handshake", and this is the one place in the Linux port where
# something is knowingly not tested.
#
# The reason: a flavour that loads its net from a file goes through the
# system-wide shared allocation in Stockfish's shm.h, and on Linux that
# deadlocks -- the engine reads `go`, unlinks its own .sock in
# /tmp/stockfish-<uid>/sfshm_<hash>/ and then blocks on a futex that never
# wakes. shm.h only compiles that path in for
# `(linux && !android) || apple || *bsd`; Android therefore never has it, and on
# iOS /tmp is not writable so create_shared() returns early and the fallback
# (private memory) is used instead. Linux is the one platform where the path is
# both compiled in and able to run, and it is the one platform upstream does not
# build these packages for. Measured here, twice, on a clean /tmp.
#
# That leaves the flavour unable to reach a perft for a second reason as well:
# its default net is the ~73 MB latest one, which is not in the tree, and the
# light net is not a drop-in substitute -- the system Stockfish 19 rejects
# nn-61e7af4bb97d.nnue as an incompatible architecture. Nothing is lost by
# stopping at the handshake: the two flavours the app uses on Linux are light
# (net embedded in the library) and variant (no net at all), and neither ever
# takes that path -- which is also why the app's capability table marks the
# latestNoNNUE slot unavailable on Linux.
depth_for() {
  case "$1" in
    chess) echo 0 ;;
    *) echo 3 ;;
  esac
}

out="$(mktemp -d)"
trap 'rm -rf "$out"' EXIT

echo "Building..."
for flavour in "${flavours[@]}"; do
  printf '  %s: configuring and building\n' "$flavour"
  cmake -S "$root/pkgs/multistockfish_$flavour/linux" -B "$out/$flavour" \
    -DCMAKE_BUILD_TYPE=Release -DCMAKE_CXX_COMPILER="$CXX" >"$out/$flavour.configure.log" 2>&1
  cmake --build "$out/$flavour" --parallel >"$out/$flavour.build.log" 2>&1
done

# Both of these are gates in their own right: a package whose linux/CMakeLists
# forgot to hand its library to the Flutter tooling would still build, and the
# failure would only show up as a missing file in a shipped bundle.
echo
for flavour in "${flavours[@]}"; do
  library="$out/$flavour/libmultistockfish_$flavour.so"
  if [ ! -f "$library" ]; then
    printf 'FAIL: %s was not built\n' "$library" >&2
    exit 1
  fi
  printf '  %-8s %s\n' "$flavour" "$(ls -lh "$library" | awk '{print $5}')"
done

echo
echo "Shim integration test, linked against the built variant .so..."
"$CXX" -std=c++17 -O1 -o "$out/shim_test" \
  "$root/pkgs/multistockfish_variant/test/shim_test.cpp" \
  -L"$out/variant" -lmultistockfish_variant
# stdout is deliberately discarded: one of the things the shim test checks is
# that the engine no longer takes the process's stdout over, so anything
# appearing on it would itself be a failure.
LD_LIBRARY_PATH="$out/variant" "$out/shim_test" 2>&1 >/dev/null

echo
echo "UCI probes..."
for flavour in "${flavours[@]}"; do
  "$CXX" -std=c++17 -O1 -DPROBE_SYMBOLS="$(symbols_for "$flavour")" \
    -o "$out/probe_$flavour" "$here/linux_probe.cpp" \
    -L"$out/$flavour" -lmultistockfish_"$flavour"
  LD_LIBRARY_PATH="$out/$flavour" "$out/probe_$flavour" "$(depth_for "$flavour")" 2>&1 >/dev/null
done
