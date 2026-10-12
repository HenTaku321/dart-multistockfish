## 0.1.0

Initial version.

- Add Pikafish, at commit `532c3ff216`, as a fourth flavour alongside
  `multistockfish_chess`, `multistockfish_light` and `multistockfish_variant`.
  The three Stockfish flavours are unmodified copies of upstream's packages;
  this one is added by the fork, because xiangqi on a phone cannot spawn an
  engine process and so needs the engine linked into the app.
- That commit and the `pikafish.nnue` it is paired with are chosen together: it
  is the last commit to change the network's on-disk format, and the asset it
  was published for is overwritten in place, so a snapshot from before the
  change rejects the current net with no diagnostic at all. The README says why
  in full. The net is 50,244,700 bytes,
  sha256 `10b84dd80bb4e324aa389cab327feeb7b4c44578e35a86105d4fcd5f840c3ac7`.
- Build for Linux as well as Android and iOS, so the desktop build gets the same
  embedded engine the phone has.
- No 32-bit Android ABI: Pikafish's `Bitboard` is a 128-bit integer and its
  `u128` typedef exists only under `IS_64BIT`, so `armeabi-v7a` cannot compile.
- `NNUE_EMBEDDING_OFF` and `USE_PTHREADS` are absent from every flag set, unlike
  the Stockfish flavours: Pikafish has neither feature. `USE_NEON` carries the
  value 8, because Pikafish's `nnue/simd.h` compares it numerically.
- The network is neither embedded nor downloaded by this package. The
  application bundles `pikafish.nnue` and passes its path as `EvalFile`.
- The vendored snapshot is produced by `tool/vendor_pikafish.py`, which renames
  the engine's namespace and routes its diagnostics through `sfio` streams of
  its own, so it can share a process with the other three flavours.
