import 'dart:async';
import 'dart:io';

import 'package:dartclaw_kernel/dartclaw_kernel.dart';
import 'package:dartclaw_runtime/src/container/container_manager.dart';
import 'package:dartclaw_testing/dartclaw_testing.dart';
import 'package:test/test.dart';

void main() {
  test('temporary authority retains foreground root stdin and uses generated-state tmpfs', () async {
    final commands = <List<String>>[];
    final lifetime = FakeProcess();
    var inspectCount = 0;
    final manager = ContainerManager(
      config: const ContainerConfig(enabled: true),
      containerName: 'dartclaw-temporary-test',
      ownerLabel: 'dartclaw.data-dir=/tmp/test',
      profileId: 'workspace',
      workspaceMounts: const ['/tmp/project:/project:rw'],
      generatedStateDir: '/tmp/must-not-be-created',
      volatileGeneratedState: true,
      runCommand: (_, arguments) async {
        commands.add(arguments);
        if (arguments.first == 'inspect') {
          inspectCount++;
          return ProcessResult(0, inspectCount == 1 ? 1 : 0, '', 'No such container');
        }
        return ProcessResult(0, 0, '', '');
      },
      startCommand: (_, arguments, {workingDirectory, environment, includeParentEnvironment = true}) async {
        commands.add(arguments);
        return lifetime;
      },
    );

    await manager.start();
    final run = commands.singleWhere((command) => command.first == 'run');
    expect(run, containsAllInOrder(['run', '--rm', '-i', '-a', 'stdin']));
    expect(run, contains('cat'));
    expect(run.where((argument) => argument.contains('/home/dartclaw/.dartclaw')), hasLength(1));
    expect(run.any((argument) => argument.contains('/tmp/must-not-be-created')), isFalse);

    scheduleMicrotask(() => lifetime.exit(0));
    await manager.stop();
    expect(commands.where((command) => command.first == 'rm'), hasLength(1));
  });
}
