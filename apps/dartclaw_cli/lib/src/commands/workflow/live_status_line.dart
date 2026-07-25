import 'dart:async';
import 'dart:io';

/// Formats a token count as a compact number: `12K` at or above 1000, else the
/// raw count. No unit word — callers append `tokens`/`total` as appropriate.
String formatTokenCount(int tokens) {
  if (tokens >= 1000) return '${(tokens / 1000).toStringAsFixed(0)}K';
  return '$tokens';
}

/// `12K tokens` form used on permanent completion lines. Shared by
/// [CliProgressPrinter] and [LiveStatusLine] so live and completion lines agree.
String formatWorkflowTokens(int tokens) => '${formatTokenCount(tokens)} tokens';

/// Live elapsed clock that always keeps seconds — unlike `humanizeDuration`,
/// whose hours tier drops them, which would freeze the seconds readout on long
/// runs: `45s`, `1m 12s`, `2h 5m 30s`.
String formatLiveElapsed(Duration d) {
  if (d.isNegative) d = Duration.zero;
  final h = d.inHours;
  final m = d.inMinutes % 60;
  final s = d.inSeconds % 60;
  if (h > 0) return '${h}h ${m}m ${s}s';
  if (m > 0) return '${m}m ${s}s';
  return '${s}s';
}

/// ANSI SGR codes used for the optional color overlay. Empty-safe: callers pass
/// `null` for "no color" and [LiveStatusLine.colorize] is a no-op when color is
/// off, so the same code path serves both colored TTYs and plain pipes.
const ansiReset = '\x1b[0m';
const ansiDim = '\x1b[2m';
const ansiCyan = '\x1b[36m';
const ansiGreen = '\x1b[32m';
const ansiRed = '\x1b[31m';
const ansiYellow = '\x1b[33m';
const ansiMagenta = '\x1b[35m';
const ansiBrightWhite = '\x1b[97m';

/// A run of text optionally rendered in an ANSI [color]. Used to build
/// permanent progress lines with per-segment coloring that collapses to a
/// byte-identical plain string when color is off.
class StyledSpan {
  final String text;
  final String? color;
  const StyledSpan(this.text, [this.color]);
}

/// Joins [spans]; wraps each colored, non-empty span in its SGR code + reset
/// when [color] is true, else emits the spans' text verbatim (so the plain
/// rendering is exactly the spans concatenated — no ANSI).
String renderStyledLine(List<StyledSpan> spans, {required bool color}) {
  final buffer = StringBuffer();
  for (final span in spans) {
    if (color && span.color != null && span.text.isNotEmpty) {
      buffer.write('${span.color}${span.text}$ansiReset');
    } else {
      buffer.write(span.text);
    }
  }
  return buffer.toString();
}

const _spinnerFrames = ['⠋', '⠙', '⠹', '⠸', '⠼', '⠴', '⠦', '⠧', '⠇', '⠏'];
const _eraseLine = '\r\x1b[2K';
const _cursorHide = '\x1b[?25l';
const _cursorShow = '\x1b[?25h';

/// Left margin so the spinner glyph isn't flush against the terminal edge.
const _leftMargin = ' ';

class _ActiveStep {
  final String label;
  final DateTime startedAt;
  int tokens;
  _ActiveStep(this.label, this.startedAt) : tokens = 0;
}

/// A single in-place "live" status line at the bottom of the terminal: an
/// animated spinner plus the running step's elapsed time and live token count,
/// in the spirit of Docker's CLI progress.
///
/// Permanent output (step-completed lines, the workflow summary) must be routed
/// through [writePermanent] so it lands *above* the spinner without leaving
/// stray glyphs. When [enabled] is false (no TTY, or JSON output) every method
/// is a no-op and the caller falls back to plain append-only writes — this is
/// the path taken in tests and CI, keeping output byte-identical to before.
class LiveStatusLine {
  final void Function(String) _write;
  final bool enabled;
  final bool _color;
  final DateTime Function() _now;
  final int Function() _columns;

  Timer? _timer;
  int _frame = 0;
  bool _lineDrawn = false;
  bool _cursorHidden = false;
  final _active = <String, _ActiveStep>{};
  // Live-tick tokens already folded into [_completedTokens] by [settleStep],
  // keyed so the eventual authoritative completion count is reconciled instead
  // of double-counted.
  final _settledTokens = <String, int>{};
  int _completedTokens = 0;

  LiveStatusLine({
    void Function(String)? write,
    required this.enabled,
    bool? color,
    DateTime Function()? now,
    int Function()? columns,
  }) : _write = write ?? stdout.write,
       _color = color ?? enabled,
       _now = now ?? DateTime.now,
       _columns = columns ?? _stdoutColumns;

  /// Builds a stdout-backed line, enabled only on an interactive terminal and
  /// when not emitting machine-readable JSON.
  factory LiveStatusLine.forStdout({required bool jsonOutput}) =>
      LiveStatusLine(enabled: stdout.hasTerminal && !jsonOutput);

  /// Registers a newly-running step under [key] (the same key the caller uses
  /// to match the eventual completion). [label] is the compact one-line
  /// description shown next to the spinner.
  void addStep(String key, String label) {
    if (!enabled) return;
    _active[key] = _ActiveStep(label, _now());
    _ensureTimer();
    _render();
  }

  /// Updates the live token count for an active step. No-op if [key] is not
  /// currently running, which inherently scopes stray token events to this run.
  void updateTokens(String key, int cumulativeTokens) {
    if (!enabled) return;
    final step = _active[key];
    if (step == null) return;
    if (cumulativeTokens > step.tokens) step.tokens = cumulativeTokens;
    _render();
  }

  /// Removes a finished step, folding [tokens] into the cumulative run total
  /// shown when several steps run at once. Any live-tick tokens an earlier
  /// [settleStep] already folded for [key] are subtracted so the authoritative
  /// count replaces them rather than stacking on top (never below zero, in
  /// case the ticks overshot the final count).
  void completeStep(String key, int tokens) {
    if (!enabled) return;
    _active.remove(key);
    final alreadyFolded = _settledTokens.remove(key) ?? 0;
    if (tokens > alreadyFolded) _completedTokens += tokens - alreadyFolded;
    _afterRemoval();
  }

  /// Removes a step whose token total is unknown (failed/blocked). Tokens an
  /// earlier [settleStep] folded for [key] stay in the run total – they were
  /// genuinely spent even though the step did not succeed.
  void removeStep(String key) {
    if (!enabled) return;
    _active.remove(key);
    _settledTokens.remove(key);
    _afterRemoval();
  }

  /// Removes a step whose task has settled ahead of its completion line – a
  /// parallel-group member finishes long before the group barrier emits the
  /// step-completed event, and until then it must not count as running.
  ///
  /// With [countTokens] (successful settle) the step's live-tick tokens fold
  /// into the run total so the figure doesn't dip while the rest of the group
  /// drains; [completeStep] for the same key later reconciles against the
  /// authoritative count, and a re-settled key folds only the delta above its
  /// prior record, never the prior fold twice. Without [countTokens] (failed/
  /// cancelled/interrupted settle) the entry is simply dropped: a failed
  /// attempt's spend re-enters via the barrier's across-attempts count and an
  /// interrupted member stays uncharged, so folding would double-count.
  void settleStep(String key, {required bool countTokens}) {
    if (!enabled) return;
    final step = _active.remove(key);
    if (step == null) return;
    final prior = _settledTokens[key] ?? 0;
    if (countTokens && step.tokens > prior) {
      _settledTokens[key] = step.tokens;
      _completedTokens += step.tokens - prior;
    }
    _afterRemoval();
  }

  /// Clears the live line, writes [line] as permanent output, then redraws the
  /// spinner (if any step is still running) beneath it.
  void writePermanent(String line) {
    if (!enabled) return;
    _clear();
    _write('$line\n');
    _render();
  }

  /// Whether ANSI color output is enabled for this line — drives whether the
  /// printer renders permanent lines with per-segment color or as plain text.
  bool get colorEnabled => _color;

  /// Stops the animation, clears the live line, and restores the cursor. Safe
  /// to call repeatedly.
  void stop() {
    _timer?.cancel();
    _timer = null;
    _clear();
    // The cursor stays hidden for the whole run (no inter-step flicker); it is
    // restored only here, once, at the end.
    if (_cursorHidden) {
      _write(_cursorShow);
      _cursorHidden = false;
    }
  }

  void _afterRemoval() {
    if (_active.isEmpty) {
      _timer?.cancel();
      _timer = null;
      _clear();
    } else {
      _render();
    }
  }

  void _ensureTimer() {
    if (!_cursorHidden) {
      _write(_cursorHide);
      _cursorHidden = true;
    }
    _timer ??= Timer.periodic(const Duration(milliseconds: 120), (_) {
      _frame++;
      _render();
    });
  }

  void _clear() {
    if (!_lineDrawn) return;
    _write(_eraseLine);
    _lineDrawn = false;
  }

  void _render() {
    if (!enabled) return;
    final body = _composeStatus();
    if (body.isEmpty) {
      _clear();
      return;
    }
    _write('$_eraseLine$_leftMargin${_colorizeStatus(body)}');
    _lineDrawn = true;
  }

  String _composeStatus() {
    if (_active.isEmpty) return '';
    final glyph = _spinnerFrames[_frame % _spinnerFrames.length];
    final steps = _active.values;
    // Elapsed is scoped to the currently-running steps (the oldest active one),
    // so it reads as "how long the in-flight work has run" — the signal for
    // spotting a stuck step. It is intentionally not anchored to a fixed run
    // start: when a parallel fan-out drains to fewer steps the figure can step
    // down, which is the right per-step reading even if not globally monotonic.
    var oldest = steps.first.startedAt;
    for (final s in steps) {
      if (s.startedAt.isBefore(oldest)) oldest = s.startedAt;
    }
    final elapsed = formatLiveElapsed(_now().difference(oldest));
    final String body;
    if (_active.length == 1) {
      // Per-step tokens appear only once the provider has reported usage. Codex
      // `exec` reports usage only at end-of-turn (one turn per run), so a codex
      // step shows no per-step figure mid-run — the ticking elapsed clock is the
      // liveness signal, and the completed line carries the final count. The
      // monotonic run-total suffix appears once earlier steps have completed (so
      // it never drops when a parallel fan-out drains to a single step).
      final s = steps.first;
      final stepTok = s.tokens > 0 ? ' · ${formatTokenCount(s.tokens)} tokens' : '';
      final totalTok = _completedTokens > 0 ? ' · ${formatTokenCount(_completedTokens + s.tokens)} total' : '';
      body = '$glyph ${s.label} · $elapsed$stepTok$totalTok';
    } else {
      final total = _completedTokens + steps.fold<int>(0, (sum, s) => sum + s.tokens);
      final tok = total > 0 ? ' · ${formatTokenCount(total)} total' : '';
      body = '$glyph ${_active.length} steps running · $elapsed$tok';
    }
    return _truncate(body, _columns() - _leftMargin.length);
  }

  /// Colors the leading spinner glyph cyan and dims the trailing metadata. The
  /// glyph is a single BMP code unit, so index-0 slicing is safe and stays
  /// width-correct after truncation (codes are appended, never counted).
  String _colorizeStatus(String plain) {
    if (!_color || plain.isEmpty) return plain;
    return '$ansiCyan${plain.substring(0, 1)}$ansiReset$ansiDim${plain.substring(1)}$ansiReset';
  }

  // Truncates by code points, not UTF-16 code units, so an astral char (e.g. an
  // emoji in a step label) at the boundary is never split into a broken half
  // surrogate. Code-point count slightly under-approximates display width for
  // double-width glyphs, which is acceptable for a transient status line.
  static String _truncate(String line, int columns) {
    if (columns <= 1 || line.length <= columns) return line;
    final runes = line.runes.toList();
    if (runes.length <= columns) return line;
    if (columns <= 2) return String.fromCharCodes(runes.take(columns));
    return '${String.fromCharCodes(runes.take(columns - 1))}…';
  }

  static int _stdoutColumns() {
    try {
      final cols = stdout.terminalColumns;
      return cols > 0 ? cols : 80;
    } on StdoutException {
      return 80;
    }
  }
}
