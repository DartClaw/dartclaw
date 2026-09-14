import 'dart:io';

import 'package:test/test.dart';

import '../test_utils.dart';

void main() {
  test('disabled and idle status dots remain semantically distinct', () async {
    final css = File(await resolveDesignSystemCss('components.css')).readAsStringSync();
    final scheduling = File(await resolveServerPackagePath('lib', 'src', 'templates', 'scheduling.dart'))
        .readAsStringSync();
    expect(css, contains('.status-dot--idle'));
    expect(css, contains('.status-dot--muted'));
    expect(scheduling, contains("task.enabled ? 'status-dot--live' : 'status-dot--muted'"));
  });
}
