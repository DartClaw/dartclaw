import 'package:dartclaw_kernel/dartclaw_kernel.dart';
import 'package:test/test.dart';

void main() {
  group('context section', () {
    DartclawConfig load(String yaml) => DartclawConfig.load(
      fileReader: (path) => path == '/home/user/.dartclaw/dartclaw.yaml' ? yaml : null,
      env: {'HOME': '/home/user'},
    );

    test('a config still carrying the retired exploration_summary_threshold key loads', () {
      final config = load('''
context:
  exploration_summary_threshold: 50000
  max_result_bytes: 65536
''');

      expect(config.context.maxResultBytes, 65536);
    });

    test('every context key the runtime still honours round-trips from YAML', () {
      final config = load('''
context:
  reserve_tokens: 30000
  max_result_bytes: 65536
  warning_threshold: 90
  compact_instructions: Keep decisions
  identifier_preservation: custom
  identifier_instructions: Keep task ids verbatim
''');

      expect(config.context.reserveTokens, 30000);
      expect(config.context.maxResultBytes, 65536);
      expect(config.context.warningThreshold, 90);
      expect(config.context.compactInstructions, 'Keep decisions');
      expect(config.context.identifierPreservation, IdentifierPreservationMode.custom);
      expect(config.context.identifierInstructions, 'Keep task ids verbatim');
    });

    test('warning_threshold saturates both bounds without an advisory', () {
      final low = load('context:\n  warning_threshold: 3\n');
      final high = load('context:\n  warning_threshold: 200\n');

      expect(low.context.warningThreshold, 50);
      expect(high.context.warningThreshold, 99);
      expect(low.warnings.where((warning) => warning.contains('context.warning_threshold')), isEmpty);
      expect(high.warnings.where((warning) => warning.contains('context.warning_threshold')), isEmpty);
    });
  });
}
