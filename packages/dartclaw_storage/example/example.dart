import 'package:dartclaw_storage/dartclaw_storage.dart';

void main() async {
  final db = openSearchDbInMemory();
  final memory = MemoryService(db);
  final backend = Fts5SearchBackend(memoryService: memory);

  memory.rebuildIndex([
    MemoryIndexRow(
      text: 'DartClaw uses a hardened Dart runtime for agent orchestration.',
      source: 'README.md',
      category: 'architecture',
      createdAt: DateTime.now(),
    ),
  ]);

  final hits = await backend.search('hardened runtime');
  print('Memory hits: ${hits.length}');
  if (hits.isNotEmpty) {
    print('Top hit: ${hits.first.text}');
  }

  db.close();
}
