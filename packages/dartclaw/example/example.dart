// ignore_for_file: avoid_print

/// Example: Guarded harness execution with event handling.
///
/// Demonstrates how to combine a [GuardChain], the typed [EventBus], and a
/// [ClaudeCodeHarness] in a minimal end-to-end workflow.
///
/// **Prerequisites**: `claude` binary installed and `ANTHROPIC_API_KEY` set.
library;

import 'package:dartclaw/dartclaw.dart';

void main() async {
  final eventBus = EventBus();
  final guardEvents = eventBus.on<GuardBlockEvent>().listen((event) {
    print('[guard:${event.verdict}] ${event.guardName}: ${event.verdictMessage}');
  });

  final sessionEvents = eventBus.on<SessionCreatedEvent>().listen((event) {
    print('Session started: ${event.sessionId} (${event.sessionType})');
  });

  final guards = GuardChain(
    guards: [InputSanitizer(), CommandGuard(), NetworkGuard()],
    onVerdict: (name, category, verdict, message, context) {
      eventBus.fire(
        GuardBlockEvent(
          guardName: name,
          guardCategory: category,
          verdict: verdict,
          verdictMessage: message,
          hookPoint: context.hookPoint,
          sessionId: context.sessionId,
          timestamp: context.timestamp,
        ),
      );
    },
  );

  final verdict = await guards.evaluateMessageReceived(
    'What is 2 + 2?',
    source: 'channel',
    sessionId: 'example-session',
    peerId: 'demo-user',
  );

  if (verdict.isBlock) {
    print('Guard chain blocked the example turn.');
    await guardEvents.cancel();
    await sessionEvents.cancel();
    await eventBus.dispose();
    return;
  }

  final harness = ClaudeCodeHarness(cwd: '.');

  try {
    eventBus.fire(
      SessionCreatedEvent(sessionId: 'example-session', sessionType: SessionType.user.name, timestamp: DateTime.now()),
    );

    await harness.start();

    // Listen for streaming bridge events from the harness.
    harness.events.listen((event) {
      switch (event) {
        case DeltaEvent(:final text):
          print(text);
        case ToolUseEvent(:final toolName):
          print('[Using tool: $toolName]');
        case _:
          break;
      }
    });

    // Execute a conversational turn after the guard chain approved it.
    final result = await harness.turn(
      sessionId: 'example-session',
      messages: [
        {'role': 'user', 'content': 'What is 2 + 2?'},
      ],
      systemPrompt: 'You are a helpful assistant.',
    );

    print('Turn result: $result');
  } finally {
    await harness.dispose();
    await guardEvents.cancel();
    await sessionEvents.cancel();
    await eventBus.dispose();
  }
}
