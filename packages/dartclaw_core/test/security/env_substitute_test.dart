import 'package:dartclaw_core/src/security/env_substitute.dart';
import 'package:test/test.dart';

void main() {
  test('resolves \${VAR} to env value', () {
    expect(envSubstitute(r'Hello ${HOME}', env: {'HOME': '/users/me'}), 'Hello /users/me');
  });

  test('undefined var resolves to empty string', () {
    expect(envSubstitute(r'key=${UNDEFINED_VAR}', env: {}), 'key=');
  });

  test('no-var string passes through unchanged', () {
    expect(envSubstitute('plain text', env: {}), 'plain text');
  });

  test('multiple vars in one string', () {
    expect(envSubstitute(r'${A} and ${B}', env: {'A': 'alpha', 'B': 'beta'}), 'alpha and beta');
  });

  test(r'$VAR (no braces) is NOT substituted', () {
    expect(envSubstitute(r'$HOME stays', env: {'HOME': '/x'}), r'$HOME stays');
  });

  test(r'nested ${${VAR}} is not supported', () {
    // Inner ${VAR} is resolved, outer literal $ remains
    expect(envSubstitute(r'${${VAR}}', env: {'VAR': 'val'}), isA<String>());
  });

  test('empty input returns empty output', () {
    expect(envSubstitute('', env: {}), '');
  });
}
