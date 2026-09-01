import 'package:dartclaw_testing/dartclaw_testing.dart';
import 'package:test/test.dart';

void main() {
  test('TI05 records schema and provider-session inputs exactly', () async {
    final turns = FakeTurnManager();
    const schema = {
      'type': 'object',
      'properties': {
        'answer': {'type': 'string'},
      },
    };

    await turns.reserveTurn(
      'session-1',
      outputSchema: schema,
      providerSessionId: 'provider-session-x',
      requestProviderSessionResume: true,
    );
    await turns.startTurn(
      'session-2',
      const [],
      outputSchema: schema,
      providerSessionId: 'provider-session-y',
      requestProviderSessionResume: true,
    );

    expect(turns.reservedTurns.first.outputSchema, same(schema));
    expect(turns.reservedTurns.first.providerSessionId, 'provider-session-x');
    expect(turns.reservedTurns.first.requestProviderSessionResume, isTrue);
    expect(turns.startedTurns.single.outputSchema, same(schema));
    expect(turns.startedTurns.single.providerSessionId, 'provider-session-y');
    expect(turns.startedTurns.single.requestProviderSessionResume, isTrue);
  });
}
