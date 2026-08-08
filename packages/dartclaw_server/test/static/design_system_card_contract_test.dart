import 'dart:io';

import 'package:test/test.dart';

void main() {
  final fromWorkspaceRoot = File('packages/dartclaw_server/lib/src/static/design-system.css').existsSync();
  final servedPath = fromWorkspaceRoot
      ? 'packages/dartclaw_server/lib/src/static/design-system.css'
      : 'lib/src/static/design-system.css';
  final canonPath = fromWorkspaceRoot ? 'dev/design-system/components.css' : '../../dev/design-system/components.css';

  test('canonical and served cards establish block layout for any host element', () {
    for (final path in [canonPath, servedPath]) {
      final css = File(path).readAsStringSync();
      _expectDisplay(css, '.card', 'block', path, 'anchor cards must be block-level containers');
      _expectDisplay(css, r'.dialog:not([open])', 'none', path, 'card styling must not expose closed dialogs');
    }
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
