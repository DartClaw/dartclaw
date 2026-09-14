import 'dart:io';

import 'package:dartclaw_runtime/src/templates/chat.dart';
import 'package:dartclaw_runtime/src/templates/loader.dart';
import 'package:test/test.dart';

import '../test_utils.dart';

void main() {
  setUpAll(() async => initTemplates(await resolveTemplatesDir()));
  tearDownAll(resetTemplates);

  test('chat projection keeps immutable workspace separate from current and next context', () {
    final html = chatAreaTemplate(
      sessionId: 'session-id',
      messagesHtml: '',
      effectiveContext: const {
        'workspace': 'agent:writer',
        'project': 'Human Project',
        'projectId': 'project-id',
        'directory': '/project/subdir',
        'provider': 'acp',
        'model': 'unavailable',
        'effort': 'unavailable',
        'current': 'project-id · claude',
        'next': 'project-id · acp',
        'telemetry': 'stale · acp · 2m ago',
        'behavior': 'CLAUDE.md (workspace)',
        'memory': 'Memory contributed',
        'projects': [
          {'value': 'project-id', 'label': 'Human Project', 'selected': true},
        ],
        'providers': [
          {'value': 'acp', 'label': 'acp', 'selected': true, 'model': 'false', 'effort': 'false'},
        ],
        'modelEditable': false,
        'effortEditable': false,
        'modelValue': '',
        'effortValue': '',
        'composer': 'acp · model unavailable · effort unavailable',
        'revision': 4,
      },
    );
    expect(html, contains('id="effective-context-summary"'));
    expect(html, contains('agent:writer'));
    expect(html, contains('project-id · claude'));
    expect(html, contains('project-id · acp'));
    expect(html, contains('unavailable'));
    expect(html, contains('Provider-native session and tool state do not'));
    expect(html, contains('aria-labelledby="effective-context-title"'));
    expect(html, contains('id="effective-context-form"'));
    expect(html, contains('Apply to next turn'));
    expect(html, contains('CLAUDE.md (workspace)'));
    expect(html, contains('Memory contributed'));
  });

  test('session projection uses the shared relative timestamp formatter', () {
    final source = File('packages/dartclaw_runtime/lib/src/api/session_routes_support.dart').readAsStringSync();
    expect(source, contains('formatRelativeTimeIso(telemetry.observedAt.toIso8601String())'));
    final template = File('packages/dartclaw_runtime/lib/src/templates/session_info.html').readAsStringSync();
    expect(template, contains('id="session-effective-context"'));
    expect(template, contains(r'data-identicon-id=${effectiveContext.projectId}'));
    expect(template, contains('id="session-memory-provenance"'));
  });
}
