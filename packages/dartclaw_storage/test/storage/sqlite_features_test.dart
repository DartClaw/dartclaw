import 'package:dartclaw_storage/dartclaw_storage.dart';
import 'package:test/test.dart';

void main() {
  test('runtime SQLite exposes FTS5 and round-trips a MATCH query', () {
    final db = openSearchDbInMemory();
    addTearDown(db.close);

    final options = db.select('PRAGMA compile_options').map((row) => row.values.first as String).toSet();
    expect(options, contains('ENABLE_FTS5'));

    db.execute('CREATE VIRTUAL TABLE release_fts_probe USING fts5(body)');
    db.execute("INSERT INTO release_fts_probe(body) VALUES ('bundled sqlite')");
    final matches = db.select("SELECT body FROM release_fts_probe WHERE body MATCH 'bundled'");
    expect(matches.single['body'], 'bundled sqlite');
  });
}
