import 'dart:convert';

import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:dartclaw_kernel/dartclaw_kernel.dart';
import 'package:dartclaw_runtime/src/api/session_routes_support.dart';
import 'package:test/test.dart';

void main() {
  final now = DateTime.utc(2026, 9, 19, 11, 42);

  Session session() => Session(
    id: 'session-1',
    type: SessionType.user,
    retention: ConversationRetention.durable,
    provider: 'claude',
    createdAt: now,
    updatedAt: now,
  );

  Future<Map<String, dynamic>> view(
    ConversationState state, {
    Map<String, EffectiveContextCapabilities> capabilities = const {},
    Map<String, ModelCatalogue> catalogues = const {},
  }) => effectiveContextView(session(), state, null, 'claude', capabilities, catalogues: (id) => catalogues[id]);

  // The composer pill is read as a claim about the next turn. A segment nobody
  // has selected has to be absent, because a stand-in reads as a selection.
  test('the composer label omits segments the conversation has not selected', () async {
    final projection = await view(ConversationState());
    expect(projection['composer'], 'claude');
    expect(projection['composer'], isNot(contains('provider model')));
    expect(projection['composer'], isNot(contains('provider effort')));
  });

  test('the composer label states the model and effort once they exist', () async {
    final projection = await view(
      ConversationState().stageContext(
        const EffectiveConversationContext(
          projectId: 'project-1',
          directory: '/tmp',
          referenceRoot: '/tmp',
          provider: 'claude',
          model: 'sonnet-4.6',
          effort: 'high',
        ),
      ),
    );
    expect(projection['composer'], 'claude · sonnet-4.6 · high');
  });

  group('model catalogue', () {
    const flags = {
      'claude': EffectiveContextCapabilities(model: true, effort: true),
      'codex': EffectiveContextCapabilities(model: true, effort: true),
    };
    const fiveEfforts = ['low', 'medium', 'high', 'xhigh', 'max'];
    const claudeCatalogue = ModelCatalogue(
      entries: [
        ModelCatalogueEntry(id: 'opus[1m]', label: 'Opus (1M context)', efforts: fiveEfforts),
        ModelCatalogueEntry(id: 'claude-fable-5-1[1m]', label: 'Fable', efforts: fiveEfforts),
        ModelCatalogueEntry(id: 'sonnet', label: 'Sonnet', efforts: fiveEfforts),
        ModelCatalogueEntry(id: 'haiku', label: 'Haiku'),
      ],
      defaultId: 'opus[1m]',
    );
    const codexCatalogue = ModelCatalogue(
      entries: [
        ModelCatalogueEntry(
          id: 'gpt-5.5',
          label: 'GPT-5.5',
          efforts: ['low', 'medium', 'high', 'xhigh', 'max', 'ultra'],
        ),
        ModelCatalogueEntry(id: 'gpt-5.4', label: 'GPT-5.4', efforts: ['low', 'medium', 'high', 'xhigh']),
      ],
      defaultId: 'gpt-5.5',
    );
    const catalogues = {'claude': claudeCatalogue, 'codex': codexCatalogue};

    ConversationState staged({String provider = 'claude', String? model, String? effort}) =>
        ConversationState().stageContext(
          EffectiveConversationContext(
            projectId: 'project-1',
            directory: '/tmp',
            referenceRoot: '/tmp',
            provider: provider,
            model: model,
            effort: effort,
          ),
        );

    List<String> labels(Object? options) => [for (final option in options! as List) option['label'] as String];
    List<String> values(Object? options) => [for (final option in options! as List) option['value'] as String];
    List<String> efforts(Map<String, dynamic> option) => [
      for (final effort in jsonDecode(option['efforts'] as String) as List) effort['value'] as String,
    ];

    test('Claude models are offered by the provider\'s own names, Default naming what it resolves to', () async {
      final projection = await view(ConversationState(), capabilities: flags, catalogues: catalogues);

      expect(labels(projection['modelOptions']), [
        'Default · Opus (1M context)',
        'Opus (1M context)',
        'Fable',
        'Sonnet',
        'Haiku',
      ]);
      expect(values(projection['modelOptions']), ['', 'opus[1m]', 'claude-fable-5-1[1m]', 'sonnet', 'haiku']);
      expect((projection['modelOptions'] as List).first['selected'], isTrue);
    });

    test('Codex models are offered by displayName with Default naming the resolved one', () async {
      final projection = await view(
        staged(provider: 'codex'),
        capabilities: flags,
        catalogues: catalogues,
      );

      expect(labels(projection['modelOptions']), ['Default · GPT-5.5', 'GPT-5.5', 'GPT-5.4']);
      expect(values(projection['modelOptions']), ['', 'gpt-5.5', 'gpt-5.4']);
      // The provider switcher carries each provider's whole picker, built here.
      final providers = {for (final option in projection['providers'] as List) option['value']: option};
      expect(labels(jsonDecode(providers['claude']['models'] as String)), contains('Default · Opus (1M context)'));
    });

    test('Effort offers exactly what the selected model reports, and locks for a model reporting none', () async {
      final haiku = await view(
        staged(model: 'haiku'),
        capabilities: flags,
        catalogues: catalogues,
      );
      expect(values(haiku['effortOptions']), ['']);
      expect(haiku['effortEditable'], isFalse);

      final sonnet = await view(
        staged(model: 'sonnet'),
        capabilities: flags,
        catalogues: catalogues,
      );
      expect(values(sonnet['effortOptions']), ['', ...fiveEfforts]);
      expect(sonnet['effortEditable'], isTrue);

      final codex = await view(
        staged(provider: 'codex', model: 'gpt-5.5'),
        capabilities: flags,
        catalogues: catalogues,
      );
      expect(values(codex['effortOptions']), ['', 'low', 'medium', 'high', 'xhigh', 'max', 'ultra']);

      // Each model option carries its own Effort picker, so a model change on
      // the page rebuilds Effort from server data rather than re-deriving it.
      final options = {for (final option in sonnet['modelOptions'] as List) option['value']: option};
      expect(efforts(options['haiku'] as Map<String, dynamic>), ['']);
      expect(options['haiku']['effortEditable'], 'false');
      expect(efforts(options['sonnet'] as Map<String, dynamic>), ['', ...fiveEfforts]);
    });

    test('the pill names the model the next turn runs, Default by what it resolves to', () async {
      final unset = await view(ConversationState(), capabilities: flags, catalogues: catalogues);
      expect(unset['composer'], 'claude · Opus (1M context)');

      final sonnet = await view(
        staged(model: 'sonnet', effort: 'high'),
        capabilities: flags,
        catalogues: catalogues,
      );
      expect(sonnet['composer'], 'claude · Sonnet · high');
    });

    test('a staged model the catalogue does not list stays selectable under its own id', () async {
      final projection = await view(
        staged(model: 'claude-sonnet-4-5'),
        capabilities: flags,
        catalogues: catalogues,
      );

      expect((projection['modelOptions'] as List).last, containsPair('value', 'claude-sonnet-4-5'));
      expect((projection['modelOptions'] as List).last, containsPair('label', 'claude-sonnet-4-5'));
      expect((projection['modelOptions'] as List).last, containsPair('selected', true));
      expect(projection['composer'], 'claude · claude-sonnet-4-5');
    });

    test('before or without a catalogue the pickers offer Default plus any staged value', () async {
      final projection = await view(
        staged(model: 'claude-sonnet-4-5', effort: 'high'),
        capabilities: flags,
      );

      expect(labels(projection['modelOptions']), ['Default', 'claude-sonnet-4-5']);
      expect(values(projection['effortOptions']), ['', 'high']);
      expect(projection['effortEditable'], isTrue);
      expect(projection['composer'], 'claude · claude-sonnet-4-5 · high');

      final unset = await view(ConversationState(), capabilities: flags);
      expect(labels(unset['modelOptions']), ['Default']);
      expect(unset['composer'], 'claude');
    });

    test('an unresolved default reads plain Default and the pill names the provider alone', () async {
      const unresolved = ModelCatalogue(
        entries: [ModelCatalogueEntry(id: 'sonnet', label: 'Sonnet')],
      );
      final projection = await view(ConversationState(), capabilities: flags, catalogues: {'claude': unresolved});

      expect(labels(projection['modelOptions']), ['Default', 'Sonnet']);
      expect(projection['composer'], 'claude');
    });

    test('Session info names the model by the same label, never the raw id', () async {
      final unset = await view(ConversationState(), capabilities: flags, catalogues: catalogues);
      expect(unset['model'], 'Opus (1M context)');
      expect(unset['effort'], 'Default');

      final sonnet = await view(
        staged(model: 'sonnet', effort: 'high'),
        capabilities: flags,
        catalogues: catalogues,
      );
      expect(sonnet['model'], 'Sonnet');
      expect(sonnet['effort'], 'high');

      final uncatalogued = await view(staged(model: 'claude-sonnet-4-5'), capabilities: flags);
      expect(uncatalogued['model'], 'claude-sonnet-4-5');
      final unresolved = await view(ConversationState(), capabilities: flags);
      expect(unresolved['model'], 'Default');
    });

    test('the current and next context labels name a catalogued model by its label', () async {
      const context = EffectiveConversationContext(
        projectId: 'project-1',
        directory: '/tmp',
        referenceRoot: '/tmp',
        provider: 'claude',
        model: 'sonnet',
      );
      final projection = await view(
        ConversationState().admitContext(context).stageContext(context),
        capabilities: flags,
        catalogues: catalogues,
      );

      expect(projection['current'], 'project-1 · claude · Sonnet');
      expect(projection['next'], 'project-1 · claude · Sonnet');
    });
  });

  test('context usage is a number only when a live measurement supplies both halves', () async {
    final unmeasured = await view(
      ConversationState().recordTelemetry(
        SessionContextTelemetry(
          sessionId: 'session-1',
          source: 'claude',
          observedAt: now,
          availability: ContextMeasurementAvailability.unsupported,
        ),
      ),
    );
    expect(unmeasured['usage'], '');
    expect(unmeasured['usageHidden'], isTrue);

    // Measured, but the provider reported no window — a percentage of an
    // unknown whole is a guess.
    final windowless = await view(
      ConversationState().recordTelemetry(
        SessionContextTelemetry(
          sessionId: 'session-1',
          source: 'claude',
          observedAt: now,
          availability: ContextMeasurementAvailability.measured,
          usedTokens: 36000,
        ),
      ),
    );
    expect(windowless['usage'], '');

    final measured = await view(
      ConversationState().recordTelemetry(
        SessionContextTelemetry(
          sessionId: 'session-1',
          source: 'claude',
          observedAt: now,
          availability: ContextMeasurementAvailability.measured,
          usedTokens: 36000,
          contextWindowTokens: 200000,
        ),
      ),
    );
    expect(measured['usage'], '18%');
    expect(measured['usageHidden'], isNull);
  });

  // The notice warns that provider-native state does not follow a provider
  // change, so it is about the provider the conversation last ran on, not the
  // session's creation provider or the previous selection.
  group('continuity notice', () {
    EffectiveConversationContext context(String provider) => EffectiveConversationContext(
      projectId: 'project-1',
      directory: '/tmp',
      referenceRoot: '/tmp',
      provider: provider,
    );

    test('shows when the next turn runs on another provider than the last one did', () async {
      final projection = await view(ConversationState().admitContext(context('claude')).stageContext(context('codex')));
      expect(projection['continuityHidden'], isNull);
    });

    test('hides when the next turn stays on the last-run provider', () async {
      final projection = await view(ConversationState().admitContext(context('codex')).stageContext(context('codex')));
      expect(projection['continuityHidden'], isTrue);
    });

    test('hides before the first turn, whatever is staged', () async {
      final projection = await view(ConversationState().stageContext(context('codex')));
      expect(projection['continuityHidden'], isTrue);
    });
  });

  test('a stale measurement reports no percentage', () async {
    final stale = await view(
      ConversationState().recordTelemetry(
        SessionContextTelemetry(
          sessionId: 'session-1',
          source: 'claude',
          observedAt: now,
          availability: ContextMeasurementAvailability.stale,
          usedTokens: 36000,
          contextWindowTokens: 200000,
        ),
      ),
    );
    expect(stale['usage'], '');
    expect(stale['usageHidden'], isTrue);
  });
}
