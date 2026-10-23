import 'package:dartclaw_kernel/dartclaw_kernel.dart';
import 'package:test/test.dart';

DartclawConfig _load(String yaml, {Map<String, String>? env}) {
  return DartclawConfig.load(
    fileReader: (path) => path == '/home/user/.dartclaw/dartclaw.yaml' ? yaml : null,
    env: env ?? {'HOME': '/home/user'},
  );
}

void main() {
  group('WorkflowConfig', () {
    test('defaults leave workspaceDir unset', () {
      const config = WorkflowConfig.defaults();
      expect(config.workspaceDir, isNull);
      expect(config.defaults.workflow.provider, 'claude');
      expect(config.defaults.reviewer.model, 'claude-opus-5');
      expect(config.cleanup.deleteRemoteBranchOnFailure, isFalse);
      expect(config.approvals, WorkflowApprovalPolicy.manual);
    });

    test('runtime-artifacts retention defaults to disabled', () {
      const config = WorkflowConfig.defaults();
      expect(config.runtimeArtifactsRetention.pruneAfterDays, 0);
      expect(config.runtimeArtifactsRetention.mode, MaintenanceMode.warn);
      expect(config.runtimeArtifactsRetention, const WorkflowRuntimeArtifactsRetentionConfig.defaults());
      expect(config.runtimeArtifactsRetention, const WorkflowConfig.defaults().runtimeArtifactsRetention);
    });

    test('equality includes runtime-artifacts retention', () {
      expect(
        const WorkflowConfig(),
        isNot(
          equals(
            const WorkflowConfig(runtimeArtifactsRetention: WorkflowRuntimeArtifactsRetentionConfig(pruneAfterDays: 7)),
          ),
        ),
      );
    });

    test('equality includes workspaceDir and role defaults', () {
      expect(
        const WorkflowConfig(workspaceDir: '/tmp/workflow'),
        equals(const WorkflowConfig(workspaceDir: '/tmp/workflow')),
      );
      expect(
        const WorkflowConfig(workspaceDir: '/tmp/workflow'),
        isNot(equals(const WorkflowConfig(workspaceDir: '/tmp/other-workflow'))),
      );
      expect(
        const WorkflowConfig(),
        isNot(
          equals(
            const WorkflowConfig(
              defaults: WorkflowRoleDefaultsConfig(workflow: WorkflowRoleModelConfig(provider: 'codex')),
            ),
          ),
        ),
      );
      expect(
        const WorkflowConfig(),
        isNot(equals(const WorkflowConfig(cleanup: WorkflowCleanupConfig(deleteRemoteBranchOnFailure: true)))),
      );
      expect(
        const WorkflowConfig(),
        isNot(equals(const WorkflowConfig(approvals: WorkflowApprovalPolicy.autoOnStall))),
      );
    });
  });

  group('DartclawConfig.load() workflow section', () {
    test('missing workflow section leaves built-in defaults in place', () {
      final config = _load('port: 3000');
      expect(config.workflow, const WorkflowConfig.defaults());
      expect(config.workflow.workspaceDir, isNull);
      expect(config.warnings, isEmpty);
    });

    test('workflow.workspace_dir is parsed and expands leading ~', () {
      final config = _load('''
workflow:
  workspace_dir: ~/workflow-workspace
''');

      expect(config.workflow.workspaceDir, '/home/user/workflow-workspace');
      expect(config.warnings, isEmpty);
    });

    test('workflow.defaults parses role-specific provider/model overrides', () {
      final config = _load('''
workflow:
  defaults:
    workflow:
      provider: codex
      model: gpt-5
    planner:
      model: gpt-5-thinking
    executor:
      provider: claude
    reviewer:
      provider: codex
      model: gpt-5.4
''');

      expect(config.workflow.defaults.workflow.provider, 'codex');
      expect(config.workflow.defaults.workflow.model, 'gpt-5');
      expect(config.workflow.defaults.planner.provider, isNull);
      expect(config.workflow.defaults.planner.model, 'gpt-5-thinking');
      expect(config.workflow.defaults.executor.provider, 'claude');
      expect(config.workflow.defaults.executor.model, isNull);
      expect(config.workflow.defaults.reviewer.provider, 'codex');
      expect(config.workflow.defaults.reviewer.model, 'gpt-5.4');
      expect(config.warnings, isEmpty);
    });

    test('workflow.defaults model shorthand populates provider and model', () {
      final config = _load('''
workflow:
  defaults:
    reviewer:
      model: claude/opus
    executor:
      model: codex/gpt-5.4-mini
''');

      expect(config.workflow.defaults.reviewer.provider, 'claude');
      expect(config.workflow.defaults.reviewer.model, 'opus');
      expect(config.workflow.defaults.executor.provider, 'codex');
      expect(config.workflow.defaults.executor.model, 'gpt-5.4-mini');
      expect(config.warnings, isEmpty);
    });

    test('workflow.defaults rejects a blank role provider', () {
      expect(
        () => _load('''
workflow:
  defaults:
    reviewer:
      provider: " "
'''),
        throwsA(isA<FormatException>().having((error) => error.message, 'message', contains('reviewer.provider'))),
      );
    });

    test('workflow.cleanup.delete_remote_branch_on_failure parses bool', () {
      final config = _load('''
workflow:
  cleanup:
    delete_remote_branch_on_failure: true
''');

      expect(config.workflow.cleanup.deleteRemoteBranchOnFailure, isTrue);
      expect(config.warnings, isEmpty);
    });

    test('workflow.approvals parses the approval policy enum', () {
      final config = _load('''
workflow:
  approvals: auto-on-stall
''');

      expect(config.workflow.approvals, WorkflowApprovalPolicy.autoOnStall);
      expect(config.warnings, isEmpty);
    });

    test('workflow.approvals rejects unknown values and falls back to manual', () {
      final config = _load('''
workflow:
  approvals: bogus
''');

      expect(config.workflow.approvals, WorkflowApprovalPolicy.manual);
      expect(config.warnings, anyElement(contains('Invalid value for workflow.approvals')));
      expect(config.warnings.single, contains('manual, auto-on-stall, auto'));
    });

    test('absent runtime_artifacts_retention section yields the disabled default', () {
      final config = _load('port: 3000');
      expect(config.workflow.runtimeArtifactsRetention, const WorkflowRuntimeArtifactsRetentionConfig.defaults());
      expect(config.workflow.runtimeArtifactsRetention.pruneAfterDays, 0);
      expect(config.warnings, isEmpty);
    });

    test('workflow.runtime_artifacts_retention parses mode and prune_after_days', () {
      final config = _load('''
workflow:
  runtime_artifacts_retention:
    mode: enforce
    prune_after_days: 7
''');

      expect(config.workflow.runtimeArtifactsRetention.mode, MaintenanceMode.enforce);
      expect(config.workflow.runtimeArtifactsRetention.pruneAfterDays, 7);
      expect(config.warnings, isEmpty);
    });

    test('workflow.runtime_artifacts_retention rejects an invalid mode and prune value', () {
      final config = _load('''
workflow:
  runtime_artifacts_retention:
    mode: bogus
    prune_after_days: -3
''');

      expect(config.workflow.runtimeArtifactsRetention.mode, MaintenanceMode.warn);
      expect(config.workflow.runtimeArtifactsRetention.pruneAfterDays, 0);
      expect(config.warnings, anyElement(contains('runtime_artifacts_retention.mode')));
      expect(config.warnings, anyElement(contains('runtime_artifacts_retention.prune_after_days')));
    });

    test('workflow.chat_notifications is null when the block is absent', () {
      final config = _load('port: 3000');
      expect(config.workflow.chatNotifications, isNull);
      expect(config.warnings, isEmpty);
    });

    test('workflow.chat_notifications with channel and recipient only posts the default four events', () {
      final config = _load('''
workflow:
  chat_notifications:
    channel: slack
    recipient: C0123ABC
''');

      expect(
        config.workflow.chatNotifications,
        const WorkflowChatNotificationsConfig(channel: ChannelType.slack, recipient: 'C0123ABC'),
      );
      expect(config.workflow.chatNotifications!.events, {
        WorkflowChatNotificationEvent.started,
        WorkflowChatNotificationEvent.awaitingApproval,
        WorkflowChatNotificationEvent.finished,
        WorkflowChatNotificationEvent.failed,
      });
      expect(config.warnings, isEmpty);
    });

    test('workflow.chat_notifications.events narrows to the listed subset', () {
      final config = _load('''
workflow:
  chat_notifications:
    channel: googlechat
    recipient: spaces/AAAA
    events: [finished]
''');

      expect(config.workflow.chatNotifications!.channel, ChannelType.googlechat);
      expect(config.workflow.chatNotifications!.events, {WorkflowChatNotificationEvent.finished});
      expect(config.warnings, isEmpty);
    });

    test('workflow.chat_notifications.events opts in to step_completed and collapses duplicates', () {
      final config = _load('''
workflow:
  chat_notifications:
    channel: signal
    recipient: "+46700000000"
    events: [started, step_completed, started, failed]
''');

      expect(config.workflow.chatNotifications!.events, {
        WorkflowChatNotificationEvent.started,
        WorkflowChatNotificationEvent.stepCompleted,
        WorkflowChatNotificationEvent.failed,
      });
      expect(config.warnings, isEmpty);
    });

    test('workflow.chat_notifications equality and hashCode follow the event set, not its order', () {
      const a = WorkflowChatNotificationsConfig(
        channel: ChannelType.slack,
        recipient: 'C1',
        events: {WorkflowChatNotificationEvent.started, WorkflowChatNotificationEvent.failed},
      );
      const b = WorkflowChatNotificationsConfig(
        channel: ChannelType.slack,
        recipient: 'C1',
        events: {WorkflowChatNotificationEvent.failed, WorkflowChatNotificationEvent.started},
      );
      expect(a, b);
      expect(a.hashCode, b.hashCode);
      expect(const WorkflowConfig(chatNotifications: a), isNot(const WorkflowConfig()));
      expect(const WorkflowConfig(chatNotifications: a), const WorkflowConfig(chatNotifications: b));
    });

    final invalidBlocks = <String, ({String yaml, String key, List<String> mentions})>{
      'an unknown event name': (
        yaml: '''
workflow:
  chat_notifications:
    channel: slack
    recipient: C1
    events: [finished, bogus]
''',
        key: 'workflow.chat_notifications.events',
        mentions: ['"bogus"', 'awaiting_approval', 'step_completed'],
      ),
      'a non-string event': (
        yaml: '''
workflow:
  chat_notifications:
    channel: slack
    recipient: C1
    events: [finished, 3]
''',
        key: 'workflow.chat_notifications.events',
        mentions: ['"3"'],
      ),
      'an empty events list': (
        yaml: '''
workflow:
  chat_notifications:
    channel: slack
    recipient: C1
    events: []
''',
        key: 'workflow.chat_notifications.events',
        mentions: ['empty list'],
      ),
      'a non-list events value': (
        yaml: '''
workflow:
  chat_notifications:
    channel: slack
    recipient: C1
    events: finished
''',
        key: 'workflow.chat_notifications.events',
        mentions: ['"String"'],
      ),
      'a channel outside the notification channels': (
        yaml: '''
workflow:
  chat_notifications:
    channel: telegram
    recipient: C1
''',
        key: 'workflow.chat_notifications.channel',
        mentions: ['"telegram"', 'whatsapp, signal, googlechat, slack'],
      ),
      'the web channel': (
        yaml: '''
workflow:
  chat_notifications:
    channel: web
    recipient: C1
''',
        key: 'workflow.chat_notifications.channel',
        mentions: ['"web"'],
      ),
      'a non-string channel': (
        yaml: '''
workflow:
  chat_notifications:
    channel: 7
    recipient: C1
''',
        key: 'workflow.chat_notifications.channel',
        mentions: ['"int"'],
      ),
      'a missing channel': (
        yaml: '''
workflow:
  chat_notifications:
    recipient: C1
''',
        key: 'workflow.chat_notifications.channel',
        mentions: ['Missing', 'slack'],
      ),
      'a missing recipient': (
        yaml: '''
workflow:
  chat_notifications:
    channel: slack
''',
        key: 'workflow.chat_notifications.recipient',
        mentions: ['Missing'],
      ),
      'a blank recipient': (
        yaml: '''
workflow:
  chat_notifications:
    channel: slack
    recipient: "   "
''',
        key: 'workflow.chat_notifications.recipient',
        mentions: ['Missing'],
      ),
      'a non-string recipient': (
        yaml: '''
workflow:
  chat_notifications:
    channel: slack
    recipient: 12345
''',
        key: 'workflow.chat_notifications.recipient',
        mentions: ['"int"'],
      ),
      'a non-map block': (
        yaml: '''
workflow:
  chat_notifications: slack
''',
        key: 'workflow.chat_notifications',
        mentions: ['"String"'],
      ),
      'two defects in one block': (
        yaml: '''
workflow:
  chat_notifications:
    channel: telegram
    events: [bogus]
''',
        key: 'workflow.chat_notifications.channel',
        mentions: ['"telegram"'],
      ),
    };
    for (final entry in invalidBlocks.entries) {
      test('workflow.chat_notifications with ${entry.key} is ignored with one warning', () {
        final config = _load(entry.value.yaml);

        expect(config.workflow.chatNotifications, isNull);
        expect(config.warnings, hasLength(1), reason: config.warnings.join('\n'));
        expect(config.warnings.single, contains(entry.value.key));
        expect(config.warnings.single, endsWith('– ignoring workflow.chat_notifications'));
        for (final mention in entry.value.mentions) {
          expect(config.warnings.single, contains(mention));
        }
      });
    }

    for (final value in ['-1', 'wrong']) {
      test('workflow.runtime_artifacts_retention keeps its fused prune warning for $value', () {
        final config = _load('''
workflow:
  runtime_artifacts_retention:
    prune_after_days: $value
''');

        expect(config.workflow.runtimeArtifactsRetention.pruneAfterDays, 0);
        expect(config.warnings, [
          'Invalid value for workflow.runtime_artifacts_retention.prune_after_days: "$value" '
              '(expected a non-negative integer) — using default 0 (disabled)',
        ]);
      });
    }
  });
}
