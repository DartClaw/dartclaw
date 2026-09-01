import 'dart:io';

import 'package:test/test.dart';

import '../test_utils.dart';

void main() {
  late String canonPath;

  setUpAll(() async {
    canonPath = await resolveDesignSystemCss('components.css');
  });

  test('canonical cards establish block layout for any host element', () {
    final css = File(canonPath).readAsStringSync();
    _expectDisplay(css, '.card', 'block', canonPath, 'anchor cards must be block-level containers');
    _expectDisplay(css, r'.dialog:not([open])', 'none', canonPath, 'card styling must not expose closed dialogs');
  });
}

void _expectDisplay(String css, String selector, String value, String path, String reason) {
  final rule = RegExp('^${RegExp.escape(selector)}\\s*\\{([^}]*)\\}', multiLine: true).firstMatch(css);
  expect(rule, isNotNull, reason: '$path must define $selector');
  expect(
    RegExp('^\\s*display:\\s*${RegExp.escape(value)}\\s*;', multiLine: true).hasMatch(rule!.group(1)!),
    isTrue,
    reason: '$path: $reason',
  );
}
