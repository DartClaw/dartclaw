import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:dartclaw_signal/dartclaw_signal.dart';
import 'package:dartclaw_server/src/web/page_support.dart';
import 'package:dartclaw_server/src/web/channel_status.dart';
import 'package:test/test.dart';

import '../signal_test_support.dart';

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

  test('indeterminate Signal registration is a connection error', () async {
    final sidecar = FakeSignalCliManager(fakeRegistrationState: SignalRegistrationState.unknown);
    final channel = SignalChannel(
      sidecar: sidecar,
      config: const SignalConfig(enabled: true, phoneNumber: '+15551234567'),
      dmAccess: DmAccessController(mode: DmAccessMode.open),
      mentionGating: SignalMentionGating(requireMention: false, mentionPatterns: [], ownNumber: '+15551234567'),
    );

    expect(await signalChannelStatus(channel), ChannelStatus.connectionError);
    expect(sidecar.linkUriRequests, 0);
  });
}
