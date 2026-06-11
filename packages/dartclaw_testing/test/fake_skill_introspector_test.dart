import 'package:dartclaw_testing/dartclaw_testing.dart';
import 'package:test/test.dart';

void main() {
  group('FakeSkillIntrospector', () {
    test('returns configured skills and tracks calls', () async {
      final introspector = FakeSkillIntrospector({
        'claude': {'andthen:spec'},
      });

      final result = await introspector.listAvailable(
        provider: 'claude',
        executable: '/bin/claude',
        providerOptions: const {'inherit_user_settings': false},
      );

      expect(result, {'andthen:spec'});
      expect(introspector.calls, [(provider: 'claude', executable: '/bin/claude')]);
      expect(introspector.providerOptionsByProvider['claude'], {'inherit_user_settings': false});
    });

    test('returns empty set for unknown provider', () async {
      final introspector = FakeSkillIntrospector(const {});
      expect(await introspector.listAvailable(provider: 'codex'), isEmpty);
    });
  });
}
