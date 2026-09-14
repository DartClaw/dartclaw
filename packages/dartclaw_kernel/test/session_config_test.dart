import 'package:dartclaw_kernel/dartclaw_kernel.dart';
import 'package:test/test.dart';

import 'support/load_config.dart';

void main() {
  test('auto settle defaults off and accepts a positive idle-day threshold', () {
    expect(const SessionConfig.defaults().autoSettleIdleDays, 0);
    final config = loadYaml('sessions:\n  auto_settle_idle_days: 14\n');
    expect(config.sessions.autoSettleIdleDays, 14);
  });

  test('negative auto settle threshold fails closed to disabled', () {
    final config = loadYaml('sessions:\n  auto_settle_idle_days: -1\n');
    expect(config.sessions.autoSettleIdleDays, 0);
  });
}
