import 'dart:io';

import 'package:test/test.dart';

import '../test_utils.dart';

void main() {
  test('effective-context controls use the corrected canonical rules', () async {
    final css = File(await resolveDesignSystemCss('components.css')).readAsStringSync();
    expect(css, contains('.identicon--5 { background: linear-gradient(135deg, var(--teal), color-mix'));
    expect(css, isNot(contains('.dialog .tabs { border-bottom: 0; }')));
    expect(css, contains('.dialog > .tabs,'));
  });
}
