/// The flavor of Stockfish to use.
enum StockfishFlavor {
  /// Stockfish engine version 19 with a small embedded NNUE (~1MB).
  ///
  /// Ready to evaluate as soon as it starts, with no net to download, at the
  /// cost of some strength compared to [latestNoNNUE]'s full-size net.
  light,

  /// Latest Stockfish engine version without embedded NNUE.
  ///
  /// The net is not part of the binary, so it must be downloaded and its path
  /// passed to `Stockfish.create(nnuePath: ...)`.
  latestNoNNUE,

  /// Multi-Variant Stockfish using Handcrafted Evaluation for chess and chess variants
  variant,

  /// Pikafish, the xiangqi (Chinese chess) engine.
  ///
  /// Not a Stockfish flavour in any meaningful sense: a separate project, a
  /// separate engine, a separate network format and its own move generation.
  /// It is here because it is the only engine that plays xiangqi offline, and
  /// on a phone it has to be linked into the app rather than spawned.
  ///
  /// Like [latestNoNNUE] it has no embedded net, so `nnuePath` is required and
  /// must name a `pikafish.nnue` matching the engine's own version — a mismatch
  /// is rejected without a diagnostic, at engine startup.
  ///
  /// No 32-bit build exists: its `Bitboard` is a 128-bit integer, and the `u128`
  /// it is typed as exists only under `IS_64BIT`.
  pikafish,
}
