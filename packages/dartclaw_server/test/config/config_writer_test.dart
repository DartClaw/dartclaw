import 'dart:async';
import 'dart:io';

import 'package:dartclaw_server/src/config/config_writer.dart';
import 'package:test/test.dart';

void main() {
  late Directory tempDir;
  late String configPath;
  late ConfigWriter writer;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('config_writer_test_');
    configPath = '${tempDir.path}/dartclaw.yaml';
    writer = ConfigWriter(configPath: configPath);
  });

  tearDown(() async {
    await writer.dispose();
    tempDir.deleteSync(recursive: true);
  });

  group('round-trip preservation', () {
    test('preserves comments and blank lines', () async {
      final original = '''
# DartClaw configuration
port: 3000

# Agent settings
agent:
  model: claude-sonnet-4-6  # default model
  max_turns: 25

# Unknown section
custom:
  foo: bar
''';
      File(configPath).writeAsStringSync(original);

      await writer.updateFields({'port': 3001});

      final result = File(configPath).readAsStringSync();
      expect(result, contains('# DartClaw configuration'));
      expect(result, contains('# Agent settings'));
      expect(result, contains('# default model'));
      expect(result, contains('port: 3001'));
      expect(result, contains('agent:'));
      expect(result, contains('model: claude-sonnet-4-6'));
      expect(result, contains('max_turns: 25'));
      expect(result, contains('custom:'));
      expect(result, contains('foo: bar'));
    });

    test('preserves unknown keys', () async {
      final original = '''
port: 3000
unknown_key: some_value
another_unknown:
  nested: true
''';
      File(configPath).writeAsStringSync(original);

      await writer.updateFields({'port': 3001});

      final result = File(configPath).readAsStringSync();
      expect(result, contains('unknown_key: some_value'));
      expect(result, contains('another_unknown:'));
      expect(result, contains('nested: true'));
    });
  });

  group('nested path creation', () {
    test('creates nested path from empty file', () async {
      File(configPath).writeAsStringSync('');

      await writer.updateFields({'agent.model': 'claude-sonnet-4-6'});

      final result = File(configPath).readAsStringSync();
      expect(result, contains('agent'));
      expect(result, contains('model: claude-sonnet-4-6'));
    });

    test('creates deeply nested path alongside existing keys', () async {
      File(configPath).writeAsStringSync('port: 3000\n');

      await writer.updateFields(
        {'scheduling.heartbeat.interval_minutes': 15},
      );

      final result = File(configPath).readAsStringSync();
      expect(result, contains('port: 3000'));
      expect(result, contains('scheduling'));
      expect(result, contains('heartbeat'));
      expect(result, contains('interval_minutes: 15'));
    });

    test('adds sibling key without disturbing existing keys', () async {
      File(configPath).writeAsStringSync('agent:\n  model: claude-sonnet-4-6\n');

      await writer.updateFields({'agent.max_turns': 10});

      final result = File(configPath).readAsStringSync();
      expect(result, contains('model: claude-sonnet-4-6'));
      expect(result, contains('max_turns: 10'));
    });
  });

  group('value removal', () {
    test('removes existing key', () async {
      File(configPath).writeAsStringSync('agent:\n  model: claude-sonnet-4-6\n  max_turns: 25\n');

      await writer.updateFields({'agent.model': null});

      final result = File(configPath).readAsStringSync();
      expect(result, isNot(contains('model:')));
      expect(result, contains('max_turns: 25'));
    });

    test('removing non-existent key is a no-op', () async {
      final original = 'port: 3000\n';
      File(configPath).writeAsStringSync(original);

      await writer.updateFields({'nonexistent.key': null});

      final result = File(configPath).readAsStringSync();
      expect(result, contains('port: 3000'));
    });
  });

  group('backup behavior', () {
    test('creates backup with original content', () async {
      final original = 'port: 3000\n';
      File(configPath).writeAsStringSync(original);

      await writer.updateFields({'port': 3001});

      final backup = File(writer.backupPath);
      expect(backup.existsSync(), isTrue);
      expect(backup.readAsStringSync(), equals(original));
    });

    test('second write overwrites backup with previous content', () async {
      File(configPath).writeAsStringSync('port: 3000\n');

      await writer.updateFields({'port': 3001});
      await writer.updateFields({'port': 3002});

      final backup = File(writer.backupPath);
      final backupContent = backup.readAsStringSync();
      expect(backupContent, contains('port: 3001'));
    });

    test('lastBackupTime returns DateTime after write', () async {
      File(configPath).writeAsStringSync('port: 3000\n');

      expect(writer.lastBackupTime, isNull);

      await writer.updateFields({'port': 3001});

      expect(writer.lastBackupTime, isNotNull);
      expect(writer.lastBackupTime, isA<DateTime>());
    });
  });

  group('backup failure aborts write', () {
    test('write aborted when backup target is read-only', () async {
      final original = 'port: 3000\n';
      File(configPath).writeAsStringSync(original);

      // Create a directory at the backup path to make File.copy fail
      Directory(writer.backupPath).createSync();

      await expectLater(
        writer.updateFields({'port': 3001}),
        throwsA(isA<StateError>()),
      );

      // Original file should be unchanged
      expect(File(configPath).readAsStringSync(), equals(original));
    });
  });

  group('atomic write safety', () {
    test('no temp file remains after successful write', () async {
      File(configPath).writeAsStringSync('port: 3000\n');

      await writer.updateFields({'port': 3001});

      expect(File('$configPath.tmp').existsSync(), isFalse);
    });

    test('file content matches expected output', () async {
      File(configPath).writeAsStringSync('port: 3000\n');

      await writer.updateFields({'port': 3001});

      final result = File(configPath).readAsStringSync();
      expect(result, contains('port: 3001'));
    });
  });

  group('concurrent writes', () {
    test('concurrent writes are serialized and both applied', () async {
      File(configPath).writeAsStringSync('port: 3000\nhost: localhost\n');

      final future1 = writer.updateFields({'port': 3001});
      final future2 = writer.updateFields({'host': '0.0.0.0'});

      await Future.wait([future1, future2]);

      final result = File(configPath).readAsStringSync();
      expect(result, contains('port: 3001'));
      expect(result, contains('host: 0.0.0.0'));
    });
  });

  group('error handling', () {
    test('throws FileSystemException when config file does not exist', () async {
      await expectLater(
        writer.updateFields({'port': 3001}),
        throwsA(isA<FileSystemException>()),
      );
    });

    test('throws on invalid YAML', () async {
      File(configPath).writeAsStringSync('invalid: yaml: content: [');

      await expectLater(writer.updateFields({'port': 3001}), throwsA(anything));
    });
  });

  group('type round-trips', () {
    test('preserves int, string, bool values', () async {
      File(configPath).writeAsStringSync('port: 3000\n');

      await writer.updateFields({
        'port': 3001,
        'host': 'localhost',
        'debug': true,
      });

      final result = File(configPath).readAsStringSync();
      expect(result, contains('port: 3001'));
      expect(result, contains('host: localhost'));
      expect(result, contains('debug: true'));
    });

    test('preserves list values', () async {
      File(configPath).writeAsStringSync('port: 3000\n');

      await writer.updateFields({
        'allowed_hosts': ['localhost', '0.0.0.0'],
      });

      final result = File(configPath).readAsStringSync();
      expect(result, contains('allowed_hosts'));
      expect(result, contains('localhost'));
      expect(result, contains('0.0.0.0'));
    });
  });

  group('empty updates', () {
    test('empty updates map is a no-op', () async {
      final original = 'port: 3000\n';
      File(configPath).writeAsStringSync(original);

      await writer.updateFields({});

      // File unchanged, no backup created
      expect(File(configPath).readAsStringSync(), equals(original));
      expect(File(writer.backupPath).existsSync(), isFalse);
    });
  });

  group('dispose', () {
    test('dispose completes without error', () async {
      await writer.dispose();
      // Recreate writer for tearDown
      writer = ConfigWriter(configPath: configPath);
    });

    test('writes after dispose are rejected', () async {
      File(configPath).writeAsStringSync('port: 3000\n');
      await writer.dispose();

      expect(
        () => writer.updateFields({'port': 3001}),
        throwsA(isA<StateError>()),
      );

      // Recreate writer for tearDown
      writer = ConfigWriter(configPath: configPath);
    });
  });

  group('complex YAML structures', () {
    test('handles multi-line strings', () async {
      final original = '''
description: |
  This is a multi-line
  description value
port: 3000
''';
      File(configPath).writeAsStringSync(original);

      await writer.updateFields({'port': 3001});

      final result = File(configPath).readAsStringSync();
      expect(result, contains('multi-line'));
      expect(result, contains('description value'));
      expect(result, contains('port: 3001'));
    });

    test('handles flow-style maps and lists', () async {
      final original = 'tags: [a, b, c]\nport: 3000\n';
      File(configPath).writeAsStringSync(original);

      await writer.updateFields({'port': 3001});

      final result = File(configPath).readAsStringSync();
      expect(result, contains('tags:'));
      expect(result, contains('port: 3001'));
    });
  });
}
