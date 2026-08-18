import 'dart:convert';
import 'dart:io';

/// The terminal state and byte-level IO a masked secret read depends on.
///
/// Injected so tests can observe the mode transitions and the mask output
/// without driving a real TTY.
abstract interface class SecretTerminal {
  /// Whether stdin is an interactive terminal.
  bool get hasTerminal;

  /// Reads one line from stdin, or `null` at end of input.
  String? readLineSync();

  /// Switches to character-at-a-time input with echo and terminal signal
  /// generation off, answering an opaque token [restoreMode] puts back.
  ///
  /// Throws rather than answering a token when the terminal cannot be put back
  /// afterwards: a secret must never be read through a mode that would outlive
  /// the read.
  Object? enterHiddenMode();

  /// Puts back the mode [enterHiddenMode] captured in [state].
  void restoreMode(Object? state);

  /// Reads one byte, or `null` at end of input.
  int? readByte();

  /// Writes [text] as-is, with no line terminator of its own.
  void write(String text);
}

/// [SecretTerminal] over the process's real stdin.
class StdinSecretTerminal implements SecretTerminal {
  const new();

  /// Reading through `/dev/tty` is required: `Process.runSync` gives the child
  /// no terminal on stdin, so `stty` would have no mode to read or set.
  static const _saveModeCommand = 'stty -g < /dev/tty';
  static const _hiddenModeCommand = 'stty -icanon -echo -isig min 1 time 0 < /dev/tty';

  /// The shape `stty -g` answers with — `gfmt1:cflag=…` on macOS, a
  /// colon-separated hex list on Linux. Anything else is not a mode string and
  /// is not handed back to a shell.
  static final _modeFormat = RegExp(r'^[A-Za-z0-9:,=-]+$');

  @override
  bool get hasTerminal => stdin.hasTerminal;

  @override
  String? readLineSync() => stdin.readLineSync();

  @override
  int? readByte() {
    final byte = stdin.readByteSync();
    return byte < 0 ? null : byte;
  }

  @override
  // `stdout` is a blocking sink, so the mask appears while the next byte read
  // blocks — a buffered sink would show nothing until the read returned.
  void write(String text) => stdout.write(text);

  @override
  Object? enterHiddenMode() {
    final saved = _savedMode();
    if (saved != null) {
      if (_stty(_hiddenModeCommand)) return _SttyMode(saved);
      // `stty` applies its settings left to right, so a rejected one can leave
      // the settings before it in force.
      _stty('stty $saved < /dev/tty');
    }
    // Windows, and any terminal `stty` could not be driven: echo and line mode
    // are the whole of what `dart:io` exposes, so a Ctrl-C here does whatever
    // the console does with it — no worse than the line-mode read it replaces.
    final previous = _DartIoMode(echoMode: stdin.echoMode, lineMode: stdin.lineMode);
    stdin.echoMode = false;
    stdin.lineMode = false;
    return previous;
  }

  @override
  void restoreMode(Object? state) {
    switch (state) {
      case _SttyMode(:final mode):
        _stty('stty $mode < /dev/tty');
      case _DartIoMode(:final echoMode, :final lineMode):
        // Windows refuses echo on while line mode is off, so the order is
        // load-bearing.
        stdin.lineMode = lineMode;
        stdin.echoMode = echoMode;
    }
  }

  String? _savedMode() {
    if (!Platform.isMacOS && !Platform.isLinux) return null;
    final result = _run(_saveModeCommand);
    if (result == null || result.exitCode != 0) return null;
    final saved = (result.stdout as String).trim();
    return _modeFormat.hasMatch(saved) ? saved : null;
  }

  bool _stty(String command) => _run(command)?.exitCode == 0;

  ProcessResult? _run(String command) {
    try {
      return Process.runSync('sh', ['-c', command]);
    } on ProcessException {
      return null;
    }
  }
}

/// The `stty` mode string a POSIX hidden read has to put back.
class _SttyMode {
  final String mode;

  const new(this.mode);
}

/// The `dart:io` stdin modes a hidden read has to put back off the `stty` path.
class _DartIoMode {
  final bool echoMode;
  final bool lineMode;

  const new({required this.echoMode, required this.lineMode});
}

const _endOfText = 3; // Ctrl-C
const _endOfTransmission = 4; // Ctrl-D
const _backspace = 8;
const _lineFeed = 10;
const _carriageReturn = 13;
const _negativeAcknowledge = 21; // Ctrl-U
const _firstPrintable = 32;
const _delete = 127;

/// Erases one mask cell: back over it, blank it, back again.
const _eraseCell = '\b \b';

/// Reads one secret line from [terminal], showing one `*` per typed character.
///
/// Returns `null` when the prompt was interrupted, when input ended before a
/// character was typed, or at end of piped input. Piped stdin is read whole,
/// unprompted, and no terminal mode is touched.
///
/// Masking needs character-at-a-time input, and a terminal in that mode must
/// also have signal generation off: a Ctrl-C that still raised SIGINT would
/// kill the process before the restoring `finally`, leaving the terminal
/// without echo *and* without line mode — strictly worse than the line-mode
/// read this replaces. Ctrl-C therefore arrives as a byte and is handled here,
/// with the mode restored before [onInterrupt] runs.
///
/// The reads are deliberately synchronous. Reading `stdin` as a stream instead
/// detaches the file descriptor, after which restoring the mode throws `EBADF`
/// and the prompt aborts with the terminal in the state this exists to undo.
///
/// The value is returned raw: what counts as a usable secret is the caller's
/// decision.
String? readSecretLine(
  SecretTerminal terminal, {
  required String prompt,
  required void Function(String) writePrompt,
  void Function()? onInterrupt,
}) {
  if (!terminal.hasTerminal) return terminal.readLineSync();

  writePrompt(prompt);
  final value = <int>[];
  final mode = terminal.enterHiddenMode();
  var restored = false;
  void restore() {
    if (restored) return;
    restored = true;
    terminal.restoreMode(mode);
  }

  try {
    while (true) {
      final byte = terminal.readByte();
      if (byte == null) break;
      switch (byte) {
        case _lineFeed || _carriageReturn:
          terminal.write('\n');
          return _decode(value);
        case _endOfText:
          restore();
          terminal.write('\n');
          onInterrupt?.call();
          return null;
        case _endOfTransmission:
          if (value.isEmpty) {
            terminal.write('\n');
            return null;
          }
        case _backspace || _delete:
          if (value.isNotEmpty) {
            value.removeLast();
            terminal.write(_eraseCell);
          }
        case _negativeAcknowledge:
          terminal.write(_eraseCell * value.length);
          value.clear();
        case >= _firstPrintable:
          // One cell per byte, so a multi-byte character masks as several —
          // accepted: a setup-token is ASCII, and keeping the cell count equal
          // to the byte count is what lets an erase match what is held.
          value.add(byte);
          terminal.write('*');
        default:
        // Every other control byte is dropped without a cell, so stray input
        // cannot desync the mask from the value.
      }
    }
    terminal.write('\n');
    return value.isEmpty ? null : _decode(value);
  } finally {
    restore();
  }
}

/// Replacement characters rather than a throw: an erase can split a multi-byte
/// character, and judging the value is the caller's job.
String _decode(List<int> value) => utf8.decode(value, allowMalformed: true);
