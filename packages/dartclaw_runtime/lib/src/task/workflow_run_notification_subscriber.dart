import 'dart:async';

import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:dartclaw_kernel/dartclaw_kernel.dart';
import 'package:dartclaw_workflow/dartclaw_workflow.dart' show WorkflowRun;
import 'package:logging/logging.dart';

import 'channel_notification_delivery.dart';

const _maxPostedTextLength = 1000;

typedef _Event = WorkflowChatNotificationEvent;

/// Posts a workflow run's lifecycle to chat: started, awaiting approval, and
/// finished or failed, plus a line per step when `step_completed` is selected.
///
/// A run started from a chat turn posts to where it was started: into its
/// origin thread when the channel threads and one was recorded, else as plain
/// messages to the origin recipient. Any other run posts to the configured
/// notification channel, one thread per run when that channel threads. A run of
/// unknown origin posts nowhere, and a run never posts to both places.
///
/// A post never blocks or fails the run, and a refused one is dropped after a
/// warning that names the run.
class WorkflowRunNotificationSubscriber {
  static final _log = Logger('WorkflowRunNotificationSubscriber');

  final Future<WorkflowRun?> Function(String runId) _lookupRun;
  final ChannelManager _channelManager;
  final WorkflowChatNotificationsConfig? _configured;
  final ThreadBindingStore? _threadBindings;
  final String? _baseUrl;
  final ChannelNotificationDelivery _delivery = ChannelNotificationDelivery();
  final Map<String, Future<void>> _chains = {};
  StreamSubscription<WorkflowLifecycleEvent>? _subscription;

  /// Creates a subscriber that loads each run through [lookupRun].
  ///
  /// [configured] is the notification channel for runs started outside chat,
  /// `null` when none is usable. A configured channel that threads needs
  /// [threadBindings] to keep one thread per run; without one its posts go out
  /// as plain messages. [baseUrl] is the deployment's public URL, used to link
  /// the run page from an approval post.
  new({
    required Future<WorkflowRun?> Function(String runId) lookupRun,
    required ChannelManager channelManager,
    WorkflowChatNotificationsConfig? configured,
    ThreadBindingStore? threadBindings,
    String? baseUrl,
  }) : _lookupRun = lookupRun,
       _channelManager = channelManager,
       _configured = configured,
       _threadBindings = threadBindings,
       _baseUrl = baseUrl;

  Set<_Event> get _events => _configured?.events ?? WorkflowChatNotificationsConfig.defaultEvents;

  void subscribe(EventBus eventBus) {
    _subscription ??= eventBus.on<WorkflowLifecycleEvent>().listen(_onEvent);
  }

  Future<void> dispose() async {
    await _subscription?.cancel();
    _subscription = null;
    await Future.wait(_chains.values);
  }

  void _onEvent(WorkflowLifecycleEvent event) {
    final kind = _kindOf(event);
    if (kind == null) return;
    final terminal = event is WorkflowRunStatusChangedEvent && event.newStatus.terminal;
    final post = _events.contains(kind);
    if (!post && !terminal) return;

    // One chain per run keeps its posts in event order and lets the first one
    // open the thread before a later one looks for it; other runs never wait.
    final runId = event.runId;
    final previous = _chains[runId] ?? Future<void>.value();
    late final Future<void> chain;
    chain = previous
        .then((_) async {
          try {
            if (post) await _post(event, kind);
          } finally {
            if (terminal) await _closeRun(runId);
          }
        })
        .catchError((Object error, StackTrace stackTrace) {
          _log.warning('Failed to post workflow run $runId notification', error, stackTrace);
        })
        .whenComplete(() {
          if (identical(_chains[runId], chain)) _chains.remove(runId);
        });
    _chains[runId] = chain;
  }

  _Event? _kindOf(WorkflowLifecycleEvent event) => switch (event) {
    WorkflowRunStatusChangedEvent(:final oldStatus, :final newStatus) => switch (newStatus) {
      WorkflowRunStatus.running when oldStatus == WorkflowRunStatus.pending => _Event.started,
      WorkflowRunStatus.completed || WorkflowRunStatus.cancelled => _Event.finished,
      WorkflowRunStatus.failed => _Event.failed,
      _ => null,
    },
    WorkflowApprovalRequestedEvent() => _Event.awaitingApproval,
    WorkflowStepCompletedEvent() => _Event.stepCompleted,
    _ => null,
  };

  Future<void> _post(WorkflowLifecycleEvent event, _Event kind) async {
    final run = await _lookupRun(event.runId);
    if (run == null) {
      _log.warning('Workflow run ${event.runId} not found while preparing a channel notification');
      return;
    }
    if (run.origin.surface == 'unknown') return;

    final notification = _notificationFor(run, event, kind);
    if (notification == null) return;
    final subject = 'workflow run ${run.id}';
    final origin = run.origin;
    final originChannelType = origin.channelType;
    final originRecipient = origin.recipientId;
    if (originChannelType != null && originRecipient != null) {
      final channel = _channelOf(originChannelType);
      if (channel == null) {
        _log.warning('No registered channel found for ${origin.channelType} while posting $subject');
        return;
      }
      final threads = channel.threadedNotifications;
      if (threads == null) {
        await _delivery.sendPlain(channel, originRecipient, notification, subject: subject);
        return;
      }
      final threadId = origin.threadId;
      if (threadId != null) {
        await _delivery.sendInThread(
          channel,
          threads,
          originRecipient,
          threads.render(notification),
          threadId: threadId,
          subject: subject,
        );
        return;
      }
    }

    final configured = _configured;
    final channel = configured == null ? null : _channelOf(configured.channel.name);
    if (configured == null || channel == null) return;
    final threads = channel.threadedNotifications;
    final store = _threadBindings;
    if (threads == null || store == null) {
      await _delivery.sendPlain(channel, configured.recipient, notification, subject: subject);
      return;
    }

    final response = threads.render(notification);
    final channelType = channel.type.name;
    final binding = store.lookupByRun(run.id).where((b) => b.channelType == channelType).firstOrNull;
    if (binding != null) {
      await _delivery.sendInThread(
        channel,
        threads,
        configured.recipient,
        response,
        threadId: binding.threadId,
        subject: subject,
      );
      return;
    }
    final post = await _delivery.sendInNewThread(
      channel,
      threads,
      configured.recipient,
      response,
      threadKey: 'run-${run.id}',
      subject: subject,
    );
    if (post == null) return;
    final now = DateTime.now();
    try {
      await store.create(
        ThreadBinding.run(
          channelType: channelType,
          threadId: post.threadId,
          runId: run.id,
          createdAt: now,
          lastActivity: now,
        ),
      );
    } catch (error, stackTrace) {
      _log.warning('Failed to bind thread ${post.threadId} to workflow run ${run.id}', error, stackTrace);
    }
  }

  /// Ends the run's thread binding once its terminal post, if any, has gone out.
  Future<void> _closeRun(String runId) async {
    _delivery.forget('workflow run $runId');
    final store = _threadBindings;
    if (store == null) return;
    try {
      await store.deleteByTarget(ThreadBindingKind.run, runId);
    } catch (error, stackTrace) {
      _log.warning('Failed to remove the thread binding of workflow run $runId', error, stackTrace);
    }
  }

  Channel? _channelOf(String channelType) =>
      _channelManager.channels.where((candidate) => candidate.type.name == channelType).firstOrNull;

  ChannelNotification? _notificationFor(WorkflowRun run, WorkflowLifecycleEvent event, _Event kind) {
    final name = run.definitionName;
    final label = "Workflow '$name' (run ${run.id})";
    final facts = <String, String>{'Run': run.id};
    String text;
    String? body;
    String? error;
    switch (event) {
      case WorkflowApprovalRequestedEvent(:final stepId, :final message):
        facts['Step'] = stepId;
        body = _truncate(message);
        final link = publicPageUrl(_baseUrl, '/workflows/${run.id}');
        if (link != null) facts['Run page'] = link;
        text = ['$label is awaiting approval at step $stepId.', if (body.isNotEmpty) body, ?link].join('\n');
      case WorkflowStepCompletedEvent(
        :final stepName,
        :final stepIndex,
        :final totalSteps,
        :final success,
        :final outcome,
      ):
        text =
            "$label: step '$stepName' (${stepIndex + 1}/$totalSteps) ${outcome ?? (success ? 'succeeded' : 'failed')}.";
      case WorkflowRunStatusChangedEvent(:final newStatus, :final errorMessage):
        error = errorMessage == null ? null : _truncate(errorMessage);
        text = switch (newStatus) {
          WorkflowRunStatus.running => '$label started.',
          WorkflowRunStatus.cancelled => '$label was cancelled.',
          WorkflowRunStatus.failed => '$label failed${error == null ? '.' : ': $error'}',
          _ => '$label finished.',
        };
      default:
        return null;
    }
    return ChannelNotification(
      kind: ChannelNotificationKind.run,
      id: run.id,
      text: text,
      title: name,
      status: kind.yamlValue,
      body: body == null || body.isEmpty ? null : body,
      error: error,
      facts: facts,
      createdAt: run.startedAt,
      updatedAt: event.timestamp,
    );
  }

  String _truncate(String text) {
    final runes = text.runes;
    return runes.length <= _maxPostedTextLength ? text : String.fromCharCodes(runes.take(_maxPostedTextLength));
  }
}
