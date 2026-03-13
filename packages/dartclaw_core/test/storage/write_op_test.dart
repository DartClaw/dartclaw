import 'dart:async';

import 'package:dartclaw_core/src/storage/write_op.dart';
import 'package:logging/logging.dart';
import 'package:test/test.dart';

void main() {
  group('WriteOp extraction', () {
    test('WriteOp completes after running the operation', () async {
      final queue = BoundedWriteQueue();
      addTearDown(queue.close);

      var executed = false;
      final op = WriteOp(() async {
        executed = true;
      });

      queue.add(op);
      await op.completer.future;

      expect(executed, isTrue);
    });
  });

  group('backpressure', () {
    test('overflow produces explicit error', () async {
      final queue = BoundedWriteQueue();
      addTearDown(queue.close);

      final gate = Completer<void>();
      final ops = List.generate(BoundedWriteQueue.maxDepth, (_) => WriteOp(() => gate.future));
      for (final op in ops) {
        queue.add(op);
      }

      final overflow = WriteOp(() async {});
      queue.add(overflow);

      await expectLater(overflow.completer.future, throwsA(isA<StateError>()));
      gate.complete();
      await Future.wait(ops.map((op) => op.completer.future));
    });

    test('logs warning at 80 percent capacity', () async {
      final records = <LogRecord>[];
      final sub = Logger.root.onRecord.listen(records.add);
      addTearDown(sub.cancel);
      final previousLevel = Logger.root.level;
      Logger.root.level = Level.ALL;
      addTearDown(() => Logger.root.level = previousLevel);

      final queue = BoundedWriteQueue();
      addTearDown(queue.close);

      final gate = Completer<void>();
      final ops = List.generate(800, (_) => WriteOp(() => gate.future));
      for (final op in ops) {
        queue.add(op);
      }

      expect(
        records.where((record) => record.level == Level.WARNING).map((record) => record.message),
        anyElement(contains('Write queue depth high')),
      );

      gate.complete();
      await Future.wait(ops.map((op) => op.completer.future));
    });
  });
}
