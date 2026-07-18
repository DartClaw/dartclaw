import 'package:dartclaw_cli/src/commands/release_sqlite_check_command.dart';
import 'package:dartclaw_cli/src/runner.dart';
import 'package:test/test.dart';

void main() {
  late List<String> output;

  setUp(() {
    output = [];
  });

  test('checks FTS5 and the loaded module through the runtime binding', () async {
    const modulePath = r'C:\release\lib\sqlite3.dll';
    final runner = DartclawRunner()
      ..addCommand(ReleaseSqliteCheckCommand(writeLine: output.add, sqliteModulePath: () => modulePath));

    await runner.run(['release-sqlite-check', '--expected-module', modulePath]);

    expect(output, ['SQLite module: $modulePath', 'Bundled SQLite FTS5 validation passed.']);
  });

  test('rejects a SQLite module outside the release bundle', () async {
    const expectedModule = r'C:\release\lib\sqlite3.dll';
    const loadedModule = r'C:\stray\sqlite3.dll';
    final runner = DartclawRunner()
      ..addCommand(ReleaseSqliteCheckCommand(writeLine: output.add, sqliteModulePath: () => loadedModule));

    await expectLater(
      runner.run(['release-sqlite-check', '--expected-module', expectedModule]),
      throwsA(
        isA<StateError>().having(
          (error) => error.message,
          'message',
          contains('expected "$expectedModule", loaded "$loadedModule"'),
        ),
      ),
    );
  });
}
