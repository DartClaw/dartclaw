import 'dart:io';

import 'package:dartclaw_core/dartclaw_core.dart' show TaskEventKind;
import 'package:dartclaw_server/src/templates/task_event_display.dart';
import 'package:test/test.dart';

/// The SSE `task_event` payload carries `kind` but no icon name, and the
/// no-backend-work constraint keeps it that way, so `dc_tasks_controller.js`
/// mirrors [eventIconClass] in a plain-data map. A mirror drifts silently — a
/// new `TaskEventKind` renders as a bare `.icon` with no mask, which paints the
/// solid square the mask path exists to remove. These tests are what makes that
/// drift fail here instead of in the UI.
void main() {
  final staticDir = File('packages/dartclaw_server/lib/src/static/controllers/index.js').existsSync()
      ? 'packages/dartclaw_server/lib/src/static'
      : 'lib/src/static';
  final controllerSource = File('$staticDir/controllers/dc_tasks_controller.js').readAsStringSync();
  final iconsCss = File('$staticDir/icons.css').readAsStringSync();

  /// Every non-default literal arm of `TaskEventKind.fromName`. Asserted against
  /// the enum source below so a new alias cannot be added without updating this.
  const fromNameAliases = <String, TaskEventKind>{'error': TaskEventKind.taskError};

  Map<String, String> parseControllerMap() {
    final start = controllerSource.indexOf('const TASK_EVENT_ICON_CLASSES = {');
    expect(start, isNot(-1), reason: 'the named kind -> icon map is missing from dc_tasks_controller.js');
    final end = controllerSource.indexOf('};', start);
    final body = controllerSource.substring(controllerSource.indexOf('{', start) + 1, end);
    return {for (final m in RegExp(r"(\w+)\s*:\s*'([\w-]+)'").allMatches(body)) m.group(1)!: m.group(2)!};
  }

  test('the controller map equals eventIconClass over every kind and alias', () {
    final expected = <String, String>{
      for (final kind in TaskEventKind.values) kind.name: eventIconClass(kind),
      for (final alias in fromNameAliases.entries) alias.key: eventIconClass(TaskEventKind.fromName(alias.key)),
    };
    // Exact equality, not containment: a superset would let a stale key survive
    // and a subset would let a new kind fall through to the no-mask branch.
    expect(parseControllerMap(), expected);
  });

  test('fromName aliases are declared, and are all of them', () {
    for (final alias in fromNameAliases.entries) {
      expect(TaskEventKind.fromName(alias.key), alias.value);
    }
    // Source-shape check: any second literal arm added to fromName has to be
    // mirrored above, or this fails.
    final enumSource = File(
      File('packages/dartclaw_core/lib/src/task/task_event.dart').existsSync()
          ? 'packages/dartclaw_core/lib/src/task/task_event.dart'
          : '../dartclaw_core/lib/src/task/task_event.dart',
    ).readAsStringSync();
    final switchStart = enumSource.indexOf('static TaskEventKind fromName(String name)');
    final switchEnd = enumSource.indexOf('};', switchStart);
    final arms = RegExp(r"'([\w-]+)'\s*=>").allMatches(enumSource.substring(switchStart, switchEnd));
    expect(arms.map((m) => m.group(1)).toSet(), fromNameAliases.keys.toSet());
  });

  test('an unrecognized kind resolves to null through a direct lookup', () {
    final parsed = parseControllerMap();
    expect(parsed.containsKey('future_event_kind'), isFalse);

    // The resolver must be a direct lookup returning null, not a fallback to
    // some default glyph — a wrong-but-present icon is worse than none. Scoped
    // to the function body: an unanchored search would be satisfied by any
    // `? x : null` elsewhere in the controller.
    final start = controllerSource.indexOf('function taskEventIconClass(kind)');
    expect(start, isNot(-1), reason: 'the resolver is missing');
    final body = controllerSource.substring(start, controllerSource.indexOf('\n  }\n', start));
    expect(body, contains('TASK_EVENT_ICON_CLASSES[kind]'));
    expect(body, contains(': null'));
    expect(body, isNot(contains("'icon-")), reason: 'the resolver must not name a default glyph');
  });

  test('the unknown branch emits neither the base icon class nor a mask', () {
    // `.icon` sets a mask-image from a custom property; with no `icon-*` class
    // that property is unset and the element paints as a filled block.
    final start = controllerSource.indexOf('function updateDashboardEvents(data) {');
    final render = controllerSource.substring(start, controllerSource.indexOf('\n  }\n', start));
    expect(render, contains("maskClass ? ['icon', maskClass] : []"));
    expect(render, isNot(contains('iconChar')));
  });

  test('every mapped icon name has a rule in the served icons.css', () {
    for (final name in parseControllerMap().values.toSet()) {
      expect(RegExp('^\\.$name\\b', multiLine: true).hasMatch(iconsCss), isTrue, reason: '$name has no mask rule');
    }
  });
}
