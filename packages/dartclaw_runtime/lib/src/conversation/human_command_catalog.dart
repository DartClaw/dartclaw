import 'dart:convert';

import 'package:dartclaw_core/dartclaw_core.dart';

/// Catalog projection requested by a keyboard surface.
enum HumanCommandSurface { slash, global }

/// Authorized provider-native skill metadata.
final class NativeSkillCatalogItem {
  const new({required this.name, required this.description});

  final String name;
  final String description;
}

/// Resolves already-authorized skills visible to one provider/workspace pair.
typedef NativeSkillCatalogResolver = Future<List<NativeSkillCatalogItem>> Function({
  required String provider,
  required String? workspaceDir,
});

/// Effective facts that determine catalog visibility and executability.
final class HumanCommandContext {
  const new({
    required this.principal,
    required this.provider,
    required this.revision,
    this.sessionId,
    this.workspaceDir,
    this.modelEditable = false,
    this.effortEditable = false,
    this.turnActive = false,
    this.forkAvailable = false,
    this.settleAvailable = false,
    this.readOnly = false,
  });

  final String principal;
  final String provider;
  final int revision;
  final String? sessionId;
  final String? workspaceDir;
  final bool modelEditable;
  final bool effortEditable;
  final bool turnActive;
  final bool forkAvailable;
  final bool settleAvailable;
  final bool readOnly;

  bool get hasSession => sessionId != null;

  List<Object?> get identityParts => [
    principal,
    sessionId,
    revision,
    provider,
    workspaceDir,
    modelEditable,
    effortEditable,
    turnActive,
    forkAvailable,
    settleAvailable,
    readOnly,
  ];
}

/// One closed catalog entry shared by slash discovery and Cmd-K.
final class HumanCommandEntry {
  const new({
    required this.id,
    required this.label,
    required this.description,
    required this.dispatchTarget,
    required this.enabled,
    this.disabledReason,
    this.confirmation,
    this.nativeInvocation,
  });

  final String id;
  final String label;
  final String description;
  final String dispatchTarget;
  final bool enabled;
  final String? disabledReason;
  final String? confirmation;
  final String? nativeInvocation;

  Map<String, Object?> toJson() => {
    'id': id,
    'label': label,
    'description': description,
    'dispatch_target': dispatchTarget,
    'enabled': enabled,
    'disabled_reason': disabledReason,
    'confirmation': confirmation,
    'native_invocation': nativeInvocation,
  };
}

/// One catalog resolution bound to all current dispatch inputs.
final class HumanCommandCatalogSnapshot {
  const new({required this.entries, required this.identityToken});

  final List<HumanCommandEntry> entries;
  final String identityToken;
}

/// The single typed authority for human slash and Cmd-K commands.
final class HumanCommandCatalog {
  new({required HarnessFactory harnessFactory, NativeSkillCatalogResolver? nativeSkills})
    : _harnessFactory = harnessFactory,
      _nativeSkills = nativeSkills;

  static const builtInNames = {'new', 'reset', 'stop', 'status', 'fork', 'settle', 'model', 'effort', 'help'};

  final HarnessFactory _harnessFactory;
  final NativeSkillCatalogResolver? _nativeSkills;

  Future<HumanCommandCatalogSnapshot> resolve(HumanCommandContext context, HumanCommandSurface surface) async {
    final result = <HumanCommandEntry>[
      for (final definition in _builtIns)
        if (definition.visible(context, surface)) definition.entry(context),
    ];
    if (!context.hasSession ||
        context.readOnly ||
        !_harnessFactory.supportsNativeSkillInvocationFor(context.provider) ||
        _nativeSkills == null) {
      return _snapshot(context, result);
    }
    final native = [...await _nativeSkills(provider: context.provider, workspaceDir: context.workspaceDir)]
      ..sort((a, b) => a.name.compareTo(b.name));
    for (final skill in native) {
      final collision = builtInNames.contains(skill.name);
      result.add(
        HumanCommandEntry(
          id: 'skill:${skill.name}',
          label: collision ? '/${skill.name} (skill)' : '/${skill.name}',
          description: skill.description,
          dispatchTarget: 'native_skill',
          enabled: true,
          nativeInvocation: _harnessFactory.skillActivationLineFor(context.provider, skill.name),
        ),
      );
    }
    return _snapshot(context, result);
  }

  Future<List<HumanCommandEntry>> entries(HumanCommandContext context, HumanCommandSurface surface) async =>
      (await resolve(context, surface)).entries;

  /// Describes text that is absent from the closed catalog without claiming support.
  String unknownSlashDisposition(String input) => input.startsWith('/') ? 'Send to provider' : '';

  HumanCommandCatalogSnapshot _snapshot(HumanCommandContext context, List<HumanCommandEntry> entries) {
    final frozen = List<HumanCommandEntry>.unmodifiable(entries);
    final identity = base64Url.encode(
      utf8.encode(
        jsonEncode({
          'context': context.identityParts,
          'entries': [
            for (final entry in frozen)
              [
                entry.id,
                entry.description,
                entry.dispatchTarget,
                entry.enabled,
                entry.confirmation,
                entry.nativeInvocation,
              ],
          ],
        }),
      ),
    );
    return HumanCommandCatalogSnapshot(entries: frozen, identityToken: identity);
  }
}

final class _HumanCommandDefinition {
  const new({
    required this.name,
    required this.description,
    required this.dispatchTarget,
    this.requiresSession = false,
    this.confirmation,
    this.available,
  });

  final String name;
  final String description;
  final String dispatchTarget;
  final bool requiresSession;
  final String? confirmation;
  final bool Function(HumanCommandContext)? available;

  bool visible(HumanCommandContext context, HumanCommandSurface surface) =>
      (!context.readOnly || !requiresSession || name == 'status') &&
      (!requiresSession || context.hasSession || surface == HumanCommandSurface.global);

  HumanCommandEntry entry(HumanCommandContext context) {
    final enabled = (!requiresSession || context.hasSession) && (available?.call(context) ?? true);
    return HumanCommandEntry(
      id: 'built-in:$name',
      label: '/$name',
      description: description,
      dispatchTarget: dispatchTarget,
      enabled: enabled,
      disabledReason: enabled ? null : _disabledReason(context),
      confirmation: enabled ? confirmation : null,
    );
  }

  String _disabledReason(HumanCommandContext context) {
    if (requiresSession && !context.hasSession) return 'Open a conversation first';
    return switch (name) {
      'stop' => 'No turn is running',
      'fork' => 'No completed message is selected',
      'settle' => 'Conversation cannot be settled',
      'model' => 'Model selection is unavailable for this provider',
      'effort' => 'Effort selection is unavailable for this provider',
      _ => 'Unavailable in this context',
    };
  }
}

const _builtIns = <_HumanCommandDefinition>[
  _HumanCommandDefinition(name: 'new', description: 'Start a new conversation', dispatchTarget: 'session.open'),
  _HumanCommandDefinition(
    name: 'reset',
    description: 'Reset this conversation',
    dispatchTarget: 'session.reset',
    requiresSession: true,
    confirmation: 'Reset this conversation?',
  ),
  _HumanCommandDefinition(
    name: 'stop',
    description: 'Stop the running turn',
    dispatchTarget: 'conversation.stop',
    requiresSession: true,
    available: _turnActive,
  ),
  _HumanCommandDefinition(
    name: 'status',
    description: 'Show conversation status',
    dispatchTarget: 'conversation.status',
    requiresSession: true,
  ),
  _HumanCommandDefinition(
    name: 'fork',
    description: 'Fork from the selected message',
    dispatchTarget: 'conversation.fork',
    requiresSession: true,
    available: _forkAvailable,
  ),
  _HumanCommandDefinition(
    name: 'settle',
    description: 'Move this conversation to settled',
    dispatchTarget: 'inbox.settle',
    requiresSession: true,
    available: _settleAvailable,
  ),
  _HumanCommandDefinition(
    name: 'model',
    description: 'Choose the next-turn model',
    dispatchTarget: 'context.model',
    requiresSession: true,
    available: _modelEditable,
  ),
  _HumanCommandDefinition(
    name: 'effort',
    description: 'Choose the next-turn reasoning effort',
    dispatchTarget: 'context.effort',
    requiresSession: true,
    available: _effortEditable,
  ),
  _HumanCommandDefinition(name: 'help', description: 'Show keyboard command help', dispatchTarget: 'navigation.help'),
];

bool _turnActive(HumanCommandContext context) => context.turnActive;
bool _forkAvailable(HumanCommandContext context) => context.forkAvailable;
bool _settleAvailable(HumanCommandContext context) => context.settleAvailable;
bool _modelEditable(HumanCommandContext context) => context.modelEditable;
bool _effortEditable(HumanCommandContext context) => context.effortEditable;
