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

  final db = openSearchDbInMemory();
  final memory = MemoryService(db);
  final backend = Fts5SearchBackend(memoryService: memory);
  memory.rebuildIndex([
    MemoryIndexRow(
      text: 'DartClaw uses a Dart runtime for agent orchestration.',
      source: 'README.md',
      category: 'architecture',
      createdAt: DateTime.now(),
    ),
  ]);
  final hits = await backend.search('agent orchestration');
  print('Memory hits: ${hits.length}');
  db.close();
}
