import 'package:dartclaw_security/src/env_substitute.dart';
import 'package:test/test.dart';

void main() {
  test('resolves \${VAR} to env value', () {
    expect(envSubstitute(r'Hello ${HOME}', env: {'HOME': '/users/me'}), 'Hello /users/me');
  });

  test('multiple vars in one string and undefined var resolves to empty string', () {
    expect(envSubstitute(r'${A} and ${B}', env: {'A': 'alpha', 'B': 'beta'}), 'alpha and beta');
    expect(envSubstitute(r'key=${UNDEFINED_VAR}', env: {}), 'key=');
  });

  test(r'$VAR (no braces) is NOT substituted', () {
    expect(envSubstitute(r'$HOME stays', env: {'HOME': '/x'}), r'$HOME stays');
  });
}
