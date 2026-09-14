// Pins subagent usage accounting against frames derived from a retained
// Claude Code 2.1.270 run: the main transcript's per-block `assistant` frames
// (each repeating the message's final usage), one subagent transcript
// (`parent_tool_use_id` set, earlier frames of a message carrying partial
// counts) and the `result` line, whose usage is the main conversation only.
import 'dart:convert';
import 'dart:io';

import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

List<Map<String, dynamic>> _frames() {
  // Suites run from the workspace root as well as the package dir.
  final relative = p.join('test', 'harness', 'fixtures', 'claude_subagent_usage_frames.jsonl');
  final file = File(relative).existsSync() ? File(relative) : File(p.join('packages', 'dartclaw_core', relative));
  return file
      .readAsLinesSync()
      .where((line) => line.trim().isNotEmpty)
      .map((line) => jsonDecode(line) as Map<String, dynamic>)
      .toList();
}

TurnComplete _replay(ClaudeProtocolAdapter adapter, Iterable<Map<String, dynamic>> frames) {
  TurnComplete? complete;
  for (final frame in frames) {
    final message = adapter.parseLine(jsonEncode(frame));
    if (message is TurnComplete) complete = message;
  }
  return complete!;
}

void main() {
  // Deduplicated by message id: the main transcript's two messages, and the
  // subagent's four (13 frames, whose naive sum would be 4536 output tokens).
  const resultUsage = (input: 4, output: 428, cacheRead: 31343, cacheWrite: 16824);
  const subagentUsage = (input: 8, output: 4518, cacheRead: 72247, cacheWrite: 35875);

  test('the fixture is what it claims: per-block repeats on the main thread, partial frames in the subagent', () {
    final frames = _frames();
    final result = frames.last;
    expect(result['type'], 'result');
    expect((result['usage'] as Map)['output_tokens'], resultUsage.output);

    final subagent = frames.where((f) => f['parent_tool_use_id'] != null).toList();
    expect(subagent, hasLength(13));
    expect(subagent.map((f) => (f['message'] as Map)['id']).toSet(), hasLength(4));
    final firstId = (subagent.first['message'] as Map)['id'];
    final outputs = subagent
        .where((f) => (f['message'] as Map)['id'] == firstId)
        .map((f) => ((f['message'] as Map)['usage'] as Map)['output_tokens'])
        .toList();
    expect(outputs, [2, 125], reason: 'the first frame of a message is partial; the last is final');
  });

  test('the turn result carries the result usage plus every subagent message, once each', () {
    final complete = _replay(ClaudeProtocolAdapter(), _frames());

    expect(complete.inputTokens, resultUsage.input + subagentUsage.input);
    expect(complete.outputTokens, resultUsage.output + subagentUsage.output);
    expect(complete.cacheReadTokens, resultUsage.cacheRead + subagentUsage.cacheRead);
    expect(complete.cacheWriteTokens, resultUsage.cacheWrite + subagentUsage.cacheWrite);
  });

  test('main-thread frames are not double counted on top of the result usage', () {
    final adapter = ClaudeProtocolAdapter();
    final complete = _replay(adapter, _frames().where((f) => f['parent_tool_use_id'] == null));

    expect(complete.outputTokens, resultUsage.output);
    expect(complete.cacheReadTokens, resultUsage.cacheRead);
  });

  test('subagent tool_use blocks still surface as tool use', () {
    final adapter = ClaudeProtocolAdapter();
    final toolUses = <ToolUse>[];
    for (final frame in _frames().where((f) => f['parent_tool_use_id'] != null)) {
      final message = adapter.parseLine(jsonEncode(frame));
      if (message is ToolUse) toolUses.add(message);
    }
    expect(toolUses, isNotEmpty);
  });

  test('a held turn credits each result with the subagent usage accrued since the previous one', () {
    final adapter = ClaudeProtocolAdapter();
    final frames = _frames();
    final result = frames.last;
    final subagent = frames.where((f) => f['parent_tool_use_id'] != null).toList();
    final firstId = (subagent.first['message'] as Map)['id'];
    final firstMessage = subagent.where((f) => (f['message'] as Map)['id'] == firstId);
    final rest = subagent.where((f) => (f['message'] as Map)['id'] != firstId);

    final first = _replay(adapter, [...firstMessage, result]);
    final second = _replay(adapter, [...rest, result]);

    expect(first.outputTokens, resultUsage.output + 125);
    expect(second.outputTokens, resultUsage.output + subagentUsage.output - 125);
    expect(
      first.cacheReadTokens! + second.cacheReadTokens!,
      2 * resultUsage.cacheRead + subagentUsage.cacheRead,
      reason: 'the harness sums held results; subagent usage must appear exactly once across them',
    );
  });

  test('a new turn request drops the previous turn subagent usage', () {
    final adapter = ClaudeProtocolAdapter();
    final frames = _frames();
    _replay(adapter, frames);
    adapter.buildTurnRequest(message: 'next');

    final complete = _replay(adapter, [frames.last]);
    expect(complete.outputTokens, resultUsage.output);
  });

  test('a result without usage stays null-valued when no subagent ran', () {
    final complete = _replay(ClaudeProtocolAdapter(), [
      {'type': 'result', 'subtype': 'success', 'is_error': false, 'stop_reason': 'end_turn'},
    ]);
    expect(complete.inputTokens, isNull);
    expect(complete.outputTokens, isNull);
  });
}
