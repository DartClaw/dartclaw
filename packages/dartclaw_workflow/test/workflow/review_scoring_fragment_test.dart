import 'package:dartclaw_workflow/src/workflow/review_scoring_fragment.dart';
import 'package:dartclaw_workflow/src/workflow/schema_presets.dart' show verdictPreset;
import 'package:test/test.dart';

void main() {
  group('isGatingSeverity', () {
    for (final (severity, gates) in <(String?, bool)>[
      ('critical', true),
      ('high', true),
      ('medium', false),
      ('low', false),
      (null, true),
      ('', true),
      ('blocker', true),
    ]) {
      test('${severity ?? 'null'} ${gates ? 'gates' : 'does not gate'}', () {
        expect(isGatingSeverity(severity), gates);
      });
    }
  });

  test('the verdict preset severity enum and the scoring fragment both read the one severity order', () {
    final findings = (verdictPreset.schema['properties'] as Map)['findings'] as Map;
    final severity = ((findings['items'] as Map)['properties'] as Map)['severity'] as Map;
    expect(severity['enum'], reviewSeverityOrder);

    final fragment = reviewScoringFragmentFor(defaultGatingSeverity);
    final lines = fragment.split('\n').where((line) => line.startsWith('- ')).map((line) => line.split(':').first);
    expect(lines, [for (final name in reviewSeverityOrder) '- $name']);
  });
}
