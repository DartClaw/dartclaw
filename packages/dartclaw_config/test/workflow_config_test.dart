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
  });
}
