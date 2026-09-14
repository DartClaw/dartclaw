// Pins `CodexProtocolAdapter` against frames captured from a real
// `codex app-server` session (codex-cli 0.146.0, gpt-5.6-sol).
//
// Both facts here were wrong in the adapter and invisible to every hand-written
// test, because the hand-written params were what the code already expected:
// usage moved to its own notification, and `turn/completed` carries the
// authoritative per-item text.
//
// A second fixture pins the `outputSchema` probe of 2026-09-13 (codex-cli
// 0.153.4, gpt-6-astra): the app server accepted the unmodified execution
// envelope schema on `turn/start` and constrained the final assistant message
// to it, with no typed payload on any frame.
import 'dart:convert';
import 'dart:io';

import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

List<String> _capturedFrames(String fixture) {
  // Suites run from the workspace root as well as the package dir.
  final relative = p.join('test', 'harness', 'fixtures', fixture);
  final file = File(relative).existsSync() ? File(relative) : File(p.join('packages', 'dartclaw_core', relative));
  return file.readAsLinesSync().where((line) => line.trim().isNotEmpty).toList();
}

Map<String, dynamic> _frame(String method, {String fixture = 'codex_turn_completion_frames.jsonl'}) =>
    jsonDecode(_capturedFrames(fixture).firstWhere((line) => (jsonDecode(line) as Map)['method'] == method))
        as Map<String, dynamic>;

/// Frames from the 2026-09-13 `outputSchema` probe (codex-cli 0.153.4,
/// gpt-6-astra). Only the request's `cwd` is redacted; the schema and the
/// reply are the captured bytes.
Map<String, dynamic> _schemaFrame(String method) => _frame(method, fixture: 'codex_output_schema_frames.jsonl');

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

  test('a captured outputSchema round-trips through buildTurnRequest and the constrained reply parses', () {
    final adapter = CodexProtocolAdapter();
    final captured = _schemaFrame('turn/start')['params'] as Map<String, dynamic>;
    final input = (captured['input'] as List).single as Map<String, dynamic>;

    final request = adapter.buildTurnRequest(
      message: input['text'] as String,
      threadId: captured['threadId'] as String,
      settings: {'model': captured['model'], 'approval_policy': captured['approvalPolicy']},
      outputSchema: captured['outputSchema'] as Map<String, dynamic>,
    );

    expect(request['method'], 'turn/start');
    expect((request['params'] as Map<String, dynamic>)['outputSchema'], captured['outputSchema']);

    // The app server constrains the final assistant message to the schema and
    // surfaces it as ordinary `text`, with no typed field anywhere on the frame.
    final complete = adapter.parseLine(jsonEncode(_schemaFrame('turn/completed')))! as TurnComplete;
    final envelope = jsonDecode(complete.finalText!) as Map<String, dynamic>;
    expect(envelope.keys, containsAll(['outputs', 'step_outcome']));
    expect((envelope['outputs'] as Map)['report_path'], isNull);
    expect((envelope['step_outcome'] as Map)['outcome'], 'succeeded');
  });

  test('a second turn does not inherit the first turn usage', () {
    final adapter = CodexProtocolAdapter();
    adapter.parseLine(jsonEncode(_frame('thread/tokenUsage/updated')));
    adapter.parseLine(jsonEncode(_frame('turn/completed')));

    final second = adapter.parseLine(jsonEncode(_frame('turn/completed')))! as TurnComplete;
    expect(second.inputTokens, isNull, reason: 'usage is consumed by the turn it belongs to');
  });
}
