import 'package:dartclaw_kernel/dartclaw_kernel.dart';
import 'package:test/test.dart';

import 'database_backend_contract.dart';

void schemaContractGroups(ContractBackend Function() current, ContractBackendKind kind) {
  group('[contract:schema.fresh_bootstrap] atomic preparation', () {
    test('creates a current schema and a second prepare is a no-op', () async {
      final schema = current().schema;
      await schema.reset();
      final empty = await schema.snapshot();
      await schema.prepare();
      final prepared = await schema.snapshot();
      expect(prepared, isNot(empty));
      await schema.verifyRequiredSchema();
      await schema.prepare();
      expect(await schema.snapshot(), prepared);
    });
  });

  group('[contract:schema.compatible_reopen] current schema', () {
    test('reopens without writes and preserves authoritative data', () async {
      final schema = current().schema;
      await schema.seedAuthoritativeData();
      final data = await schema.readAuthoritativeData();
      final before = await schema.snapshot();
      expect(await schema.prepareAndCountWrites(), 0);
      expect(await schema.snapshot(), before);
      expect(await schema.readAuthoritativeData(), data);
    });
  });

  group('[contract:schema.orphan_column_tolerance] required objects only', () {
    test('preserves an extra nullable column and foreign table', () async {
      final schema = current().schema;
      await schema.addOrphans();
      final before = await schema.snapshot();
      await schema.prepare();
      expect(await schema.snapshot(), before);
    });
  });

  group('[contract:schema.incompatible_refusal] fail closed', () {
    final mutations = <String, Future<void> Function(ContractSchemaAdapter)>{
      'epoch 0': (schema) => schema.setEpoch(0),
      'epoch 2': (schema) => schema.setEpoch(2),
      'absent marker': (schema) => schema.removeMarker(),
      'duplicated marker': (schema) => schema.duplicateMarker(),
      'non-integer marker': (schema) => schema.setTextEpoch(),
      'missing table': (schema) => schema.dropRequiredTable(),
      'missing column': (schema) => schema.dropRequiredColumn(),
      'missing index': (schema) => schema.dropRequiredIndex(),
    };
    for (final mutation in mutations.entries) {
      test('refuses ${mutation.key} without mutation', () async {
        final schema = current().schema;
        await mutation.value(schema);
        final before = await schema.snapshot();
        await expectLater(schema.prepare(), throwsA(isA<SchemaIncompatibleException>()));
        expect(await schema.snapshot(), before);
      });
    }
  });

  group('[contract:schema.bootstrap_rollback] failed transition', () {
    test('preserves the empty store and a clean retry converges', () async {
      final schema = current().schema;
      for (var statement = 1; statement <= schema.bootstrapStatementCount; statement++) {
        await schema.reset();
        final empty = await schema.snapshot();
        await expectLater(schema.prepareWithFailure(statement), throwsA(anything));
        expect(await schema.snapshot(), empty, reason: 'failed statement $statement');
        await schema.prepare();
        expect(await schema.snapshot(), isNot(empty));
      }
    });
  });

  if (kind == ContractBackendKind.sqlite) {
    group('[contract:schema.sqlite_derived_rebuild] derived store', () {
      test('rebuilds only from a complete authenticated source', () async {
        await current().schema.proveDerivedRebuild!();
      });
    });
  }
}
