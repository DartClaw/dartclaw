import 'package:dartclaw_core/dartclaw_core.dart'
    show ChannelReviewError, ChannelReviewHandler, ChannelReviewResult, ChannelReviewSuccess;
import 'package:dartclaw_kernel/dartclaw_kernel.dart' show GovernanceConfig;
import 'package:dartclaw_runtime/src/task/channel_review_gate.dart';
import 'package:test/test.dart';

import '../guard_audit_test_support.dart';

void main() {
  late RecordingGuardAuditLogger audit;
  late List<(String, String, String?, String?)> reviewed;
  late ChannelReviewHandler review;
  var adminSenders = <String>[];

  setUp(() {
    audit = RecordingGuardAuditLogger();
    reviewed = [];
    adminSenders = ['users/admin'];
    review = (taskId, action, {String? comment, String? channelType, String? senderId}) async {
      reviewed.add((taskId, action, channelType, senderId));
      return ChannelReviewSuccess(taskTitle: 'Fix login', action: action);
    };
  });

  ChannelReviewHandler gated({bool withAudit = true}) => adminGatedReviewHandler(
    review,
    isAdmin: GovernanceConfig(adminSenders: adminSenders).isAdmin,
    auditLogger: withAudit ? audit : null,
  );

  test('a non-admin click is refused before the review runs, and the refusal is audited', () async {
    final result = await gated()('task-1', 'accept', channelType: 'googlechat', senderId: 'users/member');

    expect(result, isA<ChannelReviewError>().having((r) => r.message, 'message', contains('admin')));
    expect(reviewed, isEmpty);
    expect(
      audit.entries.map((e) => (e.guard, e.hook, e.tool, e.decision, e.verdict, e.channel, e.peerId, e.principal)),
      [('TaskReviewGate', 'button', 'task_accept', 'deny', 'block', 'googlechat', 'users/member', 'users/member')],
    );
    expect(audit.entries.single.reason, allOf(contains('governance.admin_senders'), contains('task-1')));
  });

  test('an admin click reviews the task, and the decision is audited', () async {
    final result = await gated()('task-2', 'reject', channelType: 'googlechat', senderId: 'users/admin');

    expect(result, isA<ChannelReviewSuccess>());
    expect(reviewed, [('task-2', 'reject', 'googlechat', 'users/admin')]);
    expect(audit.entries.map((e) => (e.tool, e.decision, e.verdict, e.peerId)), [
      ('task_reject', 'allow', 'pass', 'users/admin'),
    ]);
    expect(audit.entries.single.reason, contains('task-2'));
  });

  test('a click with no sender is refused where admin_senders is set and allowed where it is empty', () async {
    final refused = await gated()('task-3', 'accept', channelType: 'googlechat');
    adminSenders = [];
    final allowed = await gated()('task-3', 'accept', channelType: 'googlechat');

    expect(refused, isA<ChannelReviewError>());
    expect(allowed, isA<ChannelReviewSuccess>());
    expect(audit.entries.map((e) => (e.decision, e.peerId)), [('deny', null), ('allow', null)]);
    expect(audit.entries.first.reason, contains('no sender'));
  });

  test('the sender and channel reach the review untouched, never rewritten by the gate', () async {
    final ChannelReviewResult result = await gated()(
      'task-4',
      'accept',
      comment: 'looks good',
      channelType: 'googlechat',
      senderId: 'users/admin',
    );

    expect(result, isA<ChannelReviewSuccess>());
    expect(reviewed.single, ('task-4', 'accept', 'googlechat', 'users/admin'));
  });

  test('a refusal is still answered when no audit logger is wired', () async {
    final result = await gated(withAudit: false)('task-5', 'accept', senderId: 'users/member');

    expect(result, isA<ChannelReviewError>());
    expect(reviewed, isEmpty);
    expect(audit.entries, isEmpty);
  });
}
