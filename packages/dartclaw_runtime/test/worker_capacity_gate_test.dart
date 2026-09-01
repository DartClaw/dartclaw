import 'package:dartclaw_runtime/src/worker_capacity_gate.dart';
import 'package:test/test.dart';

void main() {
  group('WorkerCapacityGate', () {
    test('admits queued callers in FIFO order as permits release', () async {
      final gate = WorkerCapacityGate(1);
      final first = await gate.acquire();
      final order = <int>[];

      final secondFuture = gate.acquire().then((permit) {
        order.add(2);
        return permit;
      });
      final thirdFuture = gate.acquire().then((permit) {
        order.add(3);
        return permit;
      });

      expect(gate.activeCount, 1);
      expect(gate.queuedCount, 2);
      expect(gate.tryAcquire(), isNull);

      first.release();
      final second = await secondFuture;
      expect(order, [2]);
      expect(gate.activeCount, 1);
      expect(gate.queuedCount, 1);

      second.release();
      final third = await thirdFuture;
      expect(order, [2, 3]);
      third.release();

      expect(gate.activeCount, 0);
      expect(gate.queuedCount, 0);
      expect(gate.availableCount, 1);
    });

    test('permit release is idempotent', () async {
      final gate = WorkerCapacityGate(1);
      final permit = await gate.acquire();

      permit.release();
      permit.release();

      expect(gate.activeCount, 0);
      expect(gate.availableCount, 1);
    });

    test('quarantine permanently removes the owned slot from effective capacity', () async {
      final gate = WorkerCapacityGate(2);
      final first = await gate.acquire();
      final second = await gate.acquire();

      first.quarantine();
      second.release();

      expect(gate.configuredCapacity, 2);
      expect(gate.effectiveCapacity, 1);
      expect(gate.quarantinedCount, 1);
      expect(gate.availableCount, 1);
    });

    test('final quarantine rejects queued and future wait acquisitions without leaking permits', () async {
      final gate = WorkerCapacityGate(1);
      final active = await gate.acquire();
      final queued = gate.acquire();
      final queuedFailure = expectLater(queued, throwsStateError);

      active.quarantine();

      await queuedFailure;
      await expectLater(gate.acquire(), throwsStateError);
      expect(gate.tryAcquire(), isNull);
      expect(gate.activeCount, 0);
      expect(gate.queuedCount, 0);
      expect(gate.quarantinedCount, 1);
      expect(gate.effectiveCapacity, 0);
      expect(gate.availableCount, 0);

      active.release();
      expect(gate.activeCount, 0);
    });

    test('close rejects queued and future acquisitions', () async {
      final gate = WorkerCapacityGate(1);
      final active = await gate.acquire();
      final queued = gate.acquire();

      gate.close();

      await expectLater(queued, throwsStateError);
      await expectLater(gate.acquire(), throwsStateError);
      expect(gate.tryAcquire(), isNull);
      active.release();
    });
  });
}
