import 'dart:async';

import 'package:dartclaw_config/dartclaw_config.dart';
import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:logging/logging.dart';

import 'alert_classifier.dart';
import 'alert_delivery_adapter.dart';
import 'alert_formatter.dart';
import 'alert_throttle.dart';

/// Subscribes to [EventBus], classifies [DartclawEvent]s to type identifiers,
/// and routes them to configured [AlertTarget]s via [AlertDeliveryAdapter].
///
/// Implements [Reconfigurable]: config changes apply to the next event without
/// restarting the subscription.
///
/// [formatter] formats events into channel-appropriate [ChannelResponse]s.
/// [taskLookup] is used to filter task-failure alerts based on [TaskOrigin]:
/// tasks originating from a DM or group channel session are suppressed.
///
/// Per-recipient throttling is delegated to [AlertThrottle]. Each target is
/// throttled independently per event type (key: `eventType:channelType:recipient`).
class AlertRouter implements Reconfigurable {
  static final _log = Logger('AlertRouter');

  AlertsConfig _config;
  final AlertDeliveryAdapter _adapter;
  final AlertFormatter _formatter;
  final Future<Task?> Function(String taskId)? _taskLookup;
  late final AlertThrottle _throttle;
  StreamSubscription<DartclawEvent>? _subscription;

  AlertRouter({
    required EventBus bus,
    required AlertDeliveryAdapter adapter,
    required AlertsConfig config,
    AlertFormatter formatter = const AlertFormatter(),
    Future<Task?> Function(String taskId)? taskLookup,
  }) : _config = config,
       _adapter = adapter,
       _formatter = formatter,
       _taskLookup = taskLookup {
    _throttle = AlertThrottle(
      cooldown: Duration(seconds: config.cooldownSeconds),
      burstThreshold: config.burstThreshold,
      onSummary: _onSummary,
    );
    _subscription = bus.on<DartclawEvent>().listen(_onEvent);
  }

  @override
  Set<String> get watchKeys => const {'alerts.*'};

  @override
  void reconfigure(ConfigDelta delta) {
    _config = delta.current.alerts;
    _throttle.reconfigure(Duration(seconds: _config.cooldownSeconds), _config.burstThreshold);
    _log.info('AlertRouter reconfigured (enabled: ${_config.enabled}, targets: ${_config.targets.length})');
  }

  /// Cancel the EventBus subscription and dispose the throttle.
  /// After this, no further events will be delivered even if the bus fires.
  Future<void> cancel() async {
    await _subscription?.cancel();
    _subscription = null;
    _throttle.dispose();
  }

  void _onEvent(DartclawEvent event) {
    if (!_config.enabled) return;

    final classification = classifyAlert(event);
    if (classification == null) return;

    final targets = _resolveTargets(classification.alertType);
    if (targets.isEmpty) return;

    // Non-channel filter: suppress task-failure alerts for channel-originated tasks.
    if (event is TaskStatusChangedEvent) {
      unawaited(_routeTaskFailure(event, classification, targets));
    } else {
      _deliver(event, classification, targets);
    }
  }

  Future<void> _routeTaskFailure(
    TaskStatusChangedEvent event,
    AlertClassification classification,
    List<AlertTarget> targets,
  ) async {
    if (_taskLookup != null) {
      final task = await _taskLookup(event.taskId);
      if (task == null) {
        _log.warning('AlertRouter: task ${event.taskId} not found — skipping alert');
        return;
      }
      if (!shouldAlertTaskFailure(task.configJson)) {
        _log.fine('AlertRouter: suppressing task-failure alert for channel-originated task ${event.taskId}');
        return;
      }
    }
    _deliver(event, classification, targets);
  }

  void _deliver(DartclawEvent event, AlertClassification classification, List<AlertTarget> targets) {
    for (final target in targets) {
      final response = _formatter.format(
        event: event,
        alertType: classification.alertType,
        severity: classification.severity,
        channelType: target.channel,
      );
      if (_throttle.shouldDeliver(classification.alertType, target)) {
        _adapter.deliver(target, response);
      }
    }
  }

  void _onSummary(String eventType, AlertTarget target, int count) {
    final response = _formatter.formatSummary(
      alertType: eventType,
      severity: _summarySeverity(eventType),
      channelType: target.channel,
      count: count,
      cooldown: Duration(seconds: _config.cooldownSeconds),
    );
    _adapter.deliver(target, response);
  }

  /// Resolves targets for [typeId] using [AlertsConfig.routes].
  ///
  /// - If `routes` is empty → all targets.
  /// - If `routes` has an entry for [typeId] with `['*']` → all targets.
  /// - If `routes` has an entry for [typeId] with specific indices → those
  ///   targets (out-of-bounds indices produce a warning and are skipped).
  /// - If `routes` has no entry for [typeId] → empty list (event not routed).
  List<AlertTarget> _resolveTargets(String typeId) {
    if (_config.targets.isEmpty) return const [];

    if (_config.routes.isEmpty) return _config.targets;

    final routeEntry = _config.routes[typeId];
    if (routeEntry == null) return const [];

    if (routeEntry.contains('*')) return _config.targets;

    final result = <AlertTarget>[];
    for (final indexStr in routeEntry) {
      final idx = int.tryParse(indexStr);
      if (idx == null || idx < 0 || idx >= _config.targets.length) {
        _log.warning('AlertRouter: routes[$typeId] contains invalid target index "$indexStr" — skipping');
        continue;
      }
      result.add(_config.targets[idx]);
    }
    return result;
  }

  static AlertSeverity _summarySeverity(String alertType) => switch (alertType) {
    'container_crash' || 'job_failure' => AlertSeverity.critical,
    'compaction' => AlertSeverity.info,
    _ => AlertSeverity.warning,
  };
}
