// ignore_for_file: avoid_print

import 'package:dartclaw_storage/dartclaw_storage.dart';

void main() async {
  final db = openSearchDbInMemory();
  final memory = MemoryService(db);
  final backend = Fts5SearchBackend(memoryService: memory);

  memory.insertChunk(
    text: 'DartClaw uses a hardened Dart runtime for agent orchestration.',
    source: 'README.md',
    category: 'architecture',
  );

  final hits = await backend.search('hardened runtime');
  print('Memory hits: ${hits.length}');
  if (hits.isNotEmpty) {
    print('Top hit: ${hits.first.text}');
  }

  memory.close();
}
