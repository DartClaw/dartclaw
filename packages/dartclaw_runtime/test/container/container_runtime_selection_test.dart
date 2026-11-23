import 'dart:async';
import 'dart:io';

import 'package:dartclaw_kernel/dartclaw_kernel.dart';
import 'package:dartclaw_runtime/dartclaw_runtime.dart';
import 'package:test/test.dart';

/// A runtime probe that answers only for the binaries in [available].
RunCommand _probe(Set<String> available, {List<String>? seen}) => (executable, arguments) async {
  seen?.add('$executable ${arguments.join(' ')}');
  if (!available.contains(executable)) throw ProcessException(executable, arguments, 'No such file or directory', 2);
  return ProcessResult(0, 0, '', '');
};

void main() {
  final posix = PlatformCapabilities(operatingSystem: 'linux');
  const enabled = DartclawConfig(container: ContainerConfig(enabled: true));

  group('a config that did not turn containers on is never probed', () {
    for (final (label, config) in [
      ('no container section', const DartclawConfig()),
      ('an explicit false', const DartclawConfig(container: ContainerConfig(enabled: false))),
    ]) {
      test('$label runs no process even where a runtime would answer', () async {
        final seen = <String>[];
        final selected = await selectContainerRuntime(
          config,
          platformCapabilities: posix,
          runCommand: _probe({'docker', 'podman'}, seen: seen),
        );

        expect(seen, isEmpty);
        expect(selected, same(config));
        expect(selected.container.enabled, isFalse);
      });
    }
  });

  group('an enabled config selects the runtime that answers', () {
    test('docker is preferred when it answers', () async {
      final selected = await selectContainerRuntime(
        enabled,
        platformCapabilities: posix,
        runCommand: _probe({'docker'}),
      );

      expect(selected.container.enabled, isTrue);
      expect(selected.container.runtimeBinary, 'docker');
    });

    test('podman is selected when only podman answers', () async {
      final seen = <String>[];
      final selected = await selectContainerRuntime(
        enabled,
        platformCapabilities: posix,
        runCommand: _probe({'podman'}, seen: seen),
      );

      expect(selected.container.enabled, isTrue);
      expect(selected.container.runtimeBinary, 'podman');
      expect(seen, ['docker version', 'podman version']);
    });

    test('the selected binary is the one every subsequent runtime call uses', () async {
      final selected = await selectContainerRuntime(
        enabled,
        platformCapabilities: posix,
        runCommand: _probe({'podman'}),
      );
      final calls = <String>[];
      final manager = ContainerManager(
        ownerLabel: 'dartclaw.data-dir=test1234',
        config: selected.container,
        containerName: 'dartclaw-test',
        profileId: 'restricted',
        workspaceMounts: const [],
        generatedStateDir: '/tmp/dartclaw-test',
        buildContextDir: '/tmp/dartclaw-test',
        runCommand: _probe({'podman'}, seen: calls),
      );

      await manager.isRuntimeAvailable();

      expect(calls, ['podman version']);
    });

    test('no answering runtime leaves the config as it is, still enabled, so wiring refuses it', () async {
      final selected = await selectContainerRuntime(enabled, platformCapabilities: posix, runCommand: _probe(const {}));

      expect(selected, same(enabled));
      expect(selected.container.enabled, isTrue);
      expect(selected.container.runtimeBinary, 'docker', reason: 'the refusal must name the runtime it looked for');
    });

    // A wedged daemon never returns rather than erroring, and this probe runs
    // before serve binds a port; the probe timeout is what turns it into a
    // refusal instead of a hung startup.
    test('a runtime that never answers does not hang selection', () async {
      final selected = await selectContainerRuntime(
        enabled,
        platformCapabilities: posix,
        runCommand: (_, _) => Completer<ProcessResult>().future,
      ).timeout(const Duration(seconds: 30));

      expect(selected, same(enabled));
    });

    test('native Windows is never probed', () async {
      final seen = <String>[];
      final selected = await selectContainerRuntime(
        enabled,
        platformCapabilities: PlatformCapabilities(operatingSystem: 'windows'),
        runCommand: _probe({'docker'}, seen: seen),
      );

      expect(selected, same(enabled));
      expect(seen, isEmpty, reason: 'the platform gate precedes any runtime detection');
    });
  });
}
