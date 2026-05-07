// ignore_for_file: avoid_print

import 'dart:io';

import 'package:dartclaw/dartclaw.dart';

const _defaultPrompt = 'What is the capital of France?';

Future<void> main(List<String> args) async {
  final prompt = args.isEmpty
      ? _readPrompt() ?? _defaultPrompt
      : args.join(' ');

  final harness = ClaudeCodeHarness(cwd: '.');
  await harness.start();
  final sub = harness.events.listen((event) {
    if (event case DeltaEvent(:final text)) stdout.write(text);
  });

  try {
    final result = await harness.turn(
      sessionId: 'single-turn-cli',
      messages: [
        {'role': 'user', 'content': prompt},
      ],
      systemPrompt: 'You are a concise assistant.',
    );
    stdout.writeln('\n\nstop_reason=${result['stop_reason']}');
  } finally {
    await sub.cancel();
    await harness.dispose();
  }
}

String? _readPrompt() {
  if (!stdin.hasTerminal) return null;
  stdout.write('Prompt [$_defaultPrompt]: ');
  final input = stdin.readLineSync()?.trim();
  if (input == null) return null;
  return input.isEmpty ? _defaultPrompt : input;
}
