import 'package:dartclaw_server/src/task/workflow_turn_extractor.dart';
import 'package:test/test.dart';

// scenario-types: hybrid, plain

void main() {
  test('partial inline workflow-context payload is preserved and marked partial', () {
    final extractor = WorkflowTurnExtractor();
    final turn = extractor.parse(
      '<workflow-context>{"summary":"Inline summary"}</workflow-context>',
      requiredKeys: const ['summary', 'confidence'],
    );

    expect(turn.inlinePayload, {'summary': 'Inline summary'});
    expect(turn.isPartial, isTrue);
    expect(turn.missingKeys, ['confidence']);
  });
}
