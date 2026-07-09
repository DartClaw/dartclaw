import 'package:dartclaw_cli/src/commands/workflow/live_status_line.dart';
import 'package:fake_async/fake_async.dart';
import 'package:test/test.dart';

void main() {
  group('formatTokenCount / formatWorkflowTokens', () {
    test('formatTokenCount omits the unit word', () {
      expect(formatTokenCount(12000), '12K');
      expect(formatTokenCount(500), '500');
    });

    test('formatWorkflowTokens uses K suffix at and above 1000', () {
      expect(formatWorkflowTokens(12000), '12K tokens');
      expect(formatWorkflowTokens(1000), '1K tokens');
    });

    test('formatWorkflowTokens keeps raw count below 1000', () {
      expect(formatWorkflowTokens(500), '500 tokens');
    });
  });

  group('formatLiveElapsed', () {
    test('keeps seconds across every tier', () {
      expect(formatLiveElapsed(const Duration(seconds: 5)), '5s');
      expect(formatLiveElapsed(const Duration(minutes: 1, seconds: 2)), '1m 2s');
      expect(formatLiveElapsed(const Duration(hours: 2, minutes: 5, seconds: 30)), '2h 5m 30s');
    });

    test('clamps a negative duration to zero', () {
      expect(formatLiveElapsed(const Duration(seconds: -3)), '0s');
    });
  });

  group('LiveStatusLine (disabled)', () {
    test('every method is a no-op and writes nothing', () {
      final out = <String>[];
      final live = LiveStatusLine(write: out.add, enabled: false, now: () => DateTime(2026));
      live.addStep('k', 'step');
      live.updateTokens('k', 5000);
      live.writePermanent('permanent');
      live.completeStep('k', 5000);
      live.stop();
      expect(out, isEmpty);
    });
  });

  group('LiveStatusLine (enabled)', () {
    late List<String> out;
    var clock = DateTime(2026, 1, 1, 12, 0, 0);

    LiveStatusLine build({bool color = false}) =>
        LiveStatusLine(write: out.add, enabled: true, color: color, now: () => clock, columns: () => 200);

    setUp(() {
      out = <String>[];
      clock = DateTime(2026, 1, 1, 12, 0, 0);
    });

    test('a single running step renders spinner, label and elapsed', () {
      final live = build();
      live.addStep('k', 'research: Research & Design (codex)');
      clock = clock.add(const Duration(seconds: 12));
      live.updateTokens('k', 8400);
      final rendered = out.join();
      expect(rendered, contains('research: Research & Design (codex)'));
      expect(rendered, contains('12s'));
      expect(rendered, contains('8K tokens'));
      live.stop();
    });

    test('token updates only count upward and ignore unknown keys', () {
      final live = build();
      live.addStep('k', 'step');
      live.updateTokens('k', 5000);
      live.updateTokens('k', 1000); // lower – ignored
      live.updateTokens('other', 99000); // unknown key – ignored
      expect(out.join(), contains('5K tokens'));
      expect(out.join(), isNot(contains('99K')));
      live.stop();
    });

    test('multiple running steps render an aggregate run total', () {
      final live = build();
      live.addStep('a', 'step a');
      live.addStep('b', 'step b');
      live.updateTokens('a', 3000);
      live.updateTokens('b', 4000);
      final rendered = out.join();
      expect(rendered, contains('2 steps running'));
      expect(rendered, contains('7K total'));
      live.stop();
    });

    test('a single remaining step keeps its per-step tokens and a monotonic run total', () {
      final live = build();
      live.addStep('a', 'step a');
      live.addStep('b', 'step b');
      live.updateTokens('a', 3000);
      live.completeStep('a', 3000); // a done (folds into completed), b still running
      live.updateTokens('b', 4000);
      // b's own tokens stay visible, and the run total (3K + 4K) does not drop
      // below the prior aggregate.
      final rendered = out.join();
      expect(rendered, contains('4K tokens'));
      expect(rendered, contains('7K total'));
      live.stop();
    });

    test('writePermanent clears the live line before the permanent text', () {
      final live = build();
      live.addStep('k', 'step');
      out.clear();
      live.writePermanent('[step 1/1] done');
      final rendered = out.join();
      // Erase sequence precedes the permanent line.
      expect(rendered, contains('\r\x1b[2K'));
      expect(rendered, contains('[step 1/1] done\n'));
      live.stop();
    });

    test('stop clears the drawn line and restores the cursor', () {
      final live = build();
      live.addStep('k', 'step');
      out.clear();
      live.stop();
      expect(out.join(), '\r\x1b[2K\x1b[?25h');
    });

    test('the cursor is hidden while animating and restored once on stop', () {
      final live = build();
      live.addStep('k', 'step');
      expect(out.join(), contains('\x1b[?25l')); // hidden on first draw
      live.stop();
      expect(out.join(), contains('\x1b[?25h')); // restored on stop
    });

    test('color overlay wraps the spinner glyph and dims the rest', () {
      final live = build(color: true);
      live.addStep('k', 'step');
      final rendered = out.join();
      expect(rendered, contains(ansiCyan));
      expect(rendered, contains(ansiDim));
      expect(rendered, contains(ansiReset));
      live.stop();
    });

    test('the spinner frame advances on the periodic timer', () {
      FakeAsync().run((async) {
        final frames = <String>[];
        final live = LiveStatusLine(
          write: frames.add,
          enabled: true,
          color: false,
          now: () => DateTime(2026),
          columns: () => 200,
        );
        live.addStep('k', 'step');
        async.elapse(const Duration(milliseconds: 260)); // ~2 ticks past the first render
        final rendered = frames.join();
        // The first render shows frame 0 (⠋); ticks must rotate to later glyphs.
        expect(rendered, contains('⠙'));
        expect(rendered, contains('⠹'));
        live.stop();
      });
    });

    test('long status lines are truncated to the column width with an ellipsis', () {
      final live = LiveStatusLine(write: out.add, enabled: true, color: false, now: () => clock, columns: () => 12);
      live.addStep('k', 'a-very-long-step-label-that-exceeds-the-width');
      final rendered = out.last;
      // Strip the leading erase sequence before measuring the visible content.
      final visible = rendered.replaceAll('\r\x1b[2K', '');
      expect(visible.endsWith('…'), isTrue);
      expect(visible.length, lessThanOrEqualTo(12));
      live.stop();
    });

    test('truncation of an astral-char label never leaves a lone surrogate', () {
      final live = LiveStatusLine(write: out.add, enabled: true, color: false, now: () => clock, columns: () => 8);
      live.addStep('k', '🎉🎉🎉🎉🎉🎉🎉🎉🎉🎉'); // 10 emoji = 20 UTF-16 units; a code-unit cut would split one
      final visible = out.last.replaceAll('\r\x1b[2K', '');
      expect(visible.endsWith('…'), isTrue);
      expect(_hasLoneSurrogate(visible), isFalse);
      expect(visible.runes.length, lessThanOrEqualTo(8));
      live.stop();
    });
  });
}

/// True if [s] contains an unpaired UTF-16 surrogate code unit — the artifact a
/// code-unit-based truncation would produce by cutting through an astral char.
bool _hasLoneSurrogate(String s) {
  final units = s.codeUnits;
  for (var i = 0; i < units.length; i++) {
    final c = units[i];
    if (c >= 0xD800 && c <= 0xDBFF) {
      if (i + 1 >= units.length || units[i + 1] < 0xDC00 || units[i + 1] > 0xDFFF) return true;
      i++;
    } else if (c >= 0xDC00 && c <= 0xDFFF) {
      return true;
    }
  }
  return false;
}
