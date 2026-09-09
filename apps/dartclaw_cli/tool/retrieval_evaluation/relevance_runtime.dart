import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:dartclaw_cli/src/commands/config_loader.dart';
import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:dartclaw_kernel/dartclaw_kernel.dart';
import 'package:dartclaw_runtime/dartclaw_runtime.dart';
import 'package:dartclaw_runtime/src/web/session_usage.dart';
import 'package:dartclaw_search/dartclaw_search.dart';
import 'package:path/path.dart' as p;

DartclawConfig loadEvaluationRuntimeConfig(String configPath, String dataDirectory) {
  final config = loadCliConfig(configPath: configPath, cliOverrides: {'data_dir': p.absolute(dataDirectory)});
  if (config.database.backend != DatabaseBackendKind.sqlite) {
    throw const FormatException('The relevance runtime requires fresh local SQLite state');
  }
  final provider = ProviderIdentity.normalize(config.agent.provider);
  final auth = config.providers[provider]?.auth;
  // Explicit selection makes the runtime refuse missing credentials instead of probing ambient vendor login.
  if (auth != ProviderAuth.apiKey && auth != ProviderAuth.subscription) {
    throw const FormatException('Evaluation requires explicit auth: api_key or subscription on its primary provider');
  }
  if (config.agent.model?.trim().isNotEmpty != true) {
    throw const FormatException('Evaluation requires an explicit model');
  }
  return config;
}

void requireCompleteEvaluationRelevanceAccounting(Object? raw) {
  if (raw is! Map<String, Object?>) throw const FormatException('Relevance runtime provenance is missing');
  final accounting = raw['outcomeAccounting'];
  if (accounting is! Map<String, Object?> ||
      accounting['accountingComplete'] != true ||
      accounting['judgeFailures'] != 0 ||
      accounting['judgeAttempts'] != accounting['judgeReturns'] ||
      accounting['judgeAttempts'] != accounting['terminalOutcomeCount']) {
    throw const FormatException('Relevance outcome accounting is incomplete');
  }
  final attempts = accounting['judgeAttempts'];
  final statuses = accounting['statusCounts'];
  if (attempts is! int || statuses is! Map || statuses.length != 1 || statuses['completed'] != attempts) {
    throw const FormatException('Relevance outcome accounting contains an unsuccessful turn');
  }
}

final class EvaluationRelevanceRuntime {
  new _(this._runtime, this._capture, Map<String, Object?> provenance)
    : _provenance = Map<String, Object?>.from(provenance),
      filter = SearchRelevanceFilter(judge: _capture.judge);

  factory capture(DartclawRuntime runtime, Map<String, Object?> provenance) {
    final capture = _RelevanceEvidenceCapture(runtime);
    return EvaluationRelevanceRuntime._(runtime, capture, provenance);
  }

  final DartclawRuntime _runtime;
  final _RelevanceEvidenceCapture _capture;
  final Map<String, Object?> _provenance;
  final SearchRelevanceFilter filter;
  Future<Map<String, Object?>>? _closeFuture;

  Map<String, Object?> get provenance => Map.unmodifiable(_provenance);

  static Future<EvaluationRelevanceRuntime> open({required String configPath, required String directory}) async {
    final root = Directory(p.absolute(directory));
    if (FileSystemEntity.typeSync(root.path, followLinks: false) == FileSystemEntityType.link ||
        (root.existsSync() &&
            root.listSync().any(
              (entry) =>
                  p.basename(entry.path) != 'credentials' ||
                  FileSystemEntity.typeSync(entry.path, followLinks: false) != FileSystemEntityType.directory,
            ))) {
      throw const FileSystemException('Evaluation runtime must have no prior state except dedicated credentials');
    }
    root.createSync(recursive: true);
    final config = loadEvaluationRuntimeConfig(configPath, root.path);
    final provider = ProviderIdentity.normalize(config.agent.provider);
    CredentialPreflight.enforce(config, Platform.environment);
    final staging = await DartclawRuntime.stageHeadless(
      config,
      dataDir: root.path,
      harnessFactory: HarnessFactory(),
      environment: Platform.environment,
      runtimeCwd: root.path,
      stderrLine: (_) {},
      exitFn: (_) => throw const FormatException('Evaluation runtime could not start'),
      runWorkflowSkillsBootstrap: false,
    );
    DartclawRuntime? runtime;
    try {
      await staging.preflightProviderAuth({provider});
      runtime = await staging.completeForExecution({provider});
      return EvaluationRelevanceRuntime.capture(runtime, {
        'provider': provider,
        'model': config.agent.model,
        'effort': config.agent.effort,
        'configSha256': (await sha256.bind(File(configPath).openRead()).first).toString(),
      });
    } on Object {
      if (runtime != null) {
        await runtime.shutdown();
      } else {
        await staging.dispose();
      }
      rethrow;
    }
  }

  Future<Map<String, Object?>> close() => _closeFuture ??= _close();

  Future<Map<String, Object?>> _close() async {
    Object? pendingError;
    StackTrace? pendingStack;
    try {
      await _runtime.requireExecutions.dispose();
    } catch (error, stackTrace) {
      pendingError = error;
      pendingStack = stackTrace;
    }
    try {
      await _capture.stop();
      _provenance['outcomeAccounting'] = await _capture.summary(_runtime.kvService, _provenance);
    } catch (error, stackTrace) {
      pendingError ??= error;
      pendingStack ??= stackTrace;
    }
    try {
      await _runtime.shutdown();
    } catch (error, stackTrace) {
      pendingError ??= error;
      pendingStack ??= stackTrace;
    }
    if (pendingError != null) Error.throwWithStackTrace(pendingError, pendingStack!);
    return provenance;
  }
}

final class _RelevanceEvidenceCapture {
  new(this._runtime) {
    _subscription = _runtime.requireExecutions.events.listen(_record, onError: (_) => _streamFailed = true);
  }

  static const _logicalAgentId = 'search-relevance';

  final DartclawRuntime _runtime;
  final _events = <ExecutionEvent>[];
  late final StreamSubscription<ExecutionEvent> _subscription;
  var _streamFailed = false;
  var _attempts = 0;
  var _returns = 0;
  var _failures = 0;

  Future<Map<String, dynamic>> judge(String prompt, Map<String, dynamic> outputSchema) async {
    _attempts++;
    try {
      final result = await _runtime.requireSearchRelevanceTurn(prompt, outputSchema);
      _returns++;
      return result;
    } on Object {
      _failures++;
      rethrow;
    }
  }

  void _record(ExecutionEvent event) {
    if (event.kind == ExecutionEventKind.turnSettled &&
        event.request.logicalAgentId == _logicalAgentId &&
        event.outcome != null &&
        event.runner != null) {
      _events.add(event);
    }
  }

  Future<void> stop() => _subscription.cancel();

  Future<Map<String, Object?>> summary(KvService kvService, Map<String, Object?> provenance) async {
    final outcomes = <Map<String, Object?>>[];
    final seen = <String>{};
    var recordsComplete = true;
    for (final event in _events) {
      final outcome = event.outcome!;
      final identity = '${outcome.sessionId}/${outcome.turnId}';
      if (!seen.add(identity)) recordsComplete = false;
      final usage = await readSessionUsage(kvService, outcome.sessionId, defaultProvider: event.request.providerId);
      final supportsCostReporting = event.runner!.harness.supportsCostReporting;
      final usageMatches =
          usage.inputTokens == outcome.inputTokens &&
          usage.outputTokens == outcome.outputTokens &&
          usage.cachedInputTokens == outcome.cacheReadTokens &&
          usage.effectiveTokens == outcome.effectiveTokens &&
          usage.provider == event.request.providerId;
      if (!usageMatches || (supportsCostReporting && usage.estimatedCostUsd == null)) recordsComplete = false;
      outcomes.add({
        'sessionSha256': sha256.convert(utf8.encode(outcome.sessionId)).toString(),
        'provider': event.request.providerId,
        'configuredModel': provenance['model'],
        'status': outcome.status.name,
        'inputTokens': outcome.inputTokens,
        'outputTokens': outcome.outputTokens,
        'cacheReadTokens': outcome.cacheReadTokens,
        'cacheWriteTokens': outcome.cacheWriteTokens,
        'effectiveTokens': outcome.effectiveTokens,
        'durationMicros': outcome.turnDuration.inMicroseconds,
        'toolCallCount': outcome.toolCallCount,
        'failedToolCallCount': outcome.failedToolCallCount,
        'costReportingSupported': supportsCostReporting,
        'estimatedCostUsd': supportsCostReporting ? usage.estimatedCostUsd : null,
        'terminalResponseSha256': _responseSha256(outcome),
      });
    }
    final statusCounts = <String, int>{};
    for (final outcome in outcomes) {
      final status = outcome['status']! as String;
      statusCounts[status] = (statusCounts[status] ?? 0) + 1;
    }
    final reportedCosts = outcomes.map((item) => item['estimatedCostUsd']).whereType<double>().toList();
    final attemptsWithoutOutcome = _attempts - outcomes.length;
    return Map.unmodifiable({
      'judgeAttempts': _attempts,
      'judgeReturns': _returns,
      'judgeFailures': _failures,
      'terminalOutcomeCount': outcomes.length,
      'attemptsWithoutTerminalOutcome': attemptsWithoutOutcome,
      'accountingComplete':
          !_streamFailed && recordsComplete && _attempts == _returns + _failures && attemptsWithoutOutcome >= 0,
      'statusCounts': Map.unmodifiable(statusCounts),
      'totals': {
        'inputTokens': outcomes.fold<int>(0, (sum, item) => sum + (item['inputTokens']! as int)),
        'outputTokens': outcomes.fold<int>(0, (sum, item) => sum + (item['outputTokens']! as int)),
        'cacheReadTokens': outcomes.fold<int>(0, (sum, item) => sum + (item['cacheReadTokens']! as int)),
        'cacheWriteTokens': outcomes.fold<int>(0, (sum, item) => sum + (item['cacheWriteTokens']! as int)),
        'reportedEstimatedCostUsd': reportedCosts.isEmpty
            ? null
            : reportedCosts.fold<double>(0, (sum, value) => sum + value),
      },
      'outcomes': List.unmodifiable(outcomes.map(Map<String, Object?>.unmodifiable)),
    });
  }

  String? _responseSha256(TurnOutcome outcome) {
    final response =
        outcome.responseText ?? (outcome.structuredOutput == null ? null : jsonEncode(outcome.structuredOutput));
    return response == null ? null : sha256.convert(utf8.encode(response)).toString();
  }
}
