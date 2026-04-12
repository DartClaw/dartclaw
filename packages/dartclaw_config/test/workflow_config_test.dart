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
    });

    test('equality includes workspaceDir', () {
      expect(
        const WorkflowConfig(workspaceDir: '/tmp/workflow'),
        equals(const WorkflowConfig(workspaceDir: '/tmp/workflow')),
      );
      expect(
        const WorkflowConfig(workspaceDir: '/tmp/workflow'),
        isNot(equals(const WorkflowConfig(workspaceDir: '/tmp/other-workflow'))),
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
  });
}
