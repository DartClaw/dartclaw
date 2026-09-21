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

/// Option set for one picker over an adapter's declared vocabulary.
///
/// The empty value is the provider's own default, so it is always offerable. A
/// [staged] value the adapter does not list is offered as itself: it reached
/// the conversation from YAML or the JSON API, and a picker that cannot
/// represent it would silently drop it on the next apply.
List<Map<String, Object>> _contextOptions(List<String> catalogue, String staged) => [
  {'value': '', 'label': 'Provider default', 'selected': staged.isEmpty},
  for (final entry in catalogue) {'value': entry, 'label': entry, 'selected': entry == staged},
  if (staged.isNotEmpty && !catalogue.contains(staged)) {'value': staged, 'label': staged, 'selected': true},
];

/// Canonical render projection for one session's effective conversation context.
Future<Map<String, dynamic>> effectiveContextView(
  Session session,
  ConversationState state,
  ProjectService? projects,
  String defaultProvider,
  Map<String, EffectiveContextCapabilities> capabilities,
) async {
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
    final model = value.model == null ? '' : ' · ${value.model}';
    final effort = value.effort == null ? '' : ' · ${value.effort}';
    return '${value.projectId} · ${value.provider}$model$effort';
  }

  // The composer pill states what the next turn will actually run. A segment
  // nobody has chosen is omitted rather than filled with a stand-in — a pill
  // reading "provider model" claims a selection that does not exist.
  final composerLabel = [provider, next?.model, next?.effort].nonNulls.join(' · ');
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
            'effort': capabilities[candidate]?.effort == true ? 'true' : 'false',
            'models': (capabilities[candidate]?.models ?? const <String>[]).join(','),
            'efforts': (capabilities[candidate]?.efforts ?? const <String>[]).join(','),
          },
        )
        .toList(growable: false),
    'modelEditable': providerCapabilities?.model == true,
    'effortEditable': providerCapabilities?.effort == true,
    'modelValue': next?.model ?? '',
    'effortValue': next?.effort ?? '',
    'modelOptions': _contextOptions(providerCapabilities?.models ?? const [], next?.model ?? ''),
    'effortOptions': _contextOptions(providerCapabilities?.efforts ?? const [], next?.effort ?? ''),
    'model': providerCapabilities?.model == false ? 'unavailable' : next?.model ?? 'provider default',
    'effort': providerCapabilities?.effort == false ? 'unavailable' : next?.effort ?? 'provider default',
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
