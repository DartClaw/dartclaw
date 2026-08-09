import 'package:dartclaw_models/dartclaw_models.dart';
import 'package:test/test.dart';

void main() {
  test('execution routing round-trips and can be cleared explicitly', () {
    final createdAt = DateTime.utc(2026, 8, 9, 10);
    final session = Session(
      id: 'session-1',
      type: SessionType.logicalAgent,
      channelKey: 'agent:search:logical:session-1',
      provider: 'codex',
      securityProfile: 'restricted',
      createdAt: createdAt,
      updatedAt: createdAt,
    );

    final decoded = Session.fromJson(session.toJson());
    expect(decoded.provider, 'codex');
    expect(decoded.securityProfile, 'restricted');
    expect(decoded.copyWith(provider: null, securityProfile: null).toJson(), isNot(contains('provider')));
    expect(decoded.copyWith(provider: null, securityProfile: null).toJson(), isNot(contains('securityProfile')));
  });
}
