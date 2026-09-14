// Pins turn usage accounting against `thread/tokenUsage/updated` frames
// derived from a retained codex-cli 0.154.0 app-server run: a main thread
// running two turns (20 usage notifications, one per model request) and a
// subagent thread the first turn spawned, reporting under its own `threadId`
// with a counter that starts at zero.
import 'dart:convert';
import 'dart:io';

import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

const _mainThread = '01a0a0a4-8bb1-7283-bd8f-abb94c7dd859';
const _childThread = '01a0a0a5-41be-78a2-be6b-c5cc02142ff4';

List<Map<String, dynamic>> _frames() {
  // Suites run from the workspace root as well as the package dir.
  final relative = p.join('test', 'harness', 'fixtures', 'codex_subagent_usage_frames.jsonl');
  final file = File(relative).existsSync() ? File(relative) : File(p.join('packages', 'dartclaw_core', relative));
  return file
      .readAsLinesSync()
      .where((line) => line.trim().isNotEmpty)
      .map((line) => jsonDecode(line) as Map<String, dynamic>)
      .toList();
}

String? _threadId(Map<String, dynamic> frame) => (frame['params'] as Map<String, dynamic>)['threadId'] as String?;

/// What `CodexHarness` lets through to the adapter during the main thread's
/// turn: every usage notification, and the main thread's own turn frames.
bool _reachesAdapter(Map<String, dynamic> frame) =>
    frame['method'] == 'thread/tokenUsage/updated' || _threadId(frame) == _mainThread;

List<TurnComplete> _replay(CodexProtocolAdapter adapter, Iterable<Map<String, dynamic>> frames) {
  final completes = <TurnComplete>[];
  for (final frame in frames) {
    final message = adapter.parseLine(jsonEncode(frame));
    if (message is TurnComplete) completes.add(message);
  }
  return completes;
}

Map<String, dynamic> _total(Map<String, dynamic> frame) =>
    ((frame['params'] as Map<String, dynamic>)['tokenUsage'] as Map<String, dynamic>)['total'] as Map<String, dynamic>;

void main() {
  test('the fixture is what it claims: cumulative totals per thread, the child starting from zero', () {
    final frames = _frames();
    final usage = frames.where((f) => f['method'] == 'thread/tokenUsage/updated').toList();
    expect(usage.map(_threadId).toSet(), {_mainThread, _childThread});

    final child = usage.where((f) => _threadId(f) == _childThread).toList();
    final childFirst = (child.first['params'] as Map<String, dynamic>)['tokenUsage'] as Map<String, dynamic>;
    expect(childFirst['total'], childFirst['last'], reason: 'a spawned thread does not inherit the parent count');

    final mainTotals = usage.where((f) => _threadId(f) == _mainThread).map((f) => _total(f)['inputTokens'] as int);
    var previous = 0;
    for (final total in mainTotals) {
      expect(total, greaterThan(previous));
      previous = total;
    }
    expect(_total(usage.where((f) => _threadId(f) == _mainThread).last)['inputTokens'], 966048);
  });

  test('a turn is credited the cumulative delta of every thread that reported, not the last request', () {
    final completes = _replay(CodexProtocolAdapter(), _frames().where(_reachesAdapter));
    expect(completes, hasLength(2));

    // Turn 1: main thread 899215 input / 841792 cached / 11265 output at its
    // completion, plus the child's 484511 / 421504 / 8872. Fresh input is
    // total minus cached, per the Anthropic convention the runtime sums in.
    final first = completes[0];
    expect(first.inputTokens, 1383726 - 1265280);
    expect(first.cacheReadTokens, 1265280);
    expect(first.outputTokens, 20137);
    expect(first.cacheWriteTokens, 0);

    // Turn 2: one model request on the main thread only.
    final second = completes[1];
    expect(second.inputTokens, 66833 - 63488);
    expect(second.cacheReadTokens, 63488);
    expect(second.outputTokens, 74);
  });

  test('the last request alone is never the answer', () {
    final frames = _frames().where(_reachesAdapter).toList();
    final lastBeforeFirstCompletion = frames
        .sublist(0, frames.indexWhere((f) => f['method'] == 'turn/completed'))
        .lastWhere((f) => f['method'] == 'thread/tokenUsage/updated');
    final last = ((lastBeforeFirstCompletion['params'] as Map<String, dynamic>)['tokenUsage'] as Map)['last'] as Map;

    final first = _replay(CodexProtocolAdapter(), frames).first;
    expect(first.outputTokens, isNot(last['outputTokens']));
  });

  test('a turn with no usage notification since the previous one reports nothing', () {
    final adapter = CodexProtocolAdapter();
    final frames = _frames().where(_reachesAdapter).toList();
    _replay(adapter, frames);

    final again = _replay(adapter, [frames.lastWhere((f) => f['method'] == 'turn/completed')]).single;
    expect(again.inputTokens, isNull);
    expect(again.outputTokens, isNull);
  });

  test('a failed turn consumes its usage instead of leaking it into the next', () {
    final adapter = CodexProtocolAdapter();
    final frames = _frames().where(_reachesAdapter).toList();
    final firstCompletion = frames.indexWhere((f) => f['method'] == 'turn/completed');
    _replay(adapter, frames.sublist(0, firstCompletion));
    adapter.parseLine(jsonEncode({'method': 'turn/failed', 'params': <String, dynamic>{}}));

    final next = _replay(adapter, [frames[firstCompletion]]).single;
    expect(next.inputTokens, isNull);
  });
}
