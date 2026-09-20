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
        'composer': 'acp',
        'usage': '',
        'usageHidden': true,
        'currentHidden': null,
        'revision': 4,
      },
    );
    expect(html, contains('agent:writer'));
    // Only the CURRENT turn is stated as prose; the editable rows above are the
    // statement of the next one, so a "Next turn" row would say it twice.
    expect(html, contains('project-id · claude'));
    expect(html, contains('Provider-native session and tool state do not'));
    expect(html, contains('aria-labelledby="effective-context-title"'));
    expect(html, contains('id="effective-context-form"'));
    expect(html, contains('Apply to next turn'));
    expect(html, contains('CLAUDE.md (workspace)'));
    expect(html, contains('Memory contributed'));
    // One representation of the payload: the editable rows. The card that used
    // to sit beside the composer and the second <dl> of the same eight fields
    // are gone, so a value cannot be read two ways.
    expect(html, isNot(contains('id="effective-context-summary"')));
    expect(html, isNot(contains('<dl>')));
    expect(html, isNot(contains('id="effective-context-detail-workspace"')));
    expect(html, isNot(contains('<div class="tabs"')));
    expect(html, isNot(contains('id="effective-context-next"')));
    expect(html, isNot(contains('Next turn')));
    // Current differs from next here (claude vs acp), so its row is shown.
    expect(html, contains('id="effective-context-current-row"'));
    expect(html, isNot(contains('id="effective-context-current-row" hidden')));
    // An unset editable field states its fallback rather than reading blank.
    expect(html, contains('placeholder="unavailable for this adapter"'));
    // Long values stay readable: the full string is on the title.
    expect(html, contains('title="/project/subdir"'));
    expect(html, contains('title="CLAUDE.md (workspace)"'));
    // The continuity notice is a consequence of changing provider, so it ships
    // hidden and is revealed by the controller.
    expect(html, contains('id="effective-context-continuity" class="banner banner-warning" hidden'));
    // No measurement, so the chip carries no percentage — never a stand-in.
    expect(html, contains('id="effective-context-usage" hidden'));
  });

  test('the composer pill states only segments the next turn actually has', () {
    final html = chatAreaTemplate(
      sessionId: 'session-id',
      messagesHtml: '',
      effectiveContext: const {
        'workspace': 'web',
        'project': 'Human Project',
        'projectId': 'project-id',
        'directory': '/project',
        'provider': 'claude',
        'current': 'project-id · claude',
        'next': 'project-id · claude',
        'telemetry': 'unavailable',
        'behavior': 'none recorded',
        'projects': [],
        'providers': [],
        'modelEditable': true,
        'effortEditable': true,
        'modelValue': '',
        'effortValue': '',
        'composer': 'claude',
        'usage': '',
        'usageHidden': true,
        'currentHidden': true,
        'revision': 1,
      },
    );
    expect(html, contains('class="composer-model"'));
    expect(html, contains('>claude</button>'));
    // Current matches next here, so the row is not drawn at all.
    expect(html, contains('id="effective-context-current-row" hidden'));
    // Both fields are editable and unset, so both offer the provider default.
    expect(html, contains('placeholder="provider default"'));
    expect(html, isNot(contains('provider model')));
    expect(html, isNot(contains('provider effort')));
  });

  test('session projection uses the shared relative timestamp formatter', () async {
    final source = File(await resolveServerPackagePath('lib', 'src', 'api', 'session_routes_support.dart'))
        .readAsStringSync();
    expect(source, contains('formatRelativeTimeIso(telemetry.observedAt.toIso8601String())'));
    final template = File(await resolveServerPackagePath('lib', 'src', 'templates', 'session_info.html'))
        .readAsStringSync();
    expect(template, contains('id="session-effective-context"'));
    expect(template, contains(r'data-identicon-id=${effectiveContext.projectId}'));
    expect(template, contains('id="session-memory-provenance"'));
  });
}
