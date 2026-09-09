@Tags(['integration'])
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:dartclaw_core/dartclaw_core.dart' hide TurnManager, TurnRunner;
import 'package:dartclaw_kernel/dartclaw_kernel.dart';
import 'package:dartclaw_runtime/dartclaw_runtime.dart';
import 'package:dartclaw_testing/dartclaw_testing.dart' hide TurnManager, TurnRunner;
import 'package:dartclaw_workflow/testing.dart' show FakeProviderAuthPreflight;
import 'package:logging/logging.dart';
import 'package:test/test.dart';

void main() {
  test('postgres runtime composition owns one prepared backend', () async {
    final configured = Platform.environment['DARTCLAW_TEST_POSTGRES_URL'];
    if (configured == null || configured.isEmpty) {
      throw StateError('DARTCLAW_TEST_POSTGRES_URL is required');
    }
    final uri = Uri.parse(configured);
    final dsn = uri.replace(queryParameters: {...uri.queryParameters, 'sslmode': 'disable'}).toString();
    final namespace = 'dc_runtime_${DateTime.now().microsecondsSinceEpoch}_${Random().nextInt(1 << 20)}';
    var admin = await PostgresBackend.open(dsn: dsn, poolSize: 1);
    await admin.execute('CREATE SCHEMA "$namespace"');
    await admin.close();
    final dataDir = Directory.systemTemp.createTempSync('postgres_runtime_');
    final configFile = File('${dataDir.path}/dartclaw.yaml')..writeAsStringSync('# test\n');
    PostgresBackend? opened;
    var opens = 0;
    var searchOpens = 0;
    DartclawRuntime? runtime;
    try {
      final config = DartclawConfig(
        agent: const AgentConfig(provider: 'claude'),
        credentials: const CredentialsConfig(entries: {'anthropic': CredentialEntry(apiKey: 'anthropic-key')}),
        providers: ProvidersConfig(
          entries: {'claude': ProviderEntry(executable: Platform.resolvedExecutable, poolSize: 0)},
        ),
        server: ServerConfig(dataDir: dataDir.path, claudeExecutable: Platform.resolvedExecutable),
        database: DatabaseConfig(backend: DatabaseBackendKind.postgres, url: dsn, poolSize: 3),
      );
      final harnesses = HarnessFactory()..register('claude', (_) => FakeAgentHarness());
      runtime = await DartclawRuntime.build(
        config,
        dataDir: dataDir.path,
        port: 0,
        harnessFactory: harnesses,
        searchBackendFactory: (_) async {
          searchOpens++;
          return SqliteBackend.openInMemory();
        },
        taskBackendFactory: (_) async {
          opens++;
          return opened = await PostgresBackend.open(dsn: dsn, poolSize: 3, namespace: namespace);
        },
        stderrLine: (_) {},
        exitFn: (code) => throw StateError('unexpected exit($code)'),
        resolvedConfigPath: configFile.path,
        messageRedactor: MessageRedactor(),
        resolvedAssets: const ResolvedAssets.embedded(),
        headless: true,
        runWorkflowSkillsBootstrap: false,
        providerAuthPreflight: FakeProviderAuthPreflight(),
      );
      final task = await runtime.taskService.create(id: 'pg-task', title: 'Postgres', description: 'round trip');
      expect((await runtime.taskService.get(task.id))?.title, 'Postgres');
      expect(opens, 1);
      expect(searchOpens, 0);
      expect(File(config.dartclawDbPath).existsSync(), isFalse);
      expect(File(config.searchDbPath).existsSync(), isFalse);

      await runtime.shutdown();
      runtime = null;
      await expectLater(() => opened!.execute('SELECT 1'), throwsStateError);
      await opened!.close();
    } finally {
      await runtime?.shutdown();
      await opened?.close();
      admin = await PostgresBackend.open(dsn: dsn, poolSize: 1);
      await admin.execute('DROP SCHEMA IF EXISTS "$namespace" CASCADE');
      await admin.close();
      if (dataDir.existsSync()) dataDir.deleteSync(recursive: true);
    }
  });

  test('runtime authentication refusal is secret-free and audited once', () async {
    final base = _configuredDsn();
    final nonce = DateTime.now().microsecondsSinceEpoch;
    final username = 'missing_runtime_$nonce';
    const password = 'RuntimeAuthFixturePasswordX9';
    final dsn = base.replace(userInfo: '$username:$password').toString();
    final dataDir = Directory.systemTemp.createTempSync('postgres_runtime_auth_refusal_');
    try {
      final capture = await _captureFailedBuild(dsn: dsn, dataDir: dataDir);
      final entries = _auditEntries(dataDir);

      expect(capture.error, isA<_RuntimeExit>().having((error) => error.code, 'code', 1));
      expect(entries, hasLength(1));
      expect(entries.single, containsPair('guard', 'DatabaseEgress'));
      expect(entries.single, containsPair('hook', 'connection'));
      expect(entries.single, containsPair('verdict', 'deny'));
      expect(entries.single, containsPair('decision', 'auth_failure'));
      expect(entries.single, containsPair('credentialRef', 'DARTCLAW_DATABASE_URL'));
      _expectCredentialAbsent(capture.observable(entries), [username, password, dsn]);
    } finally {
      if (dataDir.existsSync()) dataDir.deleteSync(recursive: true);
    }
  });

  test('runtime schema refusal closes the audited connection without leaking credentials', () async {
    final base = _configuredDsn();
    final nonce = '${DateTime.now().microsecondsSinceEpoch}_${Random().nextInt(1 << 20)}';
    final role = 'dc_schema_user_$nonce';
    final database = 'dc_schema_db_$nonce';
    const password = 'RuntimeSchemaFixturePasswordY8';
    final dsn = base.replace(userInfo: '$role:$password', path: '/$database').toString();
    final dataDir = Directory.systemTemp.createTempSync('postgres_runtime_schema_refusal_');
    final admin = await PostgresBackend.open(dsn: base.toString(), poolSize: 1);
    PostgresBackend? fixture;
    try {
      await admin.execute('CREATE ROLE "$role" LOGIN PASSWORD \'$password\' NOSUPERUSER');
      await admin.execute('CREATE DATABASE "$database" OWNER "$role"');
      fixture = await PostgresBackend.open(dsn: dsn, poolSize: 1);
      await fixture.execute('CREATE TABLE unrelated_table (id bigint PRIMARY KEY)');
      await fixture.close();
      fixture = null;

      final capture = await _captureFailedBuild(dsn: dsn, dataDir: dataDir);
      final entries = _auditEntries(dataDir);

      expect(capture.error, isA<_RuntimeExit>().having((error) => error.code, 'code', 1));
      expect(capture.formattedLogs, contains(contains('SchemaIncompatibleException')));
      expect(entries.map((entry) => entry['decision']), ['open', 'close']);
      for (final entry in entries) {
        expect(entry, containsPair('guard', 'DatabaseEgress'));
        expect(entry, containsPair('hook', 'connection'));
        expect(entry, containsPair('verdict', 'allow'));
        expect(entry, containsPair('credentialRef', 'DARTCLAW_DATABASE_URL'));
      }
      expect(entries.where((entry) => entry['decision'] == 'auth_failure'), isEmpty);
      _expectCredentialAbsent(capture.observable(entries), [role, password, dsn]);
    } finally {
      await fixture?.close();
      await admin.execute('DROP DATABASE IF EXISTS "$database" WITH (FORCE)');
      await admin.execute('DROP ROLE IF EXISTS "$role"');
      await admin.close();
      if (dataDir.existsSync()) dataDir.deleteSync(recursive: true);
    }
  });
}

Uri _configuredDsn() {
  final configured = Platform.environment['DARTCLAW_TEST_POSTGRES_URL'];
  if (configured == null || configured.isEmpty) {
    throw StateError('DARTCLAW_TEST_POSTGRES_URL is required');
  }
  final uri = Uri.parse(configured);
  return uri.replace(queryParameters: {...uri.queryParameters, 'sslmode': 'disable'});
}

Future<_FailedStartup> _captureFailedBuild({required String dsn, required Directory dataDir}) async {
  final stderrLines = <String>[];
  final stdoutLines = <String>[];
  final records = <LogRecord>[];
  final previousLevel = Logger.root.level;
  Logger.root.level = Level.ALL;
  final subscription = Logger.root.onRecord.listen(records.add);
  Object? error;
  StackTrace? stackTrace;
  DartclawRuntime? runtime;
  try {
    final configFile = File('${dataDir.path}/dartclaw.yaml')..writeAsStringSync('# live refusal fixture\n');
    final config = DartclawConfig(
      agent: const AgentConfig(provider: 'claude'),
      providers: ProvidersConfig(
        entries: {'claude': ProviderEntry(executable: Platform.resolvedExecutable, poolSize: 0)},
      ),
      server: ServerConfig(dataDir: dataDir.path, claudeExecutable: Platform.resolvedExecutable),
      database: DatabaseConfig(
        backend: DatabaseBackendKind.postgres,
        url: dsn,
        urlEnvVars: const ['DARTCLAW_DATABASE_URL'],
        poolSize: 1,
      ),
    );
    await runZoned(() async {
      runtime = await DartclawRuntime.build(
        config,
        dataDir: dataDir.path,
        port: 0,
        harnessFactory: HarnessFactory()..register('claude', (_) => FakeAgentHarness()),
        stderrLine: stderrLines.add,
        exitFn: (code) => throw _RuntimeExit(code),
        resolvedConfigPath: configFile.path,
        messageRedactor: MessageRedactor(),
        resolvedAssets: const ResolvedAssets.embedded(),
        headless: true,
        runWorkflowSkillsBootstrap: false,
      );
    }, zoneSpecification: ZoneSpecification(print: (_, _, _, line) => stdoutLines.add(line)));
    error = StateError('Expected runtime startup to fail');
  } catch (caught, caughtStackTrace) {
    error = caught;
    stackTrace = caughtStackTrace;
  } finally {
    await runtime?.shutdown();
    await subscription.cancel();
    Logger.root.level = previousLevel;
  }
  final formatter = HumanFormatter(redactor: LogRedactor(redactor: MessageRedactor()));
  return _FailedStartup(
    error: error,
    stackTrace: stackTrace,
    stderrLines: stderrLines,
    stdoutLines: stdoutLines,
    formattedLogs: records.map(formatter.format).toList(growable: false),
  );
}

List<Map<String, dynamic>> _auditEntries(Directory dataDir) {
  final files =
      dataDir
          .listSync()
          .whereType<File>()
          .where((file) => file.uri.pathSegments.last.startsWith('audit-') && file.path.endsWith('.ndjson'))
          .toList()
        ..sort((left, right) => left.path.compareTo(right.path));
  return files
      .expand((file) => file.readAsLinesSync())
      .where((line) => line.trim().isNotEmpty)
      .map((line) => jsonDecode(line) as Map<String, dynamic>)
      .toList(growable: false);
}

void _expectCredentialAbsent(String observable, List<String> forbidden) {
  for (final value in forbidden.where((value) => value.isNotEmpty)) {
    if (observable.contains(value)) {
      fail('A database credential value appeared on an observable startup surface.');
    }
  }
}

final class _FailedStartup {
  const new({
    required this.error,
    required this.stackTrace,
    required this.stderrLines,
    required this.stdoutLines,
    required this.formattedLogs,
  });

  final Object error;
  final StackTrace? stackTrace;
  final List<String> stderrLines;
  final List<String> stdoutLines;
  final List<String> formattedLogs;

  String observable(List<Map<String, dynamic>> entries) => [
    ...stdoutLines,
    ...stderrLines,
    ...formattedLogs,
    '$error',
    if (stackTrace != null) '$stackTrace',
    jsonEncode(entries),
  ].join('\n');
}

final class _RuntimeExit implements Exception {
  const new(this.code);

  final int code;
}
