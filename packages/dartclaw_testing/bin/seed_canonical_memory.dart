import 'dart:io';

import 'package:dartclaw_testing/dartclaw_testing.dart';

/// Seeds one canonical memory entry into a workspace outside a Dart test.
///
/// Release smoke tests need searchable memory in a workspace the shipped binary
/// then indexes. Writing that corpus by hand is a second encoding of the
/// canonical dialect and rots into a startup refusal the moment the dialect
/// moves, so scripts reach the authority through this entrypoint instead.
Future<void> main(List<String> arguments) async {
  if (arguments.length != 3) {
    stderr.writeln('usage: seed_canonical_memory <workspace-dir> <topic> <entry-text>');
    exitCode = 64;
    return;
  }
  final [workspaceDir, topic, text] = arguments;
  await seedCanonicalMemory(
    workspaceDir,
    topics: {
      topic: [text],
    },
  );
}
