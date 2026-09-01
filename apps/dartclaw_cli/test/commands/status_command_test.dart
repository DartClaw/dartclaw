import 'dart:convert';
import 'dart:io';

import 'package:dartclaw_cli/src/commands/status_command.dart';
import 'package:dartclaw_kernel/dartclaw_kernel.dart';
import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:test/test.dart';

void main() {
  late StatusCommand statusCommand;

  setUp(() {
    statusCommand = StatusCommand();
  });

  group('StatusCommand', () {
    test('has no custom options', () {
      expect(statusCommand.argParser.options.keys, equals(['help']));
    });

    test('missing data directory prints informative message', () async {
      final output = <String>[];
      final globalDir = '${Directory.systemTemp.path}/dartclaw-status-missing-${DateTime.now().microsecondsSinceEpoch}';

      final config = DartclawConfig(server: ServerConfig(dataDir: globalDir));
      final command = StatusCommand(config: config, writeLine: output.add);

      await command.run();
      expect(output, equals(['No data directory found at $globalDir']));
    });

    test('existing data directory prints session count and worker status line', () async {
      final output = <String>[];
      final tmp = await Directory.systemTemp.createTemp('dartclaw-status-test-');
      final sessionsDir = Directory('${tmp.path}/sessions');
      sessionsDir.createSync(recursive: true);

      // Create a session
      final sessions = SessionService(baseDir: sessionsDir.path);
      await sessions.createSession();

      addTearDown(() async {
        if (tmp.existsSync()) {
          await tmp.delete(recursive: true);
        }
      });

      final config = DartclawConfig(
        server: ServerConfig(dataDir: tmp.path, claudeExecutable: '/usr/local/bin/claude'),
      );
      final command = StatusCommand(config: config, writeLine: output.add);

      await command.run();

      expect(output, hasLength(6));
      expect(output[0], equals('DartClaw Status'));
      expect(output[1], contains('Data dir:  ${tmp.path}'));
      expect(output[2], equals('  Sessions:  1'));
      expect(output[3], equals('  Harness:   not running (executable: /usr/local/bin/claude)'));
      expect(output[4], contains('Memory:    unknown'));
      expect(output[5], equals('  Index:     unknown'));
    });

    test('reads persisted committed corpus and degraded index while server is stopped', () async {
      final output = <String>[];
      final tmp = await Directory.systemTemp.createTemp('dartclaw-status-memory-test-');
      addTearDown(() async => tmp.delete(recursive: true));
      Directory('${tmp.path}/sessions').createSync(recursive: true);
      final config = DartclawConfig(server: ServerConfig(dataDir: tmp.path));
      final corpus = MemoryCorpusService(workspaceDir: config.workspaceDir);
      final snapshot = await corpus.statusSnapshot();
      await corpus.close();
      final sidecar = File('${config.workspaceDir}/.dartclaw-memory-corpus.json');
      final persisted = jsonDecode(sidecar.readAsStringSync()) as Map<String, dynamic>;
      final status = persisted['status'] as Map<String, dynamic>;
      status
        ..['observationOldest'] = '2026-08-01T00:00:00.000Z'
        ..['observationNewest'] = '2026-08-12T00:00:00.000Z'
        ..['opaqueLegacyLocators'] = ['memory/legacy/<opaque>']
        ..['migrationState'] = 'migrated'
        ..['migrationSnapshotPath'] = '/workspace/<snapshot>'
        ..['migrationAction'] = 'Inspect <snapshot> before removal.';
      sidecar.writeAsStringSync(jsonEncode(persisted));
      await IndexHealthStore(workspaceDir: config.workspaceDir).recordDegraded(
        canonicalRevision: snapshot.collectionRevision,
        canonicalFingerprint: snapshot.collectionFingerprint,
        stage: 'validation',
        reason: 'test failure',
      );

      await StatusCommand(config: config, writeLine: output.add).run();

      expect(output, contains(contains('Memory:    revision 1; curated=0')));
      expect(output, contains('  Observation usage: 0 bytes (exact); warning=none'));
      expect(output, contains(contains('Observation range: 2026-08-01')));
      expect(output, contains('  Migration: migrated; snapshot=/workspace/<snapshot>'));
      expect(output, contains('  Migration action: Inspect <snapshot> before removal.'));
      expect(output, contains('  Opaque legacy: 1; memory/legacy/<opaque>'));
      expect(output, contains(contains('Index:     degraded; canonical=1; indexed=unknown')));
      expect(output, contains('  Index failure stage: validation'));
      expect(output, contains('  Index reason: test failure'));
      expect(output, contains(contains('stop DartClaw')));
    });

    test('corrupt persisted collection evidence fails closed without scanning the workspace', () async {
      final output = <String>[];
      final tmp = await Directory.systemTemp.createTemp('dartclaw-status-corrupt-test-');
      addTearDown(() async => tmp.delete(recursive: true));
      Directory('${tmp.path}/sessions').createSync(recursive: true);
      final config = DartclawConfig(server: ServerConfig(dataDir: tmp.path));
      Directory(config.workspaceDir).createSync(recursive: true);
      File('${config.workspaceDir}/.dartclaw-memory-corpus.json').writeAsStringSync('{broken');
      File('${config.workspaceDir}/MEMORY.md').writeAsStringSync('## tempting fallback\n- [2026-08-12] do not scan');

      await StatusCommand(config: config, writeLine: output.add).run();

      expect(output, contains('  Memory:    unknown (persisted evidence could not be read)'));
      expect(output, contains('  Index:     unknown'));
      expect(output.join('\n'), isNot(contains('tempting fallback')));
    });

    test('corrupt index evidence does not invalidate a valid persisted corpus', () async {
      final output = <String>[];
      final tmp = await Directory.systemTemp.createTemp('dartclaw-status-corrupt-index-test-');
      addTearDown(() async => tmp.delete(recursive: true));
      Directory('${tmp.path}/sessions').createSync(recursive: true);
      final config = DartclawConfig(server: ServerConfig(dataDir: tmp.path));
      final corpus = MemoryCorpusService(workspaceDir: config.workspaceDir);
      await corpus.statusSnapshot();
      await corpus.close();
      File('${config.workspaceDir}/.dartclaw-memory-index.json').writeAsStringSync('{broken');

      await StatusCommand(config: config, writeLine: output.add).run();

      expect(output, contains(contains('Memory:    revision 1; curated=0')));
      expect(output, isNot(contains('  Memory:    unknown (persisted evidence could not be read)')));
      expect(output, contains('  Index:     unknown'));
      expect(output, contains(contains('stop DartClaw')));
    });
  });
}
