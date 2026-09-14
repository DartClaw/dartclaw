import 'dart:io';

import 'package:test/test.dart';

void main() {
  test('disabled and idle status dots remain semantically distinct', () {
    final css = File('dev/design-system/components.css').readAsStringSync();
    final scheduling = File('packages/dartclaw_runtime/lib/src/templates/scheduling.dart').readAsStringSync();
    expect(css, contains('.status-dot--idle'));
    expect(css, contains('.status-dot--muted'));
    expect(scheduling, contains("task.enabled ? 'status-dot--live' : 'status-dot--muted'"));
  });
}
