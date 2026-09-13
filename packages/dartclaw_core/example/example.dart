/// Example: Setting up a security guard chain.
///
/// Demonstrates how to compose [Guard] instances into a [GuardChain]
/// for security policy enforcement.
library;

import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:dartclaw_kernel/dartclaw_kernel.dart';

void main() async {
  // Configure individual guards with defaults.
  final commandGuard = CommandGuard();
  final fileGuard = FileGuard();
  final networkGuard = NetworkGuard();

  // Compose into a chain with an optional verdict callback.
  final chain = GuardChain(
    guards: [commandGuard, fileGuard, networkGuard],
    onVerdict: (name, category, verdict, message, context) {
      print(
        '[$name][$category][${context.hookPoint}] '
        'verdict=$verdict${message != null ? ' message=$message' : ''}',
      );
    },
  );

  // Evaluate an inbound message.
  final verdict = await chain.evaluateMessageReceived('Hello, how are you?', source: 'web');

  if (verdict.isBlock) {
    print('Blocked: $verdict');
  } else {
    print('Message allowed');
  }

  final databaseBackend = SqliteBackend.openInMemory();
  await SqliteSchemaGate.prepareSearch(databaseBackend, storeName: 'example search.db');
  final index = SqliteFtsIndex(databaseBackend, table: SqliteFtsTable.memoryChunks);
  final backend = Fts5SearchBackend(index: index);
  await index.replaceAll([
    SearchDocument(
      id: 'README.md',
      chunks: const ['DartClaw uses a Dart runtime for agent orchestration.'],
      metadata: const {'source': 'README.md', 'category': 'architecture', 'role': 'memory', 'provenance': 'unknown'},
      timestamp: DateTime.now(),
    ),
  ], userId: 'owner');
  final hits = await backend.search('agent orchestration');
  print('Memory hits: ${hits.length}');
  await databaseBackend.close();
}
