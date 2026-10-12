A package internal to [multistockfish](https://github.com/HenTaku321/dart-multistockfish).

It provides only the C++ dynamic library interface to [Pikafish](https://github.com/official-pikafish/Pikafish),
and not the dart bindings.

Unlike the three Stockfish flavours, this package does not exist upstream: it is
the reason the fork exists, so that the app can offer xiangqi (Chinese chess)
against an engine on every platform instead of only where a separate binary can
be spawned.

## What is vendored, and how

`ios/multistockfish_pikafish/Sources/multistockfish_pikafish/Pikafish-532c3ff216/`
is a snapshot of Pikafish at commit `532c3ff216`, named after the commit the way
`multistockfish_variant` names its Fairy-Stockfish snapshot. The snapshot is
checked in, and the engine is compiled by the build machine -- by the Android
NDK's CMake and by Xcode's SwiftPM -- exactly as the other three flavours are.
Nothing is compiled on the device.

### The snapshot and the network file are a pair

`532c3ff216` is the last commit to change the network's on-disk format, and the
one `Networks/master-net/pikafish.nnue` was published for. Nothing after it
touches `src/nnue/` -- the current head is a compiler upgrade, and the two trees
differ under `src/nnue/` by zero bytes -- while the asset itself is republished
in place under a name that carries no version, so this paragraph is the only
place the pairing is written down.

Writing it down is worthwhile because a skew between the two is silent. A
network file's version and hash cover the feature transformer and the layer
architecture but not the layer-stack count and not the presence of the psqt
LEB128 blocks -- both of which changed upstream without either value moving --
so a snapshot from before such a change rejects the current net with every cheap
check passing. `Network::load` then leaves `EvalFile` unset without printing
anything, and the rejection surfaces only inside a search, where
`Network::verify` calls `exit(EXIT_FAILURE)`; in a library resident beside a
Dart VM that `exit()` deadlocks on a still-waiting search thread instead of
crashing, which is a hang with no message rather than a diagnosable failure.
Bumping the snapshot therefore means re-fetching the net, re-running
`tool/vendor_pikafish.py`, and updating the size and hash the app's fetch script
pins -- all three together. The vendoring tool asserts that its patch sites are
still where it expects them, but it cannot see the network file; this is that
check, written for a person.

The net at the time of writing is 50,244,700 bytes,
sha256 `10b84dd80bb4e324aa389cab327feeb7b4c44578e35a86105d4fcd5f840c3ac7`, and
decompresses to 64,700,962 bytes.

`tool/vendor_pikafish.py` produces the snapshot from an untarred upstream tree.
It renames the engine's namespace (`Stockfish` -> `Pikafish`, so the flavour can
be resident alongside the other three, each in its own namespace), and patches
`misc.h`/`misc.cpp`/`uci.cpp` to route the engine's diagnostics through
`sfio::in()`/`sfio::out()` rather than the process's `std::cin`/`std::cout`.
That last part is what lets two engines run in one process without their output
landing in one channel; the alternative, redirecting the process's `rdbuf`, is
process-global and would make Pikafish exclusive.

The snapshot keeps only `src/` plus the five root files that carry the licence
and provenance trail (`AUTHORS`, `CITATION.cff`, `Copying.txt`, `README.md`,
`Top CPU Contributors.txt`). Upstream's `tests/`, `scripts/`, `.github/` and
`CONTRIBUTING.md` are dropped -- they do not belong in a pub package, and
`scripts/` is universal-binary tooling for a release we do not make. The same
tooling is why `src/universal/` is skipped: its `entry_*` files call per-arch
namespaces that a normal build does not have.

## The network file is not in here

Pikafish embeds no network and has no mechanism to embed one: `EvalFile` names
`pikafish.nnue` relative to the engine's binary directory, and the app bundles
the file and passes an absolute path with `setoption name EvalFile value <path>`.

The file is therefore not built into this library and not downloaded by it. It
ships inside the application bundle instead (see the app's `assets/pikafish/`),
which is what makes the xiangqi screen work with no network connection. Its
size and hash are checked at fetch time, not here.

## No 32-bit Android ABI

`abiFilters` is `arm64-v8a` and `x86_64` only, where the three Stockfish
flavours also build `armeabi-v7a`. Pikafish's board is 9x10 rather than 8x8 and
its `Bitboard` is a 128-bit integer (`using Bitboard = u128`), whose `u128`
typedef exists only under `IS_64BIT` -- so a 32-bit build fails to compile and
there is no flag that fixes it. Callers must treat Pikafish as unavailable on a
32-bit device rather than expecting a loadable library.

## Compile flags

Taken from Pikafish's own `src/Makefile`, and deliberately not the ones the
Stockfish flavours use: `NNUE_EMBEDDING_OFF` and `USE_PTHREADS` mean nothing to
this code and are absent, and `USE_NEON` carries its value (`=8`) because
Pikafish's `nnue/simd.h` compares it numerically rather than testing whether it
is defined.

## Tests

`test/run_shim_test.sh` builds the shim against the vendored sources with the
host compiler and checks the engine's lifecycle -- `uci` handshake, clean exit,
restart, descriptor accounting, and that the engine does not take the process's
standard descriptors over. It needs no network file: the handshake happens
before any evaluation.
