// ignore_for_file: avoid_print

/// Example: Setting up a security guard chain.
///
/// Demonstrates how to compose [Guard] instances into a [GuardChain]
/// for security policy enforcement.
library;

import 'package:dartclaw_core/dartclaw_core.dart';

void main() async {
  // Configure individual guards with defaults.
  final commandGuard = CommandGuard();
  final fileGuard = FileGuard();
  final networkGuard = NetworkGuard();
  final sanitizer = InputSanitizer();

  // Compose into a chain with an audit logger.
  final chain = GuardChain(
    guards: [commandGuard, fileGuard, networkGuard, sanitizer],
    auditLogger: GuardAuditLogger(),
  );

  // Evaluate an inbound message.
  final verdict = await chain.evaluateMessageReceived(
    'Hello, how are you?',
    source: 'web',
  );

  if (verdict.isBlock) {
    print('Blocked: $verdict');
  } else {
    print('Message allowed');
  }
}
