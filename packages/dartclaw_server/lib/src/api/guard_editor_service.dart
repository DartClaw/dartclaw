import 'dart:io';
import 'dart:convert';

import 'package:dartclaw_config/dartclaw_config.dart';
import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:path/path.dart' as p;

import '../security/guard_builder.dart';

const guardEditorFamilies = {'command', 'file', 'network', 'input-sanitizer'};
const _guardEditorToolPolicyCascade = ToolPolicyCascade();

final class GuardEditorResult {
  final String guard;
  final String field;
  final List<Object?> entries;
  final List<String> applied;
  final List<String> pendingRestart;

  const GuardEditorResult({
    required this.guard,
    required this.field,
    required this.entries,
    required this.applied,
    required this.pendingRestart,
  });

  Map<String, Object?> toJson() => {
    'guard': guard,
    'field': field,
    'entries': entries,
    'applied': applied,
    'pendingRestart': pendingRestart,
    'errors': const <Map<String, String>>[],
  };
}

final class GuardEditorValidationException implements Exception {
  final List<String> errors;

  const GuardEditorValidationException(this.errors);
}

final class GuardEditorService {
  GuardEditorService({required this.writer, required this.dataDir, this.configNotifier, this.guardChain});

  final ConfigWriter writer;
  final String dataDir;
  final ConfigNotifier? configNotifier;
  final GuardChain? guardChain;

  Map<String, Object?> readState() {
    final config = _freshConfig();
    final yaml = _guardsYaml(config);
    return {
      'reloadable': configNotifier != null,
      'pendingRestart': _pendingGuardFields(),
      'displayedLayer': 'persisted-config',
      'runtimeLayer': guardChain == null ? null : 'runtime-chain',
      'pendingLayer': 'restart.pending',
      'guards': [
        _guardState('command', {
          'extra_blocked_patterns': _stringList(yaml, 'command', 'extra_blocked_patterns'),
          'extra_blocked_pipe_targets': _stringList(yaml, 'command', 'extra_blocked_pipe_targets'),
        }),
        _guardState('file', {'extra_rules': _mapList(yaml, 'file', 'extra_rules')}),
        _guardState('network', {
          'extra_allowed_domains': _stringList(yaml, 'network', 'extra_allowed_domains'),
          'extra_exfil_patterns': _stringList(yaml, 'network', 'extra_exfil_patterns'),
        }),
        _guardState('input-sanitizer', {'extra_patterns': _stringList(yaml, 'input_sanitizer', 'extra_patterns')}),
      ],
    };
  }

  Future<GuardEditorResult> createEntry(String guard, String field, Object? value) async {
    final normalized = _normalizeEntry(guard, field, value);
    final config = _freshConfig();
    final yaml = _editableGuardsYaml(config);
    final entries = _entriesFor(yaml, guard, field);
    entries.add(normalized);
    return _persist(guard: guard, field: field, entries: entries, candidateYaml: yaml);
  }

  Future<GuardEditorResult> updateEntry(String guard, String field, int index, Object? value) async {
    final normalized = _normalizeEntry(guard, field, value);
    final config = _freshConfig();
    final yaml = _editableGuardsYaml(config);
    final entries = _entriesFor(yaml, guard, field);
    _checkIndex(index, entries.length);
    entries[index] = normalized;
    return _persist(guard: guard, field: field, entries: entries, candidateYaml: yaml);
  }

  Future<GuardEditorResult> deleteEntry(String guard, String field, int index) async {
    final config = _freshConfig();
    final yaml = _editableGuardsYaml(config);
    final entries = _entriesFor(yaml, guard, field);
    _checkIndex(index, entries.length);
    entries.removeAt(index);
    return _persist(guard: guard, field: field, entries: entries, candidateYaml: yaml);
  }

  Future<Map<String, Object?>> testInput(String guard, Object? input) async {
    final request = input is Map ? Map<String, dynamic>.from(input) : <String, dynamic>{'input': input};
    final mode = request['input'] is Map ? (request['input'] as Map)['mode']?.toString() : request['mode']?.toString();
    final rawInput = request['input'] is Map && (request['input'] as Map).containsKey('input')
        ? (request['input'] as Map)['input']
        : request['input'];
    final context = _testContext(guard, rawInput, mode: mode);
    final chain = _testChain(guard, request);
    var matchedGuard = 'none';
    final selectedChain = GuardChain(
      failOpen: chain.failOpen,
      guards: _guardsForTest(chain, guard),
      onVerdict: (guardName, _, _, _, _) {
        if (matchedGuard == 'none') {
          matchedGuard = guardName;
        }
      },
    );
    final verdict = await _evaluateTestChain(selectedChain, context);

    return {
      'guard': guard,
      'verdict': verdict.isBlock ? 'block' : (verdict.isWarn ? 'warn' : 'pass'),
      'guardFamily': matchedGuard,
      'reason': verdict.message,
      'input': rawInput?.toString() ?? '',
      'evaluatedLayer': request['candidate'] is Map
          ? 'candidate'
          : (guardChain == null ? 'persisted-config' : 'runtime-chain'),
    };
  }

  GuardChain _testChain(String guard, Map<String, dynamic> request) {
    final candidate = request['candidate'];
    if (candidate is! Map) {
      return guardChain ?? _chainFromConfig(_freshConfig(), dataDir: dataDir);
    }
    final candidateMap = Map<String, dynamic>.from(candidate);
    final field = candidateMap['field'];
    if (field is! String) {
      throw const GuardEditorValidationException(['candidate.field is required']);
    }
    final config = _freshConfig();
    final yaml = _editableGuardsYaml(config);
    final entries = _entriesFor(yaml, guard, field);
    entries.add(_normalizeEntry(guard, field, _candidateEntryValue(guard, candidateMap['value'])));
    final candidateConfig = _freshConfigWithGuards(yaml);
    final validation = validateGuardEditorConfig(candidateConfig.security, dataDir: dataDir);
    if (validation is GuardBuildFailure) {
      throw GuardEditorValidationException(validation.errors);
    }
    return GuardChain(
      failOpen: candidateConfig.security.guards.failOpen,
      guards: (validation as GuardBuildSuccess).guards,
    );
  }

  Future<GuardEditorResult> _persist({
    required String guard,
    required String field,
    required List<Object?> entries,
    required Map<String, dynamic> candidateYaml,
  }) async {
    final section = _yamlSection(guard);
    candidateYaml.putIfAbsent(section, () => <String, dynamic>{});
    (candidateYaml[section] as Map<String, dynamic>)[field] = entries;
    final candidateConfig = _freshConfigWithGuards(candidateYaml);
    final validation = validateGuardEditorConfig(candidateConfig.security, dataDir: dataDir);
    if (validation is GuardBuildFailure) {
      throw GuardEditorValidationException(validation.errors);
    }

    final path = 'guards.$section.$field';
    await writer.updateFields({path: entries});
    final applied = <String>[];
    final pendingRestart = <String>[];
    final notifier = configNotifier;
    if (notifier == null) {
      _writeRestartPending(dataDir, [path]);
      pendingRestart.add(path);
    } else {
      try {
        notifier.reload(DartclawConfig.load(configPath: writer.configPath));
        applied.add(path);
      } catch (_) {
        _writeRestartPending(dataDir, [path]);
        pendingRestart.add(path);
      }
    }
    return GuardEditorResult(
      guard: guard,
      field: field,
      entries: List<Object?>.unmodifiable(entries),
      applied: applied,
      pendingRestart: pendingRestart,
    );
  }

  DartclawConfig _freshConfig() => DartclawConfig.load(configPath: writer.configPath);

  List<String> _pendingGuardFields() {
    final pending = _readRestartPending(dataDir);
    final fields = (pending?['fields'] as List<dynamic>?)?.whereType<String>().toList() ?? const <String>[];
    return fields.where((field) => field.startsWith('guards.')).toList(growable: false);
  }

  DartclawConfig _freshConfigWithGuards(Map<String, dynamic> guardsYaml) {
    final current = _freshConfig();
    return current.copyWith(security: current.security.copyWith(guardsYaml: guardsYaml));
  }
}

GuardBuildResult validateGuardEditorConfig(SecurityConfig securityConfig, {required String dataDir}) {
  return buildGuardsFromConfig(
    securityConfig: securityConfig,
    dataDir: dataDir,
    toolPolicyCascade: _guardEditorToolPolicyCascade,
  );
}

Map<String, Object?> _guardState(String guard, Map<String, Object?> fields) => {'guard': guard, 'fields': fields};

Map<String, dynamic> _guardsYaml(DartclawConfig config) => _deepStringMap(config.security.guardsYaml);

Map<String, dynamic> _editableGuardsYaml(DartclawConfig config) => _deepStringMap(config.security.guardsYaml);

Map<String, dynamic> _deepStringMap(Map<dynamic, dynamic> source) {
  return {
    for (final entry in source.entries)
      entry.key.toString(): switch (entry.value) {
        Map<dynamic, dynamic> value => _deepStringMap(value),
        List<dynamic> value => value.map(_deepValue).toList(),
        final value => value,
      },
  };
}

Object? _deepValue(Object? value) {
  return switch (value) {
    Map<dynamic, dynamic> value => _deepStringMap(value),
    List<dynamic> value => value.map(_deepValue).toList(),
    _ => value,
  };
}

List<String> _stringList(Map<String, dynamic> yaml, String section, String field) {
  final sectionYaml = yaml[section];
  if (sectionYaml is! Map) {
    return <String>[];
  }
  final value = sectionYaml[field];
  if (value is! List) {
    return <String>[];
  }
  return value.whereType<String>().toList();
}

List<Map<String, dynamic>> _mapList(Map<String, dynamic> yaml, String section, String field) {
  final sectionYaml = yaml[section];
  if (sectionYaml is! Map) {
    return <Map<String, dynamic>>[];
  }
  final value = sectionYaml[field];
  if (value is! List) {
    return <Map<String, dynamic>>[];
  }
  return [
    for (final item in value)
      if (item is Map) Map<String, dynamic>.from(item),
  ];
}

List<Object?> _entriesFor(Map<String, dynamic> yaml, String guard, String field) {
  _validateGuardField(guard, field);
  final section = _yamlSection(guard);
  yaml.putIfAbsent(section, () => <String, dynamic>{});
  final sectionYaml = yaml[section] as Map<String, dynamic>;
  final existing = sectionYaml[field];
  final entries = existing is List ? existing.map(_deepValue).toList() : <Object?>[];
  sectionYaml[field] = entries;
  return entries;
}

Object? _normalizeEntry(String guard, String field, Object? value) {
  _validateGuardField(guard, field);
  if (guard == 'file' && field == 'extra_rules') {
    final map = value is Map ? Map<String, dynamic>.from(value) : <String, dynamic>{};
    final pattern = map['pattern'];
    final level = map['level'];
    if (pattern is! String || pattern.trim().isEmpty) {
      throw const GuardEditorValidationException(['file.extra_rules: pattern is required']);
    }
    if (level is! String || !_fileLevels.contains(level)) {
      throw GuardEditorValidationException(['file.extra_rules: level must be one of ${_fileLevels.join(', ')}']);
    }
    return {'pattern': pattern.trim(), 'level': level};
  }
  final stringValue = value is String ? value.trim() : '';
  if (stringValue.isEmpty) {
    throw GuardEditorValidationException(['$_yamlSection(guard).$field: value is required']);
  }
  return stringValue;
}

Object? _candidateEntryValue(String guard, Object? value) {
  if (guard == 'file') return value;
  if (value is Map && value['value'] is String) {
    return value['value'];
  }
  return value;
}

void _validateGuardField(String guard, String field) {
  final allowed = switch (guard) {
    'command' => const {'extra_blocked_patterns', 'extra_blocked_pipe_targets'},
    'file' => const {'extra_rules'},
    'network' => const {'extra_allowed_domains', 'extra_exfil_patterns'},
    'input-sanitizer' => const {'extra_patterns'},
    _ => const <String>{},
  };
  if (!guardEditorFamilies.contains(guard) || !allowed.contains(field)) {
    throw GuardEditorValidationException(['Unsupported guard extension field: $guard.$field']);
  }
}

String _yamlSection(String guard) => guard == 'input-sanitizer' ? 'input_sanitizer' : guard;

void _checkIndex(int index, int length) {
  if (index < 0 || index >= length) {
    throw GuardEditorValidationException(['Rule index $index is out of range']);
  }
}

GuardContext _testContext(String guard, Object? input, {String? mode}) {
  final text = input?.toString() ?? '';
  final now = DateTime.now();
  return switch (guard) {
    'command' => GuardContext(
      hookPoint: 'beforeToolCall',
      toolName: 'shell',
      toolInput: {'command': text},
      timestamp: now,
    ),
    'file' => GuardContext(
      hookPoint: 'beforeToolCall',
      toolName: _fileTestToolName(mode),
      toolInput: _fileTestInput(text, mode),
      timestamp: now,
    ),
    'network' => _networkTestContext(text, mode: mode, timestamp: now),
    'input-sanitizer' => GuardContext(
      hookPoint: 'messageReceived',
      messageContent: text,
      source: 'channel',
      timestamp: now,
    ),
    _ => throw GuardEditorValidationException(['Unsupported guard tester family: $guard']),
  };
}

Future<GuardVerdict> _evaluateTestChain(GuardChain chain, GuardContext context) {
  return switch (context.hookPoint) {
    'beforeToolCall' => chain.evaluateBeforeToolCall(
      context.toolName ?? '',
      context.toolInput ?? const <String, dynamic>{},
      rawProviderToolName: context.rawProviderToolName,
    ),
    'messageReceived' => chain.evaluateMessageReceived(
      context.messageContent ?? '',
      source: context.source,
      sessionId: context.sessionId,
      peerId: context.peerId,
    ),
    'beforeAgentSend' => chain.evaluateBeforeAgentSend(context.messageContent ?? '', sessionId: context.sessionId),
    _ => Future.value(const GuardPass()),
  };
}

String _fileTestToolName(String? mode) {
  return switch (_fileTestMode(mode)) {
    'read' || 'delete' => 'shell',
    'write' => 'file_write',
    _ => throw GuardEditorValidationException(['file tester mode must be one of read, write, delete']),
  };
}

Map<String, Object?> _fileTestInput(String path, String? mode) {
  return switch (_fileTestMode(mode)) {
    'read' => {'command': 'cat $path'},
    'write' => {'path': path},
    'delete' => {'command': 'rm $path'},
    _ => throw GuardEditorValidationException(['file tester mode must be one of read, write, delete']),
  };
}

String _fileTestMode(String? mode) {
  final normalized = mode?.trim().toLowerCase();
  if (normalized == null || normalized.isEmpty) return 'write';
  return normalized;
}

GuardContext _networkTestContext(String text, {String? mode, required DateTime timestamp}) {
  final normalizedMode = mode?.trim().toLowerCase();
  final asShell =
      normalizedMode == 'shell' ||
      (normalizedMode == null && RegExp(r'\b(curl|wget|git|docker)\b|--data\b|-d\s|\|\s*base64').hasMatch(text));
  return GuardContext(
    hookPoint: 'beforeToolCall',
    toolName: asShell ? 'shell' : 'web_fetch',
    toolInput: asShell ? {'command': text} : {'url': text},
    timestamp: timestamp,
  );
}

GuardChain _chainFromConfig(DartclawConfig config, {required String dataDir}) {
  final result = validateGuardEditorConfig(config.security, dataDir: dataDir);
  if (result is GuardBuildFailure) {
    throw GuardEditorValidationException(result.errors);
  }
  return GuardChain(failOpen: config.security.guards.failOpen, guards: (result as GuardBuildSuccess).guards);
}

List<Guard> _guardsForTest(GuardChain chain, String guard) {
  final family = _guardRuntimeFamily(guard);
  return chain.guards.where((candidate) => candidate.name == family || candidate.category == family).toList();
}

const _fileLevels = {'no_access', 'read_only', 'no_delete'};

String _guardRuntimeFamily(String guard) => switch (guard) {
  'input-sanitizer' => 'input-sanitizer',
  _ => guard,
};

void _writeRestartPending(String dataDir, List<String> fields) {
  final filePath = p.join(dataDir, 'restart.pending');
  final file = File(filePath);
  var existingFields = <String>[];
  if (file.existsSync()) {
    try {
      final parsed = jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
      final raw = parsed['fields'];
      if (raw is List) {
        existingFields = raw.whereType<String>().toList();
      }
    } catch (_) {
      existingFields = <String>[];
    }
  }
  final merged = {...existingFields, ...fields}.toList();
  final tempFile = File('$filePath.tmp');
  tempFile.writeAsStringSync(jsonEncode({'timestamp': DateTime.now().toUtc().toIso8601String(), 'fields': merged}));
  tempFile.renameSync(filePath);
}

Map<String, dynamic>? _readRestartPending(String dataDir) {
  final file = File(p.join(dataDir, 'restart.pending'));
  if (!file.existsSync()) {
    return null;
  }
  try {
    return jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
  } catch (_) {
    return null;
  }
}
