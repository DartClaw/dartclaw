import 'package:test/test.dart';

import '../scenario_test_support.dart';

// scenario-types: plain

void main() {
  test('50 concurrent keyed-session lookups collapse to one mapping', () async {
    final harness = await ScenarioTaskHarness.create();
    addTearDown(harness.dispose);

    final results = await Future.wait(List.generate(50, (_) => harness.sessions.getOrCreateByKey('agent:same-key')));

    final ids = results.map((session) => session.id).toSet();
    expect(ids, hasLength(1));

    final index = await harness.readSessionKeyIndex();
    expect(index, {'agent:same-key': ids.single});
  });
}
