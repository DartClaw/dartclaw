import 'dart:io';
import 'dart:isolate';

import 'package:dartclaw_cli/src/commands/auth/auth_command.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

/// The AOT entry point, located through the package's own resolved lib URI so
/// the read survives a concurrent suite moving `Directory.current`.
Future<String> _entryPointSource() async {
  final runnerUri = await Isolate.resolvePackageUri(Uri.parse('package:dartclaw_cli/src/runner.dart'));
  final packageRoot = p.dirname(p.dirname(p.dirname(runnerUri!.toFilePath())));
  return File(p.join(packageRoot, 'bin', 'dartclaw.dart')).readAsStringSync();
}

void main() {
  test('the auth group is registered in the AOT entry point', () async {
    final source = await _entryPointSource();

    expect(
      source,
      contains('addCommand(AuthCommand())'),
      reason: 'an unregistered group is a command no operator can reach, with a fully green suite',
    );
    expect(source, contains("import 'package:dartclaw_cli/src/commands/auth/auth_command.dart';"));
  });

  test('the group exposes exactly the two provider write paths', () {
    final auth = AuthCommand();

    expect(auth.name, 'auth');
    expect(auth.subcommands.keys, unorderedEquals(['claude', 'codex']));
  });
}
