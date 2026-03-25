import 'dart:async';
import 'dart:convert';

import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:dartclaw_google_chat/dartclaw_google_chat.dart';
import 'package:dartclaw_storage/dartclaw_storage.dart';
import 'package:logging/logging.dart';

import '../canvas/canvas_service.dart';
import '../harness_pool.dart';
import '../task/task_service.dart';
import '../turn_manager.dart';

enum AdvisorTriggerType {
  turnDepth,
  tokenVelocity,
  periodic,
  taskReview,
  explicit;

  String get wireName => switch (this) {
    AdvisorTriggerType.turnDepth => 'turn_depth',
    AdvisorTriggerType.tokenVelocity => 'token_velocity',
    AdvisorTriggerType.periodic => 'periodic',
    AdvisorTriggerType.taskReview => 'task_review',
    AdvisorTriggerType.explicit => 'explicit',
  };

  static AdvisorTriggerType? fromWire(String value) => switch (value) {
    'turn_depth' => AdvisorTriggerType.turnDepth,
    'token_velocity' => AdvisorTriggerType.tokenVelocity,
    'periodic' => AdvisorTriggerType.periodic,
    'task_review' => AdvisorTriggerType.taskReview,
    'explicit' => AdvisorTriggerType.explicit,
    _ => null,
  };
}

enum AdvisorStatus {
  onTrack,
  diverging,
  stuck,
  concerning;

  String get wireName => switch (this) {
    AdvisorStatus.onTrack => 'on_track',
    AdvisorStatus.diverging => 'diverging',
    AdvisorStatus.stuck => 'stuck',
    AdvisorStatus.concerning => 'concerning',
  };

  static AdvisorStatus fromWire(String value) => switch (value) {
    'on_track' => AdvisorStatus.onTrack,
    'diverging' => AdvisorStatus.diverging,
    'stuck' => AdvisorStatus.stuck,
    'concerning' => AdvisorStatus.concerning,
    _ => AdvisorStatus.concerning,
  };
}

class AdvisorOutput {
  final AdvisorStatus status;
  final String observation;
  final String? suggestion;

  const AdvisorOutput({required this.status, required this.observation, this.suggestion});
}

class AdvisorTriggerContext {
  final AdvisorTriggerType type;
  final String reason;
  final String sessionKey;
  final List<String> taskIds;
  final String? channelType;
  final String? recipientId;
  final String? threadId;

  const AdvisorTriggerContext({
    required this.type,
    required this.reason,
    required this.sessionKey,
    this.taskIds = const [],
    this.channelType,
    this.recipientId,
    this.threadId,
  });

  bool get bypassCircuitBreaker => type == AdvisorTriggerType.explicit;
}

class ContextEntry {
  final String kind;
  final String summary;
  final String sessionKey;
  final String? taskId;
  final DateTime timestamp;
  final int estimatedTokens;
  final Map<String, dynamic> details;

  const ContextEntry({
    required this.kind,
    required this.summary,
    required this.sessionKey,
    this.taskId,
    required this.timestamp,
    required this.estimatedTokens,
    this.details = const {},
  });
}

class SlidingContextWindow {
  final int maxEntries;
  final List<ContextEntry> _entries = <ContextEntry>[];
  int _estimatedTokens = 0;

  SlidingContextWindow({this.maxEntries = 10});

  void add(ContextEntry entry) {
    _entries.add(entry);
    _estimatedTokens += entry.estimatedTokens;
    while (_entries.length > maxEntries) {
      final removed = _entries.removeAt(0);
      _estimatedTokens -= removed.estimatedTokens;
    }
  }

  List<ContextEntry> get entries => List<ContextEntry>.unmodifiable(_entries);

  int get estimatedTokenCount => _estimatedTokens;

  int tokenVelocityForTask(String taskId, Duration window) {
    final cutoff = DateTime.now().subtract(window);
    var total = 0;
    for (final entry in _entries) {
      if (entry.taskId != taskId || entry.timestamp.isBefore(cutoff)) continue;
      total += (entry.details['tokenCount'] as int?) ?? 0;
    }
    return total;
  }

  int completedTurnCountForTask(String taskId) {
    var count = 0;
    for (final entry in _entries) {
      if (entry.taskId != taskId) continue;
      if (entry.kind == 'task_event' && entry.details['kind'] == 'tokenUpdate') {
        count++;
      }
    }
    return count;
  }
}

class CircuitBreaker {
  final int minPrimaryTurnsBetweenFirings;
  int _primaryTurnsSinceLastFire;

  CircuitBreaker({this.minPrimaryTurnsBetweenFirings = 5}) : _primaryTurnsSinceLastFire = minPrimaryTurnsBetweenFirings;

  void recordPrimaryTurn() {
    _primaryTurnsSinceLastFire++;
  }

  bool get canFire => _primaryTurnsSinceLastFire >= minPrimaryTurnsBetweenFirings;

  void recordFiring() {
    _primaryTurnsSinceLastFire = 0;
  }
}

class TriggerEvaluator {
  final Set<AdvisorTriggerType> _triggers;
  final Duration _periodicInterval;
  final int _turnDepthThreshold;
  final int _tokenVelocityThreshold;
  final Duration _tokenVelocityWindow;
  final Future<void> Function(AdvisorTriggerContext context) _onTrigger;
  final String? Function() _periodicSessionKey;
  final List<String> Function() _periodicTaskIds;

  Timer? _periodicTimer;

  TriggerEvaluator({
    required Set<AdvisorTriggerType> triggers,
    required Duration periodicInterval,
    int turnDepthThreshold = 5,
    int tokenVelocityThreshold = 4000,
    Duration tokenVelocityWindow = const Duration(minutes: 5),
    required Future<void> Function(AdvisorTriggerContext context) onTrigger,
    required String? Function() periodicSessionKey,
    required List<String> Function() periodicTaskIds,
  }) : _triggers = triggers,
       _periodicInterval = periodicInterval,
       _turnDepthThreshold = turnDepthThreshold,
       _tokenVelocityThreshold = tokenVelocityThreshold,
       _tokenVelocityWindow = tokenVelocityWindow,
       _onTrigger = onTrigger,
       _periodicSessionKey = periodicSessionKey,
       _periodicTaskIds = periodicTaskIds;

  void start() {
    if (!_triggers.contains(AdvisorTriggerType.periodic)) return;
    _periodicTimer = Timer.periodic(_periodicInterval, (_) {
      unawaited(_firePeriodic());
    });
  }

  void dispose() {
    _periodicTimer?.cancel();
    _periodicTimer = null;
  }

  Future<void> evaluate(ContextEntry entry, SlidingContextWindow window) async {
    if (_triggers.contains(AdvisorTriggerType.explicit) && entry.kind == 'advisor_mention') {
      await _onTrigger(
        AdvisorTriggerContext(
          type: AdvisorTriggerType.explicit,
          reason: 'Explicit @advisor mention',
          sessionKey: entry.sessionKey,
          taskIds: entry.taskId == null ? const <String>[] : <String>[entry.taskId!],
          channelType: entry.details['channelType'] as String?,
          recipientId: entry.details['recipientId'] as String?,
          threadId: entry.details['threadId'] as String?,
        ),
      );
    }

    if (entry.taskId == null) return;
    final taskId = entry.taskId!;

    if (_triggers.contains(AdvisorTriggerType.taskReview) &&
        entry.kind == 'task_status_changed' &&
        entry.details['newStatus'] == 'review') {
      await _onTrigger(
        AdvisorTriggerContext(
          type: AdvisorTriggerType.taskReview,
          reason: 'Task entered review',
          sessionKey: entry.sessionKey,
          taskIds: <String>[taskId],
        ),
      );
    }

    if (_triggers.contains(AdvisorTriggerType.turnDepth) &&
        entry.kind == 'task_event' &&
        entry.details['kind'] == 'tokenUpdate' &&
        window.completedTurnCountForTask(taskId) >= _turnDepthThreshold) {
      await _onTrigger(
        AdvisorTriggerContext(
          type: AdvisorTriggerType.turnDepth,
          reason: 'Task exceeded turn depth threshold',
          sessionKey: entry.sessionKey,
          taskIds: <String>[taskId],
        ),
      );
    }

    if (_triggers.contains(AdvisorTriggerType.tokenVelocity) &&
        entry.kind == 'task_event' &&
        entry.details['kind'] == 'tokenUpdate' &&
        window.tokenVelocityForTask(taskId, _tokenVelocityWindow) >= _tokenVelocityThreshold) {
      await _onTrigger(
        AdvisorTriggerContext(
          type: AdvisorTriggerType.tokenVelocity,
          reason: 'Task exceeded token velocity threshold',
          sessionKey: entry.sessionKey,
          taskIds: <String>[taskId],
        ),
      );
    }
  }

  Future<void> _firePeriodic() async {
    final taskIds = _periodicTaskIds();
    final sessionKey = _periodicSessionKey();
    if (taskIds.isEmpty || sessionKey == null || sessionKey.isEmpty) return;
    await _onTrigger(
      AdvisorTriggerContext(
        type: AdvisorTriggerType.periodic,
        reason: 'Periodic advisor trigger',
        sessionKey: sessionKey,
        taskIds: taskIds,
      ),
    );
  }
}

class AdvisorOutputParser {
  const AdvisorOutputParser();

  AdvisorOutput parse(String rawText) {
    final trimmed = rawText.trim();
    final decoded = _decodeJson(trimmed);
    if (decoded != null) {
      return AdvisorOutput(
        status: AdvisorStatus.fromWire(decoded['status']?.toString() ?? ''),
        observation: _stringValue(decoded['observation']) ?? 'Advisor produced no observation.',
        suggestion: _stringValue(decoded['suggestion']),
      );
    }

    final status = _extractField(trimmed, 'status') ?? 'concerning';
    final observation = _extractField(trimmed, 'observation') ?? trimmed;
    final suggestion = _extractField(trimmed, 'suggestion');
    return AdvisorOutput(
      status: AdvisorStatus.fromWire(status),
      observation: observation.trim(),
      suggestion: suggestion?.trim(),
    );
  }

  Map<String, dynamic>? _decodeJson(String text) {
    final start = text.indexOf('{');
    final end = text.lastIndexOf('}');
    if (start < 0 || end <= start) return null;
    try {
      final decoded = jsonDecode(text.substring(start, end + 1));
      if (decoded is Map<String, dynamic>) {
        return decoded;
      }
    } on FormatException {
      return null;
    }
    return null;
  }

  String? _stringValue(Object? value) {
    if (value is! String) return null;
    final trimmed = value.trim();
    return trimmed.isEmpty ? null : trimmed;
  }

  String? _extractField(String text, String field) {
    final regex = RegExp('${RegExp.escape(field)}\\s*:\\s*(.+)', caseSensitive: false);
    final match = regex.firstMatch(text);
    return match?.group(1);
  }
}

class AdvisorOutputRouter {
  AdvisorOutputRouter({
    ChannelManager? channelManager,
    required EventBus eventBus,
    required ChatCardBuilder googleChatCardBuilder,
    this.threadBindings,
    this.canvasService,
    this.canvasSessionKey,
  }) : _channelManager = channelManager,
       _eventBus = eventBus,
       _googleChatCardBuilder = googleChatCardBuilder;

  final ChannelManager? _channelManager;
  final EventBus _eventBus;
  final ChatCardBuilder _googleChatCardBuilder;
  final ThreadBindingStore? threadBindings;
  final CanvasService? canvasService;
  final String? canvasSessionKey;

  Future<void> route(AdvisorOutput output, AdvisorTriggerContext trigger, List<Task> tasks) async {
    if (canvasService != null && canvasSessionKey != null) {
      canvasService!.push(canvasSessionKey!, renderAdvisorInsightCard(output: output, trigger: trigger, tasks: tasks));
    }

    _eventBus.fire(
      AdvisorInsightEvent(
        status: output.status.wireName,
        observation: output.observation,
        suggestion: output.suggestion,
        triggerType: trigger.type.wireName,
        taskIds: tasks.map((task) => task.id).toList(growable: false),
        sessionKey: trigger.sessionKey,
        timestamp: DateTime.now(),
      ),
    );

    if (trigger.type == AdvisorTriggerType.explicit) {
      await _sendToExplicitOrigin(output, trigger);
      return;
    }

    await _broadcastForTasks(output, trigger, tasks);
  }

  Future<void> _sendToExplicitOrigin(AdvisorOutput output, AdvisorTriggerContext trigger) async {
    final channelType = trigger.channelType;
    final recipientId = trigger.recipientId;
    if (channelType == null || recipientId == null) return;
    final destination = _Destination(channelType: channelType, recipientId: recipientId, threadId: trigger.threadId);
    await _sendToDestination(destination, output, trigger.type.wireName);
  }

  Future<void> _broadcastForTasks(AdvisorOutput output, AdvisorTriggerContext trigger, List<Task> tasks) async {
    final destinations = <String, _Destination>{};
    for (final task in tasks) {
      final bindings = threadBindings?.lookupByTask(task.id) ?? const <ThreadBinding>[];
      if (bindings.isNotEmpty) {
        for (final binding in bindings) {
          final destination = _destinationFromBinding(binding);
          if (destination == null) continue;
          destinations[destination.key] = destination;
        }
        continue;
      }

      final origin = TaskOrigin.fromConfigJson(task.configJson);
      if (origin == null) continue;
      final destination = _Destination(channelType: origin.channelType, recipientId: origin.recipientId);
      destinations[destination.key] = destination;
    }

    for (final destination in destinations.values) {
      await _sendToDestination(destination, output, trigger.type.wireName);
    }
  }

  _Destination? _destinationFromBinding(ThreadBinding binding) {
    if (binding.channelType == ChannelType.googlechat.name) {
      final separator = binding.threadId.indexOf('/threads/');
      if (separator <= 0) return null;
      final spaceName = binding.threadId.substring(0, separator);
      return _Destination(channelType: binding.channelType, recipientId: spaceName, threadId: binding.threadId);
    }

    return _Destination(channelType: binding.channelType, recipientId: binding.threadId, threadId: binding.threadId);
  }

  Future<void> _sendToDestination(_Destination destination, AdvisorOutput output, String triggerType) async {
    final channel = _findChannel(destination.channelType);
    if (channel == null) return;

    final response = _buildResponse(destination.channelType, output, triggerType);
    if (destination.channelType == ChannelType.googlechat.name &&
        destination.threadId != null &&
        channel is GoogleChatChannel) {
      await channel.sendMessageToThreadName(destination.recipientId, response, threadName: destination.threadId!);
      return;
    }

    await channel.sendMessage(destination.recipientId, response);
  }

  ChannelResponse _buildResponse(String channelType, AdvisorOutput output, String triggerType) {
    final suggestion = output.suggestion == null || output.suggestion!.trim().isEmpty
        ? ''
        : '\nSuggestion: ${output.suggestion!.trim()}';
    final text = '[Advisor] Status: ${output.status.wireName}\nObservation: ${output.observation.trim()}$suggestion';
    if (channelType != ChannelType.googlechat.name) {
      return ChannelResponse(text: text);
    }

    return ChannelResponse(
      text: text,
      structuredPayload: _googleChatCardBuilder.advisorInsight(
        status: output.status.wireName,
        observation: output.observation,
        suggestion: output.suggestion,
        triggerType: triggerType,
      ),
    );
  }

  Channel? _findChannel(String channelType) {
    final channelManager = _channelManager;
    if (channelManager == null) {
      return null;
    }
    for (final channel in channelManager.channels) {
      if (channel.type.name == channelType) {
        return channel;
      }
    }
    return null;
  }
}

class AdvisorSubscriber {
  static final _log = Logger('AdvisorSubscriber');

  final EventBus _eventBus;
  final HarnessPool _pool;
  final SessionService _sessions;
  final TaskService _taskService;
  final TurnTraceService? _traceService;
  final SlidingContextWindow _window;
  final Set<AdvisorTriggerType> _triggers;
  final Duration _periodicInterval;
  final CircuitBreaker _circuitBreaker;
  final AdvisorOutputParser _outputParser;
  final AdvisorOutputRouter _outputRouter;
  final List<AdvisorOutput> _priorReflections = <AdvisorOutput>[];
  final int _maxPriorReflections;
  final String? _model;
  final String? _effort;

  StreamSubscription<TaskStatusChangedEvent>? _taskStatusSub;
  StreamSubscription<TaskEventCreatedEvent>? _taskEventSub;
  StreamSubscription<AgentStateChangedEvent>? _agentStateSub;
  StreamSubscription<AdvisorMentionEvent>? _advisorMentionSub;
  String? _lastSessionKey;

  AdvisorSubscriber({
    required HarnessPool pool,
    required SessionService sessions,
    required TaskService taskService,
    required EventBus eventBus,
    ChannelManager? channelManager,
    TurnTraceService? traceService,
    ThreadBindingStore? threadBindings,
    CanvasService? canvasService,
    String? canvasSessionKey,
    List<String> triggers = const <String>[],
    int periodicIntervalMinutes = 10,
    int maxWindowTurns = 10,
    int maxPriorReflections = 3,
    String? model,
    String? effort,
    ChatCardBuilder? googleChatCardBuilder,
  }) : _pool = pool,
       _eventBus = eventBus,
       _sessions = sessions,
       _taskService = taskService,
       _traceService = traceService,
       _window = SlidingContextWindow(maxEntries: maxWindowTurns),
       _triggers = triggers.map(AdvisorTriggerType.fromWire).whereType<AdvisorTriggerType>().toSet(),
       _periodicInterval = Duration(minutes: periodicIntervalMinutes),
       _circuitBreaker = CircuitBreaker(),
       _outputParser = const AdvisorOutputParser(),
       _outputRouter = AdvisorOutputRouter(
         channelManager: channelManager,
         eventBus: eventBus,
         googleChatCardBuilder: googleChatCardBuilder ?? const ChatCardBuilder(),
         threadBindings: threadBindings,
         canvasService: canvasService,
         canvasSessionKey: canvasSessionKey,
       ),
       _maxPriorReflections = maxPriorReflections,
       _model = model,
       _effort = effort;

  late final TriggerEvaluator _evaluator = TriggerEvaluator(
    triggers: _triggers,
    periodicInterval: _periodicInterval,
    onTrigger: _maybeRunAdvisor,
    periodicSessionKey: () => _lastSessionKey,
    periodicTaskIds: () => _activeTaskIds(),
  );

  void subscribe() {
    _taskStatusSub ??= _eventBus.on<TaskStatusChangedEvent>().listen((event) {
      unawaited(_handleTaskStatusChanged(event));
    });
    _taskEventSub ??= _eventBus.on<TaskEventCreatedEvent>().listen((event) {
      unawaited(_handleTaskEventCreated(event));
    });
    _agentStateSub ??= _eventBus.on<AgentStateChangedEvent>().listen((event) {
      unawaited(_handleAgentStateChanged(event));
    });
    _advisorMentionSub ??= _eventBus.on<AdvisorMentionEvent>().listen((event) {
      unawaited(_handleAdvisorMention(event));
    });
    _evaluator.start();
  }

  Future<void> dispose() async {
    _evaluator.dispose();
    await _taskStatusSub?.cancel();
    await _taskEventSub?.cancel();
    await _agentStateSub?.cancel();
    await _advisorMentionSub?.cancel();
    _taskStatusSub = null;
    _taskEventSub = null;
    _agentStateSub = null;
    _advisorMentionSub = null;
  }

  Future<void> _handleTaskStatusChanged(TaskStatusChangedEvent event) async {
    final entry = ContextEntry(
      kind: 'task_status_changed',
      summary: 'Task ${event.taskId} moved from ${event.oldStatus.name} to ${event.newStatus.name}.',
      sessionKey: SessionKey.taskSession(taskId: event.taskId),
      taskId: event.taskId,
      timestamp: event.timestamp,
      estimatedTokens: _estimateTokens('${event.oldStatus.name} ${event.newStatus.name} ${event.trigger}'),
      details: {'oldStatus': event.oldStatus.name, 'newStatus': event.newStatus.name, 'trigger': event.trigger},
    );
    await _recordEntry(entry);
  }

  Future<void> _handleTaskEventCreated(TaskEventCreatedEvent event) async {
    final tokenCount = switch (event.kind) {
      'tokenUpdate' =>
        ((event.details['inputTokens'] as num?)?.toInt() ?? 0) +
            ((event.details['outputTokens'] as num?)?.toInt() ?? 0),
      _ => 0,
    };
    final entry = ContextEntry(
      kind: 'task_event',
      summary: _taskEventSummary(event),
      sessionKey: SessionKey.taskSession(taskId: event.taskId),
      taskId: event.taskId,
      timestamp: event.timestamp,
      estimatedTokens: _estimateTokens(_taskEventSummary(event)),
      details: {...event.details, 'kind': event.kind, 'tokenCount': tokenCount},
    );
    if (event.kind == 'tokenUpdate') {
      _circuitBreaker.recordPrimaryTurn();
    }
    await _recordEntry(entry);
  }

  Future<void> _handleAgentStateChanged(AgentStateChangedEvent event) async {
    final entry = ContextEntry(
      kind: 'agent_state_changed',
      summary: 'Runner ${event.runnerId} is ${event.state}.',
      sessionKey: _lastSessionKey ?? SessionKey.webSession(),
      taskId: event.currentTaskId,
      timestamp: event.timestamp,
      estimatedTokens: _estimateTokens('${event.runnerId} ${event.state}'),
      details: {'runnerId': event.runnerId, 'state': event.state, 'currentTaskId': event.currentTaskId},
    );
    await _recordEntry(entry);
  }

  Future<void> _handleAdvisorMention(AdvisorMentionEvent event) async {
    final entry = ContextEntry(
      kind: 'advisor_mention',
      summary: 'Explicit advisor mention from ${event.channelType}.',
      sessionKey: event.sessionKey,
      taskId: event.taskId,
      timestamp: event.timestamp,
      estimatedTokens: _estimateTokens(event.messageText),
      details: {'channelType': event.channelType, 'recipientId': event.recipientId, 'threadId': event.threadId},
    );
    await _recordEntry(entry);
  }

  Future<void> _recordEntry(ContextEntry entry) async {
    _lastSessionKey = entry.sessionKey;
    _window.add(entry);
    await _evaluator.evaluate(entry, _window);
  }

  Future<void> _maybeRunAdvisor(AdvisorTriggerContext trigger) async {
    if (!trigger.bypassCircuitBreaker && !_circuitBreaker.canFire) {
      return;
    }
    if (!trigger.bypassCircuitBreaker) {
      _circuitBreaker.recordFiring();
    }
    await _runAdvisor(trigger);
  }

  Future<void> _runAdvisor(AdvisorTriggerContext trigger) async {
    final runner = _pool.tryAcquire();
    if (runner == null) {
      _log.info('Advisor skipped for ${trigger.type.wireName}: no task runner available');
      return;
    }

    try {
      final tasks = await _loadTasks(trigger.taskIds);
      final prompt = await _buildPrompt(trigger, tasks);
      final advisorSession = await _sessions.getOrCreateByKey(
        SessionKey.cronSession(jobId: 'advisor:${trigger.sessionKey}'),
        type: SessionType.cron,
      );

      final turnId = await runner.reserveTurn(
        advisorSession.id,
        agentName: 'advisor',
        model: _model,
        effort: _effort,
        maxTurns: 1,
      );
      runner.executeTurn(
        advisorSession.id,
        turnId,
        <Map<String, dynamic>>[
          <String, dynamic>{'role': 'user', 'content': prompt},
        ],
        source: 'advisor',
        agentName: 'advisor',
      );
      final outcome = await runner.waitForOutcome(advisorSession.id, turnId);
      if (outcome.status != TurnStatus.completed ||
          outcome.responseText == null ||
          outcome.responseText!.trim().isEmpty) {
        _log.warning('Advisor turn did not produce a usable response for ${trigger.type.wireName}');
        return;
      }

      final output = _outputParser.parse(outcome.responseText!);
      _priorReflections.add(output);
      while (_priorReflections.length > _maxPriorReflections) {
        _priorReflections.removeAt(0);
      }
      await _outputRouter.route(output, trigger, tasks);
    } catch (error, stackTrace) {
      _log.warning('Advisor execution failed for ${trigger.type.wireName}', error, stackTrace);
    } finally {
      _pool.release(runner);
    }
  }

  Future<List<Task>> _loadTasks(List<String> taskIds) async {
    if (taskIds.isEmpty) {
      return await _taskService.list();
    }

    final tasks = <Task>[];
    for (final taskId in taskIds.toSet()) {
      final task = await _taskService.get(taskId);
      if (task != null) {
        tasks.add(task);
      }
    }
    return tasks;
  }

  Future<String> _buildPrompt(AdvisorTriggerContext trigger, List<Task> tasks) async {
    final buffer = StringBuffer()
      ..writeln('You are DartClaw Advisor, a concise observer for crowd coding sessions.')
      ..writeln('Return JSON only with keys: status, observation, suggestion.')
      ..writeln('Allowed status values: on_track, diverging, stuck, concerning.')
      ..writeln('Keep observation to one sentence. Suggestion is optional and short.')
      ..writeln()
      ..writeln('Trigger: ${trigger.type.wireName}')
      ..writeln('Reason: ${trigger.reason}')
      ..writeln()
      ..writeln('Recent context:');

    for (final entry in _window.entries) {
      buffer.writeln('- [${entry.timestamp.toIso8601String()}] ${entry.summary}');
    }

    if (tasks.isNotEmpty) {
      buffer.writeln();
      buffer.writeln('Current tasks:');
      for (final task in tasks) {
        buffer.writeln('- ${task.id}: ${task.title} (${task.status.name})');
      }
    }

    if (_traceService != null && tasks.isNotEmpty) {
      buffer.writeln();
      buffer.writeln('Recent turn traces:');
      for (final task in tasks.take(3)) {
        final result = await _traceService.query(taskId: task.id, limit: 3);
        for (final trace in result.traces) {
          buffer.writeln(
            '- ${task.id}: provider=${trace.provider ?? 'unknown'} model=${trace.model ?? 'unknown'} '
            'tokens=${trace.inputTokens + trace.outputTokens} error=${trace.isError}',
          );
        }
      }
    }

    if (_priorReflections.isNotEmpty) {
      buffer.writeln();
      buffer.writeln('Prior advisor reflections:');
      for (final reflection in _priorReflections) {
        buffer.writeln('- ${reflection.status.wireName}: ${reflection.observation}');
      }
    }

    return buffer.toString();
  }

  List<String> _activeTaskIds() {
    final ids = <String>{};
    for (final entry in _window.entries) {
      final taskId = entry.taskId;
      if (taskId != null) ids.add(taskId);
    }
    return ids.toList(growable: false);
  }

  String _taskEventSummary(TaskEventCreatedEvent event) {
    return switch (event.kind) {
      'toolCalled' => 'Task ${event.taskId} used tool ${event.details['name'] ?? 'unknown'}.',
      'tokenUpdate' =>
        'Task ${event.taskId} spent ${((event.details['inputTokens'] as num?)?.toInt() ?? 0) + ((event.details['outputTokens'] as num?)?.toInt() ?? 0)} tokens.',
      'error' => 'Task ${event.taskId} recorded an error.',
      _ => 'Task ${event.taskId} recorded ${event.kind}.',
    };
  }

  int _estimateTokens(String text) => (text.length / 4).ceil().clamp(1, 10000);
}

String renderAdvisorInsightCard({
  required AdvisorOutput output,
  required AdvisorTriggerContext trigger,
  required List<Task> tasks,
}) {
  final escape = const HtmlEscape(HtmlEscapeMode.element);
  final taskLabel = tasks.isEmpty ? 'No active tasks' : tasks.map((task) => task.title).join(', ');
  final suggestion = output.suggestion == null || output.suggestion!.trim().isEmpty
      ? ''
      : '<p class="advisor-insight-suggestion"><strong>Suggestion:</strong> ${escape.convert(output.suggestion!.trim())}</p>';
  return '''
<section class="advisor-insight-card" style="border:1px solid #b6c2d6;background:#f5f8fb;color:#233245;border-radius:12px;padding:14px 16px;margin:12px 0;">
  <div style="display:flex;justify-content:space-between;gap:12px;align-items:flex-start;">
    <div>
      <p style="margin:0 0 4px 0;font-style:italic;font-weight:700;letter-spacing:0.02em;">Advisor Insight</p>
      <p style="margin:0;color:#51657f;font-size:0.92rem;">Trigger: ${escape.convert(trigger.type.wireName)}</p>
    </div>
    <span style="padding:4px 8px;border-radius:999px;background:#dce7f3;font-weight:700;">${escape.convert(output.status.wireName)}</span>
  </div>
  <p style="margin:12px 0 8px 0;">${escape.convert(output.observation)}</p>
  $suggestion
  <p style="margin:10px 0 0 0;color:#51657f;font-size:0.9rem;"><strong>Tasks:</strong> ${escape.convert(taskLabel)}</p>
</section>
''';
}

class _Destination {
  final String channelType;
  final String recipientId;
  final String? threadId;

  const _Destination({required this.channelType, required this.recipientId, this.threadId});

  String get key => '$channelType::$recipientId::${threadId ?? ''}';
}
