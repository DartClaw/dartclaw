import 'dart:convert';

import 'package:dartclaw_workflow/dartclaw_workflow.dart' show workflowContextRegExp;
import 'package:logging/logging.dart';

/// Structured data extracted from one workflow task turn.
final class ExtractedTurn {
  final Map<String, Object?> inlinePayload;
  final List<String> toolCallOutputs;
  final bool isPartial;
  final List<String> missingKeys;
  final List<String> logEntries;

  const ExtractedTurn({
    required this.inlinePayload,
    required this.toolCallOutputs,
    required this.isPartial,
    required this.missingKeys,
    this.logEntries = const <String>[],
  });
}

/// Extracts workflow-context payloads from provider stdout or assistant text.
final class WorkflowTurnExtractor {
  WorkflowTurnExtractor({Logger? log}) : _log = log ?? Logger('WorkflowTurnExtractor');

  final Logger _log;

  ExtractedTurn parse(String stdoutText, {Iterable<String> requiredKeys = const <String>[]}) {
    final required = requiredKeys.toList(growable: false);
    final inlinePayloads = _workflowContextPayloads(stdoutText);
    final toolOutputs = _toolCallOutputs(stdoutText);
    final toolPayloads = <Map<String, Object?>>[
      for (final output in toolOutputs) ..._workflowContextPayloads(output),
      for (final output in toolOutputs) ?_decodePayload(output),
    ];

    final merged = <String, Object?>{};
    for (final payload in toolPayloads) {
      merged.addAll(payload);
    }
    for (final payload in inlinePayloads) {
      merged.addAll(payload);
    }

    final populatedRequired = required.where((key) => isNonEmptyPayloadValue(merged[key])).toList(growable: false);
    if (required.isNotEmpty && populatedRequired.isEmpty) {
      return ExtractedTurn(
        inlinePayload: const <String, Object?>{},
        toolCallOutputs: toolOutputs,
        isPartial: false,
        missingKeys: required,
      );
    }

    final missing = required.where((key) => !merged.containsKey(key)).toList(growable: false);
    final logs = <String>[];
    if (missing.isNotEmpty && merged.isNotEmpty) {
      final entry =
          'Inline structured payload from <workflow-context> is partial: '
          '${populatedRequired.length}/${required.length} required keys populated. Missing: $missing';
      logs.add(entry);
      _log.info(entry);
    }

    return ExtractedTurn(
      inlinePayload: merged,
      toolCallOutputs: toolOutputs,
      isPartial: missing.isNotEmpty && merged.isNotEmpty,
      missingKeys: missing,
      logEntries: logs,
    );
  }

  static bool isNonEmptyPayloadValue(Object? value) {
    if (value == null) return false;
    if (value is String) return value.isNotEmpty;
    if (value is Iterable) return value.isNotEmpty;
    if (value is Map) return value.isNotEmpty;
    return true;
  }

  static List<String> requiredTopLevelKeys(Map<String, dynamic> schema) {
    final raw = schema['required'];
    if (raw is! List) return const <String>[];
    return raw.map((value) => value.toString()).toList(growable: false);
  }

  static String? structuredOutputKey(Map<String, dynamic> schema) {
    final raw = schema['properties'];
    if (raw is! Map || raw.isEmpty) return null;
    return raw.keys.first.toString();
  }

  List<Map<String, Object?>> _workflowContextPayloads(String text) {
    return workflowContextRegExp
        .allMatches(text)
        .map((match) => match.group(1))
        .whereType<String>()
        .map(_decodePayload)
        .whereType<Map<String, Object?>>()
        .toList(growable: false);
  }

  Map<String, Object?>? _decodePayload(String rawJson) {
    try {
      final decoded = jsonDecode(rawJson);
      if (decoded is! Map) return null;
      if (decoded.isEmpty) return null;
      return decoded.map((key, value) => MapEntry(key.toString(), value));
    } on FormatException {
      return null;
    }
  }

  List<String> _toolCallOutputs(String text) {
    final tagged = RegExp(
      r'<workflow-tool-output>\s*([\s\S]*?)\s*</workflow-tool-output>',
    ).allMatches(text).map((match) => match.group(1)).whereType<String>();
    final jsonLines = text.split('\n').map(_toolOutputFromJsonLine).whereType<String>();
    return [...tagged, ...jsonLines].toList(growable: false);
  }

  String? _toolOutputFromJsonLine(String line) {
    final trimmed = line.trim();
    if (trimmed.isEmpty || !trimmed.startsWith('{')) return null;
    try {
      final decoded = jsonDecode(trimmed);
      if (decoded is! Map) return null;
      final type = decoded['type']?.toString().toLowerCase() ?? '';
      if (!type.contains('tool') || !type.contains('output')) return null;
      final output = decoded['output'] ?? decoded['content'] ?? decoded['result'];
      return output is String ? output : null;
    } on FormatException {
      return null;
    }
  }
}
