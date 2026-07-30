import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:dartclaw_server/src/web/page_support.dart';
import 'package:test/test.dart';

void main() {
  group('getStatus without HealthService', () {
    final cases = <(WorkerState?, String)>[
      (WorkerState.idle, 'healthy'),
      (WorkerState.busy, 'healthy'),
      (WorkerState.stopped, 'unhealthy'),
      (WorkerState.crashed, 'degraded'),
      (null, 'degraded'),
    ];

    for (final (workerState, expectedStatus) in cases) {
      test('maps ${workerState?.name ?? 'unknown'} to $expectedStatus', () async {
        final status = await getStatus(null, workerState == null ? null : () => workerState, 3);

        expect(status['status'], expectedStatus);
        expect(status['worker_state'], workerState?.name ?? 'unknown');
        expect(status['session_count'], 3);
      });
    }
  });
}
