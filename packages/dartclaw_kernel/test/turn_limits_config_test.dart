import 'package:dartclaw_kernel/dartclaw_kernel.dart';
import 'package:test/test.dart';

import 'support/load_config.dart';

void main() {
  group('TurnLimitsConfig', () {
    test('shipped defaults satisfy the enabled-limit relation', () {
      const limits = TurnLimitsConfig.defaults();

      expect(limits.stallTimeout, greaterThan(Duration.zero));
      expect(limits.turnTimeout, greaterThan(limits.stallTimeout));
      expect(limits.stallAction, TurnProgressAction.cancel);
    });

    test('retired keys fail with replacement named', () {
      final cases = <({String yaml, String retired, String replacement})>[
        (
          yaml: 'worker_timeout: 60\n',
          retired: 'server.worker_timeout',
          replacement: 'governance.turn_limits.turn_timeout',
        ),
        (
          yaml: 'governance:\n  turn_progress:\n    stall_timeout: 5s\n',
          retired: 'governance.turn_progress',
          replacement: 'governance.turn_limits',
        ),
        (
          yaml: 'governance:\n  turn_progress:\n    max_duration: 60s\n',
          retired: 'governance.turn_progress.max_duration',
          replacement: 'governance.turn_limits.turn_timeout',
        ),
        (
          yaml: 'harness:\n  turn_monitor:\n    stuck_after: 5s\n',
          retired: 'harness.turn_monitor',
          replacement: 'governance.turn_limits.stall_timeout',
        ),
      ];

      for (final testCase in cases) {
        expect(
          () => loadYaml(testCase.yaml),
          throwsA(
            isA<FormatException>().having(
              (error) => error.message,
              'message',
              allOf(contains(testCase.retired), contains(testCase.replacement)),
            ),
          ),
          reason: testCase.retired,
        );
      }
    });

    test('enabled stall timeout must be below enabled turn timeout', () {
      expect(
        () => loadYaml('''
governance:
  turn_limits:
    stall_timeout: 10s
    turn_timeout: 10s
'''),
        throwsA(
          isA<FormatException>().having(
            (error) => error.message,
            'message',
            allOf(contains('stall_timeout'), contains('turn_timeout'), contains('less than')),
          ),
        ),
      );
    });

    test('zero disables either budget in numeric and duration-string forms', () {
      for (final zero in ['0', '0s']) {
        final stallDisabled = loadYaml('''
governance:
  turn_limits:
    stall_timeout: $zero
    turn_timeout: 10s
''');
        final turnDisabled = loadYaml('''
governance:
  turn_limits:
    stall_timeout: 10s
    turn_timeout: $zero
''');

        expect(stallDisabled.governance.turnLimits.stallTimeout, Duration.zero, reason: zero);
        expect(turnDisabled.governance.turnLimits.turnTimeout, Duration.zero, reason: zero);
      }
    });

    test('negative numeric and duration-string budgets are rejected', () {
      for (final negative in ['-1', '-1s']) {
        expect(
          () => loadYaml('''
governance:
  turn_limits:
    stall_timeout: $negative
'''),
          throwsA(isA<FormatException>().having((error) => error.message, 'message', contains('non-negative'))),
          reason: negative,
        );
      }
    });
  });
}
