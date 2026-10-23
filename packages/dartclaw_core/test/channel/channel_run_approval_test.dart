import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:test/test.dart';

void main() {
  group('ChannelRunApprovalAction', () {
    test('every action round-trips through the ID a channel renders and reads back', () {
      for (final action in ChannelRunApprovalAction.values) {
        expect(ChannelRunApprovalAction.fromActionId(action.actionId), action);
      }
    });

    test('every action carries a distinct fixed ID the adapters register', () {
      expect(ChannelRunApprovalAction.approve.actionId, runApproveActionId);
      expect(ChannelRunApprovalAction.reject.actionId, runRejectActionId);
      expect(ChannelRunApprovalAction.checkRequestChanges.actionId, runRequestChangesActionId);
      expect(ChannelRunApprovalAction.requestChanges.actionId, runRequestChangesSubmitActionId);
      expect(ChannelRunApprovalAction.values.map((action) => action.actionId).toSet(), hasLength(4));
    });

    test('a click on the Request changes button is the check, and the form submission is the request', () {
      expect(
        ChannelRunApprovalAction.fromActionId(runRequestChangesActionId),
        ChannelRunApprovalAction.checkRequestChanges,
      );
      expect(
        ChannelRunApprovalAction.fromActionId(runRequestChangesSubmitActionId),
        ChannelRunApprovalAction.requestChanges,
      );
    });

    test('an unknown or absent action ID is not a run action', () {
      expect(ChannelRunApprovalAction.fromActionId('task_accept'), isNull);
      expect(ChannelRunApprovalAction.fromActionId(null), isNull);
    });
  });

  group('ChannelRunApprovalResult', () {
    test('an adapter must handle permitted, resolved, refused and failed, and nothing else', () {
      String answer(ChannelRunApprovalResult result) => switch (result) {
        ChannelRunApprovalPermitted() => 'permitted',
        ChannelRunApprovalResolved() => 'resolved',
        ChannelRunApprovalRefused(:final message) => 'refused: $message',
        ChannelRunApprovalFailed(:final message) => 'failed: $message',
      };

      expect(answer(const ChannelRunApprovalPermitted()), 'permitted');
      expect(answer(const ChannelRunApprovalResolved()), 'resolved');
      expect(
        answer(const ChannelRunApprovalRefused(ChannelRunApprovalRefusal.notAdmin, 'admins only')),
        'refused: admins only',
      );
      expect(answer(const ChannelRunApprovalFailed('try again')), 'failed: try again');
    });
  });

  group('ChannelNotification actions', () {
    test('a notification carries no actions unless it is given some', () {
      const notification = ChannelNotification(
        kind: ChannelNotificationKind.run,
        id: 'run-1',
        text: 't',
        title: 'wf',
        status: 'awaiting_approval',
      );

      expect(notification.actions, isEmpty);
      expect(notification.actionData, isEmpty);
    });

    test('two labelled actions share one payload', () {
      const notification = ChannelNotification(
        kind: ChannelNotificationKind.run,
        id: 'run-1',
        text: 't',
        title: 'wf',
        status: 'awaiting_approval',
        actions: [
          ChannelNotificationAction(id: runApproveActionId, label: 'Approve'),
          ChannelNotificationAction(id: runRejectActionId, label: 'Reject'),
        ],
        actionData: {runActionRunIdKey: 'run-1', runActionStepIdKey: 'gate', runActionNonceKey: 'abc'},
      );

      expect(notification.actions.map((a) => a.label), ['Approve', 'Reject']);
      expect(notification.actionData[runActionNonceKey], 'abc');
    });
  });
}
