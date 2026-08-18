import 'dart:convert';

import 'package:dartclaw_cli/src/commands/auth/secret_input.dart';
import 'package:test/test.dart';

import '../../helpers/fake_secret_terminal.dart';

const _ctrlC = 3;
const _ctrlD = 4;
const _backspace = 8;
const _enter = 10;
const _ctrlU = 21;
const _escape = 27;
const _delete = 127;

/// One mask cell erased: back over it, blank it, back again.
const _erase = '\b \b';

List<int> _typed(String value) => utf8.encode(value);

void main() {
  late List<String> prompts;

  setUp(() => prompts = <String>[]);

  String? read(FakeSecretTerminal terminal, {void Function()? onInterrupt}) =>
      readSecretLine(terminal, prompt: 'Paste it:', writePrompt: prompts.add, onInterrupt: onInterrupt);

  group('masked interactive read', () {
    test('the typed value comes back intact behind one mask cell per character', () {
      const value = 'sk-ant-oat01-EXAMPLE';
      final terminal = FakeSecretTerminal.typing(value);

      expect(read(terminal), value);
      expect(terminal.output, '${'*' * value.length}\n', reason: 'the operator sees progress, never the value');
      expect(terminal.enterCount, 1);
      expect(prompts, ['Paste it:']);
    });

    test('the read stays in hidden mode until the value is complete', () {
      final terminal = FakeSecretTerminal.typing('token');

      expect(read(terminal), 'token');
      expect(terminal.restoresAfterByteReads, [
        terminal.byteReadCount,
      ], reason: 'a mode put back mid-read would echo the rest of the value');
    });

    test('the value is returned from the call itself, not from a stream read', () {
      // Regression: an async `stdin` stream read left the restoring calls
      // throwing EBADF, because listening detaches the descriptor — the prompt
      // then aborted with the terminal still in the mode the restore exists to
      // undo. Byte-at-a-time `readByteSync` is load-bearing here, not
      // incidental.
      final terminal = FakeSecretTerminal.typing('token');

      expect(read(terminal), isA<String>(), reason: 'a Future return type would mean the stream read came back');
      expect(terminal.readCount, 0, reason: 'an interactive read is byte-at-a-time, never a whole line');
    });

    test('a carriage return ends the value, so a terminal that sends CR is not left hanging', () {
      final terminal = FakeSecretTerminal(hasTerminal: true, input: [..._typed('token'), 13]);

      expect(read(terminal), 'token');
    });

    test('Enter with nothing typed reads as an empty value, which the caller refuses', () {
      final terminal = FakeSecretTerminal(hasTerminal: true, input: [_enter]);

      expect(read(terminal), '');
    });
  });

  group('editing keeps the mask and the value in step', () {
    test('backspace drops the last character and erases exactly one cell', () {
      final terminal = FakeSecretTerminal(hasTerminal: true, input: [..._typed('ab'), _delete, ..._typed('c'), _enter]);

      expect(read(terminal), 'ac');
      expect(terminal.output, '**$_erase*\n');
    });

    test('the BS byte erases like DEL, so both terminal conventions work', () {
      final terminal = FakeSecretTerminal(
        hasTerminal: true,
        input: [..._typed('ab'), _backspace, ..._typed('c'), _enter],
      );

      expect(read(terminal), 'ac');
      expect(terminal.output, '**$_erase*\n');
    });

    test('backspace on an empty value erases nothing, so the prompt line is not eaten', () {
      final terminal = FakeSecretTerminal(hasTerminal: true, input: [_delete, ..._typed('a'), _enter]);

      expect(read(terminal), 'a');
      expect(terminal.output, '*\n');
    });

    test('Ctrl-U clears the value and the whole mask', () {
      final terminal = FakeSecretTerminal(hasTerminal: true, input: [..._typed('abc'), _ctrlU, ..._typed('z'), _enter]);

      expect(read(terminal), 'z');
      expect(terminal.output, '***${_erase * 3}*\n');
    });

    test('other control bytes are dropped without a cell, so an erase still matches what is held', () {
      final terminal = FakeSecretTerminal(
        hasTerminal: true,
        input: [..._typed('ab'), _escape, 1, _ctrlD, _delete, ..._typed('c'), _enter],
      );

      expect(read(terminal), 'ac', reason: 'Ctrl-D on a non-empty value is ignored, like every other control byte');
      expect(terminal.output, '**$_erase*\n', reason: 'one cell per accepted character, one erase for the one erase');
    });
  });

  group('the read ends without a value', () {
    test('Ctrl-C puts the mode back before the interrupt callback runs, then returns nothing', () {
      final terminal = FakeSecretTerminal(hasTerminal: true, input: [..._typed('abc'), _ctrlC]);
      var interrupts = 0;
      var hiddenAtCallback = true;

      final value = read(
        terminal,
        onInterrupt: () {
          interrupts++;
          hiddenAtCallback = terminal.hidden;
        },
      );

      expect(value, isNull);
      expect(interrupts, 1);
      expect(
        hiddenAtCallback,
        isFalse,
        reason: 'the callback exits the process, so a mode still hidden there would outlive it',
      );
      expect(terminal.output, endsWith('\n'), reason: 'the shell prompt must not land on the mask line');
    });

    test('Ctrl-D with nothing typed ends the read without interrupting', () {
      final terminal = FakeSecretTerminal(hasTerminal: true, input: [_ctrlD]);
      var interrupts = 0;

      expect(read(terminal, onInterrupt: () => interrupts++), isNull);
      expect(interrupts, 0, reason: 'end of input is not an interrupt: it exits 1 with a message, not 130');
    });

    test('end of input with nothing typed reads as no value', () {
      expect(read(FakeSecretTerminal(hasTerminal: true)), isNull);
    });

    test('end of input mid-value keeps what was typed', () {
      final terminal = FakeSecretTerminal(hasTerminal: true, input: _typed('sk-ant-oat01-PARTIAL'));

      expect(read(terminal), 'sk-ant-oat01-PARTIAL');
    });
  });

  group('the mode is put back exactly once, whatever ends the read', () {
    final endings = <String, List<int>>{
      'Enter': [..._typed('token'), _enter],
      'Ctrl-C': [..._typed('token'), _ctrlC],
      'Ctrl-D on an empty value': [_ctrlD],
      'end of input': <int>[],
      'an edit that erased everything': [..._typed('ab'), _ctrlU, _enter],
    };

    for (final ending in endings.entries) {
      test('after ${ending.key}', () {
        final terminal = FakeSecretTerminal(hasTerminal: true, input: ending.value);

        read(terminal, onInterrupt: () {});

        expect(terminal.enterCount, 1);
        expect(terminal.restoresAfterByteReads, [
          terminal.byteReadCount,
        ], reason: 'exactly one restore, after the last read — a second would put back an already-restored mode');
        expect(terminal.hidden, isFalse);
      });
    }
  });

  group('piped stdin', () {
    test('returns the piped value without prompting or touching the terminal mode', () {
      final terminal = FakeSecretTerminal(hasTerminal: false, readLine: () => 'sk-ant-oat01-PIPED');

      expect(read(terminal), 'sk-ant-oat01-PIPED');
      expect(terminal.readCount, 1, reason: 'a script supplies the whole line at once');
      expect(terminal.enterCount, 0, reason: 'every mode operation throws when stdin is not a terminal');
      expect(terminal.byteReadCount, 0);
      expect(terminal.writes, isEmpty, reason: 'a mask on piped input would corrupt the value a script sees');
      expect(prompts, isEmpty, reason: 'a prompt on piped input would be noise in a script');
    });

    test('end of input reads as no value', () {
      expect(read(FakeSecretTerminal(hasTerminal: false)), isNull);
    });
  });
}
