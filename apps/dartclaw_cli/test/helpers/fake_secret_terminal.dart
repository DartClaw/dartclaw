import 'dart:collection';
import 'dart:convert';

import 'package:dartclaw_cli/src/commands/auth/secret_input.dart';

/// Recording [SecretTerminal] that proves mode handling without a real TTY.
///
/// Every terminal-mode operation throws when [hasTerminal] is `false`, exactly
/// as `dart:io`'s stdin does, so a read that touches the mode on piped input
/// fails loudly rather than passing by construction.
class FakeSecretTerminal implements SecretTerminal {
  @override
  final bool hasTerminal;

  final String? Function()? _readLine;
  final Queue<int> _input;

  /// Everything written to the terminal, in order.
  final List<String> writes = <String>[];

  /// Number of times a hidden mode was entered.
  int enterCount = 0;

  /// The number of bytes read at the time of each [restoreMode] call, so a test
  /// can prove the mode was put back once, and only after the last read.
  final List<int> restoresAfterByteReads = <int>[];

  /// Number of times a line was read.
  int readCount = 0;

  /// Number of bytes read.
  int byteReadCount = 0;

  /// Whether the terminal is currently in hidden mode.
  bool hidden = false;

  new({required this.hasTerminal, String? Function()? readLine, List<int> input = const <int>[]})
    : _readLine = readLine,
      _input = Queue<int>.of(input);

  /// A terminal on which [value] is typed and terminated with Enter.
  factory typing(String value) => FakeSecretTerminal(hasTerminal: true, input: [...utf8.encode(value), 10]);

  /// Everything written, joined — the operator's view of the read.
  String get output => writes.join();

  @override
  Object? enterHiddenMode() {
    if (!hasTerminal) throw StateError('hidden mode entered on non-terminal stdin');
    enterCount++;
    hidden = true;
    return 'hidden';
  }

  @override
  void restoreMode(Object? state) {
    if (!hasTerminal) throw StateError('mode restored on non-terminal stdin');
    restoresAfterByteReads.add(byteReadCount);
    hidden = false;
  }

  @override
  int? readByte() {
    if (!hasTerminal) throw StateError('byte read on non-terminal stdin');
    byteReadCount++;
    return _input.isEmpty ? null : _input.removeFirst();
  }

  @override
  void write(String text) => writes.add(text);

  @override
  String? readLineSync() {
    readCount++;
    return _readLine?.call();
  }
}
