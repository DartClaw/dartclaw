import 'dart:io';

/// Captures `stdout` lines into [lines] for assertion, stubbing all other
/// [Stdout] members via [noSuchMethod].
class CapturingStdout implements Stdout {
  final List<String> lines;
  CapturingStdout(this.lines);

  @override
  void writeln([Object? object = '']) => lines.add(object.toString());

  @override
  void write(Object? object) => lines.add(object.toString());

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}
