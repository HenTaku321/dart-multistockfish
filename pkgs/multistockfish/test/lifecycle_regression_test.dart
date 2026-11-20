import 'dart:async';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:multistockfish/multistockfish.dart';

import 'stockfish_test.dart'
    show MockEngineController, createEngine, runWithMockStockfish;

void main() {
  test(
    'a spontaneous main exit retains its slot until the reader stops',
    () async {
      final controller = MockEngineController();
      await runWithMockStockfish(controller, () async {
        final engine = await createEngine(controller);
        final native = controller.engine;
        try {
          native.exitWithoutStoppingReader(1);
          await pumpEventQueue();
          expect(
            Stockfish.debugLiveEngines[StockfishFlavor.light],
            same(engine),
          );
          var disposed = false;
          final disposal = engine.dispose().then((_) => disposed = true);
          await pumpEventQueue();
          expect(disposed, isFalse);
          native.stopReader();
          await disposal;
          expect(Stockfish.debugLiveEngines, isEmpty);
        } finally {
          native.stopReader();
          await pumpEventQueue();
        }
      });
    },
  );

  test(
    'a quit timeout reports failure and retains the live native slot',
    () async {
      final controller = MockEngineController();
      await runWithMockStockfish(controller, () async {
        final engine = await createEngine(controller);
        fakeAsync((clock) {
          Object? failure;
          var succeeded = false;
          engine.dispose().then(
            (_) => succeeded = true,
            onError: (Object error) => failure = error,
          );
          clock.elapse(kQuitTimeout + const Duration(seconds: 1));
          expect(succeeded, isFalse);
          expect(failure, isA<TimeoutException>());
          expect(
            Stockfish.debugLiveEngines[StockfishFlavor.light],
            same(engine),
          );
        });
        controller.exit(0);
        await pumpEventQueue();
        expect(Stockfish.debugLiveEngines, isEmpty);
      });
    },
  );
}
