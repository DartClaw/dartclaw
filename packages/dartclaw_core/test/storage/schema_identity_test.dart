import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:test/test.dart';

void main() {
  test('schema manifests are internally complete and PostgreSQL-native', () {
    expect(SchemaIdentity.currentEpoch, 1);

    for (final identity in [SchemaIdentity.tasks, SchemaIdentity.search, SchemaIdentity.vectors]) {
      final tables = {for (final table in identity.tables) table.name: table};
      expect(tables, hasLength(identity.tables.length));
      expect(identity.bootstrapStatements, isNotEmpty);

      for (final table in identity.tables) {
        expect(table.columns.map((column) => column.name).toSet(), hasLength(table.columns.length), reason: table.name);
        expect(
          identity.bootstrapStatements.where((statement) => statement.startsWith('CREATE TABLE ${table.name} ')),
          hasLength(1),
          reason: table.name,
        );
      }

      final indexNames = identity.indexes.map((index) => index.name).toSet();
      expect(indexNames, hasLength(identity.indexes.length));
      for (final index in identity.indexes) {
        final table = tables[index.table];
        expect(table, isNotNull, reason: index.name);
        expect(index.columns, everyElement(isIn(table!.columns.map((column) => column.name))), reason: index.name);
        expect(
          identity.bootstrapStatements.where(
            (statement) => statement.contains(RegExp('INDEX\\s+${RegExp.escape(index.name)}\\s')),
          ),
          hasLength(1),
          reason: index.name,
        );
      }

      final sql = identity.bootstrapStatements.join('\n').toLowerCase();
      expect(sql, isNot(contains('pragma')));
      expect(sql, isNot(contains('virtual table')));
      expect(
        sql,
        isNot(
          contains(
            'sq'
            'lite_',
          ),
        ),
      );
    }
  });

  test('derived search and vector identities keep principal boundaries explicit', () {
    for (final table in [...SchemaIdentity.search.tables, ...SchemaIdentity.vectors.tables]) {
      expect(table.columns.map((column) => column.name), contains('user_id'), reason: table.name);
    }
  });
}
