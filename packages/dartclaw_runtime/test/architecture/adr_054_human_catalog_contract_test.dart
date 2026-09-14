import 'dart:io';

import 'package:test/test.dart';

void main() {
  test('human catalog allowance preserves the model-facing prose prohibition', () {
    final adr = File('dev/adrs/054-model-first-delegation-and-one-authority-per-concern.md').readAsStringSync();

    expect(adr, contains('A human command picker is a keyboard control, not a prose grammar.'));
    expect(adr, contains('closed, typed catalog'));
    expect(adr, contains('re-authorized at dispatch against the current conversation revision and capabilities'));
    expect(adr, contains('unknown slash-prefixed message, remains byte-identical provider transport'));
    expect(adr, contains('does not permit interpreting model output or inferring actions from user prose'));
    expect(adr, contains('Give the capability a tool, not a grammar.'));
  });
}
