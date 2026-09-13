import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:test/test.dart';

void main() {
  test('runtime SQLite exposes FTS5 and round-trips a MATCH query', () async {
    final backend = SqliteBackend.openInMemory();
    addTearDown(backend.close);

    final options = (await backend.query('PRAGMA compile_options')).map((row) => row.values.first as String).toSet();
    expect(options, contains('ENABLE_FTS5'));

    await backend.execute('CREATE VIRTUAL TABLE release_fts_probe USING fts5(body)');
    await backend.execute("INSERT INTO release_fts_probe(body) VALUES ('bundled sqlite')");
    final matches = await backend.query("SELECT body FROM release_fts_probe WHERE body MATCH 'bundled'");
    expect(matches.single['body'], 'bundled sqlite');
  });
}
