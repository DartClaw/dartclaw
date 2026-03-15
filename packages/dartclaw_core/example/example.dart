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

  // Compose into a chain with an optional verdict callback.
  final chain = GuardChain(
    guards: [commandGuard, fileGuard, networkGuard, sanitizer],
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
}
