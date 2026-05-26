import 'package:dartclaw_security/dartclaw_security.dart';
import 'package:test/test.dart';

void main() {
  group('InlineProcessEnvironmentPlan', () {
    test('null environment defaults to empty const map', () {
      const plan = InlineProcessEnvironmentPlan(null);
      expect(plan.environment, isEmpty);
      expect(identical(plan.environment, const <String, String>{}), isTrue);
    });

    test('non-null environment is exposed verbatim', () {
      const plan = InlineProcessEnvironmentPlan({'A': '1', 'B': '2'});
      expect(plan.environment, {'A': '1', 'B': '2'});
    });
  });

  group('EmptyProcessEnvironmentPlan', () {
    test('environment is the empty const map', () {
      const plan = EmptyProcessEnvironmentPlan();
      expect(plan.environment, isEmpty);
      expect(identical(plan.environment, const <String, String>{}), isTrue);
    });

    test('produces same SafeProcess.run env as an empty inline plan', () async {
      // Smoke: feed both surfaces through credentialPlan and confirm git's
      // sanitised env materialises identically (defaultGitEnvAllowlist applies).
      const baseEnvironment = {'PATH': '/usr/bin', 'HOME': '/tmp/home', 'GITHUB_TOKEN': 'secret'};

      final viaEmpty = SafeProcess.sanitize(
        baseEnvironment: baseEnvironment,
        allowlist: defaultGitEnvAllowlist,
        extraEnvironment: const EmptyProcessEnvironmentPlan().environment,
      );
      final viaInline = SafeProcess.sanitize(
        baseEnvironment: baseEnvironment,
        allowlist: defaultGitEnvAllowlist,
        extraEnvironment: const InlineProcessEnvironmentPlan(null).environment,
      );

      expect(viaEmpty, viaInline);
      expect(viaEmpty.containsKey('GITHUB_TOKEN'), isFalse);
      expect(viaEmpty['PATH'], '/usr/bin');
    });
  });
}
