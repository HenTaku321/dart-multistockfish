import 'dart:async';
import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';

import 'package:flutter/foundation.dart';
import 'package:logging/logging.dart';

import 'bindings.dart';
import 'stockfish_diagnostics.dart';
import 'stockfish_flavor.dart';
import 'stockfish_state.dart';

final _logger = Logger('Stockfish');

/// Zone key for overriding bindings factory in tests.
@visibleForTesting
const stockfishBindingsFactoryKey = #_stockfishBindingsFactory;

/// Zone key for overriding isolate spawning in tests.
@visibleForTesting
const stockfishSpawnIsolatesKey = #_stockfishSpawnIsolates;

/// Timeout duration to consider engine start failed.
const kStartTimeout = Duration(seconds: 5);

/// How long an engine is given to exit before disposal reports a failure.
const kQuitTimeout = Duration(seconds: 5);

/// How long an exited engine's reader is given to let go of the pipe.
///
/// Short, because the marker it is waiting for is already in the pipe by then:
/// this is a thread wake-up, not work.
const kReaderStopTimeout = Duration(seconds: 1);

/// A live Stockfish engine of one [StockfishFlavor].
///
/// Obtain one with [Stockfish.create], which starts the engine and completes
/// once it is ready for commands, and release it with [dispose].
///
/// **The handle is the flavor.** At most one engine per [StockfishFlavor] can
/// be live at a time: [create] throws a [StateError] while another engine of
/// the same flavor holds the slot, and [dispose] frees it. Engines of
/// *different* flavors are independent and may be live together — an analysis
/// engine and a variant opponent, say — each with its own [stdin], [stdout],
/// [state] and [diagnostics].
///
/// A handle is single-use. Once [dispose] has been called, or the engine has
/// exited on its own, that handle stays dead; call [create] again for a fresh
/// one. A flavor is reusable only after both the main and stdout workers stop.
class Stockfish {
  Stockfish._(this._flavor, {bool legacy = false}) : _legacy = legacy;

  /// The engines currently holding their flavor's slot.
  static final Map<StockfishFlavor, Stockfish> _live = {};

  /// The engines currently live, by flavor.
  ///
  /// The slots are process-wide, so a test that leaves one claimed leaks it
  /// into the next test.
  @visibleForTesting
  static Map<StockfishFlavor, Stockfish> get debugLiveEngines =>
      Map.unmodifiable(_live);

  /// Drain every handle, including a failed create whose native code is still alive.
  ///
  /// A failed drain retains its slot and reports the failure. It is never safe to
  /// start another reader on that flavor's process-wide pipe in the meantime.
  static Future<void> shutdownAll() async {
    await Future.wait(
      _live.values.toList().map(
        (engine) => engine._legacy ? engine._quitNative() : engine.dispose(),
      ),
    );
  }

  /// The default NNUE file for evaluation of [StockfishFlavor.latestNoNNUE].
  ///
  /// Stockfish 19 evaluates with a single net, replacing the big/small pair
  /// that Stockfish 18 used.
  static const latestNNUE = 'nn-1a298aa575a0.nnue';

  /// Starts an engine of [flavor] and completes when it is ready for commands.
  ///
  /// When [flavor] is [StockfishFlavor.latestNoNNUE], [nnuePath] must be
  /// provided.
  ///
  /// Throws a [StateError] if an engine of [flavor] is already live — call
  /// [dispose] on it first — and a [TimeoutException] if the engine does not
  /// become ready within [kStartTimeout]. Failed creates are cleaned up before
  /// throwing. If cleanup fails, the flavor remains occupied until its native
  /// workers finish or the application exits.
  ///
  /// Pass [onStdout] to see the engine's startup output. This future does not
  /// complete until the engine is ready, so a listener attached to [stdout]
  /// afterwards has already missed the banner and the UCI handshake;
  /// [onStdout] is attached before the engine is spawned and receives every
  /// line for its whole life.
  static Future<Stockfish> create({
    /// The flavor of Stockfish to use.
    StockfishFlavor flavor = StockfishFlavor.light,

    /// The variant of chess to use. (Only for [StockfishFlavor.variant]).
    ///
    /// Example: '3check', 'crazyhouse', 'atomic', 'kingofthehill', 'antichess', 'horde', 'racingkings'.
    String? variant,

    /// Full path to the net file for NNUE evaluation. Only used for
    /// [StockfishFlavor.latestNoNNUE] and [StockfishFlavor.pikafish].
    String? nnuePath,

    /// Receives every line the engine writes, starting from its first.
    void Function(String line)? onStdout,
  }) async {
    assert(
      flavor != StockfishFlavor.latestNoNNUE || nnuePath != null,
      'NNUE evaluation requires nnuePath',
    );
    // Pikafish has no embedded net either, and unlike the Stockfish flavours it
    // has no fallback: started without one it searches with an unset net and
    // returns nonsense rather than refusing.
    assert(
      flavor != StockfishFlavor.pikafish || nnuePath != null,
      'Pikafish requires nnuePath: it has no embedded network',
    );

    // Claiming the slot before the first await is what makes two concurrent
    // create() calls for one flavor resolve to a refusal rather than to two
    // engines racing each other into the same native globals.
    final engine =
        Stockfish._(flavor)
          .._variant = variant
          .._nnuePath = nnuePath;
    engine._claimSlot(flavor);
    if (onStdout != null) engine._stdoutController.stream.listen(onStdout);

    try {
      await engine._doStart();
    } catch (_) {
      engine._state._setValue(StockfishState.error);
      await engine.dispose();
      rethrow;
    }

    return engine;
  }

  final bool _legacy;

  StockfishFlavor _flavor;
  String? _variant;
  String? _nnuePath;

  /// The flavor of Stockfish this engine runs.
  StockfishFlavor get flavor => _flavor;

  /// The variant of chess. (Only for [StockfishFlavor.variant]).
  String? get variant => _variant;

  /// Full path to the net file for NNUE evaluation.
  String? get nnuePath => _nnuePath;

  StockfishBindings get _bindings => _getBindings(_flavor);

  final _state = _StockfishState();
  final _stdoutController = StreamController<String>.broadcast();

  /// The engine currently owning the state, or null when none is running.
  _RunningEngine? _engine;

  Future<void>? _pendingStart;
  Future<void>? _pendingQuit;
  Future<void>? _pendingDispose;

  /// The current state of the underlying C++ engine.
  ///
  /// A handle returned by [create] is [StockfishState.ready]. It ends as
  /// [StockfishState.disposed] — after [dispose], or after the engine exits
  /// cleanly on its own, as it does when sent `quit` over [stdin] — or as
  /// [StockfishState.error] if it died badly. None of those is recoverable on
  /// this handle: create another one.
  ValueListenable<StockfishState> get state => _state;

  /// The standard output stream.
  ///
  /// Closes when the engine is disposed.
  Stream<String> get stdout => _stdoutController.stream;

  /// A snapshot of what the native engine is doing.
  ///
  /// Cheap to read at any time, including while the engine is wedged — the
  /// values are atomics published by the native shim, not a round trip through
  /// the engine. Attach it to any report of an engine that would not start or
  /// would not quit.
  StockfishDiagnostics get diagnostics {
    final bindings = _bindings;
    return StockfishDiagnostics(
      phase: StockfishPhase.fromCode(bindings.phase()),
      step: bindings.phaseStep(),
      elapsed: Duration(milliseconds: bindings.phaseElapsedMs()),
      lastError: bindings.lastError(),
    );
  }

  /// The standard input sink.
  ///
  /// A failed write is logged at [Level.SEVERE] along with [diagnostics] rather
  /// than thrown, so that a broken engine does not turn every command site into
  /// a try/catch. The write never blocks: if the engine has stopped reading its
  /// input, this reports the failure instead of hanging the calling isolate.
  ///
  /// A failure that leaves the session unusable — see
  /// [StockfishWriteResult.isFatal] — additionally moves [state] to
  /// [StockfishState.error], so subsequent commands throw rather than pile onto
  /// a channel the engine can no longer read correctly.
  set stdin(String line) {
    final stateValue = _state.value;
    if (stateValue != StockfishState.ready) {
      throw StateError('Stockfish is not ready ($stateValue)');
    }

    _write(line);
  }

  /// Sends a line to the engine, returning the native write result.
  ///
  /// Negative values are failures described by [describeWriteCode]. They are
  /// logged here so that every caller reports them the same way, and returned
  /// so that callers who cannot simply carry on — [dispose] in particular — can
  /// act on them.
  int _write(String line) {
    _logger.finest('[stdin] $line');

    final written = _bindings.stdinWrite('$line\n');
    if (written < 0) {
      _logger.severe(
        'Failed to send "$line" to the engine: ${describeWriteCode(written)}. '
        '$diagnostics',
      );

      if (StockfishWriteResult.isFatal(written)) {
        // The engine can no longer be sent a coherent command stream, so this
        // session is over whatever the engine itself does next. Failing the
        // state here makes the rest of the API refuse work until the caller
        // starts another engine, instead of letting commands accumulate on a
        // broken channel and be answered with nonsense.
        _logger.severe(
          'The engine session is unrecoverable and has been marked failed. '
          'Dispose this engine and create another one.',
        );
        _state._setValue(StockfishState.error);
      }
    }
    return written;
  }

  /// Takes [flavor]'s slot, or throws if another engine still holds it.
  void _claimSlot(StockfishFlavor flavor) {
    if (_live.containsKey(flavor)) {
      throw StateError(
        'A ${flavor.name} engine is already live. Dispose it before creating '
        'another one of the same flavor. (Engines of other flavors are '
        'unaffected and can run alongside it.)',
      );
    }
    _flavor = flavor;
    _live[flavor] = this;
  }

  /// Gives this flavor's slot back, if this engine still holds it.
  void _releaseSlot() {
    if (identical(_live[_flavor], this)) _live.remove(_flavor);
  }

  Future<void> _doStart() async {
    late final _RunningEngine engine;
    engine = _RunningEngine(
      onExit: _onEngineExit,
      onStopped: (exitCode) {
        if (!identical(_engine, engine)) return;
        _release(
          exitCode != 0 || _state.value == StockfishState.error
              ? StockfishState.error
              : _legacy
              ? StockfishState.initial
              : StockfishState.disposed,
          closeStdout: !_legacy,
        );
      },
      onStdout: (line) {
        if (!_stdoutController.isClosed) _stdoutController.add(line);
      },
      onReaderFailed: (error) {
        _logger.severe(
          'The reader for the ${_flavor.name} engine died, so nothing is draining its '
          'output any more. The engine will stop answering as soon as its pipe fills, so '
          'this session is over. $diagnostics\n$error',
        );
        _state._setValue(StockfishState.error);
      },
    );
    _engine = engine;

    final success = await _spawnIsolates(
      engine.mainPort.sendPort,
      engine.stdoutPort.sendPort,
      _flavor,
    );

    if (!success) {
      _logger.severe('Failed to spawn isolates');
      // A failed spawn can leave the reader alive. Keep the handle reachable;
      // dispose must report that uncertainty instead of opening the native slot.
      throw Exception('Failed to spawn isolates');
    }

    _state._setValue(StockfishState.starting);

    try {
      // Wait for the engine to be ready by checking the first non-empty line (usually its name).
      await _awaitLine(engine, (line) => line.isNotEmpty);

      _state._setValue(StockfishState.ready);

      // Switch to the engine to UCI protocol
      stdin = 'uci';
      await _awaitLine(engine, (line) => line == 'uciok');
    } on TimeoutException {
      // Read the diagnostics before asking the engine to quit: doing so moves
      // it on to another phase and would erase the evidence of where it stalled.
      final stalledAt = diagnostics;
      _logger.severe(
        'The engine (${_flavor.name}) did not become ready in time '
        '(${kStartTimeout.inSeconds}s). $stalledAt',
      );
      throw TimeoutException(
        'Stockfish (${_flavor.name}) did not become ready in time. $stalledAt',
        kStartTimeout,
      );
    }

    if (_flavor == StockfishFlavor.variant && _variant != null) {
      stdin = 'setoption name UCI_Variant value $_variant';
    }

    if ((_flavor == StockfishFlavor.latestNoNNUE ||
            _flavor == StockfishFlavor.pikafish) &&
        _nnuePath != null) {
      stdin = 'setoption name EvalFile value $_nnuePath';
    }
  }

  /// Waits for [engine] to print a line matching [test].
  ///
  /// Throws a [TimeoutException] after [kStartTimeout], and gives up as soon as
  /// the engine exits instead: an engine the native library refused to run
  /// reports that in milliseconds, and waiting out the timeout would replace a
  /// precise answer with a vague one.
  Future<void> _awaitLine(
    _RunningEngine engine,
    bool Function(String line) test,
  ) {
    final completer = Completer<void>();

    final subscription = _stdoutController.stream.listen((line) {
      if (!completer.isCompleted && test(line)) completer.complete();
    });

    unawaited(
      engine.exited.future.then((exitCode) {
        if (completer.isCompleted) return;
        completer.completeError(
          Exception(
            'The ${_flavor.name} engine exited while starting '
            '(code $exitCode: ${describeMainExitCode(exitCode)}) '
            'and will never become ready. $diagnostics',
          ),
        );
      }),
    );

    return completer.future
        .timeout(kStartTimeout)
        .whenComplete(subscription.cancel);
  }

  /// Quits the engine and waits for both native workers to stop.
  ///
  /// Timeouts are failures, not proof of termination. The handle and its flavor
  /// remain claimed until both workers really finish, even after a failed call.
  Future<void> dispose() {
    if (_legacy) {
      throw StateError('Use quit() on Stockfish.instance');
    }
    return _pendingDispose ??= _doDispose();
  }

  Future<void> _doDispose() async {
    try {
      await _quitNative();
      _release(
        _state.value == StockfishState.error
            ? StockfishState.error
            : StockfishState.disposed,
        closeStdout: true,
      );
    } catch (_) {
      _state._setValue(StockfishState.error);
      rethrow;
    }
  }

  Future<void> _quitNative() async {
    final engine = _engine;
    if (engine != null) await _quitEngine(engine);
  }

  Future<void> _quitEngine(_RunningEngine engine) async {
    if (!engine.exited.isCompleted) {
      if (_write('quit') < 0) {
        throw StateError(
          'The ${_flavor.name} engine could not be asked to quit. '
          'Its native slot remains occupied. $diagnostics',
        );
      }
      await engine.exited.future.timeout(
        kQuitTimeout,
        onTimeout: () {
          throw TimeoutException(
            'The ${_flavor.name} engine has not exited. '
            'Its native slot remains occupied. $diagnostics',
            kQuitTimeout,
          );
        },
      );
    }
    await engine.readerStopped.future.timeout(
      kReaderStopTimeout,
      onTimeout: () {
        throw TimeoutException(
          'The ${_flavor.name} stdout reader has not stopped. '
          'Its native slot remains occupied. $diagnostics',
          kReaderStopTimeout,
        );
      },
    );
  }

  void _release(StockfishState finalState, {required bool closeStdout}) {
    final engine = _engine;
    // Neither a state transition nor a timeout can prove a native worker gone.
    if (engine != null && !engine.stopped) return;
    _releaseSlot();
    engine?.detach();
    _engine = null;
    _state._setValue(finalState);
    if (closeStdout && !_stdoutController.isClosed) _stdoutController.close();
  }

  void _onEngineExit(int exitCode) {
    if (exitCode != 0) {
      _logger.severe(
        'The engine exited with code $exitCode: '
        '${describeMainExitCode(exitCode)}. $diagnostics',
      );
      _state._setValue(StockfishState.error);
    }
    // _RunningEngine.onStopped releases the slot after the reader confirms exit.
  }

  // ---------------------------------------------------------------------------
  // Deprecated singleton facade.
  // ---------------------------------------------------------------------------

  /// The singleton instance of Stockfish.
  @Deprecated(
    'Use Stockfish.create() and dispose() instead: engines are now per-flavor '
    'handles, so several flavors can be live at once and each has its own '
    'state and streams. This singleton will be removed in the next release.',
  )
  static final Stockfish instance = Stockfish._(
    StockfishFlavor.light,
    legacy: true,
  );

  /// Starts the C++ engine.
  ///
  /// Returns a [Future] that completes when the engine is ready to accept commands.
  ///
  /// When [flavor] is [StockfishFlavor.latestNoNNUE], [nnuePath] must be provided.
  ///
  /// Throws a [TimeoutException] if the engine does not become ready in time.
  @Deprecated(
    'Use Stockfish.create() instead, which returns an engine of its own '
    'rather than reconfiguring a shared one.',
  )
  Future<void> start({
    /// The flavor of Stockfish to use.
    StockfishFlavor flavor = StockfishFlavor.light,

    /// The variant of chess to use. (Only for [StockfishFlavor.variant]).
    ///
    /// Example: '3check', 'crazyhouse', 'atomic', 'kingofthehill', 'antichess', 'horde', 'racingkings'.
    String? variant,

    /// Full path to the net file for NNUE evaluation. Only used for [StockfishFlavor.latestNoNNUE].
    String? nnuePath,
  }) {
    assert(
      _legacy,
      'start() only exists on the deprecated Stockfish.instance. An engine '
      'from Stockfish.create() is already started.',
    );
    assert(
      flavor != StockfishFlavor.latestNoNNUE || nnuePath != null,
      'NNUE evaluation requires nnuePath',
    );

    if (_pendingStart != null) {
      return _pendingStart!;
    }

    if (_state.value != StockfishState.initial &&
        _state.value != StockfishState.error) {
      _logger.warning(
        'Attempt to start Stockfish while it is already running.',
      );
      throw StateError(
        'Stockfish is already running. Call quit() before starting again.',
      );
    }

    // The singleton competes for the same per-flavor slots as create(), so a
    // caller half-migrated to handles cannot end up with two engines of one
    // flavor by using both APIs.
    _claimSlot(flavor);

    _variant = variant;
    _nnuePath = nnuePath;

    return _pendingStart = _legacyStart().whenComplete(
      () => _pendingStart = null,
    );
  }

  Future<void> _legacyStart() async {
    try {
      await _doStart();
    } catch (_) {
      _state._setValue(StockfishState.error);
      await _quitNative();
      _release(StockfishState.error, closeStdout: false);
      rethrow;
    }
  }

  /// Quits the C++ engine.
  ///
  /// Returns a [Future] that completes when the engine has exited.
  ///
  /// After quitting, the engine can be started again with [start].
  ///
  /// It is safe to call [quit] multiple times; subsequent calls will wait for the first to complete.
  @Deprecated(
    'Use dispose() on an engine from Stockfish.create() instead. Unlike quit(), '
    'it also gives up on an engine that will not exit.',
  )
  Future<void> quit() {
    assert(
      _legacy,
      'quit() only exists on the deprecated Stockfish.instance. Use dispose() '
      'on an engine from Stockfish.create().',
    );

    if (_pendingQuit != null) {
      return _pendingQuit!;
    }

    return _pendingQuit = _legacyQuit().whenComplete(() => _pendingQuit = null);
  }

  Future<void> _legacyQuit() async {
    if (_pendingStart case final starting?) {
      try {
        await starting;
      } catch (_) {
        // Startup has already attempted cleanup; still join any native workers.
      }
    }
    try {
      await _quitNative();
    } catch (_) {
      _state._setValue(StockfishState.error);
      rethrow;
    }
  }
}

/// The ports of a single engine, and its lifetime.
///
/// Each engine gets its own ports so that closing them is enough to make an
/// abandoned engine invisible to the [Stockfish] handle that started it.
class _RunningEngine {
  _RunningEngine({
    required void Function(int exitCode) onExit,
    required void Function(int exitCode) onStopped,
    required void Function(String line) onStdout,
    required void Function(String error) onReaderFailed,
  }) {
    void finishIfStopped() {
      if (stopped) onStopped(_exitCode!);
    }

    mainPort.listen((message) {
      _logger.fine('The main isolate sent $message');
      final code = message is int ? message : 1;
      _exitCode = code;
      // The only thing that completes [exited]; see its doc comment.
      if (!exited.isCompleted) exited.complete(code);
      onExit(code);
      finishIfStopped();
    });

    stdoutPort.listen((message) {
      // The reader's own end of stream, not engine output.
      if (message == null) {
        _logger.fine('The stdout isolate has let go of the pipe');
        if (!readerStopped.isCompleted) readerStopped.complete();
        finishIfStopped();
        return;
      }

      // The reader reporting that it died rather than finished.
      if (message is Map) {
        onReaderFailed('${message['error']}\n${message['stackTrace']}');
        return;
      }

      // A batch of lines from the reader, or a single line from a test's fake.
      final lines = switch (message) {
        final List<Object?> batch => batch,
        final String line => [line],
        _ => const <Object?>[],
      };

      if (lines.isEmpty) {
        _logger.fine('The stdout isolate sent $message');
        return;
      }

      // Checked once rather than per line: this runs for every line the engine
      // writes, and the interpolation below is not free when nobody is listening.
      final trace = _logger.isLoggable(Level.FINEST);

      for (final line in lines) {
        if (line is! String) continue;
        if (trace) _logger.finest('[stdout] $line');
        onStdout(line);
      }
    });
  }

  final mainPort = ReceivePort('Stockfish main isolate port');
  final stdoutPort = ReceivePort('Stockfish stdout isolate port');

  /// Completes with the engine's exit code when it has actually exited.
  ///
  /// Completed only by the main isolate reporting that the engine's `main()`
  /// returned, and never by [detach]: a handle that has stopped listening says
  /// nothing about whether the engine is still running. [Stockfish._quitEngine]
  /// skips the `quit` write for an engine that has already exited, so anything
  /// else completing this would abandon a live engine still holding its
  /// flavor's native slot.
  final exited = Completer<int>();

  /// Completes when the reader isolate has finished with the output pipe.
  ///
  /// Not the same event as the engine exiting: the reader learns of that from
  /// the quit marker in the pipe, which it may not have read yet.
  final readerStopped = Completer<void>();

  int? _exitCode;
  bool get stopped => exited.isCompleted && readerStopped.isCompleted;
  bool _detached = false;

  /// Stops listening to this engine's isolates.
  ///
  /// Says nothing about the engine, which may still be running: this is the
  /// handle letting go, not the engine ending.
  void detach() {
    if (_detached) return;
    _detached = true;
    mainPort.close();
    stdoutPort.close();
  }
}

// On iOS/macOS, each flavor's native package may be distributed either via
// CocoaPods (built into its own `$libName.framework`, dynamically loaded and
// linked into the app at launch) or via Swift Package Manager (whose local
// package integration statically merges the object code straight into the
// app binary instead of producing a separate framework). DynamicLibrary.open
// only works for the former, but DynamicLibrary.process() resolves symbols
// from *both*: dynamically linked frameworks are eagerly loaded into the
// process at launch just like statically linked code is, so their exported
// symbols are equally visible process-wide. Using it uniformly means this
// code doesn't need to know which distribution mechanism produced a given
// flavor, and keeps working as flavors migrate from one to the other.
//
// This relies on every flavor's exported C symbols being unique process-wide
// (see [StockfishBindingsFFI]'s symbolPrefix) since a process-wide lookup
// can't otherwise distinguish between multiple co-loaded flavors that
// happen to export identically-named functions.
DynamicLibrary _openDynamicLibrary(String libName) {
  if (Platform.isMacOS || Platform.isIOS) {
    return DynamicLibrary.process();
  }
  if (Platform.isAndroid) {
    return DynamicLibrary.open('lib$libName.so');
  }
  if (Platform.isLinux) {
    return DynamicLibrary.open(_linuxLibraryPath(libName));
  }
  throw UnsupportedError('Unknown platform: ${Platform.operatingSystem}');
}

/// The path a flavour's library is opened by on Linux.
///
/// A bare soname leaves the search to the dynamic linker, and whether the
/// bundle's `lib/` is among the places it looks depends on rules that are not
/// worth relying on: DT_RPATH and DT_RUNPATH are consulted for the object that
/// called dlopen, which here is not the executable but whatever inside the Dart
/// or Flutter runtime made the call. Flutter's Linux bundle does put
/// `$ORIGIN/lib` on the executable, but that is a statement about the
/// executable, not about its caller.
///
/// Naming the file outright removes the question. The library is installed
/// beside the executable -- `bundle/lib/`, which is where the app's
/// linux/CMakeLists.txt installs the `<flavour>_bundled_libraries` value each
/// flavour's linux/CMakeLists.txt sets -- and [Platform.resolvedExecutable]
/// resolves the symlink a packaged install puts in /usr/bin, so "the directory
/// the executable is in" is right however the app was started.
///
/// Falls back to the bare soname when there is no such file, which is what a
/// build that installed the library into a system directory instead would
/// need.
String _linuxLibraryPath(String libName) {
  final executableDir = File(Platform.resolvedExecutable).parent.path;
  final separator = Platform.pathSeparator;
  final bundled = '$executableDir${separator}lib${separator}lib$libName.so';
  return File(bundled).existsSync() ? bundled : 'lib$libName.so';
}

StockfishBindings? _latestBindings;
StockfishBindings? _lightBindings;
StockfishBindings? _fairyBindings;
StockfishBindings? _pikafishBindings;

StockfishBindings _getBindings(StockfishFlavor flavor) {
  // Check for zone override (used in tests)
  final override = Zone.current[stockfishBindingsFactoryKey];
  if (override != null) {
    return (override as StockfishBindings Function(StockfishFlavor))(flavor);
  }

  switch (flavor) {
    case StockfishFlavor.latestNoNNUE:
      _latestBindings ??= StockfishBindingsFFI(
        _openDynamicLibrary('multistockfish_chess'),
      );
      return _latestBindings!;
    case StockfishFlavor.light:
      _lightBindings ??= StockfishBindingsFFI(
        _openDynamicLibrary('multistockfish_light'),
        symbolPrefix: 'light',
      );
      return _lightBindings!;
    case StockfishFlavor.variant:
      _fairyBindings ??= StockfishBindingsFFI(
        _openDynamicLibrary('multistockfish_variant'),
        symbolPrefix: 'variant',
      );
      return _fairyBindings!;
    case StockfishFlavor.pikafish:
      _pikafishBindings ??= StockfishBindingsFFI(
        _openDynamicLibrary('multistockfish_pikafish'),
        symbolPrefix: 'pikafish',
      );
      return _pikafishBindings!;
  }
}

void _isolateMain(_IsolateArgs args) {
  final (mainPort, flavor) = args;
  final bindings = _getBindings(flavor);
  final exitCode = bindings.main();
  mainPort.send(exitCode);

  // Logging from a spawned isolate does not reach the root logger's listeners,
  // so the exit code is reported by _onEngineExit on the main isolate instead.
  _logger.fine('nativeMain returns $exitCode');
}

void _isolateStdout(_IsolateArgs args) {
  final (stdoutPort, flavor) = args;

  try {
    _readStdout(stdoutPort, flavor);
  } catch (error, stackTrace) {
    // This isolate is the only thing draining the engine's pipe. If it stops
    // without saying so the pipe fills, the engine blocks in write() inside its
    // UCI loop and answers nothing from then on -- a wedge with no visible
    // cause. Reporting the failure lets the handle fail the engine instead.
    stdoutPort.send({'error': '$error', 'stackTrace': '$stackTrace'});
  }

  // Tells the handle the pipe is free. Until this arrives the isolate is
  // still blocked reading it, and a create() that drained the pipe in the
  // meantime would leave it blocked forever -- a second reader stealing the
  // next engine's output.
  stdoutPort.send(null);
}

void _readStdout(SendPort stdoutPort, StockfishFlavor flavor) {
  final bindings = _getBindings(flavor);

  String previous = '';

  while (true) {
    final stdout = bindings.stdoutRead();

    if (stdout == null) {
      _logger.fine('nativeStdoutRead returns NULL');
      return;
    }

    final data = previous + stdout;
    final lines = data.split('\n');
    previous = lines.removeLast();

    // One message for the whole chunk rather than one per line. A page of
    // engine output holds dozens of `info` lines during a multi-PV search, and
    // every port message is an event the main isolate has to turn its loop for
    // -- which is the isolate also running the UI and the start-up timeouts.
    if (lines.isNotEmpty) stdoutPort.send(lines);
  }
}

Future<bool> _spawnIsolates(
  SendPort mainPort,
  SendPort stdoutPort,
  StockfishFlavor flavor,
) async {
  // Check for zone override (used in tests)
  final override = Zone.current[stockfishSpawnIsolatesKey];
  if (override != null) {
    return (override
        as Future<bool> Function(SendPort, SendPort, StockfishFlavor))(
      mainPort,
      stdoutPort,
      flavor,
    );
  }

  final bindings = _getBindings(flavor);

  final initResult = bindings.init();
  if (initResult != 0) {
    _logger.severe(
      'Failed to initialize the ${flavor.name} engine (init returned '
      '$initResult): ${describeInitCode(initResult)}. '
      'phase=${StockfishPhase.fromCode(bindings.phase()).name} '
      'step=${bindings.phaseStep()} '
      'for ${bindings.phaseElapsedMs()}ms'
      '${bindings.lastError() == null ? '' : '; native error: ${bindings.lastError()}'}',
    );
    mainPort.send(1);
    stdoutPort.send(null);
    return false;
  }

  try {
    await Isolate.spawn(_isolateStdout, (
      stdoutPort,
      flavor,
    ), debugName: 'Stockfish stdout isolate');
  } catch (error) {
    _logger.severe('Failed to spawn stdout isolate: $error');
    mainPort.send(1);
    stdoutPort.send(null);
    return false;
  }

  try {
    await Isolate.spawn(_isolateMain, (
      mainPort,
      flavor,
    ), debugName: 'Stockfish main isolate');
  } catch (error) {
    _logger.severe('Failed to spawn main isolate: $error');
    mainPort.send(1);
    return false;
  }

  return true;
}

typedef _IsolateArgs = (SendPort sendPort, StockfishFlavor flavor);

class _StockfishState extends ChangeNotifier
    implements ValueListenable<StockfishState> {
  StockfishState _value = StockfishState.initial;

  @override
  StockfishState get value => _value;

  _setValue(StockfishState v) {
    if (v == _value) return;
    _value = v;
    notifyListeners();
  }
}
