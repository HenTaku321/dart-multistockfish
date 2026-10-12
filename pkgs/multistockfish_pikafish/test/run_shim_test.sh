#!/usr/bin/env bash
#
# Builds and runs the native shim integration test on the host.
#
# Unlike the other three flavours this one gets a runner of its own rather than
# riding on the variant's: the shim it tests is the one that drives Pikafish's
# `UCIEngine`, so compiling it here is the only compile-and-run coverage that
# entry sequence has.
#
# No network file is needed here, and the reason is worth spelling out because
# it constrains the application. The engine looks the net up once, while it is
# being constructed, and a miss is quiet: `Network::load_external` gets an empty
# stream and leaves the file unset. What is *not* quiet is anything that
# evaluates -- `go`, `go perft`, `bench` call `Engine::verify_network`, and
# `Network::verify` ends in `exit(EXIT_FAILURE)` when no net is loaded, which in
# this shim's case would take the whole host process with it. The lifecycle this
# test drives (`uci` handshake, quit) never evaluates, so it runs with no net;
# the application must set `EvalFile` before its first `go`.
#
# The flags are Pikafish's, not the Stockfish flavours': no
# -DNNUE_EMBEDDING_OFF and no -DUSE_PTHREADS (it has neither feature), but
# -DIS_64BIT and -DUSE_POPCNT. -DNDEBUG matches the shape of the real build
# without its optimisation level, because the point here is the lifecycle, not
# the node rate.
#
# -fconstexpr-steps is required rather than optional: clang's default constexpr
# step budget is too small for the NNUE feature-set tables Pikafish builds in
# constexpr lambdas (see the note in android/CMakeLists.txt), and the build
# stops on nnue/features/half_ka_v2_hm.h without it. -DZSTD_DISABLE_ASM is the
# same flag the real builds pass, and without it this script would have to
# assemble huf_decompress_amd64.S or fail to link.
#
# Usage: pkgs/multistockfish_pikafish/test/run_shim_test.sh

set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
sources="$here/../ios/multistockfish_pikafish/Sources/multistockfish_pikafish"
out="$(mktemp -d)"
trap 'rm -rf "$out"' EXIT

engine_sources=$(
  find "$sources/Pikafish-532c3ff216/src" -name '*.cpp' ! -name 'main.cpp'
)

echo "Building..."
"${CXX:-clang++}" \
  -std=c++17 -O1 \
  -DIS_64BIT -DUSE_POPCNT -DNDEBUG -fconstexpr-steps=10000000 -DZSTD_DISABLE_ASM \
  -Wno-writable-strings \
  -pthread \
  -o "$out/shim_test" \
  "$sources/stockfish_pikafish.cpp" \
  "$sources/sfio.cpp" \
  "$here/shim_test.cpp" \
  $engine_sources

echo "Running..."
# The test reports on stderr and leaves stdout alone on purpose: one of the
# things it checks is that the engine does not take the process's stdout over,
# so anything appearing on stdout here would itself be a failure.
"$out/shim_test" 2>&1 >/dev/null
