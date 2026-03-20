import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:dartclaw_cli/src/commands/cleanup_command.dart';
import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:test/test.dart';

void main() {
  late Directory tempDir;
  late String sessionsDir;
  late List<String> output;
  late int? exitCode;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('dartclaw_cleanup_test_');
    sessionsDir = '${tempDir.path}/sessions';
    Directory(sessionsDir).createSync(recursive: true);
    output = [];
    exitCode = null;
  });

  tearDown(() {
    if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
  });

  /// Runs the cleanup command via a CommandRunner with the given [args].
  Future<void> runCleanup(List<String> args, {DartclawConfig? config}) async {
    final cfg = config ?? DartclawConfig(server: ServerConfig(dataDir: tempDir.path));
    final command = CleanupCommand(config: cfg, writeLine: output.add, exitFn: (code) => exitCode = code);

    final runner = CommandRunner<void>('dartclaw', 'test')..addCommand(_TestSessionsCommand(command));

    await runner.run(['sessions', 'cleanup', ...args]);
  }

  group('CleanupCommand', () {
    test('name is cleanup', () {
      final cmd = CleanupCommand();
      expect(cmd.name, 'cleanup');
    });

    test('description is set', () {
      final cmd = CleanupCommand();
      expect(cmd.description, isNotEmpty);
    });

    test('cleanup with empty sessions dir reports no actions', () async {
      await runCleanup([]);

      expect(output, anyElement(contains('Session Maintenance Report')));
      expect(output, anyElement(contains('No actions needed.')));
      expect(exitCode, 0);
    });

    test('cleanup with --dry-run always uses warn mode', () async {
      final config = DartclawConfig(
        server: ServerConfig(dataDir: tempDir.path),
        sessions: SessionConfig(maintenanceConfig: const SessionMaintenanceConfig(mode: MaintenanceMode.enforce)),
      );

      await runCleanup(['--dry-run'], config: config);

      expect(output, anyElement(contains('warn (--dry-run override)')));
      expect(exitCode, 0);
    });

    test('cleanup with --enforce always uses enforce mode', () async {
      await runCleanup(['--enforce']);

      expect(output, anyElement(contains('enforce (--enforce override)')));
      expect(exitCode, 0);
    });

    test('cleanup with no flags respects config mode', () async {
      final config = DartclawConfig(
        server: ServerConfig(dataDir: tempDir.path),
        sessions: SessionConfig(maintenanceConfig: const SessionMaintenanceConfig(mode: MaintenanceMode.enforce)),
      );

      await runCleanup([], config: config);

      expect(output, anyElement(contains('enforce (config)')));
      expect(exitCode, 0);
    });

    test('cleanup with both --dry-run and --enforce throws UsageException', () async {
      expect(() => runCleanup(['--dry-run', '--enforce']), throwsA(isA<UsageException>()));
    });

    test('output format includes summary sections', () async {
      await runCleanup([]);

      expect(output, anyElement(contains('Session Maintenance Report')));
      expect(output, anyElement(contains('Mode:')));
      expect(output, anyElement(contains('Sessions:')));
      expect(output, anyElement(contains('Disk usage:')));
    });

    test('cleanup exit code 0 on success', () async {
      await runCleanup([]);
      expect(exitCode, 0);
    });

    test('cleanup archives stale sessions in enforce mode', () async {
      // Create a stale session
      final sessions = SessionService(baseDir: sessionsDir);
      final s = await sessions.createSession();
      _backdateSession(sessionsDir, s.id, const Duration(days: 60));

      final config = DartclawConfig(
        server: ServerConfig(dataDir: tempDir.path),
        sessions: SessionConfig(
          maintenanceConfig: const SessionMaintenanceConfig(mode: MaintenanceMode.enforce, pruneAfterDays: 30),
        ),
      );

      await runCleanup([], config: config);

      expect(output, anyElement(contains('Archived:')));
      expect(output, anyElement(contains('stale')));
      expect(exitCode, 0);
    });

    test('cleanup with --dry-run does not modify sessions', () async {
      final sessions = SessionService(baseDir: sessionsDir);
      final s = await sessions.createSession();
      _backdateSession(sessionsDir, s.id, const Duration(days: 60));

      final config = DartclawConfig(
        server: ServerConfig(dataDir: tempDir.path),
        sessions: SessionConfig(
          maintenanceConfig: const SessionMaintenanceConfig(mode: MaintenanceMode.enforce, pruneAfterDays: 30),
        ),
      );

      await runCleanup(['--dry-run'], config: config);

      // Session should still be user type (not archived)
      final fetched = await sessions.getSession(s.id);
      expect(fetched!.type, SessionType.user);
    });
  });
}

/// Test wrapper for SessionsCommand that uses a pre-configured CleanupCommand.
class _TestSessionsCommand extends Command<void> {
  _TestSessionsCommand(CleanupCommand cleanup) {
    addSubcommand(cleanup);
  }

  @override
  String get name => 'sessions';

  @override
  String get description => 'test sessions';
}

void _backdateSession(String sessionsDir, String sessionId, Duration age) {
  final metaFile = File('$sessionsDir/$sessionId/meta.json');
  final content = metaFile.readAsStringSync();
  final backdated = DateTime.now().subtract(age).toIso8601String();
  // Replace the updatedAt timestamp
  final updated = content.replaceAllMapped(RegExp(r'"updatedAt":"[^"]*"'), (m) => '"updatedAt":"$backdated"');
  metaFile.writeAsStringSync(updated);
}
