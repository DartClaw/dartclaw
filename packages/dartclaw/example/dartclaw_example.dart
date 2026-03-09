// ignore_for_file: avoid_print

/// Example: Basic DartClaw agent harness usage.
///
/// Demonstrates how to create a [ClaudeCodeHarness], configure it with
/// [HarnessConfig], start it, and execute a turn with streaming events.
///
/// **Prerequisites**: `claude` binary installed and `ANTHROPIC_API_KEY` set.
library;

import 'package:dartclaw/dartclaw.dart';

void main() async {
  // Create the harness pointed at the current directory.
  final harness = ClaudeCodeHarness(cwd: '.');

  try {
    await harness.start();

    // Listen for streaming bridge events.
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

    // Execute a conversational turn.
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
  }
}
