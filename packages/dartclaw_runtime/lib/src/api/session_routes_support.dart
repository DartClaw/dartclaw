import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dartclaw_core/dartclaw_core.dart' hide TurnManager;
import 'package:dartclaw_kernel/dartclaw_kernel.dart';
import 'package:shelf/shelf.dart';

import '../templates/helpers.dart' show formatRelativeTimeIso;
import 'api_helpers.dart';

/// Shared request-parsing and small utilities for the `session_*_routes.dart`
/// family. These helpers are public-within-package so each sibling router file
/// can reuse them without re-implementing body parsing or trimming.

const maxSendBodyBytes = 256 * 1024;

String? trimmedOrNull(String? value) {
  final trimmed = value?.trim();
  if (trimmed == null || trimmed.isEmpty) {
    return null;
  }
  return trimmed;
}

/// Extracts a named field from form-urlencoded or JSON request body.
Future<({String? value, Response? error})> parseBodyField(Request request, String field) async {
  final parsed = await parseBodyFields(request);
  if (parsed.error != null) return (value: null, error: parsed.error);
  return (value: parsed.fields[field], error: null);
}

Future<({Map<String, String> fields, Response? error})> parseBodyFields(Request request) async {
  final ct = request.headers['content-type'] ?? '';
  if (ct.startsWith('application/x-www-form-urlencoded')) {
    final parsed = await readFormFields(request, maxBytes: maxSendBodyBytes);
    if (parsed.error != null) return (fields: const <String, String>{}, error: parsed.error);
    return (fields: {for (final entry in parsed.fields.entries) entry.key: entry.value.last}, error: null);
  }
  if (ct.startsWith('application/json')) {
    try {
      final bodyResult = await readRequestBody(request, maxBytes: maxSendBodyBytes);
      if (bodyResult.error != null) return (fields: const <String, String>{}, error: bodyResult.error);
      final body = bodyResult.body!;
      final json = jsonDecode(body) as Map<String, dynamic>;
      final fields = <String, String>{};
      for (final entry in json.entries) {
        final value = entry.value;
        if (value is String) {
          fields[entry.key] = value;
        } else if (value != null) {
          fields[entry.key] = jsonEncode(value);
        }
      }
      return (fields: fields, error: null);
    } on FormatException {
      return (fields: const <String, String>{}, error: errorResponse(400, 'INVALID_INPUT', 'Invalid JSON body'));
    } on TypeError {
      return (fields: const <String, String>{}, error: errorResponse(400, 'INVALID_INPUT', 'Invalid JSON structure'));
    }
  }
  return (
    fields: const <String, String>{},
    error: errorResponse(415, 'UNSUPPORTED_MEDIA_TYPE', 'Unsupported content type'),
  );
}

Future<({String? value, Response? error})> parseOptionalBodyField(Request request, String field) async {
  if ((request.contentLength ?? 0) == 0 && request.headers['content-type'] == null) {
    return (value: null, error: null);
  }

  final parsed = await parseBodyField(request, field);
  if (parsed.error != null) return parsed;
  return (value: trimmedOrNull(parsed.value), error: null);
}

Future<({Map<String, dynamic> json, Response? error})> parseJsonObjectBody(
  Request request, {
  required int maxBytes,
}) async {
  final ct = request.headers['content-type'] ?? '';
  if (!ct.startsWith('application/json')) {
    return (
      json: const <String, dynamic>{},
      error: errorResponse(415, 'UNSUPPORTED_MEDIA_TYPE', 'Unsupported content type'),
    );
  }
  try {
    final bodyResult = await readRequestBody(request, maxBytes: maxBytes);
    if (bodyResult.error != null) return (json: const <String, dynamic>{}, error: bodyResult.error);
    final body = bodyResult.body!;
    final json = jsonDecode(body);
    if (json is! Map<String, dynamic>) {
      return (json: const <String, dynamic>{}, error: errorResponse(400, 'INVALID_INPUT', 'Invalid JSON structure'));
    }
    return (json: json, error: null);
  } on FormatException {
    return (json: const <String, dynamic>{}, error: errorResponse(400, 'INVALID_INPUT', 'Invalid JSON body'));
  }
}

/// Filesystem root that file-type references are resolved against.
Future<String> sessionReferenceRoot(ProjectService? projects) async {
  if (projects == null) return Directory.current.path;
  return (await projects.defaultProject).localPath;
}

/// The model catalogue a provider reported, or `null` before or without one.
typedef ModelCatalogueLookup = ModelCatalogue? Function(String providerId);

ModelCatalogue? noModelCatalogues(String providerId) => null;

/// The name a context shows for [model]: the provider's own label for a
/// catalogued id, the id itself otherwise, and for Default (`null`) the label
/// of what it resolves to – nothing when that is unresolved, never a raw id.
String? contextModelLabel(ModelCatalogue? catalogue, String? model) =>
    model == null || model.isEmpty ? catalogue?.defaultEntry?.label : catalogue?.entryFor(model)?.label ?? model;

/// One Model picker entry; [efforts] is `null` when they are unknown.
typedef _PickerModel = ({String value, String label, List<String>? efforts});

/// A provider's Model picker: Default labelled by what it resolves to, the
/// catalogue in provider order, and a [staged] model the catalogue does not
/// list as its own id – it reached the conversation from YAML or the JSON API,
/// and a picker that cannot represent it would drop it on the next apply.
List<_PickerModel> _pickerModels(ModelCatalogue? catalogue, String staged) {
  final resolved = catalogue?.defaultEntry;
  return [
    (value: '', label: resolved == null ? 'Default' : 'Default · ${resolved.label}', efforts: resolved?.efforts),
    for (final entry in catalogue?.entries ?? const <ModelCatalogueEntry>[])
      (value: entry.id, label: entry.label, efforts: entry.efforts),
    if (staged.isNotEmpty && catalogue?.entryFor(staged) == null) (value: staged, label: staged, efforts: null),
  ];
}

/// The Effort picker [model] selects: Default plus its known efforts. Where
/// they are unknown, or [model] is the [staged] one, [stagedEffort] stays
/// representable; another model lacking it drops it to Default.
List<Map<String, String>> _effortChoices(_PickerModel model, String staged, String stagedEffort) => [
  {'value': '', 'label': 'Default'},
  for (final effort in model.efforts ?? const <String>[]) {'value': effort, 'label': effort},
  if (stagedEffort.isNotEmpty &&
      (model.efforts == null || model.value == staged) &&
      !(model.efforts ?? const <String>[]).contains(stagedEffort))
    {'value': stagedEffort, 'label': stagedEffort},
];

/// [_pickerModels] as options, each carrying the Effort picker it selects
/// (`efforts`, JSON) and whether that picker is editable – a model reporting
/// no efforts locks it.
List<Map<String, Object>> _modelOptions(
  EffectiveContextCapabilities? capabilities,
  ModelCatalogue? catalogue,
  String staged,
  String stagedEffort,
) => [
  for (final model in _pickerModels(catalogue, staged))
    {
      'value': model.value,
      'label': model.label,
      'selected': model.value == staged,
      'effortEditable': '${capabilities?.effort == true && (model.efforts == null || model.efforts!.isNotEmpty)}',
      'efforts': jsonEncode(_effortChoices(model, staged, stagedEffort)),
    },
];

/// Canonical render projection for one session's effective conversation context.
///
/// Every picker option, label and Default label is built here; the chat page
/// and its controller render these verbatim.
Future<Map<String, dynamic>> effectiveContextView(
  Session session,
  ConversationState state,
  ProjectService? projects,
  String defaultProvider,
  Map<String, EffectiveContextCapabilities> capabilities, {
  ModelCatalogueLookup catalogues = noModelCatalogues,
}) async {
  final fallbackProject = projects == null ? null : await projects.defaultProject;
  final availableProjects = projects == null ? const <Project>[] : await projects.getAll();
  final next = state.nextContext;
  final current = state.currentContext;
  final projectId = next?.projectId ?? fallbackProject?.id ?? '_local';
  final project = projects == null ? null : await projects.get(projectId);
  final projectName = project?.name ?? projectId;
  final provider = next?.provider ?? session.provider ?? defaultProvider;
  final providerCapabilities = capabilities[provider];
  final telemetry = state.telemetry;
  final telemetryLabel = telemetry == null || telemetry.sessionId != session.id
      ? 'unavailable'
      : '${telemetry.availability.name} · ${telemetry.source} · ${formatRelativeTimeIso(telemetry.observedAt.toIso8601String())}'
            '${telemetry.usedTokens == null ? '' : ' · ${telemetry.usedTokens} tokens'}';
  final behaviorLabel = telemetry == null || telemetry.sessionId != session.id || telemetry.behaviorFiles.isEmpty
      ? 'none recorded'
      : telemetry.behaviorFiles
            .map((entry) => '${entry['path'] ?? 'unknown'} (${entry['origin'] ?? 'unknown origin'})')
            .join(' · ');
  String contextLabel(EffectiveConversationContext? value) {
    if (value == null) return 'Pending first turn';
    final model = contextModelLabel(catalogues(value.provider), value.model);
    return [value.projectId, value.provider, model, value.effort].nonNulls.join(' · ');
  }

  // The composer pill states what the next turn will actually run, naming the
  // model – Default included – by the provider's own label. A segment nobody
  // has chosen and nothing resolves is omitted rather than filled with a
  // stand-in, which would claim a selection that does not exist.
  final composerLabel = [
    provider,
    contextModelLabel(catalogues(provider), next?.model),
    next?.effort,
  ].nonNulls.join(' · ');
  final stagedModel = next?.model ?? '';
  final stagedEffort = next?.effort ?? '';
  // Another provider's picker carries none of this one's staged values: a value
  // chosen for one provider would fail the next turn on another.
  List<Map<String, Object>> modelOptionsFor(String candidate) => candidate == provider
      ? _modelOptions(providerCapabilities, catalogues(candidate), stagedModel, stagedEffort)
      : _modelOptions(capabilities[candidate], catalogues(candidate), '', '');
  final modelOptions = modelOptionsFor(provider);
  final selectedModel = _pickerModels(catalogues(provider), stagedModel).firstWhere((m) => m.value == stagedModel);
  final effortOptions = [
    for (final choice in _effortChoices(selectedModel, stagedModel, stagedEffort))
      {...choice, 'selected': choice['value'] == stagedEffort},
  ];
  // Only a live measurement earns a percentage; a stale, unsupported or
  // window-less observation shows no number at all.
  final usedTokens = telemetry?.usedTokens;
  final windowTokens = telemetry?.contextWindowTokens;
  final usagePercent =
      telemetry != null &&
          telemetry.sessionId == session.id &&
          telemetry.availability == ContextMeasurementAvailability.measured &&
          usedTokens != null &&
          windowTokens != null &&
          windowTokens > 0
      ? ((usedTokens / windowTokens) * 100).clamp(0, 100).round()
      : null;

  return {
    'workspace': session.workspace == null ? 'web' : 'agent:${session.workspace!.agentId}',
    'project': projectName,
    'projectId': projectId,
    'projects': availableProjects
        .where((candidate) => candidate.status == ProjectStatus.ready)
        .map(
          (candidate) => {
            'value': candidate.id,
            'label': candidate.name.isEmpty ? candidate.id : candidate.name,
            'selected': candidate.id == projectId,
          },
        )
        .toList(growable: false),
    'directory': next?.directory ?? fallbackProject?.localPath ?? Directory.current.path,
    'referenceRoot': next?.referenceRoot ?? fallbackProject?.localPath ?? Directory.current.path,
    'provider': provider,
    'providers': {...capabilities.keys, provider}
        .map(
          (candidate) => {
            'value': candidate,
            'label': candidate,
            'selected': candidate == provider,
            'model': capabilities[candidate]?.model == true ? 'true' : 'false',
            // The provider's whole Model picker, so a provider switch renders
            // it without a round trip.
            'models': jsonEncode(modelOptionsFor(candidate)),
          },
        )
        .toList(growable: false),
    'modelEditable': providerCapabilities?.model == true,
    'effortEditable': modelOptions.firstWhere((option) => option['selected'] == true)['effortEditable'] == 'true',
    'modelValue': stagedModel,
    'effortValue': stagedEffort,
    'modelOptions': modelOptions,
    'effortOptions': effortOptions,
    // Session info names the model as the pill does; Default is labelled by
    // what it resolves to, or plain when that is unresolved.
    'model': providerCapabilities?.model == false
        ? 'unavailable'
        : contextModelLabel(catalogues(provider), next?.model) ?? 'Default',
    'effort': providerCapabilities?.effort == false ? 'unavailable' : next?.effort ?? 'Default',
    'composer': composerLabel,
    'usage': usagePercent == null ? '' : '$usagePercent%',
    'usageHidden': usagePercent == null ? true : null,
    'current': contextLabel(current),
    'next': contextLabel(next),
    // The popover's editable rows already state the next turn, so the current
    // one is worth a line only while it disagrees with them. Before the first
    // turn there is no current context to disagree.
    'currentHidden': current == null || contextLabel(current) == contextLabel(next) ? true : null,
    // The continuity notice warns only while the next turn would run on another
    // provider than the one the conversation last ran on. This is the one
    // decision: the page's first paint and dc-chat after every apply both read it.
    'continuityHidden': current == null || current.provider == provider ? true : null,
    'telemetry': telemetryLabel,
    'behavior': behaviorLabel,
    'memory': telemetry?.memoryContributed == true ? 'Memory contributed' : null,
    'memoryHidden': telemetry?.memoryContributed == true ? null : true,
    'revision': state.revision,
  };
}
