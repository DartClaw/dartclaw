import 'dart:io';

import 'package:test/test.dart';

void main() {
  test('effective-context controls use the corrected canonical rules', () {
    final css = File('dev/design-system/components.css').readAsStringSync();
    expect(css, contains('.identicon--5 { background: linear-gradient(135deg, var(--teal), color-mix'));
    expect(css, isNot(contains('.dialog .tabs { border-bottom: 0; }')));
    expect(css, contains('.dialog > .tabs,'));
  });
}
