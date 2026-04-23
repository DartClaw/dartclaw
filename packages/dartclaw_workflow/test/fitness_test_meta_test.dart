import 'package:test/test.dart';

import 'fitness_support.dart';

void main() {
  test('F-SIZE-1 failure message names the file, current LOC, and ceiling', () {
    final message = sizeViolationMessage(
      'packages/dartclaw_workflow/lib/src/workflow/workflow_executor.dart',
      901,
      800,
    );

    expect(message, isNotNull);
    expect(message, contains('workflow_executor.dart'));
    expect(message, contains('901'));
    expect(message, contains('800'));
  });
}
