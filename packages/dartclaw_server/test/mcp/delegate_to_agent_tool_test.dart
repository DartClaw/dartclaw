import 'dart:io';

import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:dartclaw_server/src/mcp/delegate_to_agent_tool.dart';
import 'package:test/test.dart';

import 'delegate_to_agent_test_support.dart';

void main() {
  group('DelegateToAgentTool preflight and schema', () {
    test('preflight rejects invalid requests before spawn', () async {
      final runner = FakeDelegationRunner(providerId: 'goose');
      final pool = FakeDelegationPool({'goose': runner});

      final disabled = DelegateToAgentTool(
        config: delegationConfig(enabled: false),
        pool: pool,
        workspaceDir: '/tmp/ws',
      );
      expect((await callDelegate(disabled, {'agent_id': 'goose', 'task': 'x'}))['code'], 'DELEGATION_DISABLED');

      final tool = DelegateToAgentTool(config: delegationConfig(), pool: pool, workspaceDir: '/tmp/ws');
      expect((await callDelegate(tool, {'agent_id': 'codex', 'task': 'x'}))['code'], 'AGENT_NOT_ALLOWLISTED');
      expect(
        (await callDelegate(tool, {'agent_id': 'missing_acp_agent', 'task': 'x'}))['code'],
        'AGENT_NOT_ALLOWLISTED',
      );
      expect((await callDelegate(tool, {'agent_id': 'goose', 'task': '   '}))['code'], 'EMPTY_TASK');
      expect(
        (await callDelegate(tool, {'agent_id': 'goose', 'task': 'x', 'work_dir': '/etc'}))['code'],
        'INVALID_WORK_DIR',
      );
      expect(pool.acquisitions, isEmpty);
      expect(runner.reserveCount, 0);
    });

    test('relative work_dir is jailed under workspace', () async {
      final runner = FakeDelegationRunner(providerId: 'goose');
      final tool = DelegateToAgentTool(
        config: delegationConfig(),
        pool: FakeDelegationPool({'goose': runner}),
        workspaceDir: '/tmp/ws',
      );

      final result = await callDelegate(tool, {'agent_id': 'goose', 'task': 'x', 'work_dir': 'packages/app'});

      expect(result['status'], 'completed');
      expect(runner.directory, '/tmp/ws/packages/app');
    });

    test('work_dir symlink escapes are rejected before spawn', () async {
      final temp = Directory.systemTemp.createTempSync('delegate_work_dir_');
      addTearDown(() => temp.deleteSync(recursive: true));
      final workspace = Directory('${temp.path}/workspace')..createSync();
      final outside = Directory('${temp.path}/outside')..createSync();
      Link('${workspace.path}/escape').createSync(outside.path);
      final runner = FakeDelegationRunner(providerId: 'goose');
      final pool = FakeDelegationPool({'goose': runner});
      final tool = DelegateToAgentTool(config: delegationConfig(), pool: pool, workspaceDir: workspace.path);

      final result = await callDelegate(tool, {'agent_id': 'goose', 'task': 'x', 'work_dir': 'escape'});

      expect(result['code'], 'INVALID_WORK_DIR');
      expect(pool.acquisitions, isEmpty);
      expect(runner.reserveCount, 0);
    });

    test('broken work_dir symlinks are rejected before spawn', () async {
      final temp = Directory.systemTemp.createTempSync('delegate_broken_work_dir_');
      addTearDown(() => temp.deleteSync(recursive: true));
      final workspace = Directory('${temp.path}/workspace')..createSync();
      Link('${workspace.path}/missing').createSync('${temp.path}/does-not-exist');
      final runner = FakeDelegationRunner(providerId: 'goose');
      final pool = FakeDelegationPool({'goose': runner});
      final tool = DelegateToAgentTool(config: delegationConfig(), pool: pool, workspaceDir: workspace.path);

      final result = await callDelegate(tool, {'agent_id': 'goose', 'task': 'x', 'work_dir': 'missing'});

      expect(result['code'], 'INVALID_WORK_DIR');
      expect(pool.acquisitions, isEmpty);
      expect(runner.reserveCount, 0);
    });

    test('schema requires agent_id and task with optional work_dir', () {
      final tool = DelegateToAgentTool(
        config: delegationConfig(),
        pool: FakeDelegationPool({'goose': FakeDelegationRunner(providerId: 'goose')}),
        workspaceDir: '/tmp/ws',
      );

      expect(tool.name, 'delegate_to_agent');
      expect(tool.inputSchema['additionalProperties'], isFalse);
      expect(tool.inputSchema['required'], containsAll(['agent_id', 'task']));
      expect((tool.inputSchema['properties'] as Map<String, dynamic>), contains('work_dir'));
    });

    test('completed result is JSON text', () async {
      final tool = DelegateToAgentTool(
        config: delegationConfig(),
        pool: FakeDelegationPool({'goose': FakeDelegationRunner(providerId: 'goose')}),
        workspaceDir: '/tmp/ws',
      );

      final result = await tool.call({'agent_id': 'goose', 'task': 'research X'});

      expect(result, isA<ToolResultText>());
      final decoded = await callDelegate(tool, {'agent_id': 'goose', 'task': 'research X'});
      expect(decoded['status'], 'completed');
      expect(decoded['security_mode'], 'guard_mediated');
      expect(decoded['output'], 'delegated output');
      expect(decoded['usage'], containsPair('budget_limit', 50000));
      expect(decoded['budget_status'], 'within_budget');
      expect(decoded['budget_enforcement'], 'strict');
    });
  });
}
