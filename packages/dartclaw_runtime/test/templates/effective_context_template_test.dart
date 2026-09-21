import 'dart:io';

import 'package:dartclaw_runtime/src/templates/chat.dart';
import 'package:dartclaw_runtime/src/templates/loader.dart';
import 'package:test/test.dart';

import '../test_utils.dart';

void main() {
  setUpAll(() async => initTemplates(await resolveTemplatesDir()));
  tearDownAll(resetTemplates);

  test('the chip and the pill open separate popovers over the fields each names', () {
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
          {
            'value': 'acp',
            'label': 'acp',
            'selected': true,
            'model': 'false',
            'effort': 'false',
            'models': '',
            'efforts': '',
          },
        ],
        'modelEditable': false,
        'effortEditable': false,
        'modelValue': '',
        'effortValue': '',
        'modelOptions': [
          {'value': '', 'label': 'Provider default', 'selected': true},
        ],
        'effortOptions': [
          {'value': '', 'label': 'Provider default', 'selected': true},
        ],
        'composer': 'acp',
        'usage': '',
        'usageHidden': true,
        'currentHidden': null,
        'revision': 4,
      },
    );
    // Each trigger names the popover it owns, so the same action serves both.
    expect(html, contains('aria-controls="effective-context-project-pop"'));
    expect(html, contains('aria-controls="effective-context-model-pop"'));
    expect(html, contains('id="effective-context-project-form"'));
    expect(html, contains('id="effective-context-model-form"'));
    expect(html, contains('aria-labelledby="effective-context-project-title"'));
    expect(html, contains('aria-labelledby="effective-context-model-title"'));
    // Two Applies, one per surface.
    expect('Apply to next turn'.allMatches(html), hasLength(2));
    // The read-only facts left the composer; Session info already lists them,
    // and the footer link is how the popover gets the reader there.
    for (final absent in const [
      'id="effective-context-workspace"',
      'id="effective-context-current-row"',
      'id="effective-context-telemetry"',
      'id="effective-context-behavior"',
      'id="effective-context-memory-row"',
      'id="effective-context-summary"',
      'class="pop pop-context',
      'meta-row',
    ]) {
      expect(html, isNot(contains(absent)), reason: absent);
    }
    expect(html, contains('href="/sessions/session-id/info"'));
    // Canon form vocabulary, and no inline-edit transparency.
    expect(html, contains('class="form-label t-caption tracking-caps"'));
    expect(html, contains('class="form-select"'));
    // `.meta-val` was the hook the transparent-until-hover rule keyed on.
    expect(html, isNot(contains('meta-val"')));
    expect(html, isNot(contains('meta-val ')));
    // An adapter that transports neither leaves both pickers disabled rather
    // than offering a value the turn would drop.
    expect(html, contains('id="effective-context-model-input" name="model" class="form-select" disabled'));
    expect(html, contains('id="effective-context-effort-input" name="effort" class="form-select" disabled'));
    expect(html, contains('Provider-native session and tool state do not'));
    // The continuity notice is a consequence of changing provider, so it ships
    // hidden and is revealed by the controller.
    expect(html, contains('id="effective-context-continuity" class="banner banner-warning" hidden'));
    // Long values stay readable: the full string is on the title.
    expect(html, contains('title="/project/subdir"'));
    // No measurement, so the chip carries no percentage — never a stand-in.
    expect(html, contains('id="effective-context-usage" hidden'));
  });

  test('the pickers render the catalogue the view projected, and the pill states only what is selected', () {
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
        'providers': [
          {
            'value': 'claude',
            'label': 'claude',
            'selected': true,
            'model': 'true',
            'effort': 'true',
            'models': 'sonnet,opus',
            'efforts': 'low,high',
          },
        ],
        'modelEditable': true,
        'effortEditable': true,
        'modelValue': 'sonnet',
        'effortValue': '',
        'modelOptions': [
          {'value': '', 'label': 'Provider default', 'selected': false},
          {'value': 'sonnet', 'label': 'sonnet', 'selected': true},
          {'value': 'opus', 'label': 'opus', 'selected': false},
        ],
        'effortOptions': [
          {'value': '', 'label': 'Provider default', 'selected': true},
          {'value': 'low', 'label': 'low', 'selected': false},
          {'value': 'high', 'label': 'high', 'selected': false},
        ],
        'composer': 'claude · sonnet',
        'usage': '',
        'usageHidden': true,
        'currentHidden': true,
        'revision': 1,
      },
    );
    expect(html, contains('class="composer-model"'));
    expect(html, contains('>claude · sonnet</button>'));
    expect(html, contains('<option value="sonnet" selected="">sonnet</option>'));
    expect(html, contains('<option value="opus">opus</option>'));
    // The provider option carries its own catalogue, so a provider change
    // re-renders the pickers without a second round trip.
    expect(html, contains('data-models="sonnet,opus"'));
    expect(html, contains('data-efforts="low,high"'));
    expect(html, isNot(contains('placeholder="provider default"')));
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
