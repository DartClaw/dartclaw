// Pins `CodexProtocolAdapter` against frames captured from a real
// `codex app-server` session (codex-cli 0.146.0, gpt-5.6-sol).
//
// Both facts here were wrong in the adapter and invisible to every hand-written
// test, because the hand-written params were what the code already expected:
// usage moved to its own notification, and `turn/completed` carries the
// authoritative per-item text.
import 'dart:convert';
import 'dart:io';

import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

List<String> _capturedFrames() {
  // Suites run from the workspace root as well as the package dir.
  final relative = p.join('test', 'harness', 'fixtures', 'codex_turn_completion_frames.jsonl');
  final file = File(relative).existsSync() ? File(relative) : File(p.join('packages', 'dartclaw_core', relative));
  return file.readAsLinesSync().where((line) => line.trim().isNotEmpty).toList();
}

Map<String, dynamic> _frame(String method) =>
    jsonDecode(_capturedFrames().firstWhere((line) => (jsonDecode(line) as Map)['method'] == method))
        as Map<String, dynamic>;

void main() {
  test('usage comes from thread/tokenUsage/updated, which turn/completed does not carry', () {
    final adapter = CodexProtocolAdapter();

    // `turn/completed`'s captured params are exactly threadId and turn — no
    // usage key — so this is the only notification carrying the numbers.
    final completedParams = _frame('turn/completed')['params'] as Map<String, dynamic>;
    expect(completedParams.keys.toSet(), {'threadId', 'turn'});

    adapter.parseLine(jsonEncode(_frame('thread/tokenUsage/updated')));
    final message = adapter.parseLine(jsonEncode(_frame('turn/completed')));

    expect(message, isA<TurnComplete>());
    final complete = message! as TurnComplete;
    // Captured: inputTokens 24264 total, of which 6912 cached; output 5.
    // Normalised to the Anthropic convention the rest of the runtime sums in.
    expect(complete.inputTokens, 24264 - 6912);
    expect(complete.cacheReadTokens, 6912);
    expect(complete.outputTokens, 5);
  });

  test('the final answer comes from the completed turn, not the delta stream', () {
    final adapter = CodexProtocolAdapter();
    final delta = adapter.parseLine(jsonEncode(_frame('item/agentMessage/delta')));
    expect(delta, isA<TextDelta>(), reason: 'deltas still stream for display');

    final complete = adapter.parseLine(jsonEncode(_frame('turn/completed')))! as TurnComplete;
    expect(complete.finalText, 'ok');
  });

  test('a second turn does not inherit the first turn usage', () {
    final adapter = CodexProtocolAdapter();
    adapter.parseLine(jsonEncode(_frame('thread/tokenUsage/updated')));
    adapter.parseLine(jsonEncode(_frame('turn/completed')));

    final second = adapter.parseLine(jsonEncode(_frame('turn/completed')))! as TurnComplete;
    expect(second.inputTokens, isNull, reason: 'usage is consumed by the turn it belongs to');
  });
}
