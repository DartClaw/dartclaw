import 'dart:io';

import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:dartclaw_kernel/dartclaw_kernel.dart';
import 'package:dartclaw_runtime/src/api/session_routes_support.dart';
import 'package:dartclaw_runtime/src/templates/chat.dart';
import 'package:dartclaw_runtime/src/templates/loader.dart';
import 'package:dartclaw_runtime/src/templates/topbar.dart';
import 'package:test/test.dart';

import '../test_utils.dart';

const _claudeCatalogue = ModelCatalogue(
  entries: [
    ModelCatalogueEntry(id: 'opus[1m]', label: 'Opus (1M context)', efforts: ['low', 'medium', 'high', 'xhigh', 'max']),
    ModelCatalogueEntry(id: 'sonnet', label: 'Sonnet', efforts: ['low', 'medium', 'high', 'xhigh', 'max']),
    ModelCatalogueEntry(id: 'haiku', label: 'Haiku'),
  ],
  defaultId: 'opus[1m]',
);

void main() {
  setUpAll(() async => initTemplates(await resolveTemplatesDir()));
  tearDownAll(resetTemplates);

  test('general chat names the owner directory and offers an explicit move without a directory editor', () {
    final html = chatAreaTemplate(
      sessionId: 'general-1',
      messagesHtml: '',
      canMove: true,
      effectiveContext: const {
        'project': 'General chat',
        'projectId': null,
        'directory': '/owner',
        'ownerDirectory': '/owner',
        'provider': 'claude',
        'composer': 'Claude',
        'projects': [
          {'value': 'website', 'label': 'Website', 'directory': '/projects/website'},
        ],
      },
    );

    expect(html, contains('data-owner-directory="/owner"'));
    expect(html, contains('id="context-move-dialog"'));
    expect(html, contains('data-directory="/projects/website"'));
    expect(html, contains('id="effective-context-directory" name="directory" type="hidden"'));
    expect(html, isNot(contains('data-identicon-id="_local"')));
  });

  test('Agent does not expose a move action', () {
    final html = chatAreaTemplate(
      sessionId: 'agent',
      messagesHtml: '',
      effectiveContext: const {
        'project': 'General chat',
        'projectId': null,
        'directory': '/owner',
        'projects': [
          {'value': 'website', 'label': 'Website', 'directory': '/projects/website'},
        ],
      },
    );
    expect(html, isNot(contains('id="context-move-dialog"')));
  });

  test('an unavailable project pauses sending and keeps General recovery reachable', () {
    final html = chatAreaTemplate(
      sessionId: 'project-1',
      messagesHtml: '<p>Retained history</p>',
      canMove: true,
      effectiveContext: const {
        'project': 'Website',
        'projectId': 'website',
        'projectUnavailable': true,
        'directory': '/projects/website',
        'ownerDirectory': '/owner',
        'projects': [],
      },
    );
    expect(html, contains('Retained history'));
    expect(html, contains('sending is paused'));
    expect(html, contains('id="context-move-dialog"'));
    expect(html, contains('<option value="">General chat</option>'));
    expect(html, contains('id="send-btn"'));
    expect(html, contains('disabled=""'));
  });

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
          {'value': 'acp', 'label': 'acp', 'selected': true, 'model': 'false', 'models': '[]'},
        ],
        'modelEditable': false,
        'effortEditable': false,
        'modelValue': '',
        'effortValue': '',
        'modelOptions': [
          {'value': '', 'label': 'Default', 'selected': true, 'efforts': '[]', 'effortEditable': 'false'},
        ],
        'effortOptions': [
          {'value': '', 'label': 'Default', 'selected': true},
        ],
        'composer': 'acp',
        'usage': '',
        'usageHidden': true,
        'currentHidden': null,
        'continuityHidden': null,
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
    // A change applies when it is committed; there is no separate step that
    // could leave a control showing a value the next turn would not run.
    expect(html, isNot(contains('Apply to next turn')));
    expect(html, isNot(contains('effective-context-apply')));
    expect(html, isNot(contains('effective-context-project-apply')));
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
    expect(html, contains('class="form-select" data-action="change->dc-chat#contextModelChanged" disabled'));
    expect(html, contains('id="effective-context-effort-input" name="effort" class="form-select" disabled'));
    expect(html, contains('Provider-native session and tool state do not'));
    // The last turn ran on claude and the next runs on acp, so the notice is
    // part of the first paint rather than something only a client apply shows.
    expect(html, contains('id="effective-context-continuity" class="banner banner-warning">'));
    // Long values stay readable: the full string is on the title.
    expect(html, contains('id="effective-context-directory-label"'));
    expect(html, contains('/project/subdir'));
    // No measurement, so the chip carries no percentage — never a stand-in.
    expect(html, contains('id="effective-context-usage" hidden'));
  });

  test('the pickers render the options the view built, and the pill names the selected model', () async {
    final now = DateTime.utc(2026, 9, 21);
    const context = EffectiveConversationContext(
      projectId: 'project-id',
      directory: '/project',
      referenceRoot: '/project',
      provider: 'claude',
      model: 'sonnet',
    );
    final view = await effectiveContextView(
      Session(
        id: 'session-id',
        type: SessionType.user,
        retention: ConversationRetention.durable,
        provider: 'claude',
        createdAt: now,
        updatedAt: now,
      ),
      ConversationState().admitContext(context).stageContext(context),
      null,
      'claude',
      const {'claude': EffectiveContextCapabilities(model: true, effort: true)},
      catalogues: (_) => _claudeCatalogue,
    );
    final html = chatAreaTemplate(sessionId: 'session-id', messagesHtml: '', effectiveContext: view);

    // Same provider as the last turn: nothing to warn about.
    expect(html, contains('id="effective-context-continuity" class="banner banner-warning" hidden'));
    expect(html, contains('class="composer-model"'));
    expect(html, contains('>claude · Sonnet</button>'));
    expect(html, matches(RegExp(r'<option value=""[^>]*>Default · Opus \(1M context\)</option>')));
    expect(html, matches(RegExp(r'<option value="sonnet" selected=""[^>]*>Sonnet</option>')));
    // Each model option carries the Effort picker it selects, and a model that
    // reports none locks it; the controller renders these, never a list of its own.
    expect(html, matches(RegExp(r'<option value="haiku"[^>]*data-effort-editable="false"[^>]*>Haiku</option>')));
    expect(html, contains('<option value="max">max</option>'));
    // The provider option carries its whole picker, so a provider change
    // re-renders it without a second round trip.
    expect(
      html,
      contains(
        'data-models="[{&quot;value&quot;:&quot;&quot;,&quot;label&quot;:&quot;Default · Opus (1M context)&quot;',
      ),
    );
    expect(html, contains('data-action="change->dc-chat#contextModelChanged"'));
  });

  group('crumb model label', () {
    String crumb(String? model) => topbarTemplate(
      title: 'Chat',
      sessionId: 'session-id',
      sessionType: SessionType.user,
      projectId: 'project-id',
      projectName: 'Human Project',
      providerLabel: 'claude',
      model: contextModelLabel(_claudeCatalogue, model),
    );

    test('names a catalogued model by the provider\'s label', () {
      expect(crumb('sonnet'), contains('>Sonnet<'));
      expect(crumb('sonnet'), isNot(contains('>sonnet<')));
    });

    test('a general chat names its context without a project identicon', () {
      final html = topbarTemplate(
        title: 'Chat',
        sessionId: 'general',
        sessionType: SessionType.user,
        providerLabel: 'claude',
      );
      expect(html, contains('>General chat<'));
      expect(html, isNot(contains('class="identicon"')));
    });

    test('names an uncatalogued model by its id', () {
      expect(crumb('claude-sonnet-4-5'), contains('>claude-sonnet-4-5<'));
    });

    test('names Default by what it resolves to, and nothing when that is unresolved', () {
      expect(crumb(null), contains('>Opus (1M context)<'));
      final unresolved = topbarTemplate(
        title: 'Chat',
        sessionId: 'session-id',
        sessionType: SessionType.user,
        providerLabel: 'claude',
        model: contextModelLabel(const ModelCatalogue(entries: []), null),
      );
      expect(unresolved, isNot(contains('crumb-model')));
    });
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
