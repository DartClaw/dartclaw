// ignore_for_file: avoid_print

import 'package:dartclaw_security/dartclaw_security.dart';

void main() async {
  final chain = GuardChain(
    guards: [InputSanitizer(), CommandGuard(), NetworkGuard()],
    onVerdict: (name, category, verdict, message, context) {
      print('[$category/$name] $verdict at ${context.hookPoint}: ${message ?? 'ok'}');
    },
  );

  final verdict = await chain.evaluateMessageReceived(
    'Please summarize the release notes for me.',
    source: 'channel',
    sessionId: 'security-example',
  );

  print('Final verdict: $verdict');
}
