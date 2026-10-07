import 'dart:async';

import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:dartclaw_kernel/dartclaw_kernel.dart';
import 'package:dartclaw_workflow/dartclaw_workflow.dart'
    show WorkflowApprovalInteraction, WorkflowApprovalPost, WorkflowApprovalSource, WorkflowRun, workflowRevisionState;
import 'package:logging/logging.dart';

import 'channel_notification_delivery.dart';

const _maxPostedTextLength = 1000;

typedef _Event = WorkflowChatNotificationEvent;

/// Issues the one interaction a post may resolve a run's pending approval step with, or `null` when it is
/// not pending there.
typedef IssueApprovalInteraction = Future<WorkflowApprovalInteraction?> Function(String runId, String stepId);

/// Binds a sent [post] to the interaction holding [nonce]; `false` when that interaction is gone.
typedef BindApprovalPost = Future<bool> Function(
  String runId, {
  required String nonce,
  required WorkflowApprovalPost post,
});

/// Posts a workflow run's lifecycle to chat: started, awaiting approval, and
/// finished or failed, plus a line per step when `step_completed` is selected.
///
/// A run started from a chat turn posts to where it was started: into its
/// origin thread when the channel threads and one was recorded, else, on a
/// channel that does not thread, as plain messages to the origin recipient. A
/// threaded channel with no recorded thread falls to the configured
/// notification channel, as does any run started outside chat, with one thread
/// per run when that channel threads. A run of unknown origin posts nowhere,
/// and a run never posts to both places.
///
/// On a channel that threads, an approval post carries Approve and Reject for the interaction issued
/// with [IssueApprovalInteraction], bound to the post once sent. Every resolution of that approval,
/// whichever surface made it, and a run that ends with it unresolved, edit the bound post once to say
/// what happened and carry no buttons.
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
  final IssueApprovalInteraction? _issueInteraction;
  final BindApprovalPost? _bindPost;
  final ChannelNotificationDelivery _delivery = ChannelNotificationDelivery();
  final Map<String, Future<void>> _chains = {};
  final Set<String> _editWarned = {};
  StreamSubscription<WorkflowLifecycleEvent>? _subscription;

  /// Creates a subscriber that loads each run through [lookupRun].
  ///
  /// [configured] is the notification channel for runs started outside chat,
  /// `null` when none is usable. A configured channel that threads needs
  /// [threadBindings] to keep one thread per run; without one its posts go out
  /// as plain messages. [baseUrl] is the deployment's public URL, used to link
  /// the run page from an approval post. Without [issueInteraction] and [bindPost] no approval post
  /// carries buttons.
  new({
    required Future<WorkflowRun?> Function(String runId) lookupRun,
    required ChannelManager channelManager,
    WorkflowChatNotificationsConfig? configured,
    ThreadBindingStore? threadBindings,
    String? baseUrl,
    IssueApprovalInteraction? issueInteraction,
    BindApprovalPost? bindPost,
  }) : _lookupRun = lookupRun,
       _channelManager = channelManager,
       _configured = configured,
       _threadBindings = threadBindings,
       _baseUrl = baseUrl,
       _issueInteraction = issueInteraction,
       _bindPost = bindPost;

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
    final resolved = event is WorkflowApprovalResolvedEvent;
    if (kind == null && !resolved) return;
    final terminal = event is WorkflowRunStatusChangedEvent && event.newStatus.terminal;
    final post = kind != null && _events.contains(kind);
    if (!post && !terminal && !resolved) return;

    // One chain per run keeps its posts in event order and lets the first one
    // open the thread before a later one looks for it; other runs never wait.
    final runId = event.runId;
    final previous = _chains[runId] ?? Future<void>.value();
    late final Future<void> chain;
    chain = previous
        .then((_) async {
          try {
            if (event is WorkflowApprovalResolvedEvent) await _editResolved(event);
            if (terminal) await _editUnresolved(runId);
            if (kind != null && post) await _post(event, kind);
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
        final interaction = await _issue(run, event);
        final post = await _delivery.sendInThread(
          channel,
          threads,
          originRecipient,
          threads.render(_withActions(notification, interaction, run)),
          notification: notification,
          threadId: threadId,
          subject: subject,
        );
        await _bind(run, interaction, channel, originRecipient, post);
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

    final interaction = await _issue(run, event);
    final response = threads.render(_withActions(notification, interaction, run));
    final channelType = channel.type.name;
    final binding = store.lookupByRun(run.id).where((b) => b.channelType == channelType).firstOrNull;
    if (binding != null) {
      final post = await _delivery.sendInThread(
        channel,
        threads,
        configured.recipient,
        response,
        notification: notification,
        threadId: binding.threadId,
        subject: subject,
      );
      await _bind(run, interaction, channel, configured.recipient, post);
      return;
    }
    final post = await _delivery.sendInNewThread(
      channel,
      threads,
      configured.recipient,
      response,
      notification: notification,
      threadKey: 'run-${run.id}',
      subject: subject,
    );
    if (post == null) return;
    await _bind(run, interaction, channel, configured.recipient, post);
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

  /// The interaction to put on an approval post, or `null` for any other post, an approval that is not pending
  /// (one the policy auto-resolved included) and a failed issue.
  Future<WorkflowApprovalInteraction?> _issue(WorkflowRun run, WorkflowLifecycleEvent event) async {
    final issue = _issueInteraction;
    if (issue == null || event is! WorkflowApprovalRequestedEvent) return null;
    try {
      return await issue(run.id, event.stepId);
    } catch (error, stackTrace) {
      _log.warning('Failed to issue the approval interaction of workflow run ${run.id}', error, stackTrace);
      return null;
    }
  }

  ChannelNotification _withActions(
    ChannelNotification notification,
    WorkflowApprovalInteraction? interaction,
    WorkflowRun run,
  ) {
    if (interaction == null) return notification;
    final changesOpen = workflowRevisionState(run)?.isOpen ?? false;
    return ChannelNotification(
      kind: notification.kind,
      id: notification.id,
      text: notification.text,
      title: notification.title,
      status: notification.status,
      body: notification.body,
      error: notification.error,
      requestedBy: notification.requestedBy,
      facts: notification.facts,
      createdAt: notification.createdAt,
      updatedAt: notification.updatedAt,
      actions: [
        for (final action in [
          ChannelRunApprovalAction.approve,
          ChannelRunApprovalAction.reject,
          if (changesOpen) ChannelRunApprovalAction.checkRequestChanges,
        ])
          ChannelNotificationAction(id: action.actionId, label: action.label),
      ],
      actionData: {
        runActionRunIdKey: notification.id,
        runActionStepIdKey: interaction.stepId,
        runActionNonceKey: interaction.nonce,
      },
    );
  }

  /// Binds [post], the message [interaction]'s buttons went out on, so a click on it is accepted.
  Future<void> _bind(
    WorkflowRun run,
    WorkflowApprovalInteraction? interaction,
    Channel channel,
    String recipientId,
    ThreadedPost? post,
  ) async {
    final bind = _bindPost;
    if (interaction == null || post == null || bind == null) return;
    try {
      final bound = await bind(
        run.id,
        nonce: interaction.nonce,
        post: WorkflowApprovalPost(channelType: channel.type.name, recipientId: recipientId, messageId: post.messageId),
      );
      if (!bound) _log.warning('The approval post of workflow run ${run.id} was resolved before it could be bound');
    } catch (error, stackTrace) {
      _log.warning('Failed to bind the approval post of workflow run ${run.id}', error, stackTrace);
    }
  }

  /// Edits the approval post to say who resolved the approval and how.
  Future<void> _editResolved(WorkflowApprovalResolvedEvent event) async {
    final run = await _lookupRun(event.runId);
    final interaction = run == null ? null : WorkflowApprovalInteraction.of(run);
    final resolution = interaction?.resolution;
    if (run == null || interaction == null || resolution == null || interaction.stepId != event.stepId) return;

    final verb = event.changesRequested
        ? 'Changes requested'
        : resolution.approved
        ? 'Approved'
        : 'Rejected';
    final round = event.changesRequested ? ' (${event.revision}/${event.maxRevisions})' : '';
    final name = switch (resolution.source) {
      WorkflowApprovalSource.button => resolution.displayName ?? resolution.senderId,
      _ => resolution.senderId,
    };
    final by = switch (resolution.source) {
      WorkflowApprovalSource.button => name == null ? '' : ' by $name',
      WorkflowApprovalSource.tool => name == null ? ' in chat' : ' by $name in chat',
      WorkflowApprovalSource.web || null => ' from the web UI or API',
    };
    await _edit(
      run,
      interaction,
      '$verb$by$round at ${_clock(resolution.at)}',
      event.changesRequested
          ? 'changes_requested'
          : resolution.approved
          ? 'approved'
          : 'rejected',
    );
  }

  /// Retires the buttons of a run that ended with its approval unresolved.
  Future<void> _editUnresolved(String runId) async {
    final run = await _lookupRun(runId);
    final interaction = run == null ? null : WorkflowApprovalInteraction.of(run);
    if (run == null || interaction == null || interaction.isResolved) return;
    await _edit(run, interaction, 'No longer pending: run ${run.status.name} at ${_clock(DateTime.now())}', 'closed');
  }

  Future<void> _edit(WorkflowRun run, WorkflowApprovalInteraction interaction, String text, String status) async {
    final post = interaction.post;
    if (post == null) return;
    final channel = _channelOf(post.channelType);
    final threads = channel?.threadedNotifications;
    var edited = false;
    Object? failure;
    if (channel != null && threads != null) {
      try {
        edited = await threads.edit(
          post.recipientId,
          post.messageId,
          threads.render(
            ChannelNotification(
              kind: ChannelNotificationKind.run,
              id: run.id,
              text: text,
              title: run.definitionName,
              status: status,
              // Block and card renderings show the body, not the fallback text.
              body: text,
              facts: {'Run': run.id, 'Step': interaction.stepId},
              createdAt: run.startedAt,
              updatedAt: DateTime.now(),
            ),
          ),
        );
      } catch (error) {
        failure = error;
      }
    }
    if (edited || !_editWarned.add(run.id)) return;
    _log.warning(
      'Could not edit the approval post of workflow run ${run.id} in ${post.channelType} ${post.recipientId}'
      '${failure == null ? '' : ' ($failure)'}',
    );
  }

  String _clock(DateTime time) {
    final utc = time.toUtc();
    return '${utc.hour.toString().padLeft(2, '0')}:${utc.minute.toString().padLeft(2, '0')} UTC';
  }

  /// Ends the run's thread binding once its terminal post, if any, has gone out.
  Future<void> _closeRun(String runId) async {
    _delivery.forget('workflow run $runId');
    _editWarned.remove(runId);
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
        final revision = workflowRevisionState(run);
        if (revision != null) {
          facts['Revision'] = '${revision.count} of ${revision.max}';
          if (!revision.isOpen) {
            final limitNote = 'Request changes is not offered: the limit of ${revision.max} revisions is reached.';
            body = body.isEmpty ? limitNote : '$body\n$limitNote';
          }
        }
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
