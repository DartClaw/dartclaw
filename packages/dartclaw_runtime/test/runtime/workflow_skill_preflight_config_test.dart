import 'package:dartclaw_kernel/dartclaw_kernel.dart';
import 'package:dartclaw_runtime/dartclaw_runtime.dart' show buildWorkflowSkillPreflightConfig;
import 'package:test/test.dart';

void main() {
  const bundled = {'dartclaw-validate-workflow'};

  DartclawConfig configWith({required bool containers, ExecutionMode? taskExecution}) =>
      DartclawConfig.defaults().copyWith(
        container: ContainerConfig(enabled: containers),
        tasks: TaskConfig(execution: taskExecution),
      );

  test('steps placed in containers are checked against the bundled skills only', () {
    final config = buildWorkflowSkillPreflightConfig(configWith(containers: true), bundledSkills: bundled);

    expect(config.containerVisibleSkills, bundled);
  });

  test('steps on the host are probed through the provider', () {
    expect(
      buildWorkflowSkillPreflightConfig(configWith(containers: false), bundledSkills: bundled).containerVisibleSkills,
      isNull,
    );
    expect(
      buildWorkflowSkillPreflightConfig(
        configWith(containers: true, taskExecution: ExecutionMode.host),
        bundledSkills: bundled,
      ).containerVisibleSkills,
      isNull,
    );
  });
}
