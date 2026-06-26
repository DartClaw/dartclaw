import 'package:dartclaw_config/dartclaw_config.dart';
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
      expect(config.defaults.reviewer.model, 'claude-opus-4');
      expect(config.cleanup.deleteRemoteBranchOnFailure, isFalse);
      expect(config.approvals, WorkflowApprovalPolicy.manual);
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
  });
}
