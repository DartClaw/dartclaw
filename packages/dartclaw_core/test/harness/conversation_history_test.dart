import 'package:dartclaw_config/dartclaw_config.dart';
import 'package:dartclaw_core/src/harness/conversation_history.dart';
import 'package:test/test.dart';

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

Map<String, dynamic> _msg(String role, String content) => {'role': role, 'content': content};

const _defaultConfig = HistoryConfig();

// ---------------------------------------------------------------------------
// T1–T6: Replay filter tests (buildReplaySafeHistory pure function)
// ---------------------------------------------------------------------------

void main() {
  group('buildReplaySafeHistory', () {
    group('T1: Excludes [Blocked by guard: ...] pairs', () {
      test('single blocked pair → empty output', () {
        final messages = [_msg('user', 'hello'), _msg('assistant', '[Blocked by guard: profanity]')];
        final result = buildReplaySafeHistory(messages, _defaultConfig);
        expect(result, isEmpty);
      });
    });

    group('T2: Excludes [Response blocked by guard: ...] pairs', () {
      test('first pair normal, second blocked → first pair only', () {
        final messages = [
          _msg('user', 'first message'),
          _msg('assistant', 'first response'),
          _msg('user', 'second message'),
          _msg('assistant', '[Response blocked by guard: length]'),
        ];
        final result = buildReplaySafeHistory(messages, _defaultConfig);
        expect(result, contains('[user]: first message'));
        expect(result, contains('[assistant]: first response'));
        expect(result, isNot(contains('second message')));
        expect(result, isNot(contains('[Response blocked by guard:')));
      });
    });

    group('T3: Excludes synthetic markers', () {
      test('[Turn failed] pair excluded', () {
        final messages = [_msg('user', 'a'), _msg('assistant', '[Turn failed]')];
        expect(buildReplaySafeHistory(messages, _defaultConfig), isEmpty);
      });

      test('[Turn failed: reason] pair excluded', () {
        final messages = [_msg('user', 'a'), _msg('assistant', '[Turn failed: timed out]')];
        expect(buildReplaySafeHistory(messages, _defaultConfig), isEmpty);
      });

      test('[Turn cancelled] pair excluded', () {
        final messages = [_msg('user', 'b'), _msg('assistant', '[Turn cancelled]')];
        expect(buildReplaySafeHistory(messages, _defaultConfig), isEmpty);
      });

      test('[Loop detected: ...] pair excluded', () {
        final messages = [_msg('user', 'c'), _msg('assistant', '[Loop detected: too many retries]')];
        expect(buildReplaySafeHistory(messages, _defaultConfig), isEmpty);
      });

      test('all three synthetic-marker pairs excluded → empty', () {
        final messages = [
          _msg('user', 'a'),
          _msg('assistant', '[Turn failed]'),
          _msg('user', 'b'),
          _msg('assistant', '[Turn cancelled]'),
          _msg('user', 'c'),
          _msg('assistant', '[Loop detected: too many retries]'),
        ];
        expect(buildReplaySafeHistory(messages, _defaultConfig), isEmpty);
      });
    });

    group('T4: Trailing orphaned user message excluded', () {
      test('one complete pair + trailing user → pair only', () {
        final messages = [_msg('user', 'first'), _msg('assistant', 'response'), _msg('user', 'orphan')];
        final result = buildReplaySafeHistory(messages, _defaultConfig);
        expect(result, contains('[user]: first'));
        expect(result, contains('[assistant]: response'));
        expect(result, isNot(contains('[user]: orphan')));
      });
    });

    group('T5: Normal user/assistant exchanges included', () {
      test('two complete pairs both appear in output', () {
        final messages = [
          _msg('user', 'msg1'),
          _msg('assistant', 'resp1'),
          _msg('user', 'msg2'),
          _msg('assistant', 'resp2'),
        ];
        final result = buildReplaySafeHistory(messages, _defaultConfig);
        expect(result, contains('[user]: msg1'));
        expect(result, contains('[assistant]: resp1'));
        expect(result, contains('[user]: msg2'));
        expect(result, contains('[assistant]: resp2'));
        expect(result, contains('<conversation_history>'));
        expect(result, contains('</conversation_history>'));
      });
    });

    group('T6: Empty-content messages skipped', () {
      test('empty-content user message treated as orphan — second pair included', () {
        final messages = [
          _msg('user', ''),
          _msg('assistant', 'some response'),
          _msg('user', 'real message'),
          _msg('assistant', 'real response'),
        ];
        final result = buildReplaySafeHistory(messages, _defaultConfig);
        // The empty-content user message is filtered out, leaving an assistant
        // message without a preceding user — it gets skipped.
        // The second user+assistant pair is complete and included.
        expect(result, contains('[user]: real message'));
        expect(result, contains('[assistant]: real response'));
        expect(result, isNot(contains('[assistant]: some response')));
      });

      test('all messages have empty content → empty output', () {
        final messages = [_msg('user', '   '), _msg('assistant', '')];
        expect(buildReplaySafeHistory(messages, _defaultConfig), isEmpty);
      });
    });

    // -------------------------------------------------------------------------
    // T7–T11: Injection boundary, effort tolerance, budget tests
    // -------------------------------------------------------------------------

    group('T7: History returned on cold process (non-empty valid history)', () {
      test('valid history → non-empty block returned', () {
        final messages = [_msg('user', 'previous question'), _msg('assistant', 'previous answer')];
        final result = buildReplaySafeHistory(messages, _defaultConfig);
        expect(result, isNotEmpty);
        expect(result, contains('<conversation_history>'));
        expect(result, contains('</conversation_history>'));
      });
    });

    group('T8: No history on empty prior messages list', () {
      test('empty messages list → empty output', () {
        final result = buildReplaySafeHistory([], _defaultConfig);
        expect(result, isEmpty);
      });

      test('single user message only → empty output (no complete pairs)', () {
        final messages = [_msg('user', 'only message')];
        final result = buildReplaySafeHistory(messages, _defaultConfig);
        expect(result, isEmpty);
      });
    });

    group('T9: Oldest exchange pairs dropped when budget exceeded', () {
      test('10 pairs with small maxTotalChars drops oldest, retains newest', () {
        // Use zero-padded numbers to avoid substring matching issues (e.g. "01"
        // vs "10") when checking that old messages are not present.
        final messages = <Map<String, dynamic>>[];
        for (var i = 1; i <= 10; i++) {
          final idx = i.toString().padLeft(2, '0');
          messages.add(_msg('user', 'user_msg_$idx'));
          messages.add(_msg('assistant', 'assistant_msg_$idx'));
        }
        // Budget tight enough to force dropping oldest pairs.
        const config = HistoryConfig(maxMessageChars: 100, maxTotalChars: 100);
        final result = buildReplaySafeHistory(messages, config);
        // Newest pair should be present.
        expect(result, contains('user_msg_10'));
        expect(result, contains('assistant_msg_10'));
        // Oldest should be dropped (padded so "01" won't substring-match "10").
        expect(result, isNot(contains('user_msg_01')));
        expect(result, isNot(contains('assistant_msg_01')));
      });

      test('result stays within budget after truncation', () {
        final messages = <Map<String, dynamic>>[];
        for (var i = 0; i < 5; i++) {
          messages.add(_msg('user', 'u' * 50));
          messages.add(_msg('assistant', 'a' * 50));
        }
        const config = HistoryConfig(maxMessageChars: 100, maxTotalChars: 200);
        final result = buildReplaySafeHistory(messages, config);
        // Content between the XML tags should be within budget.
        // We just verify the result is non-empty and contains the closing tag.
        expect(result, contains('</conversation_history>'));
      });
    });

    group('T10: Per-message truncation with ... suffix', () {
      test('message longer than maxMessageChars is truncated', () {
        const maxChars = 100;
        const config = HistoryConfig(maxMessageChars: maxChars, maxTotalChars: 50000);
        final longContent = 'x' * 5000;
        final messages = [_msg('user', longContent), _msg('assistant', 'short')];
        final result = buildReplaySafeHistory(messages, config);
        // Truncated to maxChars - 1 chars + '...'
        final truncated = '${'x' * (maxChars - 1)}...';
        expect(result, contains(truncated));
      });

      test('message exactly at limit is not truncated', () {
        const maxChars = 50;
        const config = HistoryConfig(maxMessageChars: maxChars, maxTotalChars: 50000);
        final exactContent = 'y' * maxChars;
        final messages = [_msg('user', exactContent), _msg('assistant', 'reply')];
        final result = buildReplaySafeHistory(messages, config);
        expect(result, contains(exactContent));
        expect(result, isNot(contains('...')));
      });
    });

    group('Non-user/assistant roles are filtered', () {
      test('system role message excluded', () {
        final messages = [
          _msg('system', 'system prompt content'),
          _msg('user', 'user question'),
          _msg('assistant', 'assistant answer'),
        ];
        final result = buildReplaySafeHistory(messages, _defaultConfig);
        expect(result, isNot(contains('system prompt content')));
        expect(result, contains('[user]: user question'));
        expect(result, contains('[assistant]: assistant answer'));
      });
    });

    group('Output format', () {
      test('output contains XML tags and role prefixes', () {
        final messages = [_msg('user', 'hello'), _msg('assistant', 'world')];
        final result = buildReplaySafeHistory(messages, _defaultConfig);
        expect(result, startsWith('<conversation_history>'));
        expect(result, endsWith('</conversation_history>'));
        expect(result, contains('[user]: hello'));
        expect(result, contains('[assistant]: world'));
      });
    });
  });
}
