import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:dartclaw_kernel/dartclaw_kernel.dart';
import 'package:test/test.dart';

import 'fts_contract.dart';
import 'repository_contract.dart';
import 'schema_contract.dart';

typedef ContractBackendOpener = Future<ContractBackend> Function();

final class ContractBackend {
  new({
    required this.backend,
    required this.searchBackend,
    required this.index,
    required this.schema,
    required this.engine,
    required this.blobType,
    required this.close,
    this.lexemeOf,
  });

  final DatabaseBackend backend;
  final DatabaseBackend searchBackend;
  final FullTextIndex index;
  final ContractSchemaAdapter schema;
  final String engine;
  final String blobType;
  final Future<void> Function() close;
  final Future<String?> Function(String term)? lexemeOf;
}

final class ContractSchemaAdapter {
  const new({
    required this.prepare,
    required this.snapshot,
    required this.verifyRequiredSchema,
    required this.seedAuthoritativeData,
    required this.readAuthoritativeData,
    required this.prepareAndCountWrites,
    required this.reset,
    required this.setEpoch,
    required this.removeMarker,
    required this.duplicateMarker,
    required this.setTextEpoch,
    required this.dropRequiredTable,
    required this.dropRequiredColumn,
    required this.dropRequiredIndex,
    required this.addOrphans,
    required this.bootstrapStatementCount,
    required this.prepareWithFailure,
    this.proveDerivedRebuild,
  });

  final Future<void> Function() prepare;
  final Future<Object> Function() snapshot;
  final Future<void> Function() verifyRequiredSchema;
  final Future<void> Function() seedAuthoritativeData;
  final Future<Object> Function() readAuthoritativeData;
  final Future<int> Function() prepareAndCountWrites;
  final Future<void> Function() reset;
  final Future<void> Function(int epoch) setEpoch;
  final Future<void> Function() removeMarker;
  final Future<void> Function() duplicateMarker;
  final Future<void> Function() setTextEpoch;
  final Future<void> Function() dropRequiredTable;
  final Future<void> Function() dropRequiredColumn;
  final Future<void> Function() dropRequiredIndex;
  final Future<void> Function() addOrphans;
  final int bootstrapStatementCount;
  final Future<void> Function(int statementNumber) prepareWithFailure;
  final Future<void> Function()? proveDerivedRebuild;
}

enum ContractBackendKind { sqlite, postgres }

const requiredTaskTables = <String>{
  'agent_executions',
  'workflow_step_executions',
  'tasks',
  'task_artifacts',
  'goals',
  'task_events',
  'turns',
  'workflow_runs',
  'workflow_run_migrations',
  'kg_facts',
  'dartclaw_schema',
};

const requiredTaskIndexes = <String>{
  'idx_tasks_status',
  'idx_tasks_type',
  'idx_tasks_status_type',
  'idx_tasks_workflow_run_id',
  'idx_task_artifacts_task_id',
  'idx_agent_executions_session_id',
  'idx_agent_executions_provider',
  'idx_wse_run_step',
  'idx_wse_agent_execution',
  'idx_goals_parent',
  'idx_task_events_task',
  'idx_task_events_task_kind',
  'idx_task_events_timestamp',
  'idx_turns_session',
  'idx_turns_task',
  'idx_turns_started',
  'idx_turns_model',
  'idx_turns_provider',
  'idx_workflow_runs_status',
  'idx_workflow_runs_definition',
  'kg_facts_lookup',
};

File contractFixtureFile(String name) {
  final configPath = Platform.packageConfig;
  if (configPath == null) throw StateError('Dart package configuration is unavailable');
  final configUri = Uri.parse(configPath);
  final config = jsonDecode(File.fromUri(configUri).readAsStringSync()) as Map<String, dynamic>;
  final packages = config['packages'] as List<dynamic>;
  final package = packages.cast<Map<String, dynamic>>().singleWhere((entry) => entry['name'] == 'dartclaw_core');
  final root = configUri.resolve('${package['rootUri']}/');
  return File.fromUri(root.resolve('test/storage/contract/$name'));
}

void databaseBackendContractTests({
  required String name,
  required ContractBackendOpener open,
  required ContractBackendKind kind,
}) {
  group('$name database contract', () {
    ContractBackend? current;

    setUp(() async {
      current = await open();
    });
    tearDown(() => current?.close());

    databaseBackendGroups(() => current!, kind);
    schemaContractGroups(() => current!, kind);
    ftsContractGroups(() => current!);
    repositoryContractGroups(() => current!);
  });
}

void databaseBackendGroups(ContractBackend Function() current, ContractBackendKind kind) {
  group('[contract:backend.crud] portable values', () {
    test('round-trips canonical scalars and reports changed rows', () async {
      final backend = current().backend;
      await backend.execute('''
        CREATE TABLE contract_values (
          id INTEGER PRIMARY KEY,
          integer_value INTEGER,
          real_value REAL,
          text_value TEXT,
          blob_value ${current().blobType},
          null_value TEXT
        )
      ''');
      final blob = Uint8List.fromList([0, 127, 255]);
      expect(
        await backend.execute('INSERT INTO contract_values VALUES (?, ?, ?, ?, ?, ?)', [
          1,
          42,
          3.5,
          'hello',
          blob,
          null,
        ]),
        1,
      );
      await backend.execute('INSERT INTO contract_values (id, integer_value) VALUES (?, ?)', [2, 7]);
      expect(await backend.execute('UPDATE contract_values SET text_value = ?', ['updated']), 2);
      expect(
        await backend.query('INSERT INTO contract_values (id, integer_value) VALUES (?, ?) RETURNING id', [3, 9]),
        [
          {'id': 3},
        ],
      );
      final stored = (await backend.query('SELECT * FROM contract_values WHERE id = ?', [1])).single;
      expect(stored, {
        'id': 1,
        'integer_value': 42,
        'real_value': 3.5,
        'text_value': 'updated',
        'blob_value': blob,
        'null_value': null,
      });
    });

    test('owner statements are reusable and close idempotently', () async {
      final backend = current().backend;
      await backend.execute('CREATE TABLE contract_records (value TEXT NOT NULL)');
      final statement = await backend.prepare('INSERT INTO contract_records VALUES (?)');
      expect(await statement.execute(['first']), 1);
      expect(await statement.execute(['second']), 1);
      await statement.close();
      await statement.close();
      await expectLater(statement.execute(['late']), throwsStateError);
    });
  });

  group('[contract:backend.transaction] ownership', () {
    test('rollback rethrows the body error and includes owner-zone writes', () async {
      final backend = current().backend;
      await backend.execute('CREATE TABLE contract_records (value TEXT NOT NULL)');
      final error = StateError('contract rollback');
      await expectLater(
        backend.transaction<void>((tx) async {
          await tx.execute('INSERT INTO contract_records VALUES (?)', ['handle']);
          await backend.execute('INSERT INTO contract_records VALUES (?)', ['owner']);
          throw error;
        }),
        throwsA(same(error)),
      );
      expect(await backend.query('SELECT value FROM contract_records'), isEmpty);
    });

    for (final throughOwner in [false, true]) {
      test('rejects nested transaction through ${throughOwner ? 'owner' : 'handle'}', () async {
        final backend = current().backend;
        await backend.execute('CREATE TABLE contract_records (value TEXT NOT NULL)');
        await backend
            .transaction<void>((tx) async {
              await expectLater(
                (throughOwner ? backend : tx).transaction<void>((_) async {}),
                throwsA(isA<NestedTransactionError>()),
              );
            })
            .timeout(const Duration(seconds: 2));
      });
    }

    for (final rollsBack in [false, true]) {
      test('transaction statements expire after ${rollsBack ? 'rollback' : 'commit'}', () async {
        final backend = current().backend;
        await backend.execute('CREATE TABLE contract_records (value TEXT NOT NULL)');
        late DatabaseStatement statement;
        final transaction = backend.transaction<void>((tx) async {
          statement = await tx.prepare('INSERT INTO contract_records VALUES (?)');
          await statement.execute(['inside']);
          if (rollsBack) throw StateError('rollback');
        });
        if (rollsBack) {
          await expectLater(transaction, throwsStateError);
        } else {
          await transaction;
        }
        await expectLater(statement.execute(['late']), throwsStateError);
        await expectLater(statement.query(['late']), throwsStateError);
        await statement.close();
        await statement.close();
      });
    }

    test('an outside conflicting write waits for rollback and persists', () async {
      final backend = current().backend;
      await backend.execute('CREATE TABLE contract_records (value TEXT UNIQUE NOT NULL)');
      final started = Completer<void>();
      final release = Completer<void>();
      final transaction = backend.transaction<void>((tx) async {
        await tx.execute('INSERT INTO contract_records VALUES (?)', ['uncommitted']);
        started.complete();
        await release.future;
        throw StateError('rollback');
      });
      await started.future;
      final outside = backend.execute('INSERT INTO contract_records VALUES (?)', ['uncommitted']);
      release.complete();
      await expectLater(transaction, throwsStateError);
      await outside;
      expect((await backend.query('SELECT value FROM contract_records')).single['value'], 'uncommitted');
    });
  });

  if (kind == ContractBackendKind.sqlite) {
    group('[contract:backend.sqlite_completion_order] serialization', () {
      test('outside work completes after the transaction future', () async {
        final backend = current().backend;
        await backend.execute('CREATE TABLE contract_records (value TEXT NOT NULL)');
        final started = Completer<void>();
        final release = Completer<void>();
        final order = <String>[];
        final transaction = backend
            .transaction<void>((tx) async {
              await tx.execute('INSERT INTO contract_records VALUES (?)', ['inside']);
              started.complete();
              await release.future;
            })
            .then((_) => order.add('transaction'));
        await started.future;
        final outside = backend
            .execute('INSERT INTO contract_records VALUES (?)', ['outside'])
            .then((_) => order.add('outside'));
        release.complete();
        await Future.wait([transaction, outside]);
        expect(order, ['transaction', 'outside']);
      });
    });
  }

  if (kind == ContractBackendKind.postgres) {
    group('[contract:backend.ambiguous_dispatch_no_replay] dispatch boundary', () {
      test('retries only before dispatch and never replays unknown outcomes', () async {
        const policy = PostgresDispatchPolicy('contract.local:5432/test', attemptLimit: 3, retryDelay: Duration.zero);
        var attempts = 0;
        expect(
          await policy.run<int>('connect', (_) async {
            attempts++;
            if (attempts < 3) throw StateError('before dispatch');
            return 7;
          }),
          7,
        );
        expect(attempts, 3);

        for (final operation in ['statement', 'COMMIT']) {
          attempts = 0;
          await expectLater(
            policy.run<void>(operation, (markDispatched) async {
              attempts++;
              markDispatched();
              throw StateError('transport lost');
            }),
            throwsA(isA<StorageUnknownOutcomeException>()),
          );
          expect(attempts, 1);
        }
      });
    });
  }
}
