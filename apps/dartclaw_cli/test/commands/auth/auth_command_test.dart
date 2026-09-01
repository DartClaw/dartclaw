import 'package:dartclaw_cli/src/commands/auth/auth_command.dart';
import 'package:dartclaw_cli/src/runner.dart';
import 'package:test/test.dart';

void main() {
  test('the auth group is registered in the shipped command surface', () {
    expect(
      buildDartclawRunner().commands['auth'],
      isA<AuthCommand>(),
      reason: 'an unregistered group is a command no operator can reach, with a fully green suite',
    );
  });

  test('the group exposes exactly the two provider write paths', () {
    final auth = AuthCommand();

    expect(auth.name, 'auth');
    expect(auth.subcommands.keys, unorderedEquals(['claude', 'codex']));
  });
}
