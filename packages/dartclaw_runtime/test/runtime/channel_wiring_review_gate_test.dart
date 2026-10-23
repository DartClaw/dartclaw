import 'dart:io';

import 'package:dartclaw_core/dartclaw_core.dart' hide TurnManager, TurnRunner;
import 'package:dartclaw_runtime/src/config/config_load.dart';
import 'package:dartclaw_runtime/src/runtime/channel_wiring.dart';
import 'package:test/test.dart';

import '../guard_audit_test_support.dart';
import 'channel_wiring_test_support.dart';

void main() {
  late Directory tempDir;
  late EventBus eventBus;
  late RecordingGuardAuditLogger audit;
  late ChannelWiring channels;

  setUp(() async {
    tempDir = Directory.systemTemp.createTempSync('dartclaw-channel-review-gate-');
    eventBus = EventBus();
    audit = RecordingGuardAuditLogger();
    final config = loadDartclawConfig(
      configPath: 'dartclaw.yaml',
      fileReader: (path) => path == 'dartclaw.yaml'
          ? 'data_dir: ${tempDir.path}\ngovernance:\n  admin_senders:\n    - users/admin\n'
          : null,
      env: {'HOME': tempDir.path},
    );
    channels = (await wireTestChannels(
      config,
      runtimeCwd: tempDir.path,
      eventBus: eventBus,
      auditLogger: audit,
    )).channels;
  });

  tearDown(() async {
    await eventBus.dispose();
    tempDir.deleteSync(recursive: true);
  });

  // The task service behind the wired handler answers an unknown task with its own message, so an answer that is not
  // the gate's refusal shows the click got past the gate.
  test(
    'the review handler Google Chat holds refuses a non-admin click before the task service and audits it',
    () async {
      final result = await channels.reviewHandler!(
        'no-such-task',
        'accept',
        channelType: 'googlechat',
        senderId: 'users/member',
      );

      expect(result, isA<ChannelReviewError>().having((r) => r.message, 'message', contains('admin')));
      expect(audit.entries.map((e) => (e.guard, e.tool, e.channel, e.peerId, e.decision)), [
        ('TaskReviewGate', 'task_accept', 'googlechat', 'users/member', 'deny'),
      ]);
    },
  );

  test('the same handler lets an admin click through to the task service and audits it', () async {
    final result = await channels.reviewHandler!(
      'no-such-task',
      'accept',
      channelType: 'googlechat',
      senderId: 'users/admin',
    );

    expect(result, isA<ChannelReviewError>().having((r) => r.message, 'message', contains('No task found')));
    expect(audit.entries.map((e) => (e.tool, e.peerId, e.decision)), [('task_accept', 'users/admin', 'allow')]);
  });
}
